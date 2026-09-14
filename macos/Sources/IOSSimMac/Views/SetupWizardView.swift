import SwiftUI
import IOSSimMacCore

struct SetupWizardView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ProgressView(value: Double(max(store.phase.stepIndex, 1)), total: 8)
                .accessibilityLabel("Setup progress")
            Group {
                switch store.phase {
                case .checkingMac:
                    MacCheckView()
                case .macActionRequired:
                    ActionRequiredView(
                        title: "Action required on this Mac",
                        message: "IOSSim needs this Mac to be ready before it can continue.",
                        checks: store.status?.macBlockingChecks ?? []
                    )
                case .waitingForDevice:
                    DeviceConnectView()
                case .checkingDevice:
                    DeviceRequirementsView()
                case .deviceActionRequired:
                    ActionRequiredView(
                        title: "Action required on your iPhone",
                        message: "Complete the iPhone steps below, then check again.",
                        checks: store.status?.deviceActionChecks ?? []
                    )
                case .appleAccount:
                    AppleAccountView()
                case .installing:
                    InstallationView()
                case .developerProfileTrust:
                    DeveloperProfileTrustView()
                case .runtimeSetup:
                    RuntimeSetupView()
                case .verifying:
                    VerifyingView()
                case .complete:
                    CompletionView()
                default:
                    EmptyView()
                }
            }
            Spacer()
            WizardControls()
        }
        .padding(32)
    }
}

struct WizardControls: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        HStack {
            if store.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            if store.isRunning && !store.isCriticalStage {
                Button("Cancel") {
                    store.cancelCurrentOperation()
                }
                .keyboardShortcut(.cancelAction)
            } else if store.isRunning && store.isCriticalStage {
                Text("Finishing installation...")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(buttonTitle) {
                primaryAction()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRunning || (store.phase == .appleAccount && store.selectedTeam == nil))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(buttonTitle)
        }
    }

    private var buttonTitle: String {
        switch store.phase {
        case .macActionRequired, .deviceActionRequired:
            return "Check Again"
        case .runtimeSetup:
            return "I Finished Setup"
        case .developerProfileTrust:
            return "Continue"
        case .waitingForDevice:
            return (store.status?.device.devices.isEmpty == false) ? "Continue" : "Check Again"
        case .appleAccount:
            return store.personalTeams.isEmpty ? "Check Again" : "Continue"
        case .installing:
            return "Install"
        case .complete:
            return "Open Dashboard"
        default:
            return "Continue"
        }
    }

    private func primaryAction() {
        switch store.phase {
        case .complete:
            store.showDashboard()
        case .macActionRequired, .deviceActionRequired:
            store.refresh()
        case .runtimeSetup:
            store.confirmRuntimeSetup()
        case .developerProfileTrust:
            store.continueDeveloperProfileTrust()
        case .appleAccount:
            if store.personalTeams.isEmpty { store.refresh() } else { store.continueFromCurrentStatus() }
        case .waitingForDevice:
            if store.status?.device.devices.isEmpty == false {
                store.continueFromCurrentStatus()
            } else {
                store.refresh()
            }
        case .installing:
            store.continueFromCurrentStatus()
        default:
            store.continueFromCurrentStatus()
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("IOSSim")
                .font(.largeTitle.weight(.semibold))
            Text("Set up IOSSim on your iPhone.")
                .font(.title3)
            Text("IOSSim prepares your iPhone automatically. You only need to unlock it and approve Apple’s security prompts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Get Started") {
                store.getStarted()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Get Started")
            Spacer()
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(42)
    }
}

struct MacCheckView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Checking this Mac...")
                .font(.title2.weight(.semibold))
            FriendlyCheckRow(title: "macOS supported", state: rowState(component: "Mac"))
            FriendlyCheckRow(title: "Native device bridge ready", state: rowState(component: "Apple Tooling"))
            FriendlyCheckRow(title: "IOSSim components ready", state: componentReadiness)
        }
    }

    private func rowState(component: String) -> CheckState {
        let equivalentComponents: Set<String> = component == "Apple Tooling" ? ["Apple Tooling", "Xcode"] : [component]
        guard let checks = store.status?.checks.filter({ equivalentComponents.contains($0.component) }), !checks.isEmpty else {
            return store.isRunning ? .skip : .warn
        }
        return checks.contains { $0.state == .fail || $0.state == .action } ? .action : .pass
    }

    private var componentReadiness: CheckState {
        guard let status = store.status else { return store.isRunning ? .skip : .warn }
        return status.mac.ready ? .pass : .action
    }
}

struct DeviceConnectView: View {
    @EnvironmentObject private var store: SetupStore
    @State private var showingDevicePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
            if let devices = store.status?.device.devices, devices.count > 1 {
                if let device = store.selectedDevice {
                    FriendlyCheckRow(title: "Selected iPhone", detail: deviceLabel(device), state: .pass)
                } else {
                    FriendlyCheckRow(title: "Choose an iPhone", detail: "Multiple iPhones are connected.", state: .action)
                }
                Button("Change Device") {
                    showingDevicePicker = true
                }
            } else if let device = store.selectedDevice {
                FriendlyCheckRow(title: "iPhone detected", detail: deviceLabel(device), state: .pass)
            } else {
                FriendlyCheckRow(title: "Waiting for iPhone...", state: .skip)
            }
        }
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerSheet(isPresented: $showingDevicePicker)
                .environmentObject(store)
        }
    }

    private var title: String {
        if store.status?.device.devices.isEmpty == true {
            return "No iPhone Connected"
        }
        if store.deviceSelectionRequired {
            return "Choose an iPhone"
        }
        return "Connect your iPhone"
    }

    private var message: String {
        if store.status?.device.devices.isEmpty == true {
            return "Connect and unlock an iPhone to continue."
        }
        if let name = store.disconnectedDeviceName {
            return "Reconnect \(name) or choose another device."
        }
        if store.deviceSelectionRequired {
            return "Select the iPhone IOSSim should set up."
        }
        return "Connect your iPhone to this Mac using a USB cable and unlock it."
    }

    private func deviceLabel(_ device: DetectedDevice) -> String {
        [device.name, device.osVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}

struct DeviceRequirementsView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Checking your iPhone...")
                .font(.title2.weight(.semibold))
            ForEach(store.status?.checks.filter { $0.requiredFor == "device" && $0.component == "Device" } ?? []) { check in
                FriendlyCheckRow(title: friendlyTitle(check), detail: friendlyDetail(check), state: check.state)
            }
            if let device = store.selectedDevice,
               let eligibility = device.provisioningEligibilityStatus,
               eligibility != .installable {
                FriendlyCheckRow(
                    title: "iPhone authorization",
                    detail: "This iPhone is not yet authorized for this IOSSim build.",
                    state: .action
                )
            }
        }
    }

    private func friendlyTitle(_ check: DoctorCheck) -> String {
        if check.name.localizedCaseInsensitiveContains("trusted") {
            return "Mac trusted"
        }
        return check.name
    }

    private func friendlyDetail(_ check: DoctorCheck) -> String? {
        check.state == .pass ? nil : StatusInterpreter.friendlyAction(for: check)
    }
}

struct ActionRequiredView: View {
    let title: String
    let message: String
    let checks: [DoctorCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
            ForEach(checks) { check in
                FriendlyCheckRow(
                    title: friendlyTitle(for: check),
                    detail: StatusInterpreter.friendlyAction(for: check),
                    state: .action
                )
            }
        }
    }

    private func friendlyTitle(for check: DoctorCheck) -> String {
        if check.name.localizedCaseInsensitiveContains("Developer Mode") {
            return "Developer Mode Required"
        }
        if check.name.localizedCaseInsensitiveContains("connected iPhone") {
            return "Connect and unlock your iPhone"
        }
        return check.name
    }
}

struct InstallationView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Installing IOSSim")
                .font(.title2.weight(.semibold))
            Text("Installing the components IOSSim needs on your iPhone.")
                .foregroundStyle(.secondary)
            ForEach(InstallStage.allCases) { stage in
                FriendlyCheckRow(
                    title: stage.title,
                    state: store.completedInstallStages.contains(stage) ? .pass : .skip
                )
            }
        }
    }
}

struct AppleAccountView: View {
    @EnvironmentObject private var store: SetupStore
    @State private var appleAccount = ""
    @State private var password = ""
    @State private var verificationCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.nativeProvisioningExperiment {
                Text("LOCAL TEST ONLY — Experimental Personal Team provisioning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text(store.appleVerificationChallenge == nil ? "Apple Authorization" : "Apple Verification")
                .font(.title2.weight(.semibold))
            if let challenge = store.appleVerificationChallenge {
                Text(challenge.method == .trustedDevice
                    ? "Enter the code Apple sent to your trusted device."
                    : "Enter the verification code Apple sent by text message.")
                    .foregroundStyle(.secondary)
                SecureField("Apple Verification Code", text: $verificationCode)
                    .textContentType(.oneTimeCode)
                    .frame(maxWidth: 280)
                    .onSubmit(verify)
                Button("Verify", action: verify)
                    .buttonStyle(.borderedProminent)
                    .disabled(verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isRunning)
            } else if store.personalTeams.isEmpty {
                Text("IOSSim uses your Apple Account to authorize its on-device components.")
                    .foregroundStyle(.secondary)
                TextField("Apple Account", text: $appleAccount)
                    .textContentType(.username)
                    .frame(maxWidth: 360)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .frame(maxWidth: 360)
                    .onSubmit(authorize)
                Button("Continue", action: authorize)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        appleAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || password.isEmpty
                            || store.isRunning
                    )
                FriendlyCheckRow(
                    title: "Your account stays private",
                    detail: "Your credentials are used locally to authenticate with Apple and are never sent to IOSSim servers. Apple may require two-factor verification. Free Apple authorization needs periodic refresh.",
                    state: .pass
                )
            } else {
                FriendlyCheckRow(
                    title: "Apple authorization",
                    detail: store.selectedTeam?.userDisplayName ?? "Ready",
                    state: .pass
                )
                if store.selectedTeam == nil {
                    Picker("Account", selection: Binding(
                        get: { store.selectedTeamIdentifier ?? "" },
                        set: { store.selectTeam(identifier: $0) }
                    )) {
                        Text("Choose an account").tag("")
                        ForEach(store.personalTeams) { team in
                            Text(team.userDisplayName).tag(team.teamIdentifier)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            if store.nativeProvisioningExperiment {
                Text("Safe stage: \(store.liveProvisioningCheckpoint?.rawValue ?? store.appleAuthorization.stage.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func authorize() {
        let account = appleAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        store.beginAppleAuthorization(account: account, password: password)
        password.removeAll(keepingCapacity: false)
    }

    private func verify() {
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        store.submitAppleVerification(code: code)
        verificationCode.removeAll(keepingCapacity: false)
    }
}

struct RuntimeSetupView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Finish setup on your iPhone")
                .font(.title2.weight(.semibold))
            Text("Open IOSSim, tap Set Up IOSSim, and run Setup until the iPhone shows Setup Complete. Keep LocalDevVPN enabled while setup runs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.status?.runtimeActionChecks ?? []) { check in
                runtimeBlock(for: check)
            }
            Text("After the iPhone shows Setup Complete, return here and confirm below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func runtimeBlock(for check: DoctorCheck) -> some View {
        if check.name.localizedCaseInsensitiveContains("LocalDevVPN") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable IOSSim Connection")
                    .font(.headline)
                Text("Open LocalDevVPN on your iPhone, approve Apple's VPN configuration prompt, and turn it on.")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Finish Device Pairing")
                    .font(.headline)
                Text("Keep your iPhone unlocked while IOSSim prepares and verifies the secure connection.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeveloperProfileTrustView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trust IOSSim on your iPhone")
                .font(.title2.weight(.semibold))
            Text("Apple requires you to trust apps installed with your Personal Team before they can open.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Open Settings on your iPhone.")
                Text("2. Go to General.")
                Text("3. Open VPN & Device Management.")
                Text("4. Select the developer profile for the Apple Account you used with IOSSim.")
                Text("5. Tap Trust, then confirm.")
                Text("6. Return to IOSSim on your Mac.")
                Text("7. Click Continue.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("If IOSSim was already trusted, Continue will verify it without reinstalling anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct VerifyingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Verifying setup...")
                .font(.title2.weight(.semibold))
            Text("IOSSim is checking that installation and device setup are ready.")
                .foregroundStyle(.secondary)
            ProgressView()
                .accessibilityLabel("Verifying setup")
        }
    }
}

struct CompletionView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Setup Complete")
                .font(.title2.weight(.semibold))
            Text("IOSSim is ready to manage setup, repair, and component updates from this Mac.")
                .foregroundStyle(.secondary)
            if store.nativeProvisioningExperiment {
                FriendlyCheckRow(
                    title: "LOCAL TEST ONLY",
                    detail: "Personal Team provisioning, signing, installation, and setup completed on this Mac and iPhone.",
                    state: .pass
                )
                Button("Export Support Report") { store.exportSupportBundle() }
                    .disabled(store.isRunning)
                if let url = store.lastSupportBundleURL {
                    Text("Saved to \(url.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
