#if VEYA_QUALIFICATION
import Foundation

/// The pre-install Developer Mode prerequisite. It sits strictly in front of the reconciliation
/// engine: nothing here installs, signs, pairs, mounts a developer-support image, starts
/// LocalDevVPN, or issues an engine command. The only mutation it ever performs is AMFI's
/// reveal action, which makes iOS show the Developer Mode toggle in Settings.
public enum DeveloperModeGate {
    /// Device-side proof that Developer Mode is actually usable. The user pressing Continue is
    /// never proof; exactly one of these has to come back from the phone.
    public enum Evidence: String, Codable, Equatable, Sendable {
        /// AMFI's status action reported the toggle on. Trustworthy when positive.
        case amfiStatusEnabled
        /// A personalized developer-support image is mounted, which iOS does not permit while
        /// Developer Mode is off.
        case personalizedImageMounted
        /// The complete CoreDevice/RSD/RemoteXPC/AppService chain answered.
        case developerServicesReady
    }

    /// AMFI's status action is advisory: iOS 26.6.2 has been physically observed reporting
    /// `disabled` while the full developer-services probe succeeded (see the note in
    /// `NativeDeveloperServicesCoordinator.prepare`). It is therefore one of three accepted
    /// proofs rather than the only one. No proof at all means the gate holds.
    public static func evidence(
        developerMode: DeveloperModeReadiness,
        personalizedImageMounted: Bool,
        developerServicesTransportReady: Bool
    ) -> Evidence? {
        if developerMode == .enabled { return .amfiStatusEnabled }
        if personalizedImageMounted { return .personalizedImageMounted }
        if developerServicesTransportReady { return .developerServicesReady }
        return nil
    }
}

extension DeveloperModeReadiness {
    /// Only an explicit answer from the iPhone. `unknown` and `serviceUnavailable` mean the
    /// question went unanswered and are never read as "off".
    var isAuthoritative: Bool { self == .enabled || self == .disabled }
}

public enum DeveloperModeGatePhase: String, Codable, Equatable, Sendable {
    /// The toggle may still be hidden. The only offer is the AMFI reveal.
    case reveal
    /// The toggle is showing. The user enables it and completes Apple's restart and
    /// confirmation on the iPhone, then returns.
    case enable
    /// Device-side evidence was accepted. The existing engine pipeline may run.
    case verified
    /// The iPhone did not answer whether Developer Mode is on. Veya neither claims it is off
    /// nor lets the engine run; the only offer is to check again.
    case undetermined
}

public struct DeveloperModeGateProgress: Equatable, Sendable {
    public let phase: DeveloperModeGatePhase
    public let evidence: DeveloperModeGate.Evidence?
    /// Safe, user-facing explanation of the last gate operation.
    public let detail: String
    /// The device the gate is bound to, re-read after every rebinding.
    public let device: IOSSimDeviceIdentity?

    public init(
        phase: DeveloperModeGatePhase,
        evidence: DeveloperModeGate.Evidence? = nil,
        detail: String,
        device: IOSSimDeviceIdentity? = nil
    ) {
        self.phase = phase
        self.evidence = evidence
        self.detail = detail
        self.device = device
    }

    public static let initial = DeveloperModeGateProgress(
        phase: .reveal,
        detail: "Veya will ask this iPhone to show its Developer Mode option."
    )

    public var allowsEnginePipeline: Bool { phase == .verified }
}

/// Device operations the gate needs. Every one is read-only except `revealDeveloperMode`,
/// which is AMFI action 0 and reveals the toggle without enabling it or rebooting.
public protocol DeveloperModeGateServicing: Sendable {
    func revealDeveloperMode(on device: IOSSimDeviceIdentity) async throws
    /// Re-lists devices and returns a fresh inspection for this exact stable UDID. Enabling
    /// Developer Mode reboots the iPhone, so the transport identity and connection generation
    /// change; the UDID does not, and another attached iPhone is never a substitute.
    func rebind(stableUDID: String) async throws -> NativeDeviceInspection
    func personalizedImageMounted(on device: IOSSimDeviceIdentity) async -> Bool
    func developerServicesTransportReady(on device: IOSSimDeviceIdentity) async -> Bool
}

/// Production adapter. `IOSSimDeviceBridge` is shared with the caller so the connection
/// generation it hands out stays the one the engine request is built from.
public struct NativeDeveloperModeGateServices: DeveloperModeGateServicing {
    private let bridge: IOSSimDeviceBridge
    private let transport: DynamicNativeDeviceTransport

    public init(
        bridge: IOSSimDeviceBridge,
        transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport()
    ) {
        self.bridge = bridge
        self.transport = transport
    }

    public func revealDeveloperMode(on device: IOSSimDeviceIdentity) async throws {
        try transport.revealDeveloperMode(on: device)
    }

    public func rebind(stableUDID: String) async throws -> NativeDeviceInspection {
        let descriptors = try await bridge.listDevices()
        guard let rebound = DevelopmentDeviceRebinding.descriptor(
            forStableUDID: stableUDID,
            in: descriptors
        ) else {
            throw NativeDeviceBridgeError.deviceNotFound
        }
        return try await bridge.inspect(rebound.identity)
    }

    public func personalizedImageMounted(on device: IOSSimDeviceIdentity) async -> Bool {
        ((try? transport.developerSupportMounted(on: device)) ?? false)
    }

    public func developerServicesTransportReady(on device: IOSSimDeviceIdentity) async -> Bool {
        ((try? transport.developerServicesReadiness(on: device))?.transportReady) ?? false
    }
}

/// Holds the gate's state for the selected iPhone. A run of the engine is only permitted while
/// `progress.allowsEnginePipeline` is true, and the engine can revoke that at any later point
/// through `invalidate(detail:)` when it reports the Developer Mode user action again.
public actor DeveloperModeGateCoordinator {
    private let services: any DeveloperModeGateServicing
    private var progress = DeveloperModeGateProgress.initial

    public init(services: any DeveloperModeGateServicing) {
        self.services = services
    }

    public func currentProgress() -> DeveloperModeGateProgress { progress }

    /// A different iPhone proves nothing about this one.
    @discardableResult
    public func reset() -> DeveloperModeGateProgress {
        progress = .initial
        return progress
    }

    /// Cheap evaluation from an inspection the caller already holds, used when a device is
    /// selected or the list is refreshed. It can only ever *raise* the gate to `.verified` on
    /// the device's positive answer, so an iPhone that is already set up is never
    /// interrupted, including after Veya relaunches. It never lowers a verified gate: an
    /// advisory `disabled` must not un-verify a phone proven through a mounted image or a live
    /// developer-services session. Lowering is the engine's job, through `invalidate(detail:)`,
    /// or `reset()` on a different iPhone. Before verification it only tells "the iPhone did
    /// not answer" apart from "Developer Mode is off", so the UI never claims the latter
    /// without the device saying so.
    @discardableResult
    public func adopt(inspection: NativeDeviceInspection) -> DeveloperModeGateProgress {
        switch (progress.phase, inspection.developerMode) {
        case (.verified, _):
            break
        case (_, .enabled):
            progress = DeveloperModeGateProgress(
                phase: .verified,
                evidence: .amfiStatusEnabled,
                detail: "Developer Mode verified on this iPhone.",
                device: inspection.identity
            )
        case (.reveal, let mode) where !mode.isAuthoritative:
            progress = Self.undetermined(device: inspection.identity)
        case (.undetermined, .disabled):
            progress = .initial
        default:
            break
        }
        return progress
    }

    /// AMFI action 0 only. On failure the gate stays in `.reveal` so the user is never told to
    /// look for a toggle that was not revealed.
    @discardableResult
    public func reveal(on device: IOSSimDeviceIdentity) async -> DeveloperModeGateProgress {
        do {
            try await services.revealDeveloperMode(on: device)
            progress = DeveloperModeGateProgress(
                phase: .enable,
                detail: DeveloperModeGateCoordinator.enableInstruction,
                device: device
            )
        } catch {
            progress = DeveloperModeGateProgress(
                phase: .reveal,
                detail: "Veya could not ask this iPhone to show Developer Mode: "
                    + "\(Self.describe(error)) Keep it connected, unlocked and trusted, then try again.",
                device: device
            )
        }
        return progress
    }

    /// Continue. Re-binds the iPhone after Apple's restart and accepts only device-side
    /// evidence; the click itself never advances the gate.
    @discardableResult
    public func verify(stableUDID: String) async -> DeveloperModeGateProgress {
        let inspection: NativeDeviceInspection
        do {
            inspection = try await services.rebind(stableUDID: stableUDID)
        } catch {
            progress = DeveloperModeGateProgress(
                phase: progress.phase == .reveal || progress.phase == .undetermined ? progress.phase : .enable,
                detail: "Veya could not reach the same iPhone: \(Self.describe(error)) "
                    + "Reconnect and unlock it, then press Continue again.",
                device: nil
            )
            return progress
        }
        let device = inspection.identity
        let evidence = DeveloperModeGate.evidence(
            developerMode: inspection.developerMode,
            personalizedImageMounted: await services.personalizedImageMounted(on: device),
            developerServicesTransportReady: await services.developerServicesTransportReady(on: device)
        )
        guard let evidence else {
            guard inspection.developerMode.isAuthoritative else {
                // No answer is not "off": keep the user's place and ask to check again.
                progress = progress.phase == .reveal || progress.phase == .undetermined
                    ? Self.undetermined(device: device)
                    : DeveloperModeGateProgress(phase: .enable, detail: Self.unreadable, device: device)
                return progress
            }
            progress = DeveloperModeGateProgress(
                phase: progress.phase == .reveal || progress.phase == .undetermined ? .reveal : .enable,
                detail: "This iPhone still reports Developer Mode as unavailable. "
                    + DeveloperModeGateCoordinator.enableInstruction,
                device: device
            )
            return progress
        }
        progress = DeveloperModeGateProgress(
            phase: .verified,
            evidence: evidence,
            detail: "Developer Mode verified on this iPhone.",
            device: device
        )
        return progress
    }

    /// The engine reported the Developer Mode user action after the gate had passed. Evidence is
    /// withdrawn and the prerequisite is re-entered rather than the engine being retried blindly.
    @discardableResult
    public func invalidate(detail: String) -> DeveloperModeGateProgress {
        progress = DeveloperModeGateProgress(
            phase: .enable,
            detail: detail,
            device: progress.device
        )
        return progress
    }

    static let unreadable =
        "This iPhone did not report whether Developer Mode is on. Keep it unlocked and connected, "
        + "then press Continue to check again."

    private static func undetermined(device: IOSSimDeviceIdentity) -> DeveloperModeGateProgress {
        DeveloperModeGateProgress(phase: .undetermined, detail: unreadable, device: device)
    }

    static let enableInstruction =
        "On the iPhone open Settings > Privacy & Security > Developer Mode, turn it on, follow the "
        + "restart prompt, unlock the iPhone, then press Continue."

    private static func describe(_ error: Error) -> String {
        guard let bridge = error as? NativeDeviceBridgeError else {
            return Redactor.redact(String(describing: error))
        }
        switch bridge {
        case .deviceLocked: return "the iPhone is locked."
        case .trustRequired, .trustPromptPending, .trustDenied:
            return "this Mac is not trusted by the iPhone yet."
        case .deviceNotFound, .deviceDisconnected, .deviceResolutionFailed:
            return "it is not connected."
        case .timedOut: return "the iPhone did not answer in time."
        case .incompatibleABI, .libraryUnavailable, .libraryLoadFailure:
            return "this build's device bridge is too old for the Developer Mode step."
        default: return "the device service refused the request."
        }
    }
}
#endif
