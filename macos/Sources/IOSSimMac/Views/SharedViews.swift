import SwiftUI
import IOSSimMacCore

struct FriendlyCheckRow: View {
    let title: String
    var detail: String?
    let state: CheckState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(accessibilityStatus)")
    }

    private var iconName: String {
        switch state {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail, .action: return "exclamationmark.circle.fill"
        case .skip: return "circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .pass: return .green
        case .warn: return .orange
        case .fail, .action: return .red
        case .skip: return .secondary
        }
    }

    private var accessibilityStatus: String {
        switch state {
        case .pass: return "ready"
        case .warn: return "warning"
        case .fail: return "failed"
        case .action: return "action required"
        case .skip: return "waiting"
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var store: SetupStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            Text("Pairing contents, keys, and credentials are never included.")
                .foregroundStyle(.secondary)
            Text(versionText)
                .font(.caption)
                .foregroundStyle(.secondary)
#if IOSSIM_BUNDLED_ENGINE
            VStack(alignment: .leading, spacing: 12) {
                Text("Create a sanitized support file with setup status, software versions, profile dates, and recent provisioning results.")
                    .foregroundStyle(.secondary)
                Button("Export Support Report") {
                    store.exportSupportBundle()
                }
                .disabled(store.isRunning)
                if let url = store.lastSupportBundleURL {
                    Text("Saved to \(url.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
#else
            TabView {
                ScrollView {
                    Text(doctorText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tabItem { Text("Doctor") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.logs) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.stage)
                                    .font(.headline)
                                Text(entry.result.combinedOutput.isEmpty ? "Exit \(entry.result.exitCode)" : entry.result.combinedOutput)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tabItem { Text("Logs") }
                ScrollView {
                    Text(bundleAuditText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tabItem { Text("Bundle IDs") }
            }
#endif
        }
        .padding(24)
        .frame(width: 720, height: 520)
    }

    private var doctorText: String {
        guard let status = store.status else {
            return "No doctor status loaded yet."
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) else {
            return "Doctor status could not be encoded."
        }
        return Redactor.redact(text)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "IOSSim \(version) (\(build))"
    }

    private var bundleAuditText: String {
        """
        IOSSimOnDevicePOC -> com.iossim.on-device-dvt-poc -> iPhone app
        IOSSimLocationWitness -> com.iossim.location-witness -> owned validation component
        IOSSimLocationControlTests -> com.iossim.location-control-tests -> hosted unit test bundle
        IOSSimLocationControlUITests -> com.iossim.location-control-uitests -> UI-test bundle
        IOSSimLocationControlUITests-Runner -> com.iossim.location-control-uitests.xctrunner -> generated XCTest runner app
        IOSSimMac -> com.iossim.mac-provisioner -> native macOS setup/provisioning app

        Existing iPhone/Witness/test identifiers are compatibility boundaries and are not renamed by the Mac app.
        """
    }
}

struct DevicePickerSheet: View {
    @EnvironmentObject private var store: SetupStore
    @Binding var isPresented: Bool
    @State private var pendingIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose an iPhone")
                .font(.title2.weight(.semibold))
            if let devices = store.status?.device.devices, !devices.isEmpty {
                Picker("iPhone", selection: selectionBinding) {
                    ForEach(devices) { device in
                        Text(deviceLabel(device)).tag(Optional(device.selectionIdentifier))
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Choose an iPhone")
            } else {
                Text("No iPhone Connected")
                    .font(.headline)
                Text("Connect and unlock an iPhone to continue.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Use This iPhone") {
                    if let pendingIdentifier {
                        store.selectDevice(identifier: pendingIdentifier)
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingIdentifier == nil)
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .onAppear {
            pendingIdentifier = store.selectedDevice?.selectionIdentifier ?? store.status?.device.devices.first?.selectionIdentifier
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { pendingIdentifier },
            set: { pendingIdentifier = $0 }
        )
    }

    private func deviceLabel(_ device: DetectedDevice) -> String {
        [device.name, device.osVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " - ")
    }
}
