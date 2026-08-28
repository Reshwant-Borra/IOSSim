import CoreLocation
import UIKit
import XCTest

final class AppleXCUILocationControlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpenAppleLocationControlsSmoke() throws {
        let app = launchApp()
        openAppleLocationControls(in: app)
        XCTAssertTrue(app.buttons["AppleLocationControls.StartRecording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AppleLocationControls.StopRecording"].exists)
    }

    func testXCUILocationSinglePointMetadataControl() throws {
        try requireXCUILocationSupport()
        let app = launchApp()
        openAppleLocationControls(in: app)
        startRecording(in: app)

        XCUIDevice.shared.location = XCUILocation(location: richLocation(
            latitude: 37.334_900,
            longitude: -122.009_020,
            altitude: 123,
            course: 90,
            speed: 15.646,
            timestamp: Date()
        ))

        XCTAssertTrue(waitForRawLocationCount(in: app, minimum: 1, timeout: 12))
        stopAndAttachExport(in: app, namePrefix: "APPLE-XCUILOCATION-SINGLE")
    }

    func testXCUILocationRouteControl() throws {
        try requireXCUILocationSupport()
        let app = launchApp()
        openAppleLocationControls(in: app)
        startRecording(in: app)

        let start = Date()
        for (index, coordinate) in Self.routeCoordinates().enumerated() {
            XCUIDevice.shared.location = XCUILocation(location: richLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitude: 120 + Double(index),
                course: coordinate.course,
                speed: 15.646,
                timestamp: start.addingTimeInterval(Double(index) * 0.5)
            ))
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(waitForRawLocationCount(in: app, minimum: 5, timeout: 15))
        stopAndAttachExport(in: app, namePrefix: "APPLE-XCUILOCATION-ROUTE")
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--apple-location-control-ui-test"]
        app.launch()
        return app
    }

    private func openAppleLocationControls(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        let link = app.buttons["Apple Location Controls"]
        for _ in 0..<6 where !link.exists {
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
    }

    private func startRecording(in app: XCUIApplication) {
        app.buttons["AppleLocationControls.StartRecording"].tap()
        allowLocationIfPrompted(in: app)
    }

    private func stopAndAttachExport(in app: XCUIApplication, namePrefix: String) {
        app.buttons["AppleLocationControls.StopRecording"].tap()
        XCTAssertTrue(app.buttons["AppleLocationControls.CopyJSONL"].waitForExistence(timeout: 5))
        app.buttons["AppleLocationControls.CopyJSONL"].tap()
        if let jsonl = UIPasteboard.general.string, !jsonl.isEmpty {
            let attachment = XCTAttachment(string: jsonl)
            attachment.name = "\(namePrefix).jsonl"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func allowLocationIfPrompted(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowOnce = springboard.buttons["Allow Once"]
        if allowOnce.waitForExistence(timeout: 3) {
            allowOnce.tap()
            return
        }
        let whileUsing = springboard.buttons["Allow While Using App"]
        if whileUsing.waitForExistence(timeout: 1) {
            whileUsing.tap()
        }
    }

    private func waitForRawLocationCount(in app: XCUIApplication, minimum: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = app.staticTexts["AppleLocationControls.RawLocationValue"].label
            if let value = Int(text.replacingOccurrences(of: "raw_locations=", with: "")), value >= minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func richLocation(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        course: Double,
        speed: Double,
        timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 4,
            verticalAccuracy: 2,
            course: course,
            courseAccuracy: 1,
            speed: speed,
            speedAccuracy: 0.5,
            timestamp: timestamp
        )
    }

    private func requireXCUILocationSupport() throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("XCUIDevice.location requires iOS 16.4 or newer.")
        }
    }

    private static func routeCoordinates() -> [(latitude: Double, longitude: Double, course: Double)] {
        [
            (37.334900, -122.009020, 90),
            (37.334900, -122.008932, 90),
            (37.334900, -122.008844, 90),
            (37.334900, -122.008756, 90),
            (37.334900, -122.008668, 90),
            (37.334930, -122.008580, 45),
            (37.334985, -122.008520, 25),
            (37.335055, -122.008490, 15),
            (37.335125, -122.008470, 15),
            (37.335195, -122.008450, 15),
            (37.335265, -122.008430, 15),
            (37.335335, -122.008410, 15),
            (37.335390, -122.008350, 60),
            (37.335420, -122.008262, 90),
            (37.335420, -122.008174, 90),
            (37.335420, -122.008086, 90),
            (37.335390, -122.007998, 135),
            (37.335335, -122.007938, 160),
            (37.335265, -122.007918, 180),
            (37.335195, -122.007918, 180)
        ]
    }
}
