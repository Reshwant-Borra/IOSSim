import Foundation

/// The single production composition of `VeyaReconciliationEngine`: every installation domain, each
/// backed by the one production service for it. There is no alternate signer, key store, or Keychain
/// path: the in-process signer is the only `PayloadSigning`, and the Apple backend is built with the
/// legacy identity store retired (`LiveApplePersonalTeamBackend.installationV2`).
public enum ProductionComposition {
    /// - Parameters:
    ///   - stateRoot: qualification-only isolated root holding `installation/`, `secrets/`, and content.
    ///   - device: the client's selected iPhone; device-bound domains wait for a selection without one.
    ///   - connectionGeneration: the client's current connection generation for `device`.
    ///   - appleServices: qualification-only injection point (simulated Developer Services).
    public static func make(
        helperURL: URL,
        stateRoot: URL? = nil,
        device: EngineDeviceSelection? = nil,
        connectionGeneration: UInt64? = nil,
        resourcesURL: URL? = nil,
        appleServices: (any AppleDeveloperServices)? = nil,
        runSetupProgress: (@Sendable (RunSetupProgress) -> Void)? = nil
    ) -> EngineComposition {
        compose(helperURL: helperURL, stateRoot: stateRoot, device: device,
                connectionGeneration: connectionGeneration, resourcesURL: resourcesURL,
                appleServices: appleServices, runSetupProgress: runSetupProgress)
    }

    static func compose(
        helperURL: URL, stateRoot: URL? = nil, device: EngineDeviceSelection? = nil,
        connectionGeneration: UInt64? = nil, resourcesURL: URL? = nil,
        appleServices: (any AppleDeveloperServices)? = nil,
        wrapping: any WrappingSecretStore = KeychainWrappingSecretStore(),
        pairingOverride: (any RemotePairingStore)? = nil,
        developerServicesOverride: (any DeveloperServicesPreparing)? = nil,
        runSetupProgress: (@Sendable (RunSetupProgress) -> Void)? = nil
    ) -> EngineComposition {
        let root = stateRoot ?? InstallationJournalRepository.defaultRootURL().deletingLastPathComponent()
        let repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
        let keyStore = VeyaSigningKeyStore(
            rootURL: stateRoot.map {
                $0.appendingPathComponent("secrets", isDirectory: true).appendingPathComponent("signing-keys", isDirectory: true)
            } ?? VeyaSigningKeyStore.defaultRootURL(),
            wrapping: wrapping
        )
        // Read-only legacy snapshot; an isolated qualification root never sees the real home directory.
        let migration = MigrationDomain(
            reader: LocalLegacyInventoryReader(home: stateRoot?.appendingPathComponent("home", isDirectory: true)
                ?? FileManager.default.homeDirectoryForCurrentUser,
                loginKeychainServices: stateRoot == nil ? ["com.iossim.mac.personal-team-signing", "com.iossim.mac.apple-authorization"] : []),
            repository: repository
        )
        let shipped = ShippedPayload(resourcesURL: resourcesURL ?? Self.resourcesURL(helperURL: helperURL))
        // An isolated qualification root never reads or purges the user's real Apple session files.
        let account = AppleAccountContext(services: appleServices ?? LiveApplePersonalTeamBackend.installationV2(
            diagnostics: stateRoot.map { ApplePersonalTeamDiagnosticsStore(url: $0.appendingPathComponent("apple-diagnostics.json")) }
                ?? ApplePersonalTeamDiagnosticsStore(),
            sessionStore: stateRoot.map {
                KeychainAppleAuthorizationSessionStore(
                    directory: $0.appendingPathComponent("apple-session", isDirectory: true),
                    legacyKeychainURL: $0.appendingPathComponent("home/Library/Keychains/isolated.keychain-db"))
            } ?? KeychainAppleAuthorizationSessionStore()
        ))
        let signing: any PayloadSigning = (try? InProcessSigner()).map { InProcessPayloadSigning(signer: $0, keyStore: keyStore) }
            ?? UnavailablePayloadSigning()
        let payload = PayloadDomain(rootURL: root, repository: repository,
                                    planProvider: ShippedPayloadPlanProvider(payload: shipped, rootURL: root), signing: signing)

        let transport = DynamicNativeDeviceTransport()
        let applications = NativeApplicationService(transport: transport)
        let selected: ProductionDeviceDomains.DeviceProvider = {
            guard let device else { throw NativeDeviceBridgeError.invalidIdentity }
            return try device.identity(connectionGeneration: connectionGeneration ?? 0)
        }
        #if IOSSIM_LOCAL_TEST_ONLY
        let developerServices: any DeveloperServicesPreparing = developerServicesOverride ?? NativeDeveloperServicesCoordinator(
            transport: transport, providers: [ThirdPartyMirrorDevelopmentProvider()], providerPolicy: .localTest)
        #else
        let developerServices: any DeveloperServicesPreparing = developerServicesOverride ?? NativeDeveloperServicesCoordinator(
            transport: transport, providers: [ExistingAppleCacheProvider()], providerPolicy: .publicProduction)
        #endif
        let pairingStore: any RemotePairingStore = pairingOverride ?? (stateRoot == nil ? KeychainRemotePairingStore.installationV2()
            : KeychainRemotePairingStore(service: KeychainRemotePairingStore.v2Service + ".qualification", backend: .forRunningCode()))
        let pairingNative = NativeRemotePairingOperations(transport: transport)
        let pairingCoordinator = RemotePairingCoordinator(
            store: pairingStore, native: pairingNative,
            delivery: NativeRemotePairingContainerDelivery(service: applications),
            proof: NativeDeveloperServicesRemotePairingProof(native: pairingNative, developerServices: developerServices)
        )

        let domains: [any InstallationObserver & InstallationTransition] = [
            ArtifactDomain(payload: shipped),
            migration,
            AppleAccountDomain(domain: .authorization, account: account),
            AppleAccountDomain(domain: .team, account: account),
            SigningKeyDomain(store: keyStore),
            CertificateDomain(rootURL: root, repository: repository, account: account, keyStore: keyStore),
            ProfileDomain(rootURL: root, repository: repository, account: account,
                          device: { device.map { DeviceRegistrationTarget(udid: $0.udid, name: $0.name) } }),
            payload,
            ApplicationDomain(payload: payload, repository: repository, applications: applications,
                              device: { try selected() }),
            ProductionDeviceDomains.developerSupport(probe: transport, coordinator: developerServices,
                                                     repository: repository, device: selected),
            ProductionDeviceDomains.vpn(service: applications, coordinator: LocalDevVPNSetupCoordinator(service: applications),
                                        repository: repository, device: selected),
            ProductionDeviceDomains.pairing(store: pairingStore, native: pairingNative, coordinator: pairingCoordinator,
                                            repository: repository, device: selected),
            RuntimeReadinessDomain(repository: repository, prover: JournalRuntimeProver(
                repository: repository, developerServices: developerServices, pairingStore: pairingStore,
                coordinator: RunSetupReadinessCoordinator(service: applications, progress: runSetupProgress),
                device: selected)),
        ]
        return EngineComposition(
            repository: repository,
            observers: domains,
            transitions: domains,
            identity: EngineIdentity(
                packaged: helperURL.resolvingSymlinksInPath().path.contains(".app/Contents/MacOS/"),
                qualificationBuild: isQualificationBuild
            )
        )
    }

    /// `Contents/MacOS/<helper>` → `Contents/Resources`.
    static func resourcesURL(helperURL: URL) -> URL {
        helperURL.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    public static var isQualificationBuild: Bool {
        #if VEYA_QUALIFICATION
        return true
        #else
        return false
        #endif
    }
}

/// The packaged signer could not be loaded: signing fails closed. There is no external-signer fallback.
struct UnavailablePayloadSigning: PayloadSigning {
    func inspect(_ bundle: URL) throws -> SigningBundleGraph { throw InProcessSignerFailure.libraryUnavailable }
    func sign(_ request: InProcessSigningRequest, keyID: String, installationID: UUID) async throws -> InProcessSigningReceipt {
        throw InProcessSignerFailure.libraryUnavailable
    }
    func verify(_ bundle: URL) throws -> InProcessVerificationReceipt { throw InProcessSignerFailure.libraryUnavailable }
}
