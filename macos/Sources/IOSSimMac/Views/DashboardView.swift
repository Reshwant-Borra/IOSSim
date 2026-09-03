import SwiftUI
import IOSSimMacCore

struct DashboardView: View {
    @EnvironmentObject private var store: SetupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.status?.primaryDevice.map(deviceLabel) ?? "No iPhone selected")
                    .font(.title3.weight(.semibold))
                Text("IOSSim setup manager")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                DashboardStatusRow(title: "IOSSim", ready: store.status?.mac.ready == true)
                DashboardStatusRow(title: "Device Connection", ready: store.status?.provisioningReady == true)
                DashboardStatusRow(title: "Runtime", ready: store.status?.runtimeActionChecks.isEmpty == true)
            }
            HStack {
                Button("Check Setup") {
                    store.refresh()
                }
                Button("Update Components") {
                    store.runUpdateComponents()
                }
                Button("Repair Installation") {
                    store.runRepair()
                }
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
                    ForEach(status.deviceActionChecks + status.macBlockingChecks + status.runtimeActionChecks) { check in
                        Text(StatusInterpreter.friendlyAction(for: check))
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
    }

    private func deviceLabel(_ device: DetectedDevice) -> String {
        [device.name, device.osVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}

struct DashboardStatusRow: View {
    let title: String
    let ready: Bool

    var body: some View {
        HStack {
            Text(title)
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
    }
}
