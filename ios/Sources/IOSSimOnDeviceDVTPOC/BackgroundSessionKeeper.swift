import Foundation

#if canImport(UIKit)
import UIKit
#endif

public final class BackgroundSessionKeeper: @unchecked Sendable {
    private let recorder: SessionDiagnosticRecorder
    private let lock = NSLock()

    #if canImport(UIKit)
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    public init(recorder: SessionDiagnosticRecorder = .shared) {
        self.recorder = recorder
    }

    public func begin() {
        #if canImport(UIKit)
        lock.lock()
        let alreadyActive = backgroundTask != .invalid
        lock.unlock()
        guard !alreadyActive else { return }

        Task {
            await recorder.record(
                category: "LIFECYCLE",
                component: "BackgroundTask",
                previousState: "inactive",
                newState: "starting",
                message: "begin background task"
            )
        }

        let task = UIApplication.shared.beginBackgroundTask(withName: "iossim.dvt.session") { [weak self] in
            self?.expire()
        }

        lock.lock()
        backgroundTask = task
        lock.unlock()

        Task {
            await recorder.record(
                category: "LIFECYCLE",
                component: "BackgroundTask",
                previousState: "starting",
                newState: task == .invalid ? "failed" : "active",
                errorCode: task == .invalid ? "BACKGROUND_TASK_FAILED" : nil,
                message: task == .invalid ? "background task not granted" : "background task active"
            )
        }
        #else
        Task {
            await recorder.record(
                category: "LIFECYCLE",
                component: "BackgroundTask",
                newState: "unavailable",
                message: "UIKit unavailable"
            )
        }
        #endif
    }

    public func end(reason: String) {
        #if canImport(UIKit)
        lock.lock()
        let task = backgroundTask
        backgroundTask = .invalid
        lock.unlock()

        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        Task {
            await recorder.record(
                category: "LIFECYCLE",
                component: "BackgroundTask",
                previousState: "active",
                newState: "ended",
                message: reason
            )
        }
        #endif
    }

    private func expire() {
        #if canImport(UIKit)
        lock.lock()
        let task = backgroundTask
        backgroundTask = .invalid
        lock.unlock()

        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
        Task {
            await recorder.record(
                category: "LIFECYCLE",
                component: "BackgroundTask",
                previousState: "active",
                newState: "expired",
                errorCode: "BACKGROUND_TASK_EXPIRED",
                message: "iOS expired background task"
            )
        }
        #endif
    }

    deinit {
        end(reason: "background keeper deinit")
    }
}
