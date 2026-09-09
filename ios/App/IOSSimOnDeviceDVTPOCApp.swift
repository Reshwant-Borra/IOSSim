import SwiftUI

@main
struct IOSSimOnDeviceDVTPOCApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task { await processPairingInbox() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await processPairingInbox() }
                }
        }
    }

    private func processPairingInbox() async {
        let receipts = await POCAppDependencies.pairingInbox.processPending()
        if receipts.contains(where: { $0.state == "PAIRING_READY" }) {
            await POCAppDependencies.connectionStatus.refreshFromCurrentState()
        }
    }
}
