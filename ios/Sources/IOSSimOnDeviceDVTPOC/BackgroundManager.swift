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

    #if os(iOS)
    @available(iOS 17.0, *)
    private var backgroundActivitySession: CLBackgroundActivitySession?
    #endif

    public init(recorder: SessionDiagnosticRecorder = .shared, keeper: BackgroundSessionKeeper? = nil) {
        self.recorder = recorder
        self.keeper = keeper ?? BackgroundSessionKeeper(recorder: recorder)
    }

    public func begin() {
        lock.lock()
        let alreadyActive = active
        active = true
        lock.unlock()
        guard !alreadyActive else { return }

        keeper.begin()
        #if os(iOS)
        if #available(iOS 17.0, *) {
            backgroundActivitySession = CLBackgroundActivitySession()
        }
        #endif
        Task {
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
        lock.unlock()
        guard wasActive else { return }

        #if os(iOS)
        if #available(iOS 17.0, *) {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
        }
        #endif
        keeper.end(reason: reason)
        Task {
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
        lock.unlock()
        Task {
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
}

