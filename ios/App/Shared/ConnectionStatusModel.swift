import Foundation

/// A single setup/readiness step (Pairing, LocalDevVPN, Endpoint, Session).
/// Carries the original POCErrorCode/message so Developer diagnostics never
/// lose precision, while product surfaces show `humanDetail`.
enum SetupStepState: Equatable {
    case pending
    case checking
    case pass
    case fail(code: String, detail: String)

    var isPass: Bool { self == .pass }
}

/// Product-facing readiness state, shared app-wide. Wraps the existing
/// OnDeviceDVTExperimentRunner / LocationCoordinator calls unchanged; this is
/// purely a presentation layer that translates diagnostic stage results into
/// something a normal user (and the guided Setup screen) can read, while
/// keeping the exact original POCError code/message available for Developer
/// tooling. Shared as a single instance via POCAppDependencies.connectionStatus
/// so Location, Drive, Settings, and Setup all observe the same readiness.
@MainActor
final class ConnectionStatusModel: ObservableObject {
    @Published private(set) var pairingStep: SetupStepState = .pending
    @Published private(set) var localDevVPNStep: SetupStepState = .pending
    @Published private(set) var endpointStep: SetupStepState = .pending
    @Published private(set) var sessionStep: SetupStepState = .pending
    @Published private(set) var isReady = false
    @Published private(set) var isWorking = false

    private let runner: OnDeviceDVTExperimentRunner
    private let coordinator: LocationCoordinator
    private var pollTask: Task<Void, Never>?

    init(runner: OnDeviceDVTExperimentRunner, coordinator: LocationCoordinator) {
        self.runner = runner
        self.coordinator = coordinator
    }

    var allStepsPass: Bool {
        pairingStep.isPass && localDevVPNStep.isPass && endpointStep.isPass && sessionStep.isPass
    }

    /// Cheap, side-effect-free read of current coordinator state. Safe to call
    /// often (e.g. from `.task` on appear) since it does no network work.
    func refreshFromCurrentState() async {
        let snapshot = await coordinator.snapshot()
        isReady = snapshot.connectionState == .connected
        if isReady {
            pairingStep = .pass
            localDevVPNStep = .pass
            endpointStep = .pass
            sessionStep = .pass
        }
    }

    /// Runs the full existing diagnostics + connect sequence (same calls the
    /// original developer console used) and republishes the results as
    /// human-readable step state. Safe to call repeatedly; a second call
    /// while one is in flight is a no-op.
    func runSetup() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        pairingStep = .checking
        localDevVPNStep = .checking
        endpointStep = .checking
        _ = await runner.runDiagnostics()
        let snapshot = await runner.snapshot()
        let byStage = Dictionary(uniqueKeysWithValues: snapshot.stages.map { ($0.stage, $0) })

        pairingStep = stepState(for: [.pairingImported, .pairingValidated], in: byStage)
        localDevVPNStep = stepState(for: [.localDevVPNRouteVisible], in: byStage)
        endpointStep = stepState(for: [.endpointReachable], in: byStage)

        guard pairingStep.isPass, localDevVPNStep.isPass, endpointStep.isPass else {
            sessionStep = .pending
            isReady = false
            return
        }

        sessionStep = .checking
        do {
            try await runner.connect()
            sessionStep = .pass
            isReady = true
        } catch let error as POCError {
            sessionStep = .fail(code: error.code.rawValue, detail: error.message)
            isReady = false
        } catch {
            sessionStep = .fail(code: "UNKNOWN", detail: String(describing: error))
            isReady = false
        }
    }

    /// Ensures the app is connected, running setup first if needed. Used by
    /// product actions (Set Location, Start Drive) so a user never has to
    /// visit Setup manually if things are already working.
    @discardableResult
    func ensureReady() async -> Bool {
        await refreshFromCurrentState()
        if isReady { return true }
        await runSetup()
        return isReady
    }

    private func stepState(
        for stages: [POCStage],
        in byStage: [POCStage: POCStageRecord]
    ) -> SetupStepState {
        let records = stages.compactMap { byStage[$0] }
        if let failed = records.first(where: { $0.status == .failed }) {
            return .fail(
                code: failed.errorCode?.rawValue ?? "UNKNOWN",
                detail: failed.message ?? "Step failed."
            )
        }
        if records.allSatisfy({ $0.status == .success }), !records.isEmpty {
            return .pass
        }
        return .pending
    }
}

/// Maps a raw POCErrorCode to a short, human-readable explanation while the
/// original code/message stays available (callers already have `detail`,
/// which is the untranslated original POCError.message). Only covers codes a
/// normal user could plausibly hit during setup; anything else falls back to
/// the original message.
enum HumanReadableError {
    static func describe(code: String, detail: String) -> String {
        switch code {
        case "PAIRING_MISSING":
            return "No pairing file has been imported yet. Import the RPPairing file you generated on your Mac."
        case "PAIRING_FILE_INVALID", "PAIRING_CREDENTIAL_MISSING", "PAIRING_STORAGE_FAILED", "PAIRING_READ_FAILED":
            return "The imported pairing file couldn't be used. Re-import a valid RPPairing file."
        case "LOCALDEVVPN_ROUTE_MISSING":
            return "LocalDevVPN is not active. Open LocalDevVPN, enable the VPN, then return to IOSSim."
        case "ENDPOINT_UNREACHABLE":
            return "IOSSim can't reach the developer connection over LocalDevVPN. Confirm LocalDevVPN shows Connected, then try again."
        case "IDEVICE_BRIDGE_UNAVAILABLE":
            return "This build can't reach the device bridge. Reinstall the app from a build that includes the on-device bridge."
        case "TLS_PSK_FAILED", "RSD_FAILED", "DVT_FAILED", "DEVICE_INFO_WARMUP_FAILED":
            return "The developer connection failed to come up. Try again, or restart LocalDevVPN if this keeps happening."
        case "CORELOCATION_VERIFICATION_FAILED":
            return "The location was sent, but iOS hasn't confirmed it yet. It may take a few seconds to appear in other apps."
        case "DISCONNECTED":
            return "IOSSim is disconnected. Reconnect to continue."
        default:
            return detail
        }
    }
}
