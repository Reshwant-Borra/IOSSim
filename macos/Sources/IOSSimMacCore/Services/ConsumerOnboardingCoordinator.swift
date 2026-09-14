import Foundation

public enum ConsumerOnboardingPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case checkingIPhone, preparingAppleAccount, preparingIOSSim, installingIOSSim, pairingIPhone, verifyingConnection, ready
}

public enum OnboardingUserAction: String, Codable, Equatable, Sendable {
    case connectIPhone, unlockIPhone, trustComputer, enableDeveloperMode, completeTwoFactor, approveProfileTrust, approveVPN
}

public struct ConsumerOnboardingProgress: Codable, Equatable, Sendable {
    public let phase: ConsumerOnboardingPhase
    public let selectedDevice: IOSSimDeviceIdentity?
    public let userAction: OnboardingUserAction?
    public let detail: String?
    public init(phase: ConsumerOnboardingPhase, selectedDevice: IOSSimDeviceIdentity? = nil,
                userAction: OnboardingUserAction? = nil, detail: String? = nil) {
        self.phase = phase; self.selectedDevice = selectedDevice; self.userAction = userAction; self.detail = detail
    }
}

public enum ConsumerOnboardingError: Error, Equatable, Sendable {
    case selectionRequired
    case noDevice
    case failed(ConsumerOnboardingPhase, String)
}

public protocol ConsumerOnboardingServices: Sendable {
    func inspect(_ device: IOSSimDeviceIdentity) async throws -> NativeDeviceInspection
    func prepareAppleAccount() async throws
    func prepareIOSSim() async throws
    func install(on device: IOSSimDeviceIdentity) async throws
    func pair(on device: IOSSimDeviceIdentity) async throws
    func verify(on device: IOSSimDeviceIdentity) async throws
}

public struct AwaitingPhysicalConsumerOnboardingServices: ConsumerOnboardingServices {
    public init() {}
    public func inspect(_ device: IOSSimDeviceIdentity) async throws -> NativeDeviceInspection { throw NativeDeviceBridgeError.libraryUnavailable }
    public func prepareAppleAccount() async throws { throw NativeDeviceBridgeError.libraryUnavailable }
    public func prepareIOSSim() async throws { throw NativeDeviceBridgeError.libraryUnavailable }
    public func install(on device: IOSSimDeviceIdentity) async throws { throw NativeDeviceBridgeError.libraryUnavailable }
    public func pair(on device: IOSSimDeviceIdentity) async throws { throw NativeDeviceBridgeError.libraryUnavailable }
    public func verify(on device: IOSSimDeviceIdentity) async throws { throw NativeDeviceBridgeError.libraryUnavailable }
}

public actor ConsumerOnboardingCoordinator {
    private let bridge: IOSSimDeviceBridge
    private let services: any ConsumerOnboardingServices
    private let journal: SetupJournalStore
    private var progress = ConsumerOnboardingProgress(phase: .checkingIPhone)

    public init(bridge: IOSSimDeviceBridge = IOSSimDeviceBridge(),
                services: any ConsumerOnboardingServices = AwaitingPhysicalConsumerOnboardingServices(),
                journal: SetupJournalStore = SetupJournalStore()) {
        self.bridge = bridge; self.services = services; self.journal = journal
    }

    public func currentProgress() -> ConsumerOnboardingProgress { progress }

    public func run(selectedUDID: String? = nil) async throws -> ConsumerOnboardingProgress {
        progress = .init(phase: .checkingIPhone)
        let devices = try await bridge.listDevices()
        guard !devices.isEmpty else { throw ConsumerOnboardingError.noDevice }
        let selected: NativeDeviceDescriptor
        if let selectedUDID {
            guard let match = devices.first(where: { $0.identity.udid == selectedUDID }) else { throw ConsumerOnboardingError.selectionRequired }
            selected = match
        } else {
            guard devices.count == 1 else { throw ConsumerOnboardingError.selectionRequired }
            selected = devices[0]
        }
        let identity = selected.identity
        let inspection = try await services.inspect(identity)
        if inspection.lockState == .locked { return await waiting(.unlockIPhone, device: identity) }
        if inspection.trust == .missing { return await waiting(.trustComputer, device: identity) }
        if inspection.developerMode == .disabled || inspection.developerMode == .requiresUserAction { return await waiting(.enableDeveloperMode, device: identity) }

        try await stage(.preparingAppleAccount, device: identity) { try await self.services.prepareAppleAccount() }
        try await stage(.preparingIOSSim, device: identity) { try await self.services.prepareIOSSim() }
        try await stage(.installingIOSSim, device: identity) { try await self.services.install(on: identity) }
        try await stage(.pairingIPhone, device: identity) { try await self.services.pair(on: identity) }
        try await stage(.verifyingConnection, device: identity) { try await self.services.verify(on: identity) }
        progress = .init(phase: .ready, selectedDevice: identity, detail: "IOSSim is ready")
        try? await journal.save(SetupJournalEntry(selectedDeviceUDID: identity.udid, completedStages: ConsumerOnboardingPhase.allCases.map(\.rawValue), currentStage: ConsumerOnboardingPhase.ready.rawValue))
        return progress
    }

    private func waiting(_ action: OnboardingUserAction, device: IOSSimDeviceIdentity) async -> ConsumerOnboardingProgress {
        progress = .init(phase: .checkingIPhone, selectedDevice: device, userAction: action)
        try? await journal.save(SetupJournalEntry(selectedDeviceUDID: device.udid, currentStage: progress.phase.rawValue, userAction: action.rawValue))
        return progress
    }

    private func stage(_ phase: ConsumerOnboardingPhase, device: IOSSimDeviceIdentity, operation: @escaping @Sendable () async throws -> Void) async throws {
        progress = .init(phase: phase, selectedDevice: device)
        do { try await operation() }
        catch { throw ConsumerOnboardingError.failed(phase, Redactor.redact(String(describing: error))) }
        try? await journal.save(SetupJournalEntry(selectedDeviceUDID: device.udid, currentStage: phase.rawValue))
    }
}
