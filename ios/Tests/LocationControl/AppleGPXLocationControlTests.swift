import CoreLocation
import XCTest

final class AppleGPXLocationControlTests: XCTestCase {
    private let requestedVelocityMps = 15.646
    private let expectedGPXDurationSeconds: TimeInterval = 160

    func testAppleGPXJourneyCharacterization() async throws {
        let recorder = AppleLocationControlRecorder()
        let authorized = expectation(description: "location authorization granted")
        authorized.assertForOverFulfill = false
        let firstObservation = expectation(description: "first Core Location callback delivered")
        firstObservation.assertForOverFulfill = false

        recorder.setAuthorizationHandler { status in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                authorized.fulfill()
            }
        }
        recorder.setObservationHandler { _ in
            firstObservation.fulfill()
        }

        if recorder.authorizationStatus == .authorizedWhenInUse || recorder.authorizationStatus == .authorizedAlways {
            authorized.fulfill()
        }

        await MainActor.run {
            recorder.start()
        }
        await fulfillment(of: [authorized], timeout: 60)

        let status = recorder.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            XCTFail("Location authorization status is \(status.rawValue); allow location access and rerun the test.")
            return
        }

        await fulfillment(of: [firstObservation], timeout: 30)
        try await Task.sleep(nanoseconds: UInt64((expectedGPXDurationSeconds + 20) * 1_000_000_000))
        recorder.stop()

        let observations = recorder.allObservations()
        let summary = AppleLocationControlAnalysis.summary(
            for: observations,
            requestedVelocityMps: requestedVelocityMps
        )
        let timestamp = Self.fileTimestamp(Date())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleGPX-\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonlURL = directory.appendingPathComponent("APPLE-GPX-\(timestamp).jsonl")
        let summaryURL = directory.appendingPathComponent("APPLE-GPX-\(timestamp)-summary.txt")

        try AppleLocationControlAnalysis
            .jsonLines(observations: observations, summary: summary)
            .write(to: jsonlURL, atomically: true, encoding: .utf8)
        try AppleLocationControlAnalysis
            .summaryText(summary)
            .write(to: summaryURL, atomically: true, encoding: .utf8)

        attachFile(jsonlURL, name: jsonlURL.lastPathComponent)
        attachFile(summaryURL, name: summaryURL.lastPathComponent)

        XCTAssertGreaterThanOrEqual(observations.count, 2, "Expected at least two Core Location callbacks from GPX replay.")
    }

    private func attachFile(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
