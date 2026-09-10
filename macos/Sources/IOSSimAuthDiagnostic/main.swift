import Darwin
import Foundation
import IOSSimMacCore

@main
enum IOSSimAuthDiagnostic {
    static func main() async {
        fputs("Apple Account (password is not needed for SRP init): ", stderr)
        guard let account = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty else {
            fputs("SRP_INIT_PROTOCOL_FAILURE\n", stderr)
            exit(2)
        }

        let result = await LiveApplePersonalTeamBackend().diagnoseSRPInitialization(account: account)
        print(result.outputCode)
        exit(result == .success ? 0 : 1)
    }
}
