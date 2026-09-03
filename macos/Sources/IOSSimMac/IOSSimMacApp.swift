import SwiftUI
import IOSSimMacCore

@main
struct IOSSimMacApp: App {
    @StateObject private var store: SetupStore

    init() {
        let engine: any IOSSimSetupEngine
#if IOSSIM_BUNDLED_ENGINE
        do {
            engine = try BundledProvisioningEngine.live()
        } catch {
            engine = UnavailableIOSSimSetupEngine(
                message: "Bundled runtime damaged: IOSSim cannot find its setup helper. Reinstall IOSSim."
            )
        }
#else
        do {
            engine = try DevelopmentCLIEngine.live()
        } catch {
            engine = UnavailableIOSSimSetupEngine(
                message: "The development IOSSim CLI could not be found. Set IOSSIM_REPOSITORY_ROOT or IOSSIM_CLI_PATH for this development build."
            )
        }
#endif
        _store = StateObject(wrappedValue: SetupStore(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 520)
                .task {
                    store.bootstrap()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
