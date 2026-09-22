import Darwin
import Foundation
import IOSSimMacCore

@main
enum IOSSimAuthDiagnostic {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "qualification-auth-store" {
            do {
                try runQualificationAuthStore(Array(arguments.dropFirst()))
                exit(0)
            } catch {
                fputs("QUALIFICATION_AUTH_STORE_FAILED\n", stderr)
                fputs("\(error)\n", stderr)
                exit(2)
            }
        }

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

    private static func runQualificationAuthStore(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw QualificationAuthStoreError.usage
        }
        let options = parseOptions(Array(arguments.dropFirst()))
        guard let directory = options["--directory"] else {
            throw QualificationAuthStoreError.usage
        }
        // `running-code` is the production selection. `login-keychain-test` exists only so the
        // qualification suite can exercise persistence with an isolated service on ad-hoc builds.
        let kind: WrappingSecretBackendKind
        switch options["--wrapping-backend"] ?? "running-code" {
        case "running-code": kind = .forRunningCode()
        case "login-keychain-test": kind = .loginKeychain
        default: throw QualificationAuthStoreError.usage
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let store = KeychainAppleAuthorizationSessionStore(
            service: options["--service"] ?? "com.iossim.mac.apple-authorization.qualification",
            account: options["--account"] ?? "synthetic-session",
            wrapping: KeychainWrappingSecretStore(
                kind: kind,
                service: options["--wrapping-service"] ?? "\(KeychainAppleAuthorizationSessionStore.wrappingService).qualification"
            ),
            directory: root,
            legacyKeychainURL: root.appendingPathComponent("Veya-Authorization.keychain-db")
        )
        print("AUTH_STORE_BACKEND \(kind.rawValue) persists=\(store.persistsAcrossLaunches)")

        switch command {
        case "create":
            try store.save(syntheticSession(payload: Data("synthetic-session-v1".utf8)))
            print("AUTH_STORE_CREATE_OK")
        case "read":
            guard let session = try store.load() else {
                print("AUTH_STORE_READ_MISSING")
                exit(3)
            }
            var payload = session.withOpaquePayload { Data($0) }
            defer { payload.resetBytes(in: 0..<payload.count) }
            guard payload == Data("synthetic-session-v1".utf8)
                    || payload == Data("synthetic-session-v2".utf8) else {
                print("AUTH_STORE_READ_MISMATCH")
                exit(4)
            }
            print("AUTH_STORE_READ_OK")
        case "update":
            try store.save(syntheticSession(payload: Data("synthetic-session-v2".utf8)))
            print("AUTH_STORE_UPDATE_OK")
        case "remove":
            try store.remove()
            print("AUTH_STORE_REMOVE_OK")
        default:
            throw QualificationAuthStoreError.usage
        }
    }

    private static func syntheticSession(payload: Data) -> AppleAuthorizationSession {
        AppleAuthorizationSession(
            metadata: .init(
                accountFingerprint: "qualification-synthetic-account",
                clientIdentityVersion: "qualification",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                lastValidatedAt: Date(timeIntervalSince1970: 1_800_000_001),
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            opaquePayload: payload
        )
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var output: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), index + 1 < arguments.count else {
                index += 1
                continue
            }
            output[name] = arguments[index + 1]
            index += 2
        }
        return output
    }
}

private enum QualificationAuthStoreError: Error {
    case usage
}
