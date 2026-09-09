import SwiftUI
import UniformTypeIdentifiers

/// Settings root: connection status at a glance, pairing management, and the
/// permanent home for every developer/diagnostic screen that used to sit on
/// the app's root view. All of that capability is preserved exactly — only
/// re-homed here so it doesn't compete with the normal Location/Drive flows.
struct SettingsView: View {
    @ObservedObject private var connectionStatus = POCAppDependencies.connectionStatus
    @State private var pairingSummaryText = "Checking..."
    @State private var showingImporter = false
    @State private var showingClearConfirm = false
    @State private var showingDisconnectConfirm = false

    var body: some View {
        List {
            Section("Connection") {
                statusRow("Pairing", state: connectionStatus.pairingStep)
                statusRow("LocalDevVPN", state: connectionStatus.localDevVPNStep)
                statusRow("Developer Connection", state: connectionStatus.endpointStep)
                statusRow("Session", state: connectionStatus.sessionStep)
                NavigationLink {
                    SetupView()
                } label: {
                    Text(connectionStatus.allStepsPass ? "Setup" : "Finish Setup")
                }
            }

            Section {
                Text(pairingSummaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Choose Pairing File (Advanced)") {
                    showingImporter = true
                }
            } header: {
                Text("Pairing Diagnostics")
            }

            Section("Simulation") {
                LabeledContent(
                    "Drive speed range",
                    value: "\(Int(DriveSpeed.minimumMPH))\u{2013}\(Int(DriveSpeed.maximumMPH)) mph"
                )
            }

            Section {
                NavigationLink("Developer") {
                    ContentView()
                }
                NavigationLink("Drive Diagnostics") {
                    DriveDiagnosticsView(model: POCAppDependencies.driveModel)
                }
                NavigationLink("Apple Location Controls") {
                    AppleLocationControlsView()
                }
                .accessibilityIdentifier("Settings.AppleLocationControls")
            } header: {
                Text("Developer")
            } footer: {
                Text("Pairing, connection diagnostics, E1 stage detail, session timeline, raw log, scheduler/DVT/Core Location metrics, passive Apple location controls, and diagnostic export.")
            }

            Section {
                Button("Clear Simulation", role: .destructive) {
                    showingClearConfirm = true
                }
                Button("Disconnect", role: .destructive) {
                    showingDisconnectConfirm = true
                }
            } header: {
                Text("Advanced")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.shortVersionString)
            }
        }
        .navigationTitle("Settings")
        .task {
            await connectionStatus.refreshFromCurrentState()
            pairingSummaryText = currentPairingSummary()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.propertyList, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            Task {
                guard case .success(let urls) = result, let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                _ = try? await POCAppDependencies.runner.importPairing(data)
                pairingSummaryText = currentPairingSummary()
                await connectionStatus.refreshFromCurrentState()
            }
        }
        .confirmationDialog(
            "Clear the currently simulated location?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Simulation", role: .destructive) {
                Task { try? await POCAppDependencies.runner.clear() }
            }
        }
        .confirmationDialog(
            "Disconnect from the developer session?",
            isPresented: $showingDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await POCAppDependencies.runner.disconnect() }
            }
        }
    }

    private func statusRow(_ label: String, state: SetupStepState) -> some View {
        HStack {
            Text(label)
            Spacer()
            switch state {
            case .pending:
                Text("Not started").foregroundStyle(.secondary)
            case .checking:
                ProgressView()
            case .pass:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func currentPairingSummary() -> String {
        if let summary = try? POCAppDependencies.store.pairingSummary() {
            return "Pairing imported (identifier \(summary.identifierRedacted))"
        }
        return "No pairing file imported yet."
    }
}

private extension Bundle {
    var shortVersionString: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
