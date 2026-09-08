import Foundation

public enum ConsumerProvisioningFaultPoint: String, CaseIterable, Sendable {
    case signingIdentityResolution = "SIGNING_IDENTITY_RESOLUTION"
    case preparingArtifacts = "PREPARING_ARTIFACTS"
    case nestedSigning = "NESTED_SIGNING"
    case mainSigning = "MAIN_SIGNING"
    case runnerSigning = "RUNNER_SIGNING"
    case signatureVerification = "SIGNATURE_VERIFICATION"
    case installMain = "INSTALL_MAIN"
    case installRunner = "INSTALL_RUNNER"
    case installVerification = "INSTALL_VERIFICATION"
    case runtimeConfigWrite = "RUNTIME_CONFIG_WRITE"
    case runtimeConfigVerify = "RUNTIME_CONFIG_VERIFY"
    case deviceDisconnected = "DEVICE_DISCONNECTED"
}

public protocol ConsumerProvisioningFaultInjecting: Sendable {
    func check(_ point: ConsumerProvisioningFaultPoint) throws
}

public struct NoConsumerProvisioningFaults: ConsumerProvisioningFaultInjecting {
    public init() {}
    public func check(_ point: ConsumerProvisioningFaultPoint) throws {}
}
