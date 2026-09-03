import SwiftUI
import IOSSimMacCore

struct RootView: View {
    @EnvironmentObject private var store: SetupStore
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .toolbar {
            ToolbarItem {
                Button("Diagnostics") {
                    showingDiagnostics = true
                }
                .accessibilityLabel("Open diagnostics")
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environmentObject(store)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("IOSSim")
                    .font(.title2.weight(.semibold))
                Text(store.phase == .complete ? "Setup and device status" : "Set up IOSSim on your iPhone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.phase != .welcome && store.phase != .complete && store.phase != .failed {
                Text("Step \(store.phase.stepIndex) of 8")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Step \(store.phase.stepIndex) of 8")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .welcome:
            WelcomeView()
        case .complete:
            DashboardView()
        case .failed:
            FailureView()
        default:
            SetupWizardView()
        }
    }
}
