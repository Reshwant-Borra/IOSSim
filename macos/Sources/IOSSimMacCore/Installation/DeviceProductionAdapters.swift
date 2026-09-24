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
        do {
            return try developerServicesReadiness(on: inspection.identity)
        } catch {
            throw DeviceFailureMapping.developerModeRecovery(
                from: error, developerMode: inspection.developerMode
            )
        }
    }
}

/// The facts Veya must already have proved, independently of the device's answer,
/// before a launch security denial is allowed to mean "the developer is untrusted".
///
/// iOS collapses invalid code signature, inadequate entitlements and untrusted
/// developer profile into one launch rejection. Veya cannot tell them apart from the
/// rejection alone, so it eliminates the other two in advance: every flag here
/// corresponds to evidence already recorded in the installation journal by a domain
/// that proved it cryptographically and offline. Nothing is inferred from the device.
public struct DeveloperTrustPrerequisites: Equatable, Sendable {
    /// A live developer-services session (CoreDevice/RSD/AppService) was proven before
    /// the launch, so the rejection is not DDI, transport or Developer Mode.
    public let developerServicesProven: Bool
    /// The exact expected bundle was observed installed on this device after install.
    public let applicationInstalled: Bool
    /// `veya-signing-core` re-verified the signed Mach-O graph that was installed,
    /// eliminating "invalid code signature".
    public let payloadSignatureVerified: Bool
    /// The provisioning profile validated offline against Apple's CMS anchor, and its
    /// team, application identifier, device list and expiry all matched. This
    /// eliminates "inadequate entitlements", a wrong team, an unprovisioned device and
    /// an expired profile, because signing refuses any entitlement the profile does
    /// not grant.
    public let profileBindingValidated: Bool
    /// The signing certificate matched Apple's own live inventory, eliminating a
    /// revoked or unknown certificate.
    public let certificateInventoryMatched: Bool

    public init(developerServicesProven: Bool, applicationInstalled: Bool,
                payloadSignatureVerified: Bool, profileBindingValidated: Bool,
                certificateInventoryMatched: Bool) {
        self.developerServicesProven = developerServicesProven
        self.applicationInstalled = applicationInstalled
        self.payloadSignatureVerified = payloadSignatureVerified
        self.profileBindingValidated = profileBindingValidated
        self.certificateInventoryMatched = certificateInventoryMatched
    }

    /// Nothing proved. Every caller that has not established the prerequisites gets
    /// this, so trust can never be classified by default.
    public static let unproven = DeveloperTrustPrerequisites(
        developerServicesProven: false, applicationInstalled: false,
        payloadSignatureVerified: false, profileBindingValidated: false,
        certificateInventoryMatched: false)

    public var allProven: Bool {
        developerServicesProven && applicationInstalled && payloadSignatureVerified
            && profileBindingValidated && certificateInventoryMatched
    }

    /// Evidence counts only when it is bound to the domain's *active* record, was
    /// captured at that record's generation, and has not expired.
    static func proved(_ journal: InstallationJournal, _ domain: InstallationDomain,
                       kind: String, at now: Date) -> Bool {
        guard let record = journal.activeResource(for: domain) else { return false }
        return journal.evidence.contains { evidence in
            evidence.kind == kind
                && record.evidenceIDs.contains(evidence.id)
                && evidence.generation == record.generation
                && (evidence.validUntil.map { $0 > now } ?? true)
        }
    }

    /// `developerServicesProven` is supplied by the caller because it is a property of
    /// the call site, not of the journal: the developer-services transition launches the
    /// app only after its own readiness probe has succeeded on this connection.
    public static func fromJournal(_ journal: InstallationJournal, developerServicesProven: Bool,
                                   now: Date = Date()) -> Self {
        DeveloperTrustPrerequisites(
            developerServicesProven: developerServicesProven,
            applicationInstalled: proved(journal, .application, kind: "deviceInventoryAfterInstall", at: now),
            payloadSignatureVerified: proved(journal, .payload, kind: "payloadIndependentVerification", at: now),
            profileBindingValidated: proved(journal, .profile, kind: "profileCMSBindingValidation", at: now),
            certificateInventoryMatched: proved(journal, .certificate, kind: "appleInventorySPKIMatch", at: now)
        )
    }
}

public enum DeviceFailureMapping {
    static let unlock = "Unlock your iPhone and keep it unlocked, then continue in Veya."
    static let trust = "Tap Trust on your iPhone and enter its passcode, then continue in Veya."
    public static let developerMode = "On the iPhone open Settings > Privacy & Security > Developer Mode, turn it on, "
        + "follow the restart prompt, unlock the iPhone, then continue in Veya."
    public static let developerTrust = "On the iPhone open Settings > General > VPN & Device Management, select the "
        + "Apple Development entry for your Apple Account, tap Trust, then continue in Veya."
    public static let secureStorageUnavailable = DeviceDomainFailure.make(
        .pairing, 31, "store", "Veya's secure storage is unavailable, so the device pairing cannot be kept.")

    /// Developer Mode off fails the CoreDevice/RSD chain with a transport-shaped error: iOS only
    /// returns the authoritative "Developer mode is not enabled." string on the install, launch and
    /// mount paths. Without this, that observation degrades to a generic `VEYA-DEVICE-030` and the
    /// Developer Mode prerequisite is never re-entered. AMFI's advisory status is read only to
    /// explain a probe that has already failed: it can never block a probe that succeeded, and a
    /// failure that already carries a typed meaning is returned untouched.
    static func developerModeRecovery(from error: Error, developerMode: DeveloperModeReadiness) -> Error {
        guard developerMode == .disabled, let bridge = error as? NativeDeviceBridgeError else { return error }
        switch bridge {
        case .coreDeviceProxyFailed, .softwareTunnelFailed, .rsdUnavailable, .remoteXPCFailed,
             .appServiceUnavailable, .featureUnavailable, .developerServicesNotReady, .protocolFailure:
            // Stages of the developer-services chain that iOS refuses without Developer Mode and
            // that carry no authoritative meaning of their own.
            return NativeDeviceBridgeError.developerModeRequired
        default:
            // A lost, locked, untrusted or slow device, a missing image, and Veya's own defects all
            // keep their accurate meaning; only the ambiguous chain failures are re-read.
            return error
        }
    }

    /// Typed coordinator/bridge failures → canonical meaning. Unknown errors are retryable observation failures.
    ///
    /// `trustPrerequisites` defaults to `.unproven`, so a caller that has not proved the
    /// signing chain can never reach the developer-trust classification.
    public static func map(_ error: Error,
                           trustPrerequisites: DeveloperTrustPrerequisites = .unproven) -> NativeDomainMapping {
        switch error {
        case let bridge as NativeDeviceBridgeError:
            switch bridge {
            case .deviceLocked: return .user(unlock)
            case .trustRequired, .trustPromptPending, .trustDenied: return .user(trust)
            case .developerModeRequired: return .user(developerMode)
            case _ where bridge.isDeveloperTrustRejection: return .user(developerTrust)
            case _ where bridge.isDeveloperTrustRejection(given: trustPrerequisites):
                return .user(developerTrust)
            case .ddiRequired: return .missing()
            // Not proven to be trust: the launch refusal keeps its own typed meaning.
            case .launchRejected, .launchRejectedStructured:
                return .failed(DeviceDomainFailure.launchRejected(bridge))
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
            case .developerModeRequired: return .user(developerMode)
            case .developerTrustRequired: return .user(developerTrust)
            case .secureStorageUnavailable: return .failed(secureStorageUnavailable)
            case .invalidRecord, .pairingRejected: return .incomplete()
            default: return .failed(DeviceDomainFailure.pairingFailed)
            }
        case let vpn as LocalDevVPNSetupFailure:
            switch vpn {
            case .appMissing: return .actionable(DeviceDomainFailure.vpnMissing)
            case .unsupportedVersion: return DeviceDomainMapping.localDevVPN(.installedUnsupported)
            case .vpnPermissionRequired, .userActionRequired:
                return .actionable(DeviceDomainFailure.vpnPermissionRequired)
            case .vpnNotRunning: return .actionable(DeviceDomainFailure.vpnNotRunning)
            case .endpointUnavailable: return .actionable(DeviceDomainFailure.vpnEndpointUnavailable)
            case .receiptMissing: return .actionable(DeviceDomainFailure.vpnReceiptMissing)
            case .receiptInvalid: return .actionable(DeviceDomainFailure.vpnReceiptInvalid)
            case .developerTrustRequired: return .user(developerTrust)
            case .developerModeRequired: return .user(developerMode)
            case .transportUnavailable: return .actionable(DeviceDomainFailure.vpnTransportUnavailable)
            }
        default:
            return .failed(DeviceDomainFailure.observationFailed)
        }
    }

    /// Runs a mutating coordinator call: success is `.satisfied`; typed failures throw (so the transition
    /// fails and the next observation reports the user action or failure).
    static func prepare(trustPrerequisites: DeveloperTrustPrerequisites = .unproven,
                        _ body: () async throws -> Void) async throws -> NativeDomainMapping {
        do {
            try await body()
            return .satisfied()
        } catch {
            let mapped = map(error, trustPrerequisites: trustPrerequisites)
            throw mapped.failure ?? mapped.userAction.map {
                (try? VeyaFailure(namespace: .device, number: 31, operation: "prepare", safeMessage: $0, userAction: $0,
                                  underlyingSubsystem: "deviceDomains")) ?? DeviceDomainFailure.observationFailed
            } ?? DeviceDomainFailure.observationFailed
        }
    }
}

extension NativeLaunchRejection {
    /// FrontBoard's open-application security denial: the narrow structured shape iOS
    /// returns when it refuses to launch an installed application on security grounds.
    /// It is the whole security family, not trust alone, which is why prerequisites
    /// must eliminate the rest of that family before it can mean anything.
    public var isOpenApplicationSecurityDenial: Bool {
        guard isStructurallyUsable, let terminal = chain.last else { return false }
        return terminal.domain == "FBSOpenApplicationErrorDomain"
            && terminal.code == 3
            && terminal.bsDescription == "Security"
    }
}

extension NativeDeviceBridgeError {
    /// AppService launch denied because the user has not trusted the Personal Team developer on the iPhone.
    /// A platform security requirement, not a Veya defect; reuses the physically observed classifier.
    ///
    /// This text form serves the legacy `devicectl` path, whose output genuinely carries
    /// Apple's NSError description. It is unreachable from the native bridge, which now
    /// produces `launchRejectedStructured` instead.
    public var isDeveloperTrustRejection: Bool {
        guard case .launchRejected(let detail) = self else { return false }
        return ConsumerProvisioningErrorClassifier.launchErrorCode(output: "launch_rejected: \(detail)")
            == .developerProfileTrustRequired
    }

    /// Conditional classification: a structured open-application security denial means
    /// "untrusted developer" only once Veya has independently eliminated every other
    /// cause iOS folds into that same denial. Both halves are required; neither is
    /// sufficient, and no localized text participates.
    public func isDeveloperTrustRejection(given prerequisites: DeveloperTrustPrerequisites) -> Bool {
        guard case .launchRejectedStructured(let detail) = self else { return false }
        return prerequisites.allProven && detail.isOpenApplicationSecurityDenial
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

    /// Prerequisites for the developer-trust classification, read from the journal.
    /// `developerServicesProven` is the call site's own guarantee: the developer-services
    /// transition launches the app only after its readiness probe succeeded, and the VPN
    /// and pairing domains run only after developer support is an active record.
    static func trustPrerequisites(_ repository: InstallationJournalRepository,
                                   developerServicesProven: Bool) async -> DeveloperTrustPrerequisites {
        guard let journal = try? await repository.load() else { return .unproven }
        return DeveloperTrustPrerequisites.fromJournal(
            journal, developerServicesProven: developerServicesProven)
    }

    static func payload(_ repository: InstallationJournalRepository) async throws -> InstalledPayloadIdentity {
        guard let payload = InstalledPayloadIdentity(journal: try await repository.load()) else {
            throw PayloadFailure.payloadNotReady
        }
        return payload
    }

    /// `.developerSupport`: satisfied when CoreDevice/RSD/AppService are ready (DDI mounted or not needed) and the
    /// installed app launched through them, which is also where developer trust is proven.
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
                    // Observation is read-only and never launches the app, so it cannot
                    // produce a launch rejection; prerequisites stay unproven here.
                    return DeviceFailureMapping.map(error)
                }
            },
            prepare: { _ in
                // The coordinator launches the installed app only after its own
                // CoreDevice/RSD/AppService readiness probe has succeeded on this
                // connection, so developer services are proven by construction here.
                try await DeviceFailureMapping.prepare(
                    trustPrerequisites: await trustPrerequisites(repository, developerServicesProven: true)
                ) {
                    let payload = try await payload(repository)
                    _ = try await coordinator.prepare(
                        device: try device(),
                        context: DeveloperServicesProofContext(releaseIdentity: payload.releaseIdentity, pairingGeneration: nil,
                                                               targetBundleIdentifier: payload.mainBundleIdentifier),
                        progress: { _ in }
                    )
                }
            },
            // The launch probe proves this installed app, so a reinstall makes the proof stale
            // and the next run launches the new app again before VPN, pairing or runtime.
            dependsOn: [.application],
            repository: repository
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
                try await DeviceFailureMapping.prepare(
                    trustPrerequisites: await trustPrerequisites(
                        repository,
                        developerServicesProven: (try? await repository.load())?
                            .activeResource(for: .developerSupport) != nil)
                ) {
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
                    await coordinator.recordObservation(
                        "vpn.observation.receiptReadStarted",
                        device: target,
                        appBundleIdentifier: payload.mainBundleIdentifier,
                        teamIdentifier: payload.teamIdentifier,
                        releaseIdentity: payload.releaseIdentity
                    )
                    do {
                        data = try await service.readContainer(bundleIdentifier: payload.mainBundleIdentifier,
                                                               relativePath: LocalDevVPNSetupCoordinator.receiptPath, on: target)
                    } catch NativeDeviceBridgeError.containerFileNotFound {
                        await coordinator.recordObservation(
                            "vpn.observation.containerAvailable", value: "true",
                            device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                            teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                        )
                        await coordinator.recordObservation(
                            "vpn.observation.receiptFile", value: "absent",
                            device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                            teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                        )
                        return .missing()
                    } catch {
                        await coordinator.recordObservation(
                            "vpn.observation.receiptReadFailed",
                            value: LocalDevVPNSetupCoordinator.transportCategory(error),
                            device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                            teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                        )
                        throw error
                    }
                    await coordinator.recordObservation(
                        "vpn.observation.containerAvailable", value: "true",
                        device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                        teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                    )
                    await coordinator.recordObservation(
                        "vpn.observation.receiptFile", value: "present",
                        device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                        teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                    )
                    guard let receipt = try? JSONDecoder().decode(LocalDevVPNSetupReceiptPayload.self, from: data) else {
                        await coordinator.recordObservation(
                            "vpn.observation.receiptValidation", value: "malformed",
                            device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                            teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                        )
                        return .actionable(DeviceDomainFailure.vpnReceiptInvalid)
                    }
                    guard receipt.deviceUDID == target.udid, receipt.teamIdentifier == payload.teamIdentifier,
                          receipt.releaseIdentity == payload.releaseIdentity else {
                        await coordinator.recordObservation(
                            "vpn.observation.receiptValidation", value: "bindingMismatch",
                            device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                            teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                        )
                        return .missing()
                    }
                    guard abs(now().timeIntervalSince(receipt.timestamp)) <= receiptLifetime else {
                        return NativeDomainMapping(state: .stale, userAction: nil, failure: nil)
                    }
                    let state = receipt.lifecycleState ?? (receipt.status == "ready" ? .runtimeEndpointReachable : .installed)
                    if state == .runtimeEndpointReachable, !receipt.endpointReachable { return .incomplete() }
                    let mapped = DeviceDomainMapping.localDevVPN(state)
                    await coordinator.recordObservation(
                        "vpn.observation.receiptValidation",
                        value: mapped.state == .satisfied ? "satisfied" : state.rawValue,
                        device: target, appBundleIdentifier: payload.mainBundleIdentifier,
                        teamIdentifier: payload.teamIdentifier, releaseIdentity: payload.releaseIdentity
                    )
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
                try await DeviceFailureMapping.prepare(
                    trustPrerequisites: await trustPrerequisites(
                        repository,
                        developerServicesProven: (try? await repository.load())?
                            .activeResource(for: .developerSupport) != nil)
                ) {
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
