import SwiftUI

/// Top-level product navigation. Location and Drive are the primary product
/// surfaces; developer/diagnostic tooling lives under Settings so it never
/// crowds the normal workflows. This shell intentionally does not own any
/// engine state itself — every tab reads from the same POCAppDependencies
/// singletons, so switching tabs never creates a second coordinator/tunnel
/// client and never interrupts an active Drive session.
struct RootTabView: View {
    @ObservedObject private var router = POCAppDependencies.router
    @ObservedObject private var connectionStatus = POCAppDependencies.connectionStatus
    @State private var showingVeyaSetup = false

    var body: some View {
        tabs
            // Veya delivered a setup request and is waiting. Presenting Setup only
            // puts the Run Setup button in front of the user; it never runs it.
            .onChange(of: connectionStatus.veyaSetupRequestPending) { _, pending in
                if pending { showingVeyaSetup = true }
            }
            .sheet(isPresented: $showingVeyaSetup) {
                NavigationStack {
                    SetupView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingVeyaSetup = false }
                            }
                        }
                }
            }
    }

    private var tabs: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack {
                LocationView()
            }
            .tabItem {
                Label("Location", systemImage: "location.fill")
            }
            .tag(AppRouter.Tab.location)

            NavigationStack {
                DriveView()
            }
            .tabItem {
                Label("Drive", systemImage: "car.fill")
            }
            .tag(AppRouter.Tab.drive)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(AppRouter.Tab.settings)
        }
    }
}
