import Foundation
import Darwin
import Testing
@testable import ReminderCore

struct DeletionJournalTests {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("private/deleted.json"))
    }

    private func entry(_ id: String = "reminder") -> DeletionEntry {
        DeletionEntry(id: id, title: "Title 🦈", listID: "list", parentID: "parent",
                      time: Date(timeIntervalSince1970: 1_700_000_000), state: .pending)
    }

    @Test func absentReadAndPersistenceRoundTrip() throws {
        try withFixture { url in
            let journal = DeletionJournal(url: url)
            #expect(try journal.read().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let original = entry()
            let result = try journal.transaction { entries in
                entries.append(original)
                return "persisted"
            }
            #expect(result == "persisted")
            #expect(try DeletionJournal(url: url).read() == [original])
            try journal.transaction { entries in
                entries[0].state = .confirmed
                entries[0].parentID = nil
            }
            var confirmed = original
            confirmed.state = .confirmed
            confirmed.parentID = nil
            #expect(try DeletionJournal(url: url).read() == [confirmed])
            let before = try Data(contentsOf: url)
            #expect(try journal.read() == [confirmed])
            #expect(try Data(contentsOf: url) == before)
            try journal.transaction { $0.removeAll() }
            #expect(try journal.read().isEmpty)
        }
    }

    @Test func restrictiveDirectoryAndReplacementPermissions() throws {
        try withFixture { url in
            let journal = DeletionJournal(url: url)
            try journal.transaction { $0.append(entry()) }
            func mode(_ path: URL) throws -> Int {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
            }
            #expect(try mode(url.deletingLastPathComponent()) == 0o700)
            #expect(try mode(url) == 0o600)
            #expect(try mode(url.appendingPathExtension("lock")) == 0o600)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try journal.transaction { $0.append(entry("second")) }
            #expect(try mode(url) == 0o600)
            let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            #expect(Set(siblings) == ["deleted.json", "deleted.json.lock"])
        }
    }

    @Test func throwingBodyPreservesExistingBytes() throws {
        enum Stop: Error { case requested }
        try withFixture { url in
            let journal = DeletionJournal(url: url)
            try journal.transaction { $0.append(entry()) }
            let before = try Data(contentsOf: url)
            #expect(throws: Stop.self) {
                try journal.transaction { entries in
                    entries.removeAll()
                    throw Stop.requested
                }
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(try journal.read() == [entry()])
        }
    }

    @Test func malformedJournalIsNotTreatedAsEmptyOrOverwritten() throws {
        try withFixture { url in
            let journal = DeletionJournal(url: url)
            _ = try journal.read()
            for text in ["", "not json", "null", "{}", "[{\"id\":\"incomplete\"}]"] {
                let bytes = Data(text.utf8)
                try bytes.write(to: url)
                #expect(throws: (any Error).self) { try journal.read() }
                var called = false
                #expect(throws: (any Error).self) { try journal.transaction { _ in called = true } }
                #expect(!called)
                #expect(try Data(contentsOf: url) == bytes)
            }
        }
    }

    @Test(.enabled(if: getuid() != 0, "Root bypasses mode-based read denial"))
    func unreadableExistingJournalIsRejected() throws {
        try withFixture { url in
            let journal = DeletionJournal(url: url)
            try journal.transaction { $0.append(entry()) }
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            #expect(throws: (any Error).self) { try journal.read() }
            var called = false
            #expect(throws: (any Error).self) { try journal.transaction { _ in called = true } }
            #expect(!called)
        }
    }

    @Test(.enabled(if: getuid() != 0, "Root bypasses mode-based write denial"))
    func persistenceFailurePropagatesAndPreservesJournal() throws {
        try withFixture { url in
            let journal = DeletionJournal(url: url)
            try journal.transaction { $0.append(entry()) }
            let bytes = try Data(contentsOf: url)
            let directory = url.deletingLastPathComponent().path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
            var called = false
            #expect(throws: (any Error).self) {
                try journal.transaction { entries in
                    called = true
                    entries.removeAll()
                }
            }
            #expect(called)
            #expect(try journal.read() == [entry()])
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func nonRegularJournalAndInvalidParentAreRejected() throws {
        try withFixture { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let journal = DeletionJournal(url: url)
            #expect(throws: (any Error).self) { try journal.read() }
            #expect(throws: (any Error).self) { try journal.transaction { $0.removeAll() } }
        }
        try withFixture { url in
            try Data("parent is a file".utf8).write(to: url.deletingLastPathComponent())
            let journal = DeletionJournal(url: url)
            #expect(throws: (any Error).self) { try journal.read() }
            #expect(throws: (any Error).self) { try journal.transaction { $0.removeAll() } }
        }
    }

    @Test func crossProcessUpdatesDoNotLoseEntries() throws {
        try withFixture { url in
            var children: [(Process, Pipe)] = []
            defer { for (process, _) in children where process.isRunning { process.terminate(); process.waitUntilExit() } }
            for index in 0..<4 {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                var arguments = Array(CommandLine.arguments.dropFirst())
                if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
                    arguments[filter + 1] = "DeletionJournalTests/journalChildProcess"
                } else {
                    arguments += ["--filter", "DeletionJournalTests/journalChildProcess"]
                }
                child.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["DELETION_JOURNAL_CHILD_URL"] = url.path
                environment["DELETION_JOURNAL_CHILD_ID"] = String(index)
                child.environment = environment
                let output = Pipe()
                child.standardOutput = output
                child.standardError = output
                try child.run()
                children.append((child, output))
            }
            for (child, output) in children {
                child.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(child.terminationStatus == 0, "\(text)")
            }
            let entries = try DeletionJournal(url: url).read()
            let expected = Set((0..<4).flatMap { child in (0..<30).map { "\(child)-\($0)" } })
            #expect(entries.count == expected.count)
            #expect(Set(entries.map(\.id)) == expected)
        }
    }

    // Independent test-runner processes, never forked from a multithreaded runtime.
    @Test func journalChildProcess() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DELETION_JOURNAL_CHILD_URL"],
              let child = environment["DELETION_JOURNAL_CHILD_ID"] else { return }
        let journal = DeletionJournal(url: URL(fileURLWithPath: path))
        for iteration in 0..<30 {
            try journal.transaction { entries in
                usleep(1_000) // Widen the read-modify-write race if the process lock is missing.
                entries.append(entry("\(child)-\(iteration)"))
            }
        }
    }
}
