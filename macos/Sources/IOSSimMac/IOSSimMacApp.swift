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
                message: String(describing: error)
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
            #if VEYA_QUALIFICATION
            if Bundle.main.object(forInfoDictionaryKey: "VeyaDevelopmentSession") as? Bool == true
                || ProcessInfo.processInfo.environment["VEYA_DEVELOPMENT_SESSION"] == "1" {
                DevelopmentInstallationView().frame(minWidth: 720, minHeight: 620)
            } else {
                setupView
            }
            #else
            setupView
            #endif
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private var setupView: some View {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 520)
                .task {
                    store.bootstrap()
                }
    }
}
