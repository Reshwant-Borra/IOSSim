import Foundation

public struct ReconciliationPlanner: Sendable {
    public init() {}

    public func plan(
        snapshot: InstallationSnapshot,
        desired: DesiredInstallationState,
        policy: ReconciliationPolicy
    ) throws -> ReconciliationPlan {
        for requirement in desired.requirements where requirement.required {
            guard let observation = snapshot.observation(for: requirement.domain) else {
                // Nothing observed the domain: its state is unknown, so no mutation can be planned.
                return ReconciliationPlan(
                    snapshotRevision: snapshot.revision,
                    disposition: .blocked,
                    domain: requirement.domain,
                    failure: try VeyaFailure(
                        namespace: .state,
                        number: 17,
                        operation: "observeDomain",
                        safeMessage: "The installation domain could not be observed.",
                        underlyingSubsystem: requirement.domain.rawValue
                    )
                )
            }
            // Evidence from an earlier device connection proves nothing about the current one.
            let connectionCurrent = observation.isConnectionCurrent(snapshot.connectionGeneration)
            switch observation.state {
            case .satisfied:
                if !observation.isFresh(at: snapshot.capturedAt) || !connectionCurrent {
                    return try transitionPlan(
                        snapshot: snapshot,
                        desired: desired,
                        requirement: requirement,
                        kind: .replaceCandidate,
                        policy: policy
                    )
                }
                if let target = requirement.target, observation.resource != target {
                    return try transitionPlan(
                        snapshot: snapshot,
                        desired: desired,
                        requirement: requirement,
                        kind: .replaceCandidate,
                        policy: policy
                    )
                }
            case .missing:
                return try transitionPlan(
                    snapshot: snapshot,
                    desired: desired,
                    requirement: requirement,
                    kind: .createCandidate,
                    policy: policy
                )
            case .stale, .invalid:
                return try transitionPlan(
                    snapshot: snapshot,
                    desired: desired,
                    requirement: requirement,
                    kind: .replaceCandidate,
                    policy: policy
                )
            case .candidateUnproved:
                return try transitionPlan(
                    snapshot: snapshot,
                    desired: desired,
                    requirement: requirement,
                    kind: .proveCandidate,
                    policy: policy,
                    generation: snapshot.generation
                )
            case .candidateProved:
                return try transitionPlan(
                    snapshot: snapshot,
                    desired: desired,
                    requirement: requirement,
                    kind: connectionCurrent ? .promoteCandidate : .proveCandidate,
                    policy: policy,
                    generation: snapshot.generation
                )
            case .waitingForUser:
                return ReconciliationPlan(
                    snapshotRevision: snapshot.revision,
                    disposition: .userActionRequired,
                    domain: requirement.domain,
                    userAction: observation.userAction
                )
            case .retryableFailure:
                return ReconciliationPlan(
                    snapshotRevision: snapshot.revision,
                    disposition: .retryableWait,
                    domain: requirement.domain,
                    failure: observation.failure
                )
            case .terminalFailure:
                return ReconciliationPlan(
                    snapshotRevision: snapshot.revision,
                    disposition: .blocked,
                    domain: requirement.domain,
                    failure: observation.failure
                )
            }
        }
        return ReconciliationPlan(snapshotRevision: snapshot.revision, disposition: .ready)
    }

    private func transitionPlan(
        snapshot: InstallationSnapshot,
        desired: DesiredInstallationState,
        requirement: DesiredDomainState,
        kind: TransitionKind,
        policy: ReconciliationPolicy,
        generation: Generation? = nil
    ) throws -> ReconciliationPlan {
        // Policy gates mutation only; satisfied domains never need permission to be reported ready.
        let permission: ReconciliationPermission = .safeRepair
        guard permission <= policy.maximumPermission, policy.allowedDomains.contains(requirement.domain) else {
            return ReconciliationPlan(
                snapshotRevision: snapshot.revision,
                disposition: .blocked,
                domain: requirement.domain,
                failure: try policyFailure(requirement.domain)
            )
        }
        let plannedGeneration = try generation ?? snapshot.generation.advanced()
        let transition = try PlannedTransition(
            domain: requirement.domain,
            kind: kind,
            permission: permission,
            generation: plannedGeneration,
            target: requirement.target,
            desiredDigest: desired.digest
        )
        return ReconciliationPlan(
            snapshotRevision: snapshot.revision,
            disposition: .transitionRequired,
            transitions: [transition]
        )
    }

    private func policyFailure(_ domain: InstallationDomain) throws -> VeyaFailure {
        try VeyaFailure(
            namespace: .state,
            number: 12,
            operation: "planTransition",
            safeMessage: "The requested installation repair is outside the allowed qualification scope.",
            underlyingSubsystem: domain.rawValue
        )
    }
}
