import Foundation

// M9: the existing, physically exercised device coordinators (DDI, RemotePairing, LocalDevVPN) as
// canonical engine domains. Their native state machines are kept, not flattened to booleans. Only a
// fully proven native state is `.satisfied`. Every observation is bound to the device connection
// generation, so reconnects, reboots and transport switches invalidate evidence.

/// Canonical engine meaning of a native domain state.
public struct NativeDomainMapping: Equatable, Sendable {
    public let state: DomainObservationState
    public let userAction: String?
    public let failure: VeyaFailure?

    static func satisfied() -> Self { .init(state: .satisfied, userAction: nil, failure: nil) }
    static func missing() -> Self { .init(state: .missing, userAction: nil, failure: nil) }
    /// Veya-driven work is in flight or incomplete: the next transition completes or replaces it.
    static func incomplete() -> Self { .init(state: .invalid, userAction: nil, failure: nil) }
    static func user(_ action: String) -> Self { .init(state: .waitingForUser, userAction: action, failure: nil) }
    static func failed(_ failure: VeyaFailure) -> Self {
        .init(state: failure.retryable ? .retryableFailure : .terminalFailure, userAction: nil, failure: failure)
    }
}

public enum DeviceDomainFailure {
    static func make(_ namespace: InstallationFailureNamespace, _ number: Int, _ operation: String, _ message: String,
                     retryable: Bool = false) -> VeyaFailure {
        // Constant, validated inputs; construction cannot fail.
        try! VeyaFailure(namespace: namespace, number: number, operation: operation, safeMessage: message,
                         retryable: retryable, underlyingSubsystem: "deviceDomains")
    }
    public static let ddiIncompatible = make(.developerSupport, 30, "resolve", "No developer support image is approved for this iOS build.")
    public static let ddiUnavailable = make(.developerSupport, 31, "mount", "Developer support could not be prepared.", retryable: true)
    public static let vpnUnsupportedVersion = make(.vpn, 30, "observe", "The installed LocalDevVPN version is not supported.")
    public static let pairingFailed = make(.pairing, 30, "prove", "The device pairing could not be proven.", retryable: true)
    public static let observationFailed = make(.device, 30, "observe", "The device could not be observed.", retryable: true)
}

public enum DeviceDomainMapping {
    /// Mounted is `.satisfied` only because the coordinator reports `mounted` after RSD verification.
    public static func developerSupport(_ status: DeveloperSupportStatus) -> NativeDomainMapping {
        switch status.state {
        case .mounted, .notNeeded: return .satisfied()
        case .missing, .acquisitionNeeded: return .missing()
        case .available, .personalizationRequired, .personalizing, .mountRequired, .mounting: return .incomplete()
        case .incompatible: return .failed(DeviceDomainFailure.ddiIncompatible)
        case .failed:
            switch status.failure {
            case .developerModeDisabled?: return .user("Turn on Developer Mode on the iPhone, restart it, then retry.")
            case .noApprovedSource?, .wrongBuildIdentity?: return .failed(DeviceDomainFailure.ddiIncompatible)
            default: return .failed(DeviceDomainFailure.ddiUnavailable)
            }
        }
    }

    /// Only an endpoint challenge through the tunnel satisfies runtime prerequisites; `running` does not.
    public static func localDevVPN(_ state: LocalDevVPNLifecycleState) -> NativeDomainMapping {
        switch state {
        case .runtimeEndpointReachable: return .satisfied()
        case .missing: return .user("Install LocalDevVPN from the App Store on the iPhone, then continue in Veya.")
        case .installedUnsupported: return .failed(DeviceDomainFailure.vpnUnsupportedVersion)
        case .vpnPermissionRequired: return .user("Open LocalDevVPN on the iPhone and allow the VPN configuration, then continue in Veya.")
        case .installed, .configured, .running: return .incomplete()
        }
    }

    public static func remotePairing(_ state: RemotePairingLifecycleState) -> NativeDomainMapping {
        switch state {
        case .operational: return .satisfied()
        case .missing: return .missing()
        case .creating, .candidateStored, .delivering, .awaitingReceipt, .provingPossession,
             .provingDeveloperServices, .promoting, .stored, .validating, .repairable:
            return .incomplete()
        case .failed: return .failed(DeviceDomainFailure.pairingFailed)
        }
    }
}

/// Generic connection-bound adapter over a coordinator: `observe` must be read-only, `prepare` may mutate.
public struct CoordinatedDeviceDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain
    private let observeNative: @Sendable (InstallationScope) async throws -> NativeDomainMapping
    private let prepareNative: @Sendable (InstallationScope) async throws -> NativeDomainMapping
    private let dependsOn: [InstallationDomain]
    private let repository: InstallationJournalRepository?
    private let now: @Sendable () -> Date

    /// `dependsOn`: domains whose active record is part of this domain's identity. Pairing and VPN state
    /// live in the installed app's container, so replacing the application makes them stale.
    public init(domain: InstallationDomain,
                observe: @escaping @Sendable (InstallationScope) async throws -> NativeDomainMapping,
                prepare: @escaping @Sendable (InstallationScope) async throws -> NativeDomainMapping,
                dependsOn: [InstallationDomain] = [],
                repository: InstallationJournalRepository? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(dependsOn.isEmpty || repository != nil, "dependent device domains read the journal")
        self.domain = domain
        observeNative = observe
        prepareNative = prepare
        self.dependsOn = dependsOn
        self.repository = repository
        self.now = now
    }

    private func identity(_ scope: InstallationScope, _ journal: InstallationJournal?) throws -> ResourceIdentity {
        var material = "\(domain.rawValue)|\(scope.selectedDeviceIDHash ?? "none")|\(scope.connectionGeneration ?? 0)"
        for upstream in dependsOn {
            let active = journal?.activeResource(for: upstream)
            material += "|\(upstream.rawValue)=\(active?.identity.resourceID ?? "-")@\(active?.identity.digest ?? "-")"
        }
        return try ResourceIdentity(domain: domain, resourceID: "\(domain.rawValue)-device",
                                    digest: VeyaSigningKeyStore.sha256(Data(material.utf8)))
    }

    private func currentJournal() async throws -> InstallationJournal? {
        dependsOn.isEmpty ? nil : try await repository?.load()
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        let native: NativeDomainMapping
        do { native = try await observeNative(scope) } catch {
            native = .failed(DeviceDomainFailure.observationFailed)
        }
        let current = try identity(scope, journal)
        let generation = scope.connectionGeneration
        if let candidate = journal.candidateResource(for: domain) {
            // A candidate from another connection proves nothing now.
            guard candidate.identity == current, native.state == .satisfied else {
                return try DomainObservation(domain: domain, state: native.state == .satisfied ? .invalid : native.state,
                                             resource: candidate.identity, capturedAt: now(), connectionGeneration: generation,
                                             userAction: native.userAction, failure: native.failure)
            }
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, ownership: .activePayloadCorroboration,
                                         capturedAt: now(), connectionGeneration: generation)
        }
        let active = journal.activeResource(for: domain)
        if native.state == .satisfied {
            // Satisfied on this connection only if the active record was proven on this connection.
            let state: DomainObservationState = active?.identity == current ? .satisfied : (active == nil ? .missing : .stale)
            return try DomainObservation(domain: domain, state: state, resource: active?.identity,
                                         ownership: .activePayloadCorroboration, capturedAt: now(), connectionGeneration: generation)
        }
        return try DomainObservation(domain: domain, state: native.state, resource: active?.identity, capturedAt: now(),
                                     connectionGeneration: generation, userAction: native.userAction, failure: native.failure)
    }

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        switch context.planned.kind {
        case .proveCandidate, .promoteCandidate:
            guard let candidate = context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation, candidate: candidate)
        case .revokeOwnedCertificate:
            throw InstallationStateFailure.transitionUnavailable(domain)
        case .createCandidate, .replaceCandidate:
            break
        }
        let result = try await prepareNative(context.scope)
        if let failure = result.failure { throw failure }
        let record = try ResourceRecord(
            id: "\(domain.rawValue)-\(context.planned.generation.rawValue)",
            identity: identity(context.scope, try await currentJournal()),
            lifecycle: .candidate,
            generation: context.planned.generation,
            ownership: .activePayloadCorroboration,
            createdAt: now(),
            observedAt: now()
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
        // Proof is a fresh read-only observation, never the prepare call's own return value.
        let fresh = try await observeNative(context.scope)
        guard fresh.state == .satisfied, candidate.identity == (try identity(context.scope, try await currentJournal())) else {
            throw fresh.failure ?? InstallationStateFailure.candidateUnproved(domain)
        }
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("\(domain.rawValue)-proof|\(candidate.id)|\(candidate.generation.rawValue)|\(context.scope.connectionGeneration ?? 0)".utf8)),
            kind: "\(domain.rawValue)FreshObservation",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            connectionGeneration: context.scope.connectionGeneration,
            provenance: "device-coordinator"
        )
    }
}
