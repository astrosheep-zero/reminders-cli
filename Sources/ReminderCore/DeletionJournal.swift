import Foundation
import Darwin

public struct DeletionEntry: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case pending, confirmed
    }

    public var id: String
    public var title: String
    public var listID: String
    public var parentID: String?
    public var time: Date
    public var state: State

    public init(id: String, title: String, listID: String, parentID: String?, time: Date, state: State) {
        self.id = id
        self.title = title
        self.listID = listID
        self.parentID = parentID
        self.time = time
        self.state = state
    }
}

/// Serializes cooperating processes using a stable sibling lock, never the replaced file's inode.
public final class DeletionJournal {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemindersCLI", isDirectory: true)
            .appendingPathComponent("deleted.json")
    }

    private let url: URL

    public init(url: URL = DeletionJournal.defaultURL) {
        self.url = url
    }

    /// The lock covers load, the caller's mutation, and durable atomic replacement.
    /// A throwing body leaves the journal unchanged. Do not reenter this journal from the body.
    public func transaction<T>(_ body: (inout [DeletionEntry]) throws -> T) throws -> T {
        try withLock {
            var entries = try load()
            let result = try body(&entries)
            try persist(entries)
            return result
        }
    }

    /// May create the directory and sibling lock, but never creates or rewrites the journal.
    public func read() throws -> [DeletionEntry] {
        try withLock { try load() }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        try retry { flock(fd, LOCK_EX) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func load() throws -> [DeletionEntry] {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return [] }
            throw posixError()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode([DeletionEntry].self, from: data)
    }

    private func persist(_ entries: [DeletionEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        let directory = url.deletingLastPathComponent()
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError() }
        defer { close(directoryFD) }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer {
            close(fd)
            _ = unlink(temporary.path)
        }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        try retry { fsync(fd) }
        // On Darwin, also flush the drive's volatile write cache before publishing intent.
        try retry { fcntl(fd, F_FULLFSYNC) }
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        // If this fails, replacement may already be visible; callers must not assume rollback.
        try retry { fsync(directoryFD) }
    }

    private func retry(_ operation: () -> Int32) throws {
        while operation() != 0 {
            if errno != EINTR { throw posixError() }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
