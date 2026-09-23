#if VEYA_QUALIFICATION
import CryptoKit
import Foundation

/// Development only. Ciphertext may persist; its wrapping key never leaves this process.
/// Relaunch deliberately loses access. The journal retains old public-key ownership evidence.
final class DevelopmentMemoryWrappingStore: WrappingSecretStore, @unchecked Sendable {
    let kind: WrappingSecretBackendKind = .unavailable
    private let lock = NSLock()
    private var keys: [UUID: SymmetricKey] = [:]

    func read(installationID: UUID) throws -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return keys[installationID]
    }

    func create(installationID: UUID) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let key = keys[installationID] { return key }
        let key = SymmetricKey(size: .bits256)
        keys[installationID] = key
        return key
    }

    func delete(installationID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: installationID)
    }
}

/// Shares the live Apple backend and volatile secrets with the canonical engine in one process.
/// This type and its UI are absent from release builds; no environment flag can enable them there.
public final class DevelopmentInstallationSession: @unchecked Sendable {
    public let apple: LiveApplePersonalTeamBackend
    public let root: URL
    private let wrapping = DevelopmentMemoryWrappingStore()
    private let pairing = InMemoryRemotePairingStore()

    public init(root: URL = InstallationJournalRepository.defaultRootURL().deletingLastPathComponent()
        .appendingPathComponent("development-session", isDirectory: true)) {
        self.root = root
        apple = .installationV2(
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: root.appendingPathComponent("apple-diagnostics.json")),
            sessionStore: KeychainAppleAuthorizationSessionStore(
                wrapping: KeychainWrappingSecretStore(kind: .unavailable),
                directory: root.appendingPathComponent("apple-session", isDirectory: true),
                legacyKeychainURL: root.appendingPathComponent("unused.keychain-db")))
    }

    public func composition(helperURL: URL, device: EngineDeviceSelection?, connectionGeneration: UInt64,
                            resourcesURL: URL? = nil,
                            runSetupProgress: (@Sendable (RunSetupProgress) -> Void)? = nil) -> EngineComposition {
        ProductionComposition.compose(helperURL: helperURL, stateRoot: root, device: device,
                                      connectionGeneration: connectionGeneration, resourcesURL: resourcesURL,
                                      appleServices: apple, wrapping: wrapping, pairingOverride: pairing,
                                      developerServicesOverride: NativeDeveloperServicesCoordinator(
                                        providers: [ThirdPartyMirrorDevelopmentProvider()], providerPolicy: .localTest),
                                      runSetupProgress: runSetupProgress)
    }
}
#endif
