import Foundation

public enum RenewalProfileState: String, Codable, Equatable, Sendable { case valid, nearExpiry, expired, missing }
public enum RenewalCertificateState: String, Codable, Equatable, Sendable { case valid, revoked, expired, unknown }
public enum RenewalSessionState: String, Codable, Equatable, Sendable { case valid, reauthenticationRequired }

public struct RenewalInput: Codable, Equatable, Sendable {
    public let profile: RenewalProfileState
    public let certificate: RenewalCertificateState
    public let session: RenewalSessionState
    public let pairingOperational: Bool
    public let appInstalled: Bool
    public init(profile: RenewalProfileState, certificate: RenewalCertificateState, session: RenewalSessionState,
                pairingOperational: Bool, appInstalled: Bool) {
        self.profile = profile; self.certificate = certificate; self.session = session
        self.pairingOperational = pairingOperational; self.appInstalled = appInstalled
    }
}

public enum RenewalAction: String, Codable, Equatable, Sendable { case none, refreshProfiles, recreateCertificate, reauthenticate, repairPairing, installInPlace }

public struct RenewalPlan: Codable, Equatable, Sendable {
    public let actions: [RenewalAction]
    public init(actions: [RenewalAction]) { self.actions = actions }
}

public enum RenewalError: Error, Equatable, Sendable { case reauthenticationRequired, certificateUnavailable, appUpgradeFailed, verificationFailed }

public protocol MacAssistedRenewalService: Sendable {
    func reauthenticate() async throws
    func refreshProfiles(reuseCertificate: Bool) async throws
    func upgradeInPlace(on device: IOSSimDeviceIdentity) async throws
    func verifyAfterRenewal(on device: IOSSimDeviceIdentity) async throws
}

public struct AwaitingPhysicalRenewalService: MacAssistedRenewalService {
    public init() {}
    public func reauthenticate() async throws { throw RenewalError.reauthenticationRequired }
    public func refreshProfiles(reuseCertificate: Bool) async throws { throw RenewalError.appUpgradeFailed }
    public func upgradeInPlace(on device: IOSSimDeviceIdentity) async throws { throw RenewalError.appUpgradeFailed }
    public func verifyAfterRenewal(on device: IOSSimDeviceIdentity) async throws { throw RenewalError.verificationFailed }
}

public actor MacAssistedRenewalCoordinator {
    private let service: any MacAssistedRenewalService
    public init(service: any MacAssistedRenewalService = AwaitingPhysicalRenewalService()) { self.service = service }

    public static func plan(for input: RenewalInput) -> RenewalPlan {
        var actions: [RenewalAction] = []
        if input.session == .reauthenticationRequired { actions.append(.reauthenticate) }
        if input.certificate == .revoked || input.certificate == .expired { actions.append(.recreateCertificate) }
        if input.profile == .expired || input.profile == .nearExpiry || input.profile == .missing { actions.append(.refreshProfiles) }
        if !input.pairingOperational { actions.append(.repairPairing) }
        if input.appInstalled && actions.contains(.refreshProfiles) { actions.append(.installInPlace) }
        return RenewalPlan(actions: actions)
    }

    public func renew(input: RenewalInput, device: IOSSimDeviceIdentity) async throws -> RenewalPlan {
        let plan = Self.plan(for: input)
        if plan.actions.contains(.reauthenticate) {
            try await service.reauthenticate()
        }
        let recreate = plan.actions.contains(.recreateCertificate)
        if plan.actions.contains(.refreshProfiles) {
            try await service.refreshProfiles(reuseCertificate: !recreate)
            try await service.upgradeInPlace(on: device)
        }
        // Pairing is deliberately not deleted or regenerated as a side effect
        // of renewal. A separate repair action is required when proof fails.
        if plan.actions.contains(.installInPlace) || plan.actions.contains(.refreshProfiles) {
            try await service.verifyAfterRenewal(on: device)
        }
        return plan
    }
}
