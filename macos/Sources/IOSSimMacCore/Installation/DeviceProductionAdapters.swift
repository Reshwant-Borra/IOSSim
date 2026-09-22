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
    static let unlock = "Unlock your iPhone and keep it unlocked, then continue."
    static let trust = "Tap Trust on your iPhone and enter its passcode, then continue."
    static let developerMode = "Turn on Developer Mode on the iPhone, restart it, then retry."
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
            case .vpnNotRunning: return .user("Open LocalDevVPN on the iPhone and tap Connect, then continue.")
            case .endpointUnavailable, .receiptMissing, .receiptInvalid: return DeviceDomainMapping.localDevVPN(.running)
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
        receiptLifetime: TimeInterval = 600,
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
                          receipt.releaseIdentity == payload.releaseIdentity,
                          abs(now().timeIntervalSince(receipt.timestamp)) <= receiptLifetime else {
                        return .missing()
                    }
                    let state = receipt.lifecycleState ?? (receipt.status == "ready" ? .runtimeEndpointReachable : .installed)
                    if state == .runtimeEndpointReachable, !receipt.endpointReachable { return .incomplete() }
                    return DeviceDomainMapping.localDevVPN(state)
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

/// Production M10 prover: a fresh developer-services session plus the phone's full-chain Rich runtime
/// receipt, bound to the journal's installed payload and the device's current pairing generation.
public struct JournalRuntimeProver: RuntimeProving {
    private let repository: InstallationJournalRepository
    private let developerServices: any DeveloperServicesPreparing
    private let pairingStore: any RemotePairingStore
    private let coordinator: RichRuntimeReadinessCoordinator
    private let device: ProductionDeviceDomains.DeviceProvider

    public init(repository: InstallationJournalRepository, developerServices: any DeveloperServicesPreparing,
                pairingStore: any RemotePairingStore, coordinator: RichRuntimeReadinessCoordinator,
                device: @escaping ProductionDeviceDomains.DeviceProvider) {
        self.repository = repository
        self.developerServices = developerServices
        self.pairingStore = pairingStore
        self.coordinator = coordinator
        self.device = device
    }

    public func proveRuntime(binding: String, scope: InstallationScope) async throws -> RuntimeProofResult {
        let journal = try await repository.load()
        guard let payload = InstalledPayloadIdentity(journal: journal),
              let profiles = journal.activeResource(for: .profile)?.identity.digest else {
            throw RichRuntimeProofFailure.invalidRequest
        }
        let target = try device()
        guard let pairingGeneration = try pairingStore.load(deviceUDID: target.udid, teamIdentifier: payload.teamIdentifier)?
            .metadata.pairingGeneration, pairingGeneration > 0 else {
            throw RichRuntimeProofFailure.invalidRequest
        }
        let session = try await developerServices.prepare(
            device: target,
            context: DeveloperServicesProofContext(releaseIdentity: payload.releaseIdentity, pairingGeneration: pairingGeneration,
                                                   targetBundleIdentifier: payload.mainBundleIdentifier),
            progress: { _ in }
        )
        guard session.isCurrent(for: target, releaseIdentity: payload.releaseIdentity, pairingGeneration: pairingGeneration,
                                targetBundleIdentifier: payload.mainBundleIdentifier),
              let sessionID = session.sessionIdentifier, let supportIdentity = session.developerSupportIdentity else {
            throw RichRuntimeProofFailure.invalidRequest
        }
        let receipt = try await coordinator.prove(
            request: RichRuntimeProofRequest(
                deviceUDID: target.udid,
                teamIdentifier: payload.teamIdentifier,
                releaseIdentity: payload.releaseIdentity,
                // The engine binding covers application/DDI/pairing/VPN records, device and connection.
                artifactSetIdentity: String(binding.dropFirst(7)),
                profileSetIdentity: String(profiles.dropFirst(7)),
                pairingGeneration: pairingGeneration,
                developerServicesSession: sessionID,
                developerSupportIdentity: supportIdentity,
                runnerBundleIdentifier: payload.runnerBundleIdentifier
            ),
            device: target,
            appBundleIdentifier: payload.mainBundleIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return RuntimeProofResult(receiptDigest: VeyaSigningKeyStore.sha256(try encoder.encode(receipt)),
                                  completedAt: receipt.completedAt)
    }
}
