import CoreLocation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

public final class DriveBackgroundManager: @unchecked Sendable {
    private let recorder: SessionDiagnosticRecorder
    private let keeper: BackgroundSessionKeeper
    private let lock = NSLock()
    private var lifecycleState = "foreground"
    private var active = false
    private var diagnostics: DriveDiagnostics?

    #if os(iOS)
    @available(iOS 17.0, *)
    private var backgroundActivitySession: CLBackgroundActivitySession?
    #endif

    public init(recorder: SessionDiagnosticRecorder = .shared, keeper: BackgroundSessionKeeper? = nil) {
        self.recorder = recorder
        self.keeper = keeper ?? BackgroundSessionKeeper(recorder: recorder)
    }

    public func setDiagnostics(_ diagnostics: DriveDiagnostics?) {
        lock.lock()
        self.diagnostics = diagnostics
        lock.unlock()
    }

    public func begin() {
        lock.lock()
        let alreadyActive = active
        active = true
        let diagnostics = diagnostics
        lock.unlock()
        guard !alreadyActive else { return }

        keeper.begin()
        #if os(iOS)
        if #available(iOS 17.0, *) {
            backgroundActivitySession = CLBackgroundActivitySession()
            Task {
                await diagnostics?.recordBackgroundEvent("background_activity_session_created")
            }
        }
        #endif
        Task {
            await diagnostics?.recordBackgroundEvent("background_task_started", metadata: verifierConfigurationMetadata())
            await recorder.record(
                category: "LIFECYCLE",
                component: "DriveBackground",
                previousState: "inactive",
                newState: "active",
                message: "drive background support requested"
            )
        }
    }

    public func end(reason: String) {
        lock.lock()
        let wasActive = active
        active = false
        let diagnostics = diagnostics
        lock.unlock()
        guard wasActive else { return }

        #if os(iOS)
        if #available(iOS 17.0, *) {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
            Task {
                await diagnostics?.recordBackgroundEvent("background_activity_session_destroyed")
            }
        }
        #endif
        keeper.end(reason: reason)
        Task {
            await diagnostics?.recordBackgroundEvent("background_task_ended", metadata: ["reason": reason])
            await recorder.record(
                category: "LIFECYCLE",
                component: "DriveBackground",
                previousState: "active",
                newState: "ended",
                message: reason
            )
        }
    }

    public func recordLifecycle(_ state: String) {
        lock.lock()
        lifecycleState = state
        let active = active
        let diagnostics = diagnostics
        lock.unlock()
        Task {
            await diagnostics?.recordLifecycle(
                state,
                schedulerState: active ? "active" : "inactive",
                backgroundSessionActive: active,
                connectionGeneration: 0
            )
            await recorder.record(
                category: "APP_LIFECYCLE",
                component: "DriveBackground",
                previousState: nil,
                newState: state,
                message: "drive lifecycle transition"
            )
        }
    }

    public func applicationLifecycleState() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lifecycleState
    }

    public func isBackgroundSessionActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private func verifierConfigurationMetadata() -> [String: String] {
        #if os(iOS)
        return [
            "allows_background_location_updates": "true",
            "pauses_location_updates_automatically": "false",
            "activity_type": "automotiveNavigation"
        ]
        #else
        return [:]
        #endif
    }
}
