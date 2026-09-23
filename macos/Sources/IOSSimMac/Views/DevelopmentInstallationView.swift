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
            let target = EngineDeviceSelection(udid: device.identity.udid, name: device.name ?? "iPhone",
                                               transportIdentity: device.identity)
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/IOSSimProvisioner")
            // Setup completion waits on the user's Run Setup tap, so the instruction
            // has to appear while the run is still in flight.
            let composition = self.session.composition(
                helperURL: helper, device: target,
                connectionGeneration: device.identity.connectionGeneration,
                runSetupProgress: { [weak self] progress in
                    Task { @MainActor in self?.message = Self.describe(progress) }
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
            self.message = response.userAction.map { "ACTION REQUIRED: \($0)" }
                ?? response.firstFailure?.safeMessage ?? response.status
        }
    }

    static func describe(_ progress: RunSetupProgress) -> String {
        switch progress {
        case .waitingForRunSetupTap:
            return "ACTION REQUIRED: Open Veya on your iPhone and tap Run Setup."
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
                Button("Install / Resume") { Task { await model.run(.reconcile) } }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.selected.isEmpty)
            // `.id`: a selectable Text can keep its old (blank) layout when the string changes (observed physically).
            Text(model.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).id(model.message)
            if let result = model.result {
                Text("Last observation (not continuous readiness). Development session: relaunching Veya discards the "
                     + "Apple session and signing key (M4 deferred), so those show waitingForUser/invalid until the next Install / Resume.")
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
