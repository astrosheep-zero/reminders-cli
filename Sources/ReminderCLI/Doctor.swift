import Foundation
import Security
import ReminderCore
import ReminderFacade

/// Static bundle/signature inspection is separate from the explicitly authorized, read-only sentinel probe.
enum Doctor {
    private struct Metadata: Decodable {
        let CFBundleIdentifier: String
        let CFBundleExecutable: String
        let ReminderBuildID: String
        let NSRemindersFullAccessUsageDescription: String
        let LSUIElement: Bool
    }
    static func inspect(executable: URL, checkSignature: (URL) -> DiagnosticCheck = signature) -> (DiagnosticCheck, DiagnosticCheck) {
        let executable = executable.resolvingSymlinksInPath()
        let macOS = executable.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else {
            return (.init(status: .failed, message: "Executable is outside an app bundle; use dist/reminder for packaged identity"),
                    .init(status: .skipped, message: "No app bundle signature to inspect"))
        }
        do {
            let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
            let metadata = try PropertyListDecoder().decode(Metadata.self, from: data)
            guard !metadata.CFBundleIdentifier.isEmpty, metadata.CFBundleExecutable == executable.lastPathComponent,
                  !metadata.ReminderBuildID.isEmpty, metadata.ReminderBuildID != "unpackaged", metadata.LSUIElement,
                  !metadata.NSRemindersFullAccessUsageDescription.isEmpty else {
                throw Failure(.invalidInput, "Bundle identity, buildID, executable, UIElement or usage description is invalid")
            }
            return (.init(status: .passed, message: "\(metadata.CFBundleIdentifier), buildID \(metadata.ReminderBuildID)"), checkSignature(app))
        } catch {
            return (.init(status: .failed, message: "Bundle metadata invalid: \(error)"), checkSignature(app))
        }
    }
    static func signature(_ app: URL) -> DiagnosticCheck {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code)
        guard created == errSecSuccess, let code else {
            return .init(status: .failed, message: "Cannot inspect static signature (OSStatus \(created))")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        return .init(status: status == errSecSuccess ? .passed : .failed,
                     message: status == errSecSuccess ? "Static bundle signature validates (ad-hoc is allowed); this does not prove TCC attribution" : "Static signature invalid (OSStatus \(status))")
    }
    static func diagnose(authorization: String, capabilities: [String], allowProbe: Bool,
                         executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                         inspectBundle: (URL) -> (DiagnosticCheck, DiagnosticCheck) = { inspect(executable: $0) },
                         probe: () throws -> Void) -> Diagnostics {
        let (bundle, signature) = inspectBundle(executable)
        var diagnostic = Diagnostics(authorization: authorization, sandbox: BuildIdentity.sandbox, buildID: BuildIdentity.current,
                                     capabilities: capabilities, notes: BuildIdentity.notes)
        diagnostic.bundle = bundle; diagnostic.signature = signature
        guard allowProbe && authorization == "fullAccess" else {
            diagnostic.readProbe = .init(status: .skipped, message: allowProbe ? "Full access is not already granted; no store read or prompt attempted" : "Setup does not probe the reminder store")
            return diagnostic
        }
        do {
            try probe()
            diagnostic.readProbe = .init(status: .passed, message: "Direct sentinel UUID read completed; a miss is expected. No account enumeration performed")
        } catch {
            let failure = error as? Failure ?? Failure(.backend, String(describing: error))
            diagnostic.readProbe = .init(status: .failed, message: "Authorized-only read probe failed", error: failure)
        }
        return diagnostic
    }
}
