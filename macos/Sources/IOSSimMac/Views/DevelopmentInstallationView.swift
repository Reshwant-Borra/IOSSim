#if VEYA_QUALIFICATION
import SwiftUI
import IOSSimMacCore

@MainActor
final class DevelopmentInstallationModel: ObservableObject {
    @Published var devices: [NativeDeviceInspection] = []
    @Published var selected = ""
    @Published var message = "M4 DEFERRED - development session only"
    @Published var busy = false
    @Published var needsVerification = false
    @Published var result: QualificationResult?
    @Published var primaryAction: DevelopmentInstallationPrimaryAction = .installOrPrepare
    @Published var stage: DevelopmentInstallationStage = .preparingApp
    @Published var lastActionFailure: DevelopmentInstallationFailureContext?
    /// Pre-install Developer Mode gate. While this is not `.verified` the primary button belongs
    /// to the gate and no engine command runs for the selected iPhone.
    @Published var gate = DeveloperModeGateProgress.initial
    private var issuedRunSetupRequest = false
    private let session = DevelopmentInstallationSession()
    private let bridge = IOSSimDeviceBridge()
    private let transport = DynamicNativeDeviceTransport()
    private lazy var developerModeGate = DeveloperModeGateCoordinator(
        services: NativeDeveloperModeGateServices(bridge: bridge, transport: transport)
    )

    func refresh() async {
        await perform {
            self.result = nil
            self.primaryAction = .installOrPrepare
            self.stage = .preparingApp
            self.lastActionFailure = nil
            self.devices = []
            for descriptor in try await self.bridge.listDevices() {
                self.devices.append(try await self.bridge.inspect(descriptor.identity))
            }
            if !self.devices.contains(where: { $0.identity.udid == self.selected }) {
                self.selected = self.devices.count == 1 ? self.devices[0].identity.udid : ""
            }
            await self.evaluateGate()
            self.message = self.devices.isEmpty ? "Connect and unlock your iPhone." : "Device observation complete."
        }
    }

    func authorize(account: String, secret: SensitiveInput, verification: Bool) async {
        defer { secret.clear() }
        await perform {
            let response = try await verification
                ? self.session.apple.submitVerification(code: secret)
                : self.session.apple.beginAuthorization(account: account, password: secret)
            switch response {
            case .verificationRequired:
                self.needsVerification = true
                self.message = "Enter the Apple verification code."
            case .authorized(let teams):
                self.needsVerification = false
                self.message = "Authorized: " + teams.map(\.name).joined(separator: ", ")
            }
        }
    }

    func pair() async {
        guard let device = devices.first(where: { $0.identity.udid == selected }) else { return }
        await perform {
            _ = try self.transport.pairLockdownOnce(on: device.identity)
            self.message = "Lockdown session validated."
        }
        await refresh()
    }

    // MARK: - Pre-install Developer Mode gate

    /// Cheap re-evaluation from the inspection `refresh()` already took. It can only raise the
    /// gate, so an iPhone that already reports Developer Mode on goes straight to Install /
    /// Prepare without an extra step.
    private func evaluateGate() async {
        guard let device = devices.first(where: { $0.identity.udid == selected }) else {
            gate = await developerModeGate.reset()
            applyGateStage()
            return
        }
        gate = await developerModeGate.adopt(inspection: device)
        applyGateStage()
    }

    /// "Enable Developer Mode". The minimum safe operation: AMFI action 0, which makes iOS show
    /// the toggle. It installs nothing, enables nothing, starts no VPN or pairing, and never
    /// runs the engine.
    func revealDeveloperMode() async {
        guard let device = devices.first(where: { $0.identity.udid == selected }) else { return }
        await perform {
            self.gate = await self.developerModeGate.reveal(on: device.identity)
            self.applyGateStage()
            self.message = self.gate.detail
        }
    }

    /// "Continue" while the gate holds. Re-binds the iPhone after Apple's restart and accepts
    /// only device-side evidence. The click alone never advances anything.
    func continueDeveloperModeGate() async {
        guard !selected.isEmpty else { return }
        let selectedUDID = selected
        await perform {
            self.gate = await self.developerModeGate.verify(stableUDID: selectedUDID)
            self.applyGateStage()
            if let rebound = self.gate.device {
                let inspection = try? await self.bridge.inspect(rebound)
                if let inspection, let index = self.devices.firstIndex(where: { $0.identity.udid == selectedUDID }) {
                    self.devices[index] = inspection
                } else if let inspection {
                    self.devices.append(inspection)
                }
            }
            self.message = self.gate.detail
        }
    }

    private func applyGateStage() {
        switch gate.phase {
        case .reveal:
            stage = .revealDeveloperMode
        case .enable:
            stage = .enableDeveloperMode
        case .verified:
            if stage.isDeveloperModeGate {
                stage = .preparingApp
                primaryAction = .installOrPrepare
            }
        }
    }

    func run(_ command: EngineCommand) async {
        guard !selected.isEmpty else { return }
        // The engine never runs for an iPhone whose Developer Mode prerequisite is unmet. The
        // gate owns the button until it has device-side evidence; this is the fail-closed
        // backstop for any path that reaches `run` with the gate still holding.
        guard gate.allowsEnginePipeline else {
            await continueDeveloperModeGate()
            return
        }
        let selectedUDID = selected
        await perform {
            self.result = nil
            self.issuedRunSetupRequest = false
            self.lastActionFailure = nil
            if self.primaryAction == .continueOrVerifySetup {
                self.stage = .verifyingSetup
            }
            guard let device = self.devices.first(where: { $0.identity.udid == selectedUDID }) else { return }
            let target = EngineDeviceSelection(udid: device.identity.udid, name: device.name ?? "iPhone",
                                               transportIdentity: device.identity)
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/IOSSimProvisioner")
            // No run waits on the user: the request is placed and the run ends. The callback
            // records which of the two setup states this run reached.
            let composition = self.session.composition(
                helperURL: helper, device: target,
                connectionGeneration: device.identity.connectionGeneration,
                runSetupProgress: { [weak self] progress in
                    Task { @MainActor in
                        if progress == .readyForSetup { self?.issuedRunSetupRequest = true }
                        self?.message = Self.describe(progress)
                    }
                },
                transitionProgress: { [weak self] domain in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stage = .transition(domain, current: self.stage)
                    }
                })
            let request = EngineRequest(command: command,
                capabilities: CapabilityManifest(allowedDomains: InstallationDomain.reconciliationOrder,
                                                 maximumPermission: .destructiveOwned, maximumTransitions: 64),
                connectionGeneration: device.identity.connectionGeneration, device: target)
            let response = await EngineHost.handle(request, composition: composition)
            let waiting = response.firstFailure?.code == RuntimeReadinessDomain.runSetupRequired.code
            self.lastActionFailure = waiting && self.issuedRunSetupRequest
                ? nil
                : DevelopmentInstallationFailureContext(result: response)
            // A transition that throws returns no snapshot; re-observe so the list is current, not blank or stale.
            self.result = response.observations.isEmpty && command != .inspect
                ? await EngineHost.handle(EngineRequest(command: .inspect, connectionGeneration: device.identity.connectionGeneration,
                                                        device: target), composition: composition)
                : response
            if command != .inspect {
                self.stage = .resolve(
                    firstFailureCode: response.firstFailure?.code,
                    failureDomain: response.firstFailure?.domain,
                    userAction: response.userAction,
                    status: response.status,
                    issuedRunSetupRequest: self.issuedRunSetupRequest
                )
                self.primaryAction = self.stage == .preparingApp
                    ? .resolve(firstFailureCode: response.firstFailure?.code, userAction: response.userAction)
                    : self.stage.primaryAction
                if response.userAction == DeviceFailureMapping.developerMode {
                    // Developer Mode was verified earlier and is no longer available. Withdraw the
                    // evidence and re-enter the prerequisite instead of retrying the engine.
                    self.gate = await self.developerModeGate.invalidate(
                        detail: "This iPhone no longer reports Developer Mode as available. "
                            + (response.userAction ?? "")
                    )
                    self.applyGateStage()
                }
            }
            // Everything the Mac can do finished and the request is newly placed: that is the
            // hand-off to the iPhone, not a complaint that the user has not acted yet.
            self.message = waiting && self.issuedRunSetupRequest
                ? Self.readyForSetup
                : response.userAction.map { "ACTION REQUIRED: \($0)" }
                    ?? response.firstFailure?.safeMessage ?? response.status
        }
    }

    static let readyForSetup = "READY FOR SETUP\nOpen Veya on your iPhone and tap Run Setup, "
        + "then continue in Veya."

    static func describe(_ progress: RunSetupProgress) -> String {
        switch progress {
        case .readyForSetup:
            return readyForSetup
        case .waitingForRunSetupTap:
            return "Reading the Run Setup result from your iPhone."
        case .failedOnPhone(let code, let message):
            return "Run Setup on the iPhone failed (\(code)): \(message) — fix it and tap Run Setup again."
        }
    }

    func resetPresentation() {
        result = nil
        primaryAction = .installOrPrepare
        stage = .preparingApp
        lastActionFailure = nil
        // A different iPhone proves nothing about this one.
        Task { [weak self] in
            guard let self else { return }
            self.gate = await self.developerModeGate.reset()
            await self.evaluateGate()
        }
    }

    private func perform(_ body: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await body() }
        catch { message = (error as? VeyaFailure)?.safeMessage ?? String(describing: error) }
    }
}

struct DevelopmentInstallationView: View {
    @StateObject private var model = DevelopmentInstallationModel()
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Veya Development").font(.title2.bold())
            Text("M4 DEFERRED - PRE-RELEASE BLOCKER").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.stage.title).font(.headline)
                Text(model.stage.instruction).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Picker("iPhone", selection: $model.selected) {
                    Text("Select iPhone").tag("")
                    ForEach(model.devices, id: \.identity.udid) { device in
                        Text("\(device.name ?? "iPhone") - \(device.osVersion ?? "unknown iOS")").tag(device.identity.udid)
                    }
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh devices")
                Button("Trust / Pair") { Task { await model.pair() } }.disabled(model.selected.isEmpty)
            }
            HStack {
                TextField("Apple Account", text: $account)
                SecureField("Password", text: $password)
                Button("Sign In") {
                    let secret = SensitiveInput(password)
                    password = ""
                    Task { await model.authorize(account: account, secret: secret, verification: false) }
                }.disabled(account.isEmpty || password.isEmpty)
            }
            if model.needsVerification {
                HStack {
                    SecureField("Verification code", text: $code)
                    Button("Verify") {
                        let secret = SensitiveInput(code)
                        code = ""
                        Task { await model.authorize(account: account, secret: secret, verification: true) }
                    }.disabled(code.isEmpty)
                }
            }
            HStack {
                Button("Inspect") { Task { await model.run(.inspect) } }
                // While the Developer Mode prerequisite is unmet the button belongs to the gate:
                // "Enable Developer Mode" performs only AMFI's reveal, and "Continue" only
                // re-verifies the device. Neither starts the engine.
                if !model.gate.allowsEnginePipeline {
                    switch model.gate.phase {
                    case .reveal:
                        Button("Enable Developer Mode") { Task { await model.revealDeveloperMode() } }
                    case .enable, .verified:
                        Button("Continue") { Task { await model.continueDeveloperModeGate() } }
                    }
                } else {
                    // One primary action, named for the phase it is in. Every run re-observes and the
                    // planner stops at the first unsatisfied domain, so the same `.reconcile` both
                    // prepares and verifies; a second button would only be a second name for it, and a
                    // disabled one contradicts every "then continue in Veya" instruction.
                    Button(model.primaryAction.rawValue) {
                        Task { await model.run(model.primaryAction.command) }
                    }
                }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.selected.isEmpty)
            // `.id`: a selectable Text can keep its old (blank) layout when the string changes (observed physically).
            Text(model.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).id(model.message)
            if let failure = model.lastActionFailure {
                GroupBox("Last action failed") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let domain = failure.domain { Text(domain.rawValue).fontWeight(.semibold) }
                            if let code = failure.code { Text(code).font(.system(.caption, design: .monospaced)) }
                        }
                        Text(failure.safeMessage).textSelection(.enabled)
                        if let action = failure.userAction, action != failure.safeMessage {
                            Text(action).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let result = model.result {
                Text("Current device state")
                    .font(.headline)
                Text("Read-only observation (not continuous readiness). Development session: relaunching Veya discards the "
                     + "Apple session and signing key (M4 deferred), so those show waitingForUser/invalid until the next Install / Prepare.")
                    .font(.caption).foregroundStyle(.secondary)
                List(result.observations, id: \.domain) { observation in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(observation.domain.rawValue).frame(width: 150, alignment: .leading)
                            Text(observation.state.rawValue)
                            Spacer()
                            Text(observation.capturedAt, style: .time).foregroundStyle(.secondary)
                        }
                        if let action = observation.userAction {
                            Text(action).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .disabled(model.busy)
        .onChange(of: model.selected) { _ in model.resetPresentation() }
        .task { await model.refresh() }
    }
}
#endif
