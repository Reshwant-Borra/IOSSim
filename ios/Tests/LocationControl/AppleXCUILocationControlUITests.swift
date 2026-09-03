import CoreLocation
import Darwin
import UIKit
import XCTest

final class AppleXCUILocationControlUITests: XCTestCase {
  private let witnessBundleIdentifier = "com.iossim.location-witness"
  private static let gate1RichLocationOnlyEnvironmentKey = "IOSSIM_GATE1_RICH_LOCATION_ONLY"
  private static let gate1RichLocationTestName = "testGate1NoXcodebuildRichLocationWitnessProof"
  private static let richDriveRunnerEnvironmentKey = "IOSSIM_RICH_DRIVE_RUNNER"
  private static let richDriveRunnerTestName = "testRichDriveLongLivedRunner"

  override func setUpWithError() throws {
    continueAfterFailure = false
    if Self.isGate1RichLocationOnlyRun, !name.contains(Self.gate1RichLocationTestName) {
      throw XCTSkip("Skipping non-Gate-1 test during no-xcodebuild rich-location runner proof.")
    }
    if Self.isRichDriveRunnerRun, !name.contains(Self.richDriveRunnerTestName) {
      throw XCTSkip("Skipping non-rich-drive test during long-lived runner mode.")
    }
  }

  func testOpenAppleLocationControlsSmoke() throws {
    let app = launchApp()
    openAppleLocationControls(in: app)
    XCTAssertTrue(app.buttons["AppleLocationControls.StartRecording"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["AppleLocationControls.StopRecording"].exists)
  }

  func testLocationWitnessExportMetricsDoesNotTriggerStop() throws {
    try requireXCUILocationSupport()
    let witness = launchWitnessApp()
    XCTAssertTrue(witness.buttons["LocationWitness.Reset"].waitForExistence(timeout: 10))

    let reset = witness.buttons["LocationWitness.Reset"]
    let start = witness.buttons["LocationWitness.Start"]
    let stop = witness.buttons["LocationWitness.Stop"]
    let export = witness.buttons["LocationWitness.ExportMetrics"]

    assertControlsDoNotOverlap([reset, start, stop, export])

    reset.tap()
    XCTAssertFalse(export.isEnabled, "Export remains disabled before completed recording data exists.")

    start.tap()
    allowLocationIfPrompted(in: witness)
    allowAlwaysLocationUpgradeIfPrompted()
    let baselineSequence =
      latestRawLocationSnapshot(in: witness, prefix: "LocationWitness")?.sequence ?? 0
    let injectedLatitude = 37.334_456
    let injectedLongitude = -122.008_654
    XCUIDevice.shared.location = XCUILocation(
      location: richLocation(
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        altitude: 123,
        course: 90,
        speed: 15.646,
        timestamp: Date()
      ))
    XCTAssertNotNil(
      waitForFreshRawLocation(
        in: witness,
        prefix: "LocationWitness",
        afterSequence: baselineSequence,
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        timeout: 15
      ),
      "Witness should receive at least one raw callback before exporting."
    )

    stop.tap()
    let status = witness.staticTexts["LocationWitness.Status"]
    XCTAssertTrue(status.waitForExistence(timeout: 3))
    XCTAssertEqual(status.label, "Stopped")
    XCTAssertTrue(export.waitForExistence(timeout: 3))
    XCTAssertTrue(export.isEnabled)
    XCTAssertTrue(
      ((export.value as? String) ?? "").contains("IOSSim-Witness-Metrics-"),
      "Export button exposes a prepared JSON file name."
    )

    export.tap()
    XCTAssertEqual(status.label, "Stopped", "Export Metrics must not change recorder state.")
    XCTAssertTrue(
      waitForShareSheet(in: witness, timeout: 8),
      "Export Metrics should present the system share sheet."
    )
  }

  func testXCUILocationSinglePointMetadataControl() throws {
    try requireXCUILocationSupport()
    let app = launchApp()
    openAppleLocationControls(in: app)
    startRecording(in: app)

    let baselineSequence = latestRawLocationSnapshot(in: app)?.sequence ?? 0
    let injectedLatitude = 37.334_900
    let injectedLongitude = -122.009_020
    let injectedTimestamp = Date()
    XCUIDevice.shared.location = XCUILocation(
      location: richLocation(
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        altitude: 123,
        course: 90,
        speed: 15.646,
        timestamp: injectedTimestamp
      ))

    guard
      let received = waitForFreshRawLocation(
        in: app,
        afterSequence: baselineSequence,
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        timeout: 15
      )
    else {
      let latestSummary = latestRawLocationSummary(in: app) ?? "MISSING"
      XCTFail(
        """
        Timed out waiting for fresh CLLocation callback matching injected coordinate.
        baseline_sequence=\(baselineSequence)
        injected_latitude=\(String(format: "%.8f", injectedLatitude))
        injected_longitude=\(String(format: "%.8f", injectedLongitude))
        latest_raw_metadata=\(latestSummary)
        """)
      return
    }

    let summary = """
      Received raw CLLocation metadata after XCUIDevice.shared.location injection:
      injected.latitude=\(String(format: "%.8f", injectedLatitude))
      injected.longitude=\(String(format: "%.8f", injectedLongitude))
      injected.horizontalAccuracy=4.000000
      injected.verticalAccuracy=2.000000
      injected.altitude=123.000000
      injected.speed=15.646000
      injected.course=90.000000
      injected.timestamp=\(Self.iso8601String(from: injectedTimestamp))
      received.sequence=\(received.sequence.map(String.init) ?? "UNKNOWN")
      received.latitude=\(Self.format(received.latitude))
      received.longitude=\(Self.format(received.longitude))
      received.horizontalAccuracy=\(Self.format(received.horizontalAccuracy))
      received.verticalAccuracy=\(Self.format(received.verticalAccuracy))
      received.altitude=\(Self.format(received.altitude))
      received.speed=\(Self.format(received.speed))
      received.course=\(Self.format(received.course))
      received.locationTimestamp=\(received.locationTimestamp ?? "UNKNOWN")
      received.wallClockTimestamp=\(received.wallClockTimestamp ?? "UNKNOWN")
      received.isSimulatedBySoftware=\(received.isSimulatedBySoftware ?? "UNKNOWN")
      received.isProducedByAccessory=\(received.isProducedByAccessory ?? "UNKNOWN")
      raw_metadata_summary=\(received.rawSummary)
      """
    print(summary)
    let attachment = XCTAttachment(string: summary)
    attachment.name = "APPLE-XCUILOCATION-SINGLE-received-metadata.txt"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testReceivedRawLocationSnapshotParsing() throws {
    let snapshot = try XCTUnwrap(
      ReceivedRawLocationSnapshot(
        summary: [
          "sequence=7",
          "latitude=37.33490000",
          "longitude=-122.00902000",
          "speed=15.646000",
          "course=90.000000",
          "horizontalAccuracy=4.000000",
          "verticalAccuracy=2.000000",
          "altitude=123.000000",
          "locationTimestamp=2026-08-30T12:34:56.789Z",
          "wallClockTimestamp=2026-08-30T12:34:57.123Z",
          "isSimulatedBySoftware=true",
          "isProducedByAccessory=false",
        ].joined(separator: " ")))

    XCTAssertEqual(snapshot.sequence, 7)
    XCTAssertEqual(try XCTUnwrap(snapshot.latitude), 37.33490000, accuracy: 0.00000001)
    XCTAssertEqual(try XCTUnwrap(snapshot.longitude), -122.00902000, accuracy: 0.00000001)
    XCTAssertEqual(try XCTUnwrap(snapshot.speed), 15.646000, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(snapshot.course), 90.000000, accuracy: 0.000001)
    XCTAssertTrue(snapshot.matches(latitude: 37.33490000, longitude: -122.00902000))
    XCTAssertFalse(snapshot.matches(latitude: 37.33590000, longitude: -122.00902000))
    XCTAssertEqual(snapshot.isSimulatedBySoftware, "true")
    XCTAssertEqual(snapshot.isProducedByAccessory, "false")
  }

  func testRouteMetadataSummaryCalculations() throws {
    let injected = Array(Self.routeCoordinates().prefix(3))
    let received = try injected.enumerated().map { index, coordinate in
      try XCTUnwrap(
        ReceivedRawLocationSnapshot(
          summary: [
            "sequence=\(index + 1)",
            "latitude=\(String(format: "%.8f", coordinate.latitude))",
            "longitude=\(String(format: "%.8f", coordinate.longitude))",
            "speed=15.646000",
            "course=\(String(format: "%.6f", coordinate.course))",
            "horizontalAccuracy=4.000000",
            "verticalAccuracy=2.000000",
            "altitude=\(String(format: "%.6f", 120 + Double(index)))",
            "locationTimestamp=2026-08-30T12:34:5\(index).000Z",
            "wallClockTimestamp=2026-08-30T12:34:5\(index).000Z",
            "isSimulatedBySoftware=true",
            "isProducedByAccessory=false",
          ].joined(separator: " ")))
    }

    let summary = Self.routeSummary(for: received, injected: injected)
    XCTAssertTrue(summary.contains("injected_point_count=3"))
    XCTAssertTrue(summary.contains("received_matching_point_count=3"))
    XCTAssertTrue(summary.contains("speed_valid_count=3"))
    XCTAssertTrue(summary.contains("course_valid_count=3"))
    XCTAssertTrue(summary.contains("received_speed_matches_15_646_mps_within_0_1=true"))
    XCTAssertTrue(summary.contains("received_course_follows_injected_within_1_deg=true"))
    XCTAssertTrue(summary.contains("callback_cadence_count=2"))
    XCTAssertTrue(summary.contains("callback_cadence_median_s=1.000000"))
  }

  func testWitnessSystemScopeClassificationCalculations() throws {
    let injected = Array(Self.routeCoordinates().prefix(3))
    let richMatches = try injected.enumerated().map { index, coordinate in
      try XCTUnwrap(
        ReceivedRawLocationSnapshot(
          summary: [
            "sequence=\(index + 10)",
            "latitude=\(String(format: "%.8f", coordinate.latitude))",
            "longitude=\(String(format: "%.8f", coordinate.longitude))",
            "speed=15.646000",
            "course=\(String(format: "%.6f", coordinate.course))",
            "horizontalAccuracy=4.000000",
            "verticalAccuracy=2.000000",
            "altitude=\(String(format: "%.6f", 120 + Double(index)))",
            "locationTimestamp=2026-08-30T12:34:5\(index).000Z",
            "wallClockTimestamp=2026-08-30T12:34:5\(index).500Z",
            "isSimulatedBySoftware=true",
            "isProducedByAccessory=false",
          ].joined(separator: " ")))
    }
    let coordinateOnlyMatches = try injected.enumerated().map { index, coordinate in
      try XCTUnwrap(
        ReceivedRawLocationSnapshot(
          summary: [
            "sequence=\(index + 10)",
            "latitude=\(String(format: "%.8f", coordinate.latitude))",
            "longitude=\(String(format: "%.8f", coordinate.longitude))",
            "speed=-1.000000",
            "course=-1.000000",
          ].joined(separator: " ")))
    }

    XCTAssertEqual(Self.systemScopeClassification(for: [], injected: injected), "A")
    XCTAssertEqual(
      Self.systemScopeClassification(for: coordinateOnlyMatches, injected: injected), "B")
    XCTAssertEqual(Self.systemScopeClassification(for: richMatches, injected: injected), "C")

    let summary = Self.systemScopeSummary(for: richMatches, injected: injected, baselineSequence: 9)
    XCTAssertTrue(summary.contains("final_classification=C"))
    XCTAssertTrue(summary.contains("witness_matching_point_count=3"))
    XCTAssertTrue(summary.contains("speed_valid_count=3"))
    XCTAssertTrue(summary.contains("course_valid_count=3"))
  }

  func testXCUILocationWitnessForegroundControl() throws {
    try requireXCUILocationSupport()
    let witness = launchWitnessApp()
    resetAndStartWitnessRecorder(in: witness)

    let baselineSequence =
      latestRawLocationSnapshot(in: witness, prefix: "LocationWitness")?.sequence ?? 0
    let injectedLatitude = 37.334_321
    let injectedLongitude = -122.008_765
    let injectedCourse = 123.0
    let injectedAltitude = 147.0
    let injectedTimestamp = Date()
    XCUIDevice.shared.location = XCUILocation(
      location: richLocation(
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        altitude: injectedAltitude,
        course: injectedCourse,
        speed: 15.646,
        timestamp: injectedTimestamp
      ))

    guard
      let received = waitForFreshRawLocation(
        in: witness,
        prefix: "LocationWitness",
        afterSequence: baselineSequence,
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        timeout: 15
      )
    else {
      let latestSummary =
        latestRawLocationSummary(in: witness, prefix: "LocationWitness") ?? "MISSING"
      XCTFail(
        """
        Timed out waiting for foreground witness CLLocation callback matching injected coordinate.
        baseline_sequence=\(baselineSequence)
        injected_latitude=\(String(format: "%.8f", injectedLatitude))
        injected_longitude=\(String(format: "%.8f", injectedLongitude))
        latest_witness_metadata=\(latestSummary)
        """)
      return
    }

    let summary = """
      WITNESS-FOREGROUND received raw CLLocation metadata:
      injected.latitude=\(String(format: "%.8f", injectedLatitude))
      injected.longitude=\(String(format: "%.8f", injectedLongitude))
      injected.horizontalAccuracy=4.000000
      injected.verticalAccuracy=2.000000
      injected.altitude=\(String(format: "%.6f", injectedAltitude))
      injected.speed=15.646000
      injected.course=\(String(format: "%.6f", injectedCourse))
      injected.timestamp=\(Self.iso8601String(from: injectedTimestamp))
      received.sequence=\(received.sequence.map(String.init) ?? "UNKNOWN")
      received.latitude=\(Self.format(received.latitude))
      received.longitude=\(Self.format(received.longitude))
      received.speed=\(Self.format(received.speed))
      received.course=\(Self.format(received.course))
      received.horizontalAccuracy=\(Self.format(received.horizontalAccuracy))
      received.verticalAccuracy=\(Self.format(received.verticalAccuracy))
      received.altitude=\(Self.format(received.altitude))
      received.locationTimestamp=\(received.locationTimestamp ?? "UNKNOWN")
      received.wallClockTimestamp=\(received.wallClockTimestamp ?? "UNKNOWN")
      received.isSimulatedBySoftware=\(received.isSimulatedBySoftware ?? "UNKNOWN")
      received.isProducedByAccessory=\(received.isProducedByAccessory ?? "UNKNOWN")
      raw_metadata_summary=\(received.rawSummary)
      """
    print(summary)
    attach(summary, name: "WITNESS-FOREGROUND-received-metadata.txt")
  }

  func testGate1NoXcodebuildRichLocationWitnessProof() throws {
    guard Self.isGate1RichLocationOnlyRun else {
      throw XCTSkip(
        "Gate 1 proof runs only when \(Self.gate1RichLocationOnlyEnvironmentKey)=1 is set.")
    }
    try requireXCUILocationSupport()

    let witness = launchWitnessApp()
    resetAndStartWitnessRecorder(in: witness)

    let baselineSequence =
      latestRawLocationSnapshot(in: witness, prefix: "LocationWitness")?.sequence ?? 0
    let injectedLatitude = 37.334_900
    let injectedLongitude = -122.009_020
    let injectedCourse = 90.0
    let injectedSpeed = 15.646
    let injectedAltitude = 123.0
    let injectedHorizontalAccuracy = 4.0
    let injectedVerticalAccuracy = 3.0
    let injectedTimestamp = Date()

    XCUIDevice.shared.location = XCUILocation(
      location: richLocation(
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        altitude: injectedAltitude,
        course: injectedCourse,
        speed: injectedSpeed,
        timestamp: injectedTimestamp
      ))

    RunLoop.current.run(until: Date().addingTimeInterval(3))

    guard
      let received = waitForFreshRawLocation(
        in: witness,
        prefix: "LocationWitness",
        afterSequence: baselineSequence,
        latitude: injectedLatitude,
        longitude: injectedLongitude,
        timeout: 20
      )
    else {
      let latestSummary =
        latestRawLocationSummary(in: witness, prefix: "LocationWitness") ?? "MISSING"
      XCTFail(
        """
        Gate 1 witness timed out waiting for no-xcodebuild rich-location CLLocation callback.
        baseline_sequence=\(baselineSequence)
        injected.latitude=\(String(format: "%.8f", injectedLatitude))
        injected.longitude=\(String(format: "%.8f", injectedLongitude))
        injected.speed=\(String(format: "%.6f", injectedSpeed))
        injected.course=\(String(format: "%.6f", injectedCourse))
        injected.altitude=\(String(format: "%.6f", injectedAltitude))
        latest_witness_metadata=\(latestSummary)
        authorization=\(authorizationSummary(in: witness))
        """)
      return
    }

    let speedDelta = abs((received.speed ?? -.greatestFiniteMagnitude) - injectedSpeed)
    let courseDelta = received.course.map { Self.angularDifferenceDegrees($0, injectedCourse) }
    XCTAssertEqual(try XCTUnwrap(received.latitude), injectedLatitude, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(received.longitude), injectedLongitude, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(received.speed), injectedSpeed, accuracy: 0.1)
    XCTAssertLessThanOrEqual(try XCTUnwrap(courseDelta), 1.0)
    XCTAssertEqual(try XCTUnwrap(received.altitude), injectedAltitude, accuracy: 0.1)
    XCTAssertEqual(
      try XCTUnwrap(received.horizontalAccuracy), injectedHorizontalAccuracy, accuracy: 0.1)
    XCTAssertEqual(
      try XCTUnwrap(received.verticalAccuracy), injectedVerticalAccuracy, accuracy: 0.1)
    XCTAssertEqual(received.isSimulatedBySoftware, "true")
    XCTAssertEqual(received.isProducedByAccessory, "false")

    let summary = """
      RICH_LOCATION_RUNNER_EXECUTED
      GATE1_NO_XCODEBUILD_RICH_LOCATION_WITNESS_METADATA:
      injected.latitude=\(String(format: "%.8f", injectedLatitude))
      injected.longitude=\(String(format: "%.8f", injectedLongitude))
      injected.horizontalAccuracy=\(String(format: "%.6f", injectedHorizontalAccuracy))
      injected.verticalAccuracy=\(String(format: "%.6f", injectedVerticalAccuracy))
      injected.altitude=\(String(format: "%.6f", injectedAltitude))
      injected.speed=\(String(format: "%.6f", injectedSpeed))
      injected.course=\(String(format: "%.6f", injectedCourse))
      injected.timestamp=\(Self.iso8601String(from: injectedTimestamp))
      received.sequence=\(received.sequence.map(String.init) ?? "UNKNOWN")
      received.latitude=\(Self.format(received.latitude))
      received.longitude=\(Self.format(received.longitude))
      received.speed=\(Self.format(received.speed))
      received.course=\(Self.format(received.course))
      received.speed_delta_mps=\(String(format: "%.6f", speedDelta))
      received.course_delta_deg=\(Self.format(courseDelta))
      received.horizontalAccuracy=\(Self.format(received.horizontalAccuracy))
      received.verticalAccuracy=\(Self.format(received.verticalAccuracy))
      received.altitude=\(Self.format(received.altitude))
      received.locationTimestamp=\(received.locationTimestamp ?? "UNKNOWN")
      received.wallClockTimestamp=\(received.wallClockTimestamp ?? "UNKNOWN")
      received.isSimulatedBySoftware=\(received.isSimulatedBySoftware ?? "UNKNOWN")
      received.isProducedByAccessory=\(received.isProducedByAccessory ?? "UNKNOWN")
      witness_authorization=\(authorizationSummary(in: witness))
      raw_metadata_summary=\(received.rawSummary)
      """
    print(summary)
    attach(summary, name: "GATE1-NO-XCODEBUILD-rich-location-witness-metadata.txt")

    RunLoop.current.run(until: Date().addingTimeInterval(5))
  }

  func testRichDriveLongLivedRunner() throws {
    guard Self.isRichDriveRunnerRun else {
      throw XCTSkip(
        "Rich Drive runner runs only when \(Self.richDriveRunnerEnvironmentKey)=1 is set.")
    }
    try requireXCUILocationSupport()

    let port = Self.richDriveRunnerPort()
    let timeout = Self.richDriveRunnerTimeoutSeconds()
    let server = RichDriveRunnerServer(port: port, timeoutSeconds: timeout)
    try server.run { sample in
      XCUIDevice.shared.location = XCUILocation(
        location: CLLocation(
          coordinate: CLLocationCoordinate2D(
            latitude: sample.latitude, longitude: sample.longitude),
          altitude: sample.altitude,
          horizontalAccuracy: sample.horizontalAccuracy,
          verticalAccuracy: sample.verticalAccuracy,
          course: sample.courseDegrees,
          courseAccuracy: 1,
          speed: sample.speedMetersPerSecond,
          speedAccuracy: 0.5,
          timestamp: sample.timestamp
        ))
    }
  }

  func testXCUILocationWitnessBackgroundSystemScopeExperiment() throws {
    try requireXCUILocationSupport()
    let witness = launchWitnessApp()
    resetAndStartWitnessRecorder(in: witness)

    let baselineLatitude = 37.333_900
    let baselineLongitude = -122.010_020
    let baselineTimestamp = Date()
    let initialSequence =
      latestRawLocationSnapshot(in: witness, prefix: "LocationWitness")?.sequence ?? 0
    XCUIDevice.shared.location = XCUILocation(
      location: richLocation(
        latitude: baselineLatitude,
        longitude: baselineLongitude,
        altitude: 100,
        course: 45,
        speed: 3,
        timestamp: baselineTimestamp
      ))
    guard
      let baseline = waitForFreshRawLocation(
        in: witness,
        prefix: "LocationWitness",
        afterSequence: initialSequence,
        latitude: baselineLatitude,
        longitude: baselineLongitude,
        timeout: 15
      )
    else {
      let latestSummary =
        latestRawLocationSummary(in: witness, prefix: "LocationWitness") ?? "MISSING"
      XCTFail(
        """
        Witness setup failed before background experiment: no foreground baseline callback.
        initial_sequence=\(initialSequence)
        latest_witness_metadata=\(latestSummary)
        authorization=\(authorizationSummary(in: witness))
        """)
      return
    }
    let baselineSequence = baseline.sequence ?? initialSequence
    let authorizationBeforeBackground = authorizationSummary(in: witness)

    XCUIDevice.shared.press(.home)

    let app = launchApp()
    openAppleLocationControls(in: app)
    let route = Self.routeCoordinates()
    let routeStartWallClock = Date()
    let routeStartUptime = ProcessInfo.processInfo.systemUptime + 1.0
    injectRouteOnFixedDeadlines(
      route, startWallClock: routeStartWallClock, startUptime: routeStartUptime)

    witness.activate()
    XCTAssertTrue(
      witness.staticTexts["LocationWitness.PersistedRawLocationsValue"].waitForExistence(
        timeout: 10))
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let persistedSnapshots = persistedWitnessSnapshots(in: witness)
    let matchingSnapshots = Self.matchingRouteSnapshots(
      in: persistedSnapshots,
      route: route,
      afterSequence: baselineSequence
    )
    var summary = Self.systemScopeSummary(
      for: matchingSnapshots,
      injected: route,
      baselineSequence: baselineSequence
    )
    if !matchingSnapshots.isEmpty {
      summary += "\n\nWITNESS-BACKGROUND matching raw CLLocation callbacks:"
      for (index, snapshot) in matchingSnapshots.enumerated() {
        summary += "\n"
        summary += [
          "witness_match index=\(index)",
          "received.sequence=\(snapshot.sequence.map(String.init) ?? "UNKNOWN")",
          "received.latitude=\(Self.format(snapshot.latitude))",
          "received.longitude=\(Self.format(snapshot.longitude))",
          "received.speed=\(Self.format(snapshot.speed))",
          "received.course=\(Self.format(snapshot.course))",
          "received.horizontalAccuracy=\(Self.format(snapshot.horizontalAccuracy))",
          "received.verticalAccuracy=\(Self.format(snapshot.verticalAccuracy))",
          "received.altitude=\(Self.format(snapshot.altitude))",
          "received.locationTimestamp=\(snapshot.locationTimestamp ?? "UNKNOWN")",
          "received.wallClockTimestamp=\(snapshot.wallClockTimestamp ?? "UNKNOWN")",
          "received.isSimulatedBySoftware=\(snapshot.isSimulatedBySoftware ?? "UNKNOWN")",
          "received.isProducedByAccessory=\(snapshot.isProducedByAccessory ?? "UNKNOWN")",
          "raw_metadata_summary=\(snapshot.rawSummary)",
        ].joined(separator: " ")
      }
    }
    summary += "\n"
    summary += """
      witness_authorization_before_background=\(authorizationBeforeBackground)
      witness_authorization_after_relaunch=\(authorizationSummary(in: witness))
      witness_background_interpretation_limit=\(authorizationBeforeBackground.contains("authorizedAlways") ? "none_detected" : "ambiguous_without_authorizedAlways")
      witness_persisted_observation_count=\(persistedSnapshots.count)
      foreground_baseline_raw_metadata=\(baseline.rawSummary)
      """

    print(summary)
    attach(summary, name: "WITNESS-BACKGROUND-system-scope-summary.txt")
  }

  func testXCUILocationRouteControl() throws {
    try requireXCUILocationSupport()
    let app = launchApp()
    openAppleLocationControls(in: app)
    startRecording(in: app)

    var baselineSequence = latestRawLocationSnapshot(in: app)?.sequence ?? 0
    let start = Date()
    var receivedSnapshots: [ReceivedRawLocationSnapshot] = []
    var routeLogLines: [String] = [
      "Received raw CLLocation route metadata after XCUIDevice.shared.location updates:"
    ]
    for (index, coordinate) in Self.routeCoordinates().enumerated() {
      let pointStart = Date()
      let injectedAltitude = 120 + Double(index)
      let injectedTimestamp = start.addingTimeInterval(Double(index) * 0.5)
      XCUIDevice.shared.location = XCUILocation(
        location: richLocation(
          latitude: coordinate.latitude,
          longitude: coordinate.longitude,
          altitude: injectedAltitude,
          course: coordinate.course,
          speed: 15.646,
          timestamp: injectedTimestamp
        ))

      guard
        let received = waitForFreshRawLocation(
          in: app,
          afterSequence: baselineSequence,
          latitude: coordinate.latitude,
          longitude: coordinate.longitude,
          timeout: 8
        )
      else {
        let latestSummary = latestRawLocationSummary(in: app) ?? "MISSING"
        XCTFail(
          """
          Timed out waiting for fresh CLLocation callback matching injected route point.
          route_index=\(index)
          baseline_sequence=\(baselineSequence)
          injected_latitude=\(String(format: "%.8f", coordinate.latitude))
          injected_longitude=\(String(format: "%.8f", coordinate.longitude))
          injected_speed=15.646000
          injected_course=\(String(format: "%.6f", coordinate.course))
          injected_altitude=\(String(format: "%.6f", injectedAltitude))
          injected_timestamp=\(Self.iso8601String(from: injectedTimestamp))
          latest_raw_metadata=\(latestSummary)
          """)
        cleanupRecorderIfPossible(in: app)
        return
      }

      receivedSnapshots.append(received)
      baselineSequence = received.sequence ?? baselineSequence
      let line = Self.routePointLogLine(
        index: index,
        injected: coordinate,
        injectedAltitude: injectedAltitude,
        injectedTimestamp: injectedTimestamp,
        received: received
      )
      routeLogLines.append(line)
      print(line)

      let elapsed = Date().timeIntervalSince(pointStart)
      if elapsed < 0.5 {
        Thread.sleep(forTimeInterval: 0.5 - elapsed)
      }
    }

    routeLogLines.append("")
    routeLogLines.append(
      Self.routeSummary(for: receivedSnapshots, injected: Self.routeCoordinates()))
    let summary = routeLogLines.joined(separator: "\n")
    print(summary)
    let attachment = XCTAttachment(string: summary)
    attachment.name = "APPLE-XCUILOCATION-ROUTE-received-metadata.txt"
    attachment.lifetime = .keepAlways
    add(attachment)

    cleanupRecorderIfPossible(in: app)
  }

  private func launchApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["--apple-location-control-ui-test"]
    app.launch()
    return app
  }

  private func launchWitnessApp() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: witnessBundleIdentifier)
    app.launch()
    return app
  }

  private func resetAndStartWitnessRecorder(in app: XCUIApplication) {
    XCTAssertTrue(app.buttons["LocationWitness.Reset"].waitForExistence(timeout: 10))
    app.buttons["LocationWitness.Reset"].tap()
    app.buttons["LocationWitness.Start"].tap()
    allowLocationIfPrompted(in: app)
    allowAlwaysLocationUpgradeIfPrompted()
    XCTAssertTrue(
      app.staticTexts["LocationWitness.LatestRawLocationMetadataValue"].waitForExistence(timeout: 5)
    )
  }

  private func assertControlsDoNotOverlap(
    _ controls: [XCUIElement],
    file: StaticString = #fileID,
    line: UInt = #line
  ) {
    for index in controls.indices {
      XCTAssertTrue(controls[index].waitForExistence(timeout: 5), file: file, line: line)
      for otherIndex in controls.indices where otherIndex > index {
        XCTAssertFalse(
          controls[index].frame.intersects(controls[otherIndex].frame),
          "\(controls[index].identifier) overlaps \(controls[otherIndex].identifier)",
          file: file,
          line: line
        )
      }
    }
  }

  private func waitForShareSheet(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let sharingViewService = XCUIApplication(bundleIdentifier: "com.apple.SharingViewService")
    let uiKitActivityService = XCUIApplication(bundleIdentifier: "com.apple.UIKit.activity")
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if app.sheets.firstMatch.exists
        || app.navigationBars["Share"].exists
        || app.buttons["Copy"].exists
        || sharingViewService.state == .runningForeground
        || sharingViewService.sheets.firstMatch.exists
        || sharingViewService.navigationBars["Share"].exists
        || sharingViewService.buttons["Copy"].exists
        || sharingViewService.staticTexts["AirDrop"].exists
        || sharingViewService.staticTexts["Messages"].exists
        || uiKitActivityService.state == .runningForeground
        || uiKitActivityService.sheets.firstMatch.exists
        || uiKitActivityService.navigationBars["Share"].exists
        || uiKitActivityService.buttons["Copy"].exists
        || uiKitActivityService.staticTexts["AirDrop"].exists
        || uiKitActivityService.staticTexts["Messages"].exists
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return false
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

  private func cleanupRecorderIfPossible(in app: XCUIApplication) {
    let stopButton = app.buttons["AppleLocationControls.StopRecording"]
    if stopButton.waitForExistence(timeout: 2), stopButton.isEnabled {
      stopButton.tap()
      return
    }

    let status =
      app.staticTexts["AppleLocationControls.Status"].exists
      ? app.staticTexts["AppleLocationControls.Status"].label
      : "UNKNOWN"
    let startState = buttonState(app.buttons["AppleLocationControls.StartRecording"])
    let stopState = buttonState(stopButton)
    let copyState = buttonState(app.buttons["AppleLocationControls.CopyJSONL"])
    print(
      """
      Recorder cleanup skipped; StopRecording was not tappable.
      start_button=\(startState)
      stop_button=\(stopState)
      copy_jsonl_button=\(copyState)
      status=\(status)
      """)
  }

  private func latestRawLocationSummary(in app: XCUIApplication) -> String? {
    latestRawLocationSummary(in: app, prefix: "AppleLocationControls")
  }

  private func latestRawLocationSummary(in app: XCUIApplication, prefix: String) -> String? {
    let element = app.staticTexts["\(prefix).LatestRawLocationMetadataValue"]
    guard element.waitForExistence(timeout: 2) else { return nil }
    return element.label
  }

  private func latestRawLocationSnapshot(in app: XCUIApplication) -> ReceivedRawLocationSnapshot? {
    latestRawLocationSummary(in: app).flatMap(ReceivedRawLocationSnapshot.init(summary:))
  }

  private func latestRawLocationSnapshot(in app: XCUIApplication, prefix: String)
    -> ReceivedRawLocationSnapshot?
  {
    latestRawLocationSummary(in: app, prefix: prefix).flatMap(
      ReceivedRawLocationSnapshot.init(summary:))
  }

  private func persistedWitnessSnapshots(in app: XCUIApplication) -> [ReceivedRawLocationSnapshot] {
    let element = app.staticTexts["LocationWitness.PersistedRawLocationsValue"]
    guard element.waitForExistence(timeout: 5) else { return [] }
    return element.label
      .split(separator: "|")
      .compactMap { ReceivedRawLocationSnapshot(summary: String($0)) }
  }

  private func authorizationSummary(in app: XCUIApplication) -> String {
    let element = app.staticTexts["LocationWitness.AuthorizationValue"]
    guard element.waitForExistence(timeout: 2) else { return "UNKNOWN" }
    return element.label
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

  private func allowAlwaysLocationUpgradeIfPrompted() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let alwaysAllow = springboard.buttons["Always Allow"]
    if alwaysAllow.waitForExistence(timeout: 2) {
      alwaysAllow.tap()
      return
    }
    let changeToAlways = springboard.buttons["Change to Always Allow"]
    if changeToAlways.waitForExistence(timeout: 1) {
      changeToAlways.tap()
    }
  }

  private func waitForRawLocationCount(in app: XCUIApplication, minimum: Int, timeout: TimeInterval)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let text = app.staticTexts["AppleLocationControls.RawLocationValue"].label
      if let value = Int(text.replacingOccurrences(of: "raw_locations=", with: "")),
        value >= minimum
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return false
  }

  private func waitForFreshRawLocation(
    in app: XCUIApplication,
    afterSequence baselineSequence: Int,
    latitude: Double,
    longitude: Double,
    timeout: TimeInterval
  ) -> ReceivedRawLocationSnapshot? {
    waitForFreshRawLocation(
      in: app,
      prefix: "AppleLocationControls",
      afterSequence: baselineSequence,
      latitude: latitude,
      longitude: longitude,
      timeout: timeout
    )
  }

  private func waitForFreshRawLocation(
    in app: XCUIApplication,
    prefix: String,
    afterSequence baselineSequence: Int,
    latitude: Double,
    longitude: Double,
    timeout: TimeInterval
  ) -> ReceivedRawLocationSnapshot? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let snapshot = latestRawLocationSnapshot(in: app, prefix: prefix),
        let sequence = snapshot.sequence,
        sequence > baselineSequence,
        snapshot.matches(latitude: latitude, longitude: longitude)
      {
        return snapshot
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return nil
  }

  private func injectRouteOnFixedDeadlines(
    _ route: [(latitude: Double, longitude: Double, course: Double)],
    startWallClock: Date,
    startUptime: TimeInterval
  ) {
    for (index, coordinate) in route.enumerated() {
      let targetUptime = startUptime + Double(index) * 0.5
      while ProcessInfo.processInfo.systemUptime < targetUptime {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      let injectedTimestamp = startWallClock.addingTimeInterval(Double(index) * 0.5)
      XCUIDevice.shared.location = XCUILocation(
        location: richLocation(
          latitude: coordinate.latitude,
          longitude: coordinate.longitude,
          altitude: 120 + Double(index),
          course: coordinate.course,
          speed: 15.646,
          timestamp: injectedTimestamp
        ))
      print(
        [
          "witness_scope_injected_route_point index=\(index)",
          "latitude=\(String(format: "%.8f", coordinate.latitude))",
          "longitude=\(String(format: "%.8f", coordinate.longitude))",
          "speed=15.646000",
          "course=\(String(format: "%.6f", coordinate.course))",
          "altitude=\(String(format: "%.6f", 120 + Double(index)))",
          "timestamp=\(Self.iso8601String(from: injectedTimestamp))",
        ].joined(separator: " "))
    }
  }

  private func attach(_ text: String, name: String) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
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

  private static func routeCoordinates() -> [(latitude: Double, longitude: Double, course: Double)]
  {
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
      (37.335195, -122.007918, 180),
    ]
  }

  private static func format(_ value: Double?) -> String {
    guard let value else { return "UNKNOWN" }
    return String(format: "%.6f", value)
  }

  private static func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func buttonState(_ button: XCUIElement) -> String {
    guard button.exists else { return "absent" }
    return button.isEnabled ? "enabled" : "disabled"
  }

  private static func routePointLogLine(
    index: Int,
    injected: (latitude: Double, longitude: Double, course: Double),
    injectedAltitude: Double,
    injectedTimestamp: Date,
    received: ReceivedRawLocationSnapshot
  ) -> String {
    [
      "route_point index=\(index)",
      "injected.latitude=\(String(format: "%.8f", injected.latitude))",
      "injected.longitude=\(String(format: "%.8f", injected.longitude))",
      "injected.speed=15.646000",
      "injected.course=\(String(format: "%.6f", injected.course))",
      "injected.altitude=\(String(format: "%.6f", injectedAltitude))",
      "injected.timestamp=\(iso8601String(from: injectedTimestamp))",
      "received.sequence=\(received.sequence.map(String.init) ?? "UNKNOWN")",
      "received.latitude=\(format(received.latitude))",
      "received.longitude=\(format(received.longitude))",
      "received.speed=\(format(received.speed))",
      "received.course=\(format(received.course))",
      "received.horizontalAccuracy=\(format(received.horizontalAccuracy))",
      "received.verticalAccuracy=\(format(received.verticalAccuracy))",
      "received.altitude=\(format(received.altitude))",
      "received.locationTimestamp=\(received.locationTimestamp ?? "UNKNOWN")",
      "received.wallClockTimestamp=\(received.wallClockTimestamp ?? "UNKNOWN")",
      "received.isSimulatedBySoftware=\(received.isSimulatedBySoftware ?? "UNKNOWN")",
      "received.isProducedByAccessory=\(received.isProducedByAccessory ?? "UNKNOWN")",
    ].joined(separator: " ")
  }

  private static func routeSummary(
    for received: [ReceivedRawLocationSnapshot],
    injected: [(latitude: Double, longitude: Double, course: Double)]
  ) -> String {
    let speeds = received.compactMap(\.speed)
    let courses = received.compactMap(\.course)
    let speedValidCount = speeds.filter { $0 >= 0 && $0.isFinite }.count
    let courseValidCount = courses.filter { $0 >= 0 && $0.isFinite }.count
    let speedMatches = received.allSatisfy { snapshot in
      guard let speed = snapshot.speed, speed.isFinite, speed >= 0 else { return false }
      return abs(speed - 15.646) <= 0.1
    }
    let courseFollows = zip(received, injected).allSatisfy { snapshot, injectedPoint in
      guard let course = snapshot.course, course.isFinite, course >= 0 else { return false }
      return angularDifferenceDegrees(course, injectedPoint.course) <= 1
    }
    let callbackIntervals = callbackIntervalsSeconds(for: received)
    return """
      XCUIDevice route received metadata summary:
      injected_point_count=\(injected.count)
      received_matching_point_count=\(received.count)
      speed_valid_count=\(speedValidCount)
      speed_valid_percent=\(percent(speedValidCount, received.count))
      course_valid_count=\(courseValidCount)
      course_valid_percent=\(percent(courseValidCount, received.count))
      received_speed_min_mps=\(format(speeds.min()))
      received_speed_median_mps=\(format(median(speeds)))
      received_speed_max_mps=\(format(speeds.max()))
      received_speed_matches_15_646_mps_within_0_1=\(speedMatches)
      received_course_follows_injected_within_1_deg=\(courseFollows)
      callback_cadence_count=\(callbackIntervals.count)
      callback_cadence_min_s=\(format(callbackIntervals.min()))
      callback_cadence_median_s=\(format(median(callbackIntervals)))
      callback_cadence_max_s=\(format(callbackIntervals.max()))
      """
  }

  private static func matchingRouteSnapshots(
    in snapshots: [ReceivedRawLocationSnapshot],
    route: [(latitude: Double, longitude: Double, course: Double)],
    afterSequence baselineSequence: Int
  ) -> [ReceivedRawLocationSnapshot] {
    let candidates = snapshots.filter { ($0.sequence ?? 0) > baselineSequence }
    var cursor = candidates.startIndex
    var matches: [ReceivedRawLocationSnapshot] = []
    for routePoint in route {
      guard cursor < candidates.endIndex,
        let matchIndex = candidates[cursor...].firstIndex(where: {
          coordinatesMatch($0, latitude: routePoint.latitude, longitude: routePoint.longitude)
        })
      else {
        continue
      }
      matches.append(candidates[matchIndex])
      cursor = candidates.index(after: matchIndex)
    }
    return matches
  }

  private static func systemScopeSummary(
    for received: [ReceivedRawLocationSnapshot],
    injected: [(latitude: Double, longitude: Double, course: Double)],
    baselineSequence: Int
  ) -> String {
    let speeds = received.compactMap(\.speed)
    let courses = received.compactMap(\.course)
    let speedValidCount = speeds.filter { $0 >= 0 && $0.isFinite }.count
    let courseValidCount = courses.filter { $0 >= 0 && $0.isFinite }.count
    let classification = systemScopeClassification(for: received, injected: injected)
    let callbackIntervals = callbackIntervalsSeconds(for: received)
    return """
      WITNESS-BACKGROUND XCUIDevice system-scope summary:
      classification_legend=A:no_matching_route_coordinates B:coordinates_only_or_invalid_metadata C:coordinates_and_rich_metadata
      baseline_sequence=\(baselineSequence)
      injected_point_count=\(injected.count)
      witness_matching_point_count=\(received.count)
      speed_valid_count=\(speedValidCount)
      speed_valid_percent=\(percent(speedValidCount, received.count))
      course_valid_count=\(courseValidCount)
      course_valid_percent=\(percent(courseValidCount, received.count))
      received_speed_min_mps=\(format(speeds.min()))
      received_speed_median_mps=\(format(median(speeds)))
      received_speed_max_mps=\(format(speeds.max()))
      received_speed_matches_15_646_mps_within_0_1=\(receivedSpeedsMatchInjected(received))
      received_course_follows_injected_within_1_deg=\(receivedCoursesMatchInjected(received, injected: injected))
      first_matching_locationTimestamp=\(received.first?.locationTimestamp ?? "UNKNOWN")
      last_matching_locationTimestamp=\(received.last?.locationTimestamp ?? "UNKNOWN")
      first_matching_wallClockTimestamp=\(received.first?.wallClockTimestamp ?? "UNKNOWN")
      last_matching_wallClockTimestamp=\(received.last?.wallClockTimestamp ?? "UNKNOWN")
      callback_cadence_count=\(callbackIntervals.count)
      callback_cadence_min_s=\(format(callbackIntervals.min()))
      callback_cadence_median_s=\(format(median(callbackIntervals)))
      callback_cadence_max_s=\(format(callbackIntervals.max()))
      final_classification=\(classification)
      """
  }

  private static func systemScopeClassification(
    for received: [ReceivedRawLocationSnapshot],
    injected: [(latitude: Double, longitude: Double, course: Double)]
  ) -> String {
    guard !received.isEmpty else { return "A" }
    if receivedSpeedsMatchInjected(received)
      && receivedCoursesMatchInjected(received, injected: injected)
    {
      return "C"
    }
    return "B"
  }

  private static func receivedSpeedsMatchInjected(_ received: [ReceivedRawLocationSnapshot]) -> Bool
  {
    guard !received.isEmpty else { return false }
    return received.allSatisfy { snapshot in
      guard let speed = snapshot.speed, speed.isFinite, speed >= 0 else { return false }
      return abs(speed - 15.646) <= 0.1
    }
  }

  private static func receivedCoursesMatchInjected(
    _ received: [ReceivedRawLocationSnapshot],
    injected: [(latitude: Double, longitude: Double, course: Double)]
  ) -> Bool {
    guard !received.isEmpty else { return false }
    return received.allSatisfy { snapshot in
      guard let receivedCourse = snapshot.course,
        receivedCourse.isFinite,
        receivedCourse >= 0,
        let expectedCourse = injected.first(where: {
          coordinatesMatch(snapshot, latitude: $0.latitude, longitude: $0.longitude)
        })?.course
      else {
        return false
      }
      return angularDifferenceDegrees(receivedCourse, expectedCourse) <= 1
    }
  }

  private static func coordinatesMatch(
    _ snapshot: ReceivedRawLocationSnapshot,
    latitude expectedLatitude: Double,
    longitude expectedLongitude: Double
  ) -> Bool {
    guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return false }
    return abs(latitude - expectedLatitude) <= 0.00002
      && abs(longitude - expectedLongitude) <= 0.00002
  }

  private static func percent(_ count: Int, _ total: Int) -> String {
    guard total > 0 else { return "UNKNOWN" }
    return String(format: "%.1f", Double(count) / Double(total) * 100)
  }

  private static func median(_ values: [Double]) -> Double? {
    let sorted = values.filter { $0.isFinite }.sorted()
    guard !sorted.isEmpty else { return nil }
    if sorted.count % 2 == 1 {
      return sorted[sorted.count / 2]
    }
    let upper = sorted.count / 2
    return (sorted[upper - 1] + sorted[upper]) / 2
  }

  private static func angularDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
    let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
    return min(raw, 360 - raw)
  }

  private static func callbackIntervalsSeconds(for received: [ReceivedRawLocationSnapshot])
    -> [Double]
  {
    let dates = received.compactMap { snapshot in
      snapshot.wallClockTimestamp.flatMap(Self.date(from:))
    }
    guard dates.count > 1 else { return [] }
    return zip(dates, dates.dropFirst()).map { previous, current in
      current.timeIntervalSince(previous)
    }
  }

  private static func date(from string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
  }

  private static var isGate1RichLocationOnlyRun: Bool {
    let value = ProcessInfo.processInfo.environment[gate1RichLocationOnlyEnvironmentKey]
    return value == "1" || value?.lowercased() == "true"
  }

  private static var isRichDriveRunnerRun: Bool {
    let value = ProcessInfo.processInfo.environment[richDriveRunnerEnvironmentKey]
    return value == "1" || value?.lowercased() == "true"
  }

  private static func richDriveRunnerPort() -> UInt16 {
    let value = ProcessInfo.processInfo.environment["IOSSIM_RICH_DRIVE_PORT"].flatMap(UInt16.init)
    return value ?? 31_337
  }

  private static func richDriveRunnerTimeoutSeconds() -> TimeInterval {
    let value = ProcessInfo.processInfo.environment["IOSSIM_RICH_DRIVE_TIMEOUT_SECONDS"].flatMap(
      TimeInterval.init)
    return value ?? 3_600
  }
}

private final class RichDriveRunnerServer {
  private let port: UInt16
  private let timeoutSeconds: TimeInterval
  private var readBuffer = Data()
  private var activeSessionID: String?

  init(port: UInt16, timeoutSeconds: TimeInterval) {
    self.port = port
    self.timeoutSeconds = timeoutSeconds
  }

  func run(applyLocation: (RichDriveRunnerSample) throws -> Void) throws {
    let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
      throw NSError(
        domain: "RichDriveRunnerServer", code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "socket failed: \(errnoDescription())"])
    }
    defer { Darwin.close(serverFD) }

    var reuse: Int32 = 1
    Darwin.setsockopt(
      serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
      }
    }
    guard bindResult == 0 else {
      throw NSError(
        domain: "RichDriveRunnerServer", code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "bind failed: \(errnoDescription())"])
    }
    guard Darwin.listen(serverFD, 1) == 0 else {
      throw NSError(
        domain: "RichDriveRunnerServer", code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "listen failed: \(errnoDescription())"])
    }

    print("RICH_DRIVE_RUNNER_READY port=\(port)")
    let clientFD = try acceptClient(serverFD: serverFD)
    defer { Darwin.close(clientFD) }
    print("RICH_DRIVE_RUNNER_CLIENT_CONNECTED")

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      var descriptor = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, 250)
      if ready < 0 {
        throw NSError(
          domain: "RichDriveRunnerServer", code: Int(errno),
          userInfo: [NSLocalizedDescriptionKey: "poll failed: \(errnoDescription())"])
      }
      if ready == 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        continue
      }

      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = Darwin.recv(clientFD, &buffer, buffer.count, 0)
      if count <= 0 {
        print("RICH_DRIVE_RUNNER_CLIENT_DISCONNECTED")
        return
      }
      readBuffer.append(buffer, count: count)
      while let line = nextLine() {
        let message = try JSONDecoder().decode(RichDriveRunnerMessage.self, from: line)
        switch message.type {
        case .startSession, .ping:
          if message.type == .startSession {
            activeSessionID = message.sessionID
          }
          try writeAck(sequence: message.sequence, fd: clientFD)
        case .setLocation:
          guard acceptsSession(message.sessionID) else {
            try writeAck(
              sequence: message.sequence,
              fd: clientFD,
              status: "ERROR",
              message: "stale session")
            continue
          }
          guard let sample = message.sample else {
            try writeAck(
              sequence: message.sequence, fd: clientFD, status: "ERROR", message: "missing sample")
            continue
          }
          try applyLocation(sample)
          print(
            [
              "RICH_DRIVE_SET_LOCATION",
              "sequence=\(message.sequence)",
              "latitude=\(String(format: "%.8f", sample.latitude))",
              "longitude=\(String(format: "%.8f", sample.longitude))",
              "speed=\(String(format: "%.6f", sample.speedMetersPerSecond))",
              "course=\(String(format: "%.6f", sample.courseDegrees))",
              "altitude=\(String(format: "%.6f", sample.altitude))",
            ].joined(separator: " "))
          try writeAck(sequence: message.sequence, fd: clientFD)
        case .stopSession:
          guard acceptsSession(message.sessionID) else {
            try writeAck(
              sequence: message.sequence,
              fd: clientFD,
              status: "ERROR",
              message: "stale session")
            continue
          }
          activeSessionID = nil
          try writeAck(sequence: message.sequence, fd: clientFD)
          print("RICH_DRIVE_RUNNER_STOPPED")
          return
        }
      }
    }

    print("RICH_DRIVE_RUNNER_TIMEOUT")
  }

  private func acceptsSession(_ sessionID: String?) -> Bool {
    guard let activeSessionID else { return true }
    return sessionID == activeSessionID
  }

  private func acceptClient(serverFD: Int32) throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      var descriptor = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, 250)
      if ready < 0 {
        throw NSError(
          domain: "RichDriveRunnerServer", code: Int(errno),
          userInfo: [NSLocalizedDescriptionKey: "accept poll failed: \(errnoDescription())"])
      }
      if ready == 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        continue
      }
      let fd = Darwin.accept(serverFD, nil, nil)
      if fd >= 0 {
        return fd
      }
    }
    throw NSError(
      domain: "RichDriveRunnerServer", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "timed out waiting for Rich Drive IPC client"])
  }

  private func writeAck(sequence: Int, fd: Int32, status: String = "OK", message: String? = nil)
    throws
  {
    let ack = RichDriveRunnerAck(type: "ACK", sequence: sequence, status: status, message: message)
    var data = try JSONEncoder().encode(ack)
    data.append(0x0A)
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var sent = 0
      while sent < data.count {
        let result = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
        if result <= 0 {
          throw NSError(
            domain: "RichDriveRunnerServer", code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "ack send failed: \(errnoDescription())"])
        }
        sent += result
      }
    }
  }

  private func nextLine() -> Data? {
    guard let newline = readBuffer.firstIndex(of: 0x0A) else { return nil }
    let line = readBuffer[..<newline]
    readBuffer.removeSubrange(...newline)
    return Data(line)
  }

  private func errnoDescription() -> String {
    String(cString: strerror(errno))
  }
}

private enum RichDriveRunnerMessageType: String, Codable {
  case startSession = "START_SESSION"
  case setLocation = "SET_LOCATION"
  case stopSession = "STOP_SESSION"
  case ping = "PING"
}

private struct RichDriveRunnerMessage: Decodable {
  let type: RichDriveRunnerMessageType
  let sequence: Int
  let sessionID: String?
  let sample: RichDriveRunnerSample?
}

private struct RichDriveRunnerSample: Decodable {
  let latitude: Double
  let longitude: Double
  let speedMetersPerSecond: Double
  let courseDegrees: Double
  let altitude: Double
  let horizontalAccuracy: Double
  let verticalAccuracy: Double
  let timestamp: Date
}

private struct RichDriveRunnerAck: Encodable {
  let type: String
  let sequence: Int
  let status: String
  let message: String?
}

private struct ReceivedRawLocationSnapshot {
  let rawSummary: String
  let sequence: Int?
  let latitude: Double?
  let longitude: Double?
  let speed: Double?
  let course: Double?
  let horizontalAccuracy: Double?
  let verticalAccuracy: Double?
  let altitude: Double?
  let locationTimestamp: String?
  let wallClockTimestamp: String?
  let isSimulatedBySoftware: String?
  let isProducedByAccessory: String?

  init?(summary: String) {
    let fields = Dictionary(
      uniqueKeysWithValues: summary.split(separator: " ").compactMap { token -> (String, String)? in
        guard let separator = token.firstIndex(of: "=") else { return nil }
        let key = String(token[..<separator])
        let value = String(token[token.index(after: separator)...])
        return (key, value)
      })
    guard !fields.isEmpty else { return nil }
    self.rawSummary = summary
    self.sequence = Self.intValue(fields["sequence"])
    self.latitude = Self.doubleValue(fields["latitude"])
    self.longitude = Self.doubleValue(fields["longitude"])
    self.speed = Self.doubleValue(fields["speed"])
    self.course = Self.doubleValue(fields["course"])
    self.horizontalAccuracy = Self.doubleValue(fields["horizontalAccuracy"])
    self.verticalAccuracy = Self.doubleValue(fields["verticalAccuracy"])
    self.altitude = Self.doubleValue(fields["altitude"])
    self.locationTimestamp = Self.stringValue(fields["locationTimestamp"])
    self.wallClockTimestamp = Self.stringValue(fields["wallClockTimestamp"])
    self.isSimulatedBySoftware = Self.stringValue(fields["isSimulatedBySoftware"])
    self.isProducedByAccessory = Self.stringValue(fields["isProducedByAccessory"])
  }

  func matches(latitude expectedLatitude: Double, longitude expectedLongitude: Double) -> Bool {
    guard let latitude, let longitude else { return false }
    return abs(latitude - expectedLatitude) <= 0.0001
      && abs(longitude - expectedLongitude) <= 0.0001
  }

  private static func intValue(_ value: String?) -> Int? {
    guard let value, value != "UNKNOWN" else { return nil }
    return Int(value)
  }

  private static func doubleValue(_ value: String?) -> Double? {
    guard let value, value != "UNKNOWN" else { return nil }
    return Double(value)
  }

  private static func stringValue(_ value: String?) -> String? {
    guard let value, value != "UNKNOWN" else { return nil }
    return value
  }
}
