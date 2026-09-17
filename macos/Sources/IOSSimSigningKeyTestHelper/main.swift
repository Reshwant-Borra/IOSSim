import Foundation
import IOSSimMacCore

@main
enum IOSSimSigningKeyTestHelper {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Clean-consumer signing qualification for PHYSICAL_DEFECT_001.
        //
        // This has to run *here*, in an ordinary ad-hoc-signed executable, and
        // not inside xctest. xctest is Apple-signed, so keys it creates in the
        // login Keychain get a partition /usr/bin/codesign can match, and the
        // defect becomes invisible. This binary is signed the way the packaged
        // Veya helper is, so it reproduces the consumer's conditions.
        if arguments.first == "qualify-signing" {
            let destination = VeyaSigningQualification.Destination(
                rawValue: arguments.count > 1 ? arguments[1] : "veya"
            ) ?? .veyaKeychain
            let outcome = VeyaSigningQualification.run(destination: destination) { message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
            Foundation.exit(outcome.rawValue)
        }
        guard arguments.count == 2 else {
            fputs("usage: IOSSimSigningKeyTestHelper <certificate-sha1> <working-directory>\n       IOSSimSigningKeyTestHelper qualify-signing [veya|login]\n", stderr)
            Foundation.exit(2)
        }
        let identity = arguments[0]
        let workingDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let app = workingDirectory.appendingPathComponent("CleanConsumerSigningProbe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.iossim.clean-consumer-signing-probe",
            "CFBundleExecutable": "CleanConsumerSigningProbe",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: app.appendingPathComponent("CleanConsumerSigningProbe")
        )

        try runCodesign(["--force", "--sign", identity, "--timestamp=none", app.path], in: workingDirectory)
        try runCodesign(["--verify", "--deep", "--strict", app.path], in: workingDirectory)
    }

    private static func runCodesign(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "IOSSimSigningKeyTestHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
