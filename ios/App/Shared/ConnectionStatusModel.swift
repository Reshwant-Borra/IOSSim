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
    /// Veya on the Mac has delivered a setup request and is waiting for the user
    /// to tap Run Setup here. Nothing starts the run except that tap.
    @Published private(set) var veyaSetupRequestPending = false

    private let runner: OnDeviceDVTExperimentRunner
    private let coordinator: LocationCoordinator
    private let setupInbox: RunSetupInbox
    private var pollTask: Task<Void, Never>?

    init(
        runner: OnDeviceDVTExperimentRunner,
        coordinator: LocationCoordinator,
        setupInbox: RunSetupInbox = RunSetupInbox()
    ) {
        self.runner = runner
        self.coordinator = coordinator
        self.setupInbox = setupInbox
    }

    /// Polls the container inbox while the app is active. House Arrest may place
    /// the request after this app was already launched, so a single check on
    /// appear would miss it.
    func watchForVeyaSetupRequest(pollNanoseconds: UInt64 = 1_000_000_000) async {
        while !Task.isCancelled {
            veyaSetupRequestPending = pendingVeyaRequest() != nil
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    private func pendingVeyaRequest() -> RunSetupRequest? {
        (try? setupInbox.pendingRequest()) ?? nil
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
    ///
    /// `answeringVeyaRequest` is set only by the Run Setup button. It records the
    /// result of this same real run for Veya, and adds the one check the run
    /// otherwise lacks: a delivered coordinate that Core Location confirms, then
    /// cleared. Product paths (`ensureReady`) never pass it, so ordinary use is
    /// unchanged.
    func runSetup(answeringVeyaRequest: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let request = answeringVeyaRequest ? pendingVeyaRequest() : nil
        var outcome = RunSetupOutcome()

        pairingStep = .checking
        localDevVPNStep = .checking
        endpointStep = .checking
        _ = await runner.runDiagnostics()
        let snapshot = await runner.snapshot()
        let byStage = Dictionary(uniqueKeysWithValues: snapshot.stages.map { ($0.stage, $0) })

        pairingStep = stepState(for: [.pairingImported, .pairingValidated], in: byStage)
        localDevVPNStep = stepState(for: [.localDevVPNRouteVisible], in: byStage)
        endpointStep = stepState(for: [.endpointReachable], in: byStage)
        outcome.pairingReady = pairingStep.isPass
        outcome.localDevVPNReady = localDevVPNStep.isPass
        outcome.endpointReachable = endpointStep.isPass

        guard snapshot.setupPrerequisitesReady else {
            sessionStep = .pending
            isReady = false
            if let request {
                let failure = firstFailure(in: [pairingStep, localDevVPNStep, endpointStep])
                outcome.fail(
                    code: failure?.code ?? "SETUP_PREREQUISITES_INCOMPLETE",
                    message: failure?.detail ?? "Pairing, LocalDevVPN and the developer endpoint are not all ready."
                )
                record(outcome, for: request)
            }
            return
        }

        sessionStep = .checking
        do {
            try await runner.connect()
            outcome.sessionEstablished = true
            sessionStep = .pass
            isReady = true
        } catch let error as POCError {
            sessionStep = .fail(code: error.code.rawValue, detail: error.message)
            isReady = false
            if let request {
                outcome.fail(code: error.code.rawValue, message: error.message)
                record(outcome, for: request)
            }
            return
        } catch {
            sessionStep = .fail(code: "UNKNOWN", detail: String(describing: error))
            isReady = false
            if let request {
                outcome.fail(code: "UNKNOWN", message: String(describing: error))
                record(outcome, for: request)
            }
            return
        }

        guard let request else { return }
        await completeSetupForVeya(request: request, outcome: outcome)
    }

    /// `connect()` can return from a cached session without touching the device, so a
    /// reported success would otherwise only mean the channel was once open. One real,
    /// read-only dtservicehub round-trip proves the session is alive now. It sends no
    /// coordinate and clears nothing: setup never moves the iPhone's location.
    private func completeSetupForVeya(request: RunSetupRequest, outcome baseline: RunSetupOutcome) async {
        var outcome = baseline
        do {
            try await runner.probeSession()
            outcome.sessionProbed = true
        } catch let error as POCError {
            outcome.fail(code: error.code.rawValue, message: error.message)
            sessionStep = .fail(code: error.code.rawValue, detail: error.message)
            isReady = false
        } catch {
            outcome.fail(code: "UNKNOWN", message: String(describing: error))
            sessionStep = .fail(code: "UNKNOWN", detail: String(describing: error))
            isReady = false
        }

        record(outcome, for: request)
        // The probe leaves the session exactly as it found it, so there is nothing to
        // restore: the app stays usable right after setup.
        isReady = outcome.sessionProbed && outcome.errorCode == nil
    }

    private func record(_ outcome: RunSetupOutcome, for request: RunSetupRequest) {
        let receipt = try? setupInbox.record(outcome, for: request)
        veyaSetupRequestPending = !(receipt?.succeeded ?? false)
    }

    private func firstFailure(in steps: [SetupStepState]) -> (code: String, detail: String)? {
        for step in steps {
            if case .fail(let code, let detail) = step { return (code, detail) }
        }
        return nil
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
            return "IOSSim could not see the expected VPN interface address. Run setup again to check the developer endpoint."
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
