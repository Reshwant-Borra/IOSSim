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
                        message: "Veya needs this Mac to be ready before it can continue.",
                        checks: store.status?.macBlockingChecks ?? []
                    )
                case .waitingForDevice:
                    DeviceConnectView()
                case .checkingDevice:
                    DeviceRequirementsView()
                case .deviceActionRequired:
                    ActionRequiredView(
                        title: "Action required on your iPhone",
                        message: deviceActionMessage,
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

    private var deviceActionMessage: String {
        switch store.lockdownPairingReceipt?.state {
        case .waitingForUnlock:
            return "Unlock your iPhone, then check again. Veya will never enter your passcode."
        case .waitingForUserTrust:
            return "Tap Trust on your iPhone, enter its passcode if Apple asks, then check again."
        case .denied:
            return "Computer trust was declined. Check again when you are ready to approve Apple's Trust prompt."
        case .disconnected:
            return "Reconnect this iPhone by USB, unlock it, then check again."
        default:
            return "Complete the iPhone steps below, then check again."
        }
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
        case .macActionRequired:
            return "Check Again"
        case .deviceActionRequired:
            return store.selectedDevice?.pairingState == "paired" ? "Check Again" : "Request Trust"
        case .runtimeSetup:
            return "Try Again"
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
        case .macActionRequired:
            store.refresh()
        case .deviceActionRequired:
            store.continueDeviceSecurityAction()
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
            Text(ProductBrand.migrationDisplayName)
                .font(.largeTitle.weight(.semibold))
            Text("Set up Veya on your iPhone.")
                .font(.title3)
            Text("Veya prepares your iPhone automatically. You only need to unlock it and approve Apple’s security prompts.")
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
            FriendlyCheckRow(title: "Veya components ready", state: componentReadiness)
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
            return deviceDiscoveryFailure == nil ? "No iPhone Connected" : "Device Discovery Unavailable"
        }
        if store.deviceSelectionRequired {
            return "Choose an iPhone"
        }
        return "Connect your iPhone"
    }

    private var message: String {
        if store.status?.device.devices.isEmpty == true {
            return deviceDiscoveryFailure == nil
                ? "Connect and unlock an iPhone to continue."
                : "Veya could not query its native device bridge. Open Diagnostics for details."
        }
        if let name = store.disconnectedDeviceName {
            return "Reconnect \(name) or choose another device."
        }
        if store.deviceSelectionRequired {
            return "Select the iPhone Veya should set up."
        }
        return "Connect your iPhone to this Mac using a USB cable and unlock it."
    }

    private var deviceDiscoveryFailure: DoctorCheck? {
        store.status?.checks.first { $0.component == "Device Bridge" && ($0.state == .action || $0.state == .fail) }
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
                    detail: "This iPhone is not yet authorized for this Veya build.",
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
            Text("Installing Veya")
                .font(.title2.weight(.semibold))
            Text("Installing the components Veya needs on your iPhone.")
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
                Text("Veya uses your Apple Account to authorize its on-device components.")
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
                    detail: "Your credentials are used locally to authenticate with Apple and are never sent to Veya servers. Apple may require two-factor verification. Free Apple authorization needs periodic refresh.",
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
            Text("Preparing LocalDevVPN")
                .font(.title2.weight(.semibold))
            Text("Veya opens the installed LocalDevVPN app and verifies its existing developer route automatically. If Apple asks, approve the VPN configuration or tap Connect in LocalDevVPN, then choose Try Again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.headline).font(.headline)
                    Text(error.recovery).foregroundStyle(.secondary)
                    Text(error.details).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            ForEach(store.status?.runtimeActionChecks ?? []) { check in
                runtimeBlock(for: check)
            }
            Text("Setup completes after LocalDevVPN is reachable and Veya runs one bounded Rich location check through TestManager/XCTest. The check clears location and closes its setup session; it never starts a Drive route.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func runtimeBlock(for check: DoctorCheck) -> some View {
        if check.name.localizedCaseInsensitiveContains("LocalDevVPN") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable Veya Connection")
                    .font(.headline)
                Text("Veya opens LocalDevVPN automatically. If required, approve Apple's VPN prompt or tap Connect, then choose Try Again.")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Finish Device Pairing")
                    .font(.headline)
                Text("Keep your iPhone unlocked while Veya prepares and verifies the secure connection.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeveloperProfileTrustView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trust Veya on your iPhone")
                .font(.title2.weight(.semibold))
            Text("Apple requires you to trust apps installed with your Personal Team before they can open.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Open Settings on your iPhone.")
                Text("2. Go to General.")
                Text("3. Open VPN & Device Management.")
                Text("4. Select the developer profile for the Apple Account you used with Veya.")
                Text("5. Tap Trust, then confirm.")
                Text("6. Return to Veya on your Mac.")
                Text("7. Click Continue.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("If Veya was already trusted, Continue will verify it without reinstalling anything.")
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
            Text("Veya is checking that installation and device setup are ready.")
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
            Text("Veya is ready to manage setup, repair, and component updates from this Mac.")
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
