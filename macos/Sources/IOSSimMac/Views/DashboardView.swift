import SwiftUI
import IOSSimMacCore

struct DashboardView: View {
    @EnvironmentObject private var store: SetupStore
    @State private var showingDevicePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            deviceHeader
            VStack(alignment: .leading, spacing: 12) {
                DashboardStatusRow(title: "Mac", detail: "Ready", ready: store.status?.mac.ready == true)
                DashboardStatusRow(title: "Device", detail: "Selected and trusted", ready: store.selectedDeviceProvisioningReady)
                DashboardStatusRow(title: "IOSSim", detail: "Installed on your iPhone", ready: store.provisioningManifest != nil)
                DashboardStatusRow(title: "Provisioning", detail: profileDetail, ready: !profileNeedsAttention)
                DashboardStatusRow(title: "Runtime", detail: "LocalDevVPN and pairing", ready: store.selectedDeviceProvisioningReady && store.status?.runtimeActionChecks.isEmpty == true)
            }
            HStack {
                Button("Check Setup") {
                    store.refresh()
                }
                Button("Refresh Now") {
                    store.runUpdateComponents()
                }
                .disabled(store.selectedDevice == nil || store.selectedTeam == nil)
                Button("Repair") {
                    store.runRepair()
                }
                .disabled(store.selectedDevice == nil || store.selectedTeam == nil)
                Spacer()
                if store.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }
            Toggle("Refresh automatically when this Mac and iPhone are available", isOn: Binding(
                get: { store.automaticRefreshEnabled },
                set: { store.setAutomaticRefreshEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            if let status = store.status, !status.actionsRequired.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Needs attention")
                        .font(.headline)
                    ForEach(status.canonicalRequiredActions) { action in
                        Text(StatusInterpreter.friendlyAction(for: action.check))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Everything is ready.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerSheet(isPresented: $showingDevicePicker)
                .environmentObject(store)
        }
    }

    private var profileNeedsAttention: Bool {
        [.dueNow, .expired, .unavailable].contains(store.refreshDueState)
    }

    private var profileDetail: String {
        guard let expiration = store.provisioningManifest?.earliestExpiration else { return "Setup information unavailable" }
        let days = max(0, Int(expiration.timeIntervalSinceNow / (24 * 60 * 60)))
        switch store.refreshDueState {
        case .expired: return "Refresh required"
        case .dueNow: return "Refresh needed soon"
        case .dueSoon, .current: return "Refresh due in \(days) day\(days == 1 ? "" : "s")"
        case .unavailable: return "Setup information unavailable"
        }
    }

    @ViewBuilder
    private var deviceHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let device = store.selectedDevice {
                    Text(device.name)
                        .font(.title3.weight(.semibold))
                    Text(device.osVersion.map { "iOS \($0)" } ?? "iOS version unavailable")
                        .foregroundStyle(.secondary)
                    if let eligibility = device.provisioningEligibilityStatus, eligibility != .installable {
                        Text("This iPhone is not yet authorized for this IOSSim build.")
                            .foregroundStyle(.orange)
                    }
                } else if store.status?.device.devices.isEmpty == true {
                    Text(deviceDiscoveryFailure == nil ? "No iPhone Connected" : "Device Discovery Unavailable")
                        .font(.title3.weight(.semibold))
                    Text(deviceDiscoveryFailure == nil
                        ? "Connect and unlock an iPhone to continue."
                        : "IOSSim could not query its native device bridge. Open Diagnostics for details.")
                        .foregroundStyle(.secondary)
                } else if let name = store.disconnectedDeviceName {
                    Text("iPhone Disconnected")
                        .font(.title3.weight(.semibold))
                    Text("Reconnect \(name) or choose another device.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose an iPhone")
                        .font(.title3.weight(.semibold))
                    Text("Select the iPhone IOSSim should set up.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.status?.device.devices.isEmpty == false {
                Button("Change Device") {
                    showingDevicePicker = true
                }
            }
        }
    }

    private var deviceDiscoveryFailure: DoctorCheck? {
        store.status?.checks.first { $0.component == "Device Bridge" && ($0.state == .action || $0.state == .fail) }
    }

    private func deviceLabel(_ device: DetectedDevice) -> String {
        [device.name, device.osVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}

struct DashboardStatusRow: View {
    let title: String
    let detail: String
    let ready: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(ready ? "Ready" : "Needs Attention", systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
        }
        .font(.body)
        .accessibilityElement(children: .combine)
    }
}

struct FailureView: View {
    @EnvironmentObject private var store: SetupStore
#if !IOSSIM_BUNDLED_ENGINE
    @State private var showDetails = false
#endif
    @State private var showingDevicePicker = false
    @State private var confirmingFreshInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.lastError?.headline ?? "IOSSim could not complete setup.")
                .font(.title2.weight(.semibold))
            Text(store.lastError?.recovery ?? "Try again after addressing the issue.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Try Again") {
                    store.retryCurrentStep()
                }
                .buttonStyle(.borderedProminent)
                if store.status?.device.devices.isEmpty == false {
                    Button("Change Device") {
                        showingDevicePicker = true
                    }
                }
                Button("Export Support Report") {
                    store.exportSupportBundle()
                }
                .disabled(store.isRunning)
#if !IOSSIM_BUNDLED_ENGINE
                Button(showDetails ? "Hide Details" : "Show Details") {
                    showDetails.toggle()
                }
#endif
                if store.lastError?.details.contains(ConsumerProvisioningErrorCode.crossTeamUpgradeBlocked.rawValue) == true
                    || store.lastError?.details.contains(ConsumerProvisioningErrorCode.installedIdentityMigrationRequired.rawValue) == true {
                    Button("Fresh Install", role: .destructive) {
                        confirmingFreshInstall = true
                    }
                }
            }
#if !IOSSIM_BUNDLED_ENGINE
            if showDetails {
                ScrollView {
                    Text(store.lastError?.details ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
#endif
            Spacer()
        }
        .padding(32)
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerSheet(isPresented: $showingDevicePicker)
                .environmentObject(store)
        }
        .confirmationDialog(
            "Fresh install removes IOSSim data from this iPhone",
            isPresented: $confirmingFreshInstall,
            titleVisibility: .visible
        ) {
            Button("Remove IOSSim Data and Install", role: .destructive) {
                store.runConfirmedFreshInstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
#if IOSSIM_BUNDLED_ENGINE
            Text("Only IOSSim and its installed support component will be removed. LocalDevVPN and unrelated apps are not changed.")
#else
            Text("Only the IOSSim app and its XCTest runner will be removed. LocalDevVPN and unrelated apps are not changed.")
#endif
        }
    }
}
