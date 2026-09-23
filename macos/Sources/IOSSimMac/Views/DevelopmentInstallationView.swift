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
    /// Veya is holding a request the iPhone has not answered yet: the Mac's work is done
    /// and the next step is the user's Run Setup tap, verified by Continue.
    @Published var awaitingRunSetup = false
    private var issuedRunSetupRequest = false
    private let session = DevelopmentInstallationSession()
    private let bridge = IOSSimDeviceBridge()
    private let transport = DynamicNativeDeviceTransport()

    func refresh() async {
        await perform {
            self.result = nil
            self.devices = []
            for descriptor in try await self.bridge.listDevices() {
                self.devices.append(try await self.bridge.inspect(descriptor.identity))
            }
            if !self.devices.contains(where: { $0.identity.udid == self.selected }) {
                self.selected = self.devices.count == 1 ? self.devices[0].identity.udid : ""
            }
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

    func run(_ command: EngineCommand) async {
        guard let device = devices.first(where: { $0.identity.udid == selected }) else { return }
        await perform {
            self.result = nil
            self.issuedRunSetupRequest = false
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
                })
            let request = EngineRequest(command: command,
                capabilities: CapabilityManifest(allowedDomains: InstallationDomain.reconciliationOrder,
                                                 maximumPermission: .destructiveOwned, maximumTransitions: 64),
                connectionGeneration: device.identity.connectionGeneration, device: target)
            let response = await EngineHost.handle(request, composition: composition)
            // A transition that throws returns no snapshot; re-observe so the list is current, not blank or stale.
            self.result = response.observations.isEmpty && command != .inspect
                ? await EngineHost.handle(EngineRequest(command: .inspect, connectionGeneration: device.identity.connectionGeneration,
                                                        device: target), composition: composition)
                : response
            let waiting = response.firstFailure?.code == RuntimeReadinessDomain.runSetupRequired.code
            if command != .inspect { self.awaitingRunSetup = waiting }
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
                // One primary action, named for the phase it is in. Every run re-observes and the
                // planner stops at the first unsatisfied domain, so the same `.reconcile` both
                // prepares and verifies; a second button would only be a second name for it, and a
                // disabled one contradicts every "then continue in Veya" instruction.
                Button(model.awaitingRunSetup ? "Continue / Verify Setup" : "Install / Prepare") {
                    Task { await model.run(.reconcile) }
                }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.selected.isEmpty)
            // `.id`: a selectable Text can keep its old (blank) layout when the string changes (observed physically).
            Text(model.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).id(model.message)
            if let result = model.result {
                Text("Last observation (not continuous readiness). Development session: relaunching Veya discards the "
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
        .onChange(of: model.selected) { _ in model.result = nil }
        .task { await model.refresh() }
    }
}
#endif
