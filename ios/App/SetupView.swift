import SwiftUI
import UniformTypeIdentifiers

/// Guided first-run / recovery setup flow. Translates the same diagnostic
/// stages the original developer console showed (Pairing, LocalDevVPN,
/// Endpoint, Session/DVT) into plain language, while the exact POCErrorCode
/// and message are still shown via HumanReadableError -> the same mapping
/// Developer diagnostics use, so nothing about the failure is hidden, only
/// translated.
struct SetupView: View {
    @ObservedObject private var connectionStatus = POCAppDependencies.connectionStatus
    @State private var showingImporter = false

    var body: some View {
        List {
            if connectionStatus.veyaSetupRequestPending {
                Section {
                    Label("Veya is waiting on your Mac. Tap Run Setup below to finish setup.",
                          systemImage: "desktopcomputer.and.arrow.down")
                        .font(.footnote)
                }
            }

            Section {
                Text("IOSSim needs a one-time pairing, an active LocalDevVPN connection, and a developer session before it can simulate a location.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            step(
                title: "Pairing",
                state: connectionStatus.pairingStep,
                detail: "Veya delivers this automatically from your Mac. Import a file only if Veya asks you to.",
                actionLabel: "Import RPPairing File",
                action: { showingImporter = true }
            )

            step(
                title: "LocalDevVPN",
                state: connectionStatus.localDevVPNStep,
                detail: "Open LocalDevVPN, enable the VPN, then return to IOSSim.",
                actionLabel: nil,
                action: nil
            )

            step(
                title: "Developer Connection",
                state: connectionStatus.endpointStep,
                detail: "IOSSim reaches the developer service over the LocalDevVPN route.",
                actionLabel: nil,
                action: nil
            )

            step(
                title: "Session",
                state: connectionStatus.sessionStep,
                detail: "IOSSim establishes the on-device developer session.",
                actionLabel: nil,
                action: nil
            )

            Section {
                Button {
                    // The user's own tap is the setup-completion signal Veya waits for.
                    Task { await connectionStatus.runSetup(answeringVeyaRequest: true) }
                } label: {
                    HStack {
                        if connectionStatus.isWorking {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text(connectionStatus.allStepsPass ? "Setup Complete" : "Run Setup")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(connectionStatus.isWorking)
                .tint(connectionStatus.allStepsPass ? .green : .accentColor)
            }
        }
        .navigationTitle("Set Up IOSSim")
        .task {
            await connectionStatus.refreshFromCurrentState()
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
                await connectionStatus.runSetup()
            }
        }
    }

    private func step(
        title: String,
        state: SetupStepState,
        detail: String,
        actionLabel: String?,
        action: (() -> Void)?
    ) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                icon(for: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(explanation(for: state, fallback: detail))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let action, let actionLabel {
                Button(actionLabel, action: action)
            }
        }
    }

    @ViewBuilder
    private func icon(for state: SetupStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .fail:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func explanation(for state: SetupStepState, fallback: String) -> String {
        if case .fail(let code, let detail) = state {
            return HumanReadableError.describe(code: code, detail: detail)
        }
        return fallback
    }
}
