import SwiftUI

@main
struct IOSSimOnDeviceDVTPOCApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    // Setup ingress only: creates the one-time bootstrap or
                    // imports a delivered envelope. House Arrest may place the
                    // request after this already-running app was activated, so
                    // keep a short bounded setup-only inbox watch. This never
                    // starts LocalDevVPN, TestManager, XCTest, or location.
                    let inbox = AutomaticPairingInboxController()
                    for _ in 0..<240 {
                        if Task.isCancelled { break }
                        do {
                            if try inbox.reconcile()?.status == "operational" { break }
                        } catch {
                            // A malformed/expired request is retried on a later
                            // activation after the Mac has repaired delivery;
                            // do not hammer a persistent failure at 4 Hz.
                            break
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    // Setup-only LocalDevVPN readiness receipt. The Mac first
                    // activates IOSSim, then launches the separately installed
                    // LocalDevVPN app. This task gets a bounded background
                    // window to reuse the existing 10.7.0.1:49152 probe and
                    // never starts TestManager, XCTest, or location.
                    try? await LocalDevVPNSetupInboxController().reconcileIfRequested()
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    // Watches only for Veya's setup request so the Run Setup prompt
                    // can be shown. It never starts a setup run: the user's tap does.
                    await POCAppDependencies.connectionStatus.watchForVeyaSetupRequest()
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    // Legacy Mac-driven proof, retained for the provisioner's
                    // diagnostic command. The setup flow no longer requests it, so
                    // this stays inert unless a rich-runtime-proof request exists.
                    // Final setup proof only: one DVT and one Rich Drive coordinate,
                    // each confirmed by Core Location here, then cleared. The
                    // verifier is created on the main thread for its callbacks.
                    try? await RichRuntimeProofInboxController(
                        locationCoordinator: POCAppDependencies.locationCoordinator,
                        tunnelClient: POCAppDependencies.tunnelClient,
                        verifier: CoreLocationVerifier()
                    ).reconcileIfRequested()
                }
        }
    }
}
