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
                DashboardStatusRow(title: "IOSSim Installed", detail: "Project components", ready: store.selectedDevice?.allProjectAppsInstalled == true)
                DashboardStatusRow(title: "Runtime", detail: "LocalDevVPN and pairing", ready: store.selectedDeviceProvisioningReady && store.status?.runtimeActionChecks.isEmpty == true)
            }
            HStack {
                Button("Check Setup") {
                    store.refresh()
                }
                Button("Update Components") {
                    store.runUpdateComponents()
                }
                .disabled(store.selectedDevice == nil)
                Button("Repair Installation") {
                    store.runRepair()
                }
                .disabled(store.selectedDevice == nil)
                Spacer()
                if store.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }
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
                    Text("No iPhone Connected")
                        .font(.title3.weight(.semibold))
                    Text("Connect and unlock an iPhone to continue.")
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
    @State private var showDetails = false
    @State private var showingDevicePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.lastError?.headline ?? "IOSSim could not complete setup.")
                .font(.title2.weight(.semibold))
            Text(store.lastError?.recovery ?? "Try again after addressing the issue.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Try Again") {
                    store.refresh()
                }
                .buttonStyle(.borderedProminent)
                if store.status?.device.devices.isEmpty == false {
                    Button("Change Device") {
                        showingDevicePicker = true
                    }
                }
                Button(showDetails ? "Hide Details" : "Show Details") {
                    showDetails.toggle()
                }
            }
            if showDetails {
                ScrollView {
                    Text(store.lastError?.details ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            Spacer()
        }
        .padding(32)
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerSheet(isPresented: $showingDevicePicker)
                .environmentObject(store)
        }
    }
}
