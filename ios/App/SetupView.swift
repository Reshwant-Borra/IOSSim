import SwiftUI

/// Guided first-run / recovery setup flow. Translates the same diagnostic
/// stages the original developer console showed (Pairing, LocalDevVPN,
/// Endpoint, Session/DVT) into plain language, while the exact POCErrorCode
/// and message are still shown via HumanReadableError -> the same mapping
/// Developer diagnostics use, so nothing about the failure is hidden, only
/// translated.
struct SetupView: View {
    @ObservedObject private var connectionStatus = POCAppDependencies.connectionStatus

    var body: some View {
        List {
            Section {
                Text("IOSSim needs a one-time pairing, an active LocalDevVPN connection, and a developer session before it can simulate a location.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            step(
                title: "Pairing",
                state: connectionStatus.pairingStep,
                detail: "Keep this iPhone unlocked while IOSSim on your Mac prepares the secure connection.",
                actionLabel: nil,
                action: nil
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
                    Task { await connectionStatus.runSetup() }
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
