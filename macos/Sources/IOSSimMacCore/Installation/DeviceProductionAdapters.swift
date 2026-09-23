import Foundation

// M9/M10 production wiring: the coordinators the shipping helper actually uses
// (`NativeDeveloperServicesCoordinator`, `RemotePairingCoordinator`, `LocalDevVPNSetupCoordinator`,
// `RichRuntimeReadinessCoordinator`) behind the canonical connection-bound device domains. Observation is
// read-only in every case; the coordinators' mutating `prepare` paths run only as transitions.

/// The iPhone an engine run targets, chosen by the client. The UDID is the Developer Services
/// registration identifier; the connection generation travels in the request.
public struct EngineDeviceSelection: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let transportIdentity: IOSSimDeviceIdentity?

    public init(udid: String, name: String, transportIdentity: IOSSimDeviceIdentity? = nil) {
        self.udid = udid
        self.name = name
        self.transportIdentity = transportIdentity
    }

    public func identity(connectionGeneration: UInt64) throws -> IOSSimDeviceIdentity {
        if let transportIdentity {
            guard transportIdentity.udid == udid,
                  transportIdentity.connectionGeneration == connectionGeneration else {
                throw NativeDeviceBridgeError.invalidIdentity
            }
            return transportIdentity
        }
        return try IOSSimDeviceIdentity(udid: udid, connectionGeneration: connectionGeneration)
    }

    public var idHash: String { VeyaSigningKeyStore.sha256(Data("device|\(udid)".utf8)) }
}

/// Read-only developer-services probe: inspect + CoreDevice/RSD/AppService readiness, never a mount.
public protocol DeveloperServicesProbing: Sendable {
    func readiness(_ device: IOSSimDeviceIdentity) async throws -> DeveloperServicesReadinessReceipt
}

extension DynamicNativeDeviceTransport: DeveloperServicesProbing {
    public func readiness(_ device: IOSSimDeviceIdentity) async throws -> DeveloperServicesReadinessReceipt {
        let inspection = try await inspect(device, timeout: .seconds(12))
        return try developerServicesReadiness(on: inspection.identity)
    }
}

public enum DeviceFailureMapping {
    static let unlock = "Unlock your iPhone and keep it unlocked, then continue in Veya."
    static let trust = "Tap Trust on your iPhone and enter its passcode, then continue in Veya."
    static let developerMode = "Turn on Developer Mode on the iPhone, restart it, then continue in Veya."
    public static let developerTrust = "On the iPhone open Settings > General > VPN & Device Management, select the "
        + "Apple Development entry for your Apple Account, tap Trust, then continue in Veya."
    public static let secureStorageUnavailable = DeviceDomainFailure.make(
        .pairing, 31, "store", "Veya's secure storage is unavailable, so the device pairing cannot be kept.")

    /// Typed coordinator/bridge failures → canonical meaning. Unknown errors are retryable observation failures.
    public static func map(_ error: Error) -> NativeDomainMapping {
        switch error {
        case let bridge as NativeDeviceBridgeError:
            switch bridge {
            case .deviceLocked: return .user(unlock)
            case .trustRequired, .trustPromptPending, .trustDenied: return .user(trust)
            case .developerModeRequired: return .user(developerMode)
            case _ where bridge.isDeveloperTrustRejection: return .user(developerTrust)
            case .ddiRequired: return .missing()
            default: return .failed(DeviceDomainFailure.observationFailed)
            }
        case let ddi as DeveloperSupportFailure:
            switch ddi {
            case .noApprovedSource, .wrongBuildIdentity: return .failed(DeviceDomainFailure.ddiIncompatible)
            case .developerModeDisabled: return .user(developerMode)
            default: return .failed(DeviceDomainFailure.ddiUnavailable)
            }
        case let pairing as RemotePairingFailure:
            switch pairing {
            case .deviceLocked: return .user(unlock)
            case .deviceTrustRequired: return .user(trust)
            case .secureStorageUnavailable: return .failed(secureStorageUnavailable)
            case .invalidRecord, .pairingRejected: return .incomplete()
            default: return .failed(DeviceDomainFailure.pairingFailed)
            }
        case let vpn as LocalDevVPNSetupFailure:
            switch vpn {
            case .appMissing: return DeviceDomainMapping.localDevVPN(.missing)
            case .unsupportedVersion: return DeviceDomainMapping.localDevVPN(.installedUnsupported)
            case .vpnPermissionRequired, .userActionRequired: return DeviceDomainMapping.localDevVPN(.vpnPermissionRequired)
            case .vpnNotRunning: return .user("Open LocalDevVPN on the iPhone and tap Connect, then continue in Veya.")
            case .endpointUnavailable, .receiptMissing, .receiptInvalid: return DeviceDomainMapping.localDevVPN(.running)
            case .developerTrustRequired: return .user(developerTrust)
            case .transportUnavailable: return .failed(DeviceDomainFailure.observationFailed)
            }
        default:
            return .failed(DeviceDomainFailure.observationFailed)
        }
    }

    /// Runs a mutating coordinator call: success is `.satisfied`; typed failures throw (so the transition
    /// fails and the next observation reports the user action or failure).
    static func prepare(_ body: () async throws -> Void) async throws -> NativeDomainMapping {
        do {
            try await body()
            return .satisfied()
        } catch {
            let mapped = map(error)
            throw mapped.failure ?? mapped.userAction.map {
                (try? VeyaFailure(namespace: .device, number: 31, operation: "prepare", safeMessage: $0, userAction: $0,
                                  underlyingSubsystem: "deviceDomains")) ?? DeviceDomainFailure.observationFailed
            } ?? DeviceDomainFailure.observationFailed
        }
    }
}

extension NativeDeviceBridgeError {
    /// AppService launch denied because the user has not trusted the Personal Team developer on the iPhone.
    /// A platform security requirement, not a Veya defect; reuses the physically observed classifier.
    public var isDeveloperTrustRejection: Bool {
        guard case .launchRejected(let detail) = self else { return false }
        return ConsumerProvisioningErrorClassifier.launchErrorCode(output: "launch_rejected: \(detail)")
            == .developerProfileTrustRequired
    }
}

/// What the installed payload means to device domains, read from the journal's active records.
public struct InstalledPayloadIdentity: Equatable, Sendable {
    public let teamIdentifier: String
    public let mainBundleIdentifier: String
    public let runnerBundleIdentifier: String
    /// Binds phone-side requests/receipts to this exact signed payload.
    public let releaseIdentity: String

    public init?(journal: InstallationJournal) {
        guard let application = journal.activeResource(for: .application),
              let team = application.metadata["teamIdentifier"], !team.isEmpty,
              let main = application.metadata["bundle.main"], let runner = application.metadata["bundle.runner"],
              let digest = application.identity.digest else { return nil }
        teamIdentifier = team
        mainBundleIdentifier = main
        runnerBundleIdentifier = runner
        releaseIdentity = "veya-v2:\(digest.dropFirst(7).prefix(16))"
    }
}

public enum ProductionDeviceDomains {
    public typealias DeviceProvider = @Sendable () throws -> IOSSimDeviceIdentity

    static func payload(_ repository: InstallationJournalRepository) async throws -> InstalledPayloadIdentity {
        guard let payload = InstalledPayloadIdentity(journal: try await repository.load()) else {
            throw PayloadFailure.payloadNotReady
        }
        return payload
    }

    /// `.developerSupport`: satisfied when CoreDevice/RSD/AppService are ready (DDI mounted or not needed).
    public static func developerSupport(
        probe: any DeveloperServicesProbing,
        coordinator: any DeveloperServicesPreparing,
        repository: InstallationJournalRepository,
        device: @escaping DeviceProvider
    ) -> CoordinatedDeviceDomain {
        CoordinatedDeviceDomain(
            domain: .developerSupport,
            observe: { _ in
                do {
                    return try await probe.readiness(try device()).transportReady ? .satisfied() : .incomplete()
                } catch {
                    return DeviceFailureMapping.map(error)
                }
            },
            prepare: { _ in
                try await DeviceFailureMapping.prepare {
                    let payload = try await payload(repository)
                    _ = try await coordinator.prepare(
                        device: try device(),
                        context: DeveloperServicesProofContext(releaseIdentity: payload.releaseIdentity, pairingGeneration: nil,
                                                               targetBundleIdentifier: payload.mainBundleIdentifier),
                        progress: { _ in }
                    )
                }
            }
        )
    }

    /// `.pairing`: the Mac-side record for this device/team validates against the device (read-only);
    /// creation and delivery to the installed app are the coordinator's transition.
    public static func pairing(
        store: any RemotePairingStore,
        native: any RemotePairingNativeOperations,
        coordinator: RemotePairingCoordinator,
        repository: InstallationJournalRepository,
        device: @escaping DeviceProvider,
        hostname: String = "IOSSim-Mac"
    ) -> CoordinatedDeviceDomain {
        CoordinatedDeviceDomain(
            domain: .pairing,
            observe: { _ in
                do {
                    let payload = try await payload(repository)
                    let target = try device()
                    guard let record = try store.load(deviceUDID: target.udid, teamIdentifier: payload.teamIdentifier) else {
                        return .missing()
                    }
                    try await native.validate(record, on: target, hostname: hostname)
                    return .satisfied()
                } catch {
                    return DeviceFailureMapping.map(error)
                }
            },
            prepare: { _ in
                try await DeviceFailureMapping.prepare {
                    let payload = try await payload(repository)
                    _ = try await coordinator.reconcileAutomatically(
                        device: try device(), teamIdentifier: payload.teamIdentifier,
                        appBundleIdentifier: payload.mainBundleIdentifier, hostname: hostname,
                        releaseIdentity: payload.releaseIdentity
                    )
                }
            },
            dependsOn: [.application],
            repository: repository
        )
    }

    /// `.vpn`: read-only observation of the phone's last LocalDevVPN receipt in the app container; only a
    /// fresh, device/team/release-bound `runtimeEndpointReachable` receipt satisfies.
    public static func vpn(
        service: any NativeApplicationServicing,
        coordinator: LocalDevVPNSetupCoordinator,
        repository: InstallationJournalRepository,
        device: @escaping DeviceProvider,
        // Physically observed: a 600 s window reported `satisfied` minutes after LocalDevVPN was turned off. Older
        // bound receipts are `stale`, so the next run re-probes the phone instead of trusting them.
        receiptLifetime: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CoordinatedDeviceDomain {
        CoordinatedDeviceDomain(
            domain: .vpn,
            observe: { _ in
                do {
                    let payload = try await payload(repository)
                    let target = try device()
                    let data: Data
                    do {
                        data = try await service.readContainer(bundleIdentifier: payload.mainBundleIdentifier,
                                                               relativePath: LocalDevVPNSetupCoordinator.receiptPath, on: target)
                    } catch NativeDeviceBridgeError.containerUnavailable, NativeDeviceBridgeError.applicationNotFound {
                        return .missing()
                    }
                    guard let receipt = try? JSONDecoder().decode(LocalDevVPNSetupReceiptPayload.self, from: data),
                          receipt.deviceUDID == target.udid, receipt.teamIdentifier == payload.teamIdentifier,
                          receipt.releaseIdentity == payload.releaseIdentity else {
                        return .missing()
                    }
                    guard abs(now().timeIntervalSince(receipt.timestamp)) <= receiptLifetime else {
                        return NativeDomainMapping(state: .stale, userAction: nil, failure: nil)
                    }
                    let state = receipt.lifecycleState ?? (receipt.status == "ready" ? .runtimeEndpointReachable : .installed)
                    if state == .runtimeEndpointReachable, !receipt.endpointReachable { return .incomplete() }
                    let mapped = DeviceDomainMapping.localDevVPN(state)
                    // The receipt is the phone's report from the last probe, not the current state. Waiting on it
                    // would never re-probe after the user acted (physically observed deadlock), so it stays a hint
                    // and the transition re-probes; that throws the same action if it is still needed.
                    guard mapped.state == .waitingForUser else { return mapped }
                    return NativeDomainMapping(state: .invalid, userAction: mapped.userAction, failure: nil)
                } catch {
                    return DeviceFailureMapping.map(error)
                }
            },
            prepare: { _ in
                try await DeviceFailureMapping.prepare {
                    let payload = try await payload(repository)
                    let receipt = try await coordinator.prepare(
                        device: try device(), iosSimBundleIdentifier: payload.mainBundleIdentifier,
                        teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                    )
                    guard receipt.endpointReachable else { throw LocalDevVPNSetupFailure.endpointUnavailable }
                }
            },
            dependsOn: [.application],
            repository: repository
        )
    }
}

/// Production M10 prover: a fresh developer-services session (the DDI-backed services the real Run Setup
/// needs) plus the receipt the user's own Run Setup tap leaves in the app container, bound to the
/// journal's installed payload and to the pairing record Veya delivered. Veya never starts the run.
public struct JournalRuntimeProver: RuntimeProving {
    private let repository: InstallationJournalRepository
    private let developerServices: any DeveloperServicesPreparing
    private let pairingStore: any RemotePairingStore
    private let coordinator: RunSetupReadinessCoordinator
    private let device: ProductionDeviceDomains.DeviceProvider

    public init(repository: InstallationJournalRepository, developerServices: any DeveloperServicesPreparing,
                pairingStore: any RemotePairingStore, coordinator: RunSetupReadinessCoordinator,
                device: @escaping ProductionDeviceDomains.DeviceProvider) {
        self.repository = repository
        self.developerServices = developerServices
        self.pairingStore = pairingStore
        self.coordinator = coordinator
        self.device = device
    }

    public func proveRuntime(binding: String, scope: InstallationScope) async throws -> RuntimeProofResult {
        let journal = try await repository.load()
        guard let payload = InstalledPayloadIdentity(journal: journal) else {
            throw RunSetupFailure.requestInvalid
        }
        let target = try device()
        guard let pairing = try pairingStore.load(deviceUDID: target.udid, teamIdentifier: payload.teamIdentifier),
              let pairingGeneration = pairing.metadata.pairingGeneration, pairingGeneration > 0 else {
            throw RunSetupFailure.requestInvalid
        }
        // A request Veya already issued and the phone can still answer is reused, so a tap
        // that lands between two runs counts and pressing Continue never invalidates it.
        // Only an absent, expired or differently bound request is reissued, and it is placed
        // before the app is next opened so the prompt is already waiting for the user.
        let pending = await coordinator.pendingRequest(
            device: target,
            appBundleIdentifier: payload.mainBundleIdentifier,
            teamIdentifier: payload.teamIdentifier,
            releaseIdentity: payload.releaseIdentity
        )
        let request: RunSetupRequest
        if let pending {
            request = pending
        } else {
            request = try await coordinator.requestSetup(
                device: target,
                appBundleIdentifier: payload.mainBundleIdentifier,
                teamIdentifier: payload.teamIdentifier,
                releaseIdentity: payload.releaseIdentity
            )
        }
        // Run Setup itself needs the DDI-backed developer services (dtservicehub over
        // RSD), so they are proven fresh here before the user is asked to tap.
        let session = try await developerServices.prepare(
            device: target,
            context: DeveloperServicesProofContext(releaseIdentity: payload.releaseIdentity,
                                                   pairingGeneration: pairingGeneration,
                                                   targetBundleIdentifier: payload.mainBundleIdentifier),
            progress: { _ in }
        )
        guard session.isCurrent(for: target, releaseIdentity: payload.releaseIdentity,
                                pairingGeneration: pairingGeneration,
                                targetBundleIdentifier: payload.mainBundleIdentifier) else {
            throw RunSetupFailure.requestInvalid
        }
        let receipt = try await coordinator.awaitRunSetup(
            request: request,
            device: target,
            appBundleIdentifier: payload.mainBundleIdentifier,
            pairingIdentifier: pairing.metadata.identifier,
            pairingPublicKeyFingerprint: pairing.metadata.publicKeyFingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // The engine binding covers application/DDI/pairing/VPN records, device and connection.
        let digest = VeyaSigningKeyStore.sha256(try encoder.encode(receipt) + Data(binding.utf8))
        return RuntimeProofResult(receiptDigest: digest, completedAt: receipt.completedAt)
    }
}
