import Foundation
import Testing
import ReminderCore
@testable import ReminderCLI
@testable import ReminderFacade

struct DoctorAndTextTests {
    @Test func doctorProbesOnlyWithPriorFullAccessAndNeverPrompts() {
        var probes = 0
        let inspection: (URL) -> (DiagnosticCheck, DiagnosticCheck) = { _ in
            (.init(status: .passed, message: "fixture bundle"), .init(status: .unverified, message: "fixture signature"))
        }
        for authorization in ["notDetermined", "denied", "restricted", "writeOnly", "unavailable"] {
            let result = Doctor.diagnose(authorization: authorization, capabilities: [], allowProbe: true, inspectBundle: inspection) { probes += 1 }
            #expect(result.readProbe.status == .skipped)
        }
        let setup = Doctor.diagnose(authorization: "fullAccess", capabilities: [], allowProbe: false, inspectBundle: inspection) { probes += 1 }
        #expect(setup.readProbe.status == .skipped); #expect(probes == 0)
        let authorized = Doctor.diagnose(authorization: "fullAccess", capabilities: [], allowProbe: true, inspectBundle: inspection) { probes += 1 }
        #expect(authorized.readProbe.status == .passed); #expect(probes == 1)
        #expect(authorized.tccOwnership.status == .unverified)
        let failure = Doctor.diagnose(authorization: "fullAccess", capabilities: [], allowProbe: true, inspectBundle: inspection) { throw Failure(.permission, "Fixture attribution denied") }
        #expect(failure.readProbe.status == .failed); #expect(failure.readProbe.error?.code == .permission)
    }
    @Test func bundleIdentityAndSignatureAreSeparateChecks() throws {
        struct Metadata: Encodable {
            let CFBundleIdentifier = "fixture.reminder"
            let CFBundleExecutable = "reminder"
            let ReminderBuildID = "fixture-build"
            let NSRemindersFullAccessUsageDescription = "Fixture usage"
            let LSUIElement = true
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-doctor-\(UUID())")
        let app = directory.appendingPathComponent("Fixture.app"), contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/reminder")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: executable)
        try PropertyListEncoder().encode(Metadata()).write(to: contents.appendingPathComponent("Info.plist"))
        var checked: [URL] = []
        let result = Doctor.inspect(executable: executable) { checked.append($0); return .init(status: .passed, message: "Fixture signature") }
        #expect(result.0.status == .passed); #expect(result.1.status == .passed); #expect(checked.map(\.path) == [app.path])
        let outside = Doctor.inspect(executable: directory.appendingPathComponent("reminder")) { _ in Issue.record("No bundle signature should be checked"); return .init(status: .passed, message: "") }
        #expect(outside.0.status == .failed); #expect(outside.1.status == .skipped)
    }
    @Test func commonResultsRenderConciseHumanRowsWithVersion() throws {
        let item = Reminder(id: "fixture-id", fields: ReminderFields(title: "Buy milk", listID: "fixture-list", due: .date(CalendarDate(2030, 2, 3))))
        let show = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .reminders([item]))))
        let text = try show.text()
        #expect(text.contains("fixture-id")); #expect(text.contains("Buy milk")); #expect(text.contains("2030-02-03"))
        #expect(text.contains(try item.version()))
        let list = ReminderList(id: "list-id", fields: ListFields(name: "Work"), isDefault: true)
        let lists = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .catalog(Catalog(lists: [list]), scope: .lists))))
        #expect(try lists.text().contains("list-id")); #expect(try lists.text().contains("Work"))
        let mutation = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .mutation(MutationResult(affectedIDs: [item.id], reminders: [item])))))
        #expect(try mutation.text().contains("Changed 1 record"))
        #expect(try mutation.text().contains("fixture-id"))
    }
}
