import CoreLocation
import Foundation

public actor DriveDiagnostics {
    private let recorder: SessionDiagnosticRecorder
    private var sessionID: String = "NO_DRIVE_SESSION"
    private var writerID: String = "NO_WRITER"
    private var route: RouteResampler?
    private var lastObservedRouteDistance: CLLocationDistance?
    private var latestExpectedRouteDistance: CLLocationDistance?
    private var latestExpectedCoordinate: SimulatedCoordinate?

    public init(recorder: SessionDiagnosticRecorder = .shared) {
        self.recorder = recorder
    }

    public func start(sessionID: UUID, writerID: String, route: RouteResampler) async {
        self.sessionID = sessionID.uuidString
        self.writerID = writerID
        self.route = route
        lastObservedRouteDistance = nil
        latestExpectedRouteDistance = nil
        latestExpectedCoordinate = nil
        _ = await recorder.startSession(prefix: "DRIVE")
        await recorder.record(
            category: "DRIVE",
            component: "DriveSession",
            previousState: nil,
            newState: "started",
            message: "experimental drive session started",
            metadata: [
                "drive_session_id": self.sessionID,
                "writer_id": writerID,
                "route_distance_m": String(format: "%.1f", route.totalDistanceMeters)
            ]
        )
    }

    public func recordRequestedUpdate(
        sequenceNumber: Int,
        tickNumber: Int,
        monotonicElapsedTime: TimeInterval,
        connectionGeneration: Int,
        expectedRouteDistanceMeters: CLLocationDistance,
        expectedCoordinate: CLLocationCoordinate2D,
        requestedCoordinate: CLLocationCoordinate2D,
        calculatedRouteSpeedMetersPerSecond: Double,
        observed: LocationObservation?,
        applicationLifecycleState: String,
        backgroundSessionActive: Bool
    ) async {
        latestExpectedRouteDistance = expectedRouteDistanceMeters
        latestExpectedCoordinate = SimulatedCoordinate(expectedCoordinate)
        let observedProjection = observed.flatMap { observation -> RouteProjection? in
            route?.nearestProjection(to: CLLocationCoordinate2D(latitude: observation.latitude, longitude: observation.longitude))
        }
        var metadata: [String: String] = [
            "drive_session_id": sessionID,
            "writer_id": writerID,
            "sequence_number": "\(sequenceNumber)",
            "scheduler_tick_number": "\(tickNumber)",
            "monotonic_elapsed_time": String(format: "%.3f", monotonicElapsedTime),
            "connection_generation": "\(connectionGeneration)",
            "expected_route_distance_m": String(format: "%.2f", expectedRouteDistanceMeters),
            "expected_latitude": String(format: "%.6f", expectedCoordinate.latitude),
            "expected_longitude": String(format: "%.6f", expectedCoordinate.longitude),
            "requested_latitude": String(format: "%.6f", requestedCoordinate.latitude),
            "requested_longitude": String(format: "%.6f", requestedCoordinate.longitude),
            "calculated_route_speed_mps": String(format: "%.3f", calculatedRouteSpeedMetersPerSecond),
            "application_lifecycle_state": applicationLifecycleState,
            "background_session_active": "\(backgroundSessionActive)"
        ]
        appendObservationMetadata(observed, projection: observedProjection, metadata: &metadata)
        await recorder.record(
            category: "DRIVE_LOCATION_UPDATE",
            component: "DriveScheduler",
            previousState: nil,
            newState: "requested",
            message: "drive location update requested",
            metadata: metadata
        )
    }

    public func recordObservation(
        _ observation: LocationObservation,
        applicationLifecycleState: String,
        backgroundSessionActive: Bool,
        connectionGeneration: Int
    ) async {
        let coordinate = CLLocationCoordinate2D(latitude: observation.latitude, longitude: observation.longitude)
        let projection = route?.nearestProjection(to: coordinate)
        var metadata: [String: String] = [
            "drive_session_id": sessionID,
            "writer_id": writerID,
            "observed_latitude": String(format: "%.6f", observation.latitude),
            "observed_longitude": String(format: "%.6f", observation.longitude),
            "connection_generation": "\(connectionGeneration)",
            "application_lifecycle_state": applicationLifecycleState,
            "background_session_active": "\(backgroundSessionActive)"
        ]
        appendObservationMetadata(observation, projection: projection, metadata: &metadata)
        if let expected = latestExpectedRouteDistance {
            metadata["expected_route_distance_m"] = String(format: "%.2f", expected)
        }
        if let expectedCoordinate = latestExpectedCoordinate {
            metadata["expected_latitude"] = String(format: "%.6f", expectedCoordinate.latitude)
            metadata["expected_longitude"] = String(format: "%.6f", expectedCoordinate.longitude)
        }
        await recorder.record(
            category: "DRIVE_CORELOCATION",
            component: "CoreLocation",
            previousState: nil,
            newState: observation.classification,
            message: "drive core location observation",
            metadata: metadata
        )
        await detectSnapBackIfNeeded(
            projection: projection,
            observation: observation,
            applicationLifecycleState: applicationLifecycleState,
            backgroundSessionActive: backgroundSessionActive,
            connectionGeneration: connectionGeneration
        )
    }

    public func recordState(_ state: String, message: String, metadata: [String: String] = [:]) async {
        await recorder.record(
            category: "DRIVE_STATE",
            component: "DriveSession",
            previousState: nil,
            newState: state,
            message: message,
            metadata: metadata.merging([
                "drive_session_id": sessionID,
                "writer_id": writerID
            ]) { _, new in new }
        )
    }

    public func exportURLs() async -> [URL] {
        await recorder.exportURLs()
    }

    private func detectSnapBackIfNeeded(
        projection: RouteProjection?,
        observation: LocationObservation,
        applicationLifecycleState: String,
        backgroundSessionActive: Bool,
        connectionGeneration: Int
    ) async {
        guard let projection else { return }
        defer {
            lastObservedRouteDistance = projection.distanceAlongRouteMeters
        }
        guard let previous = lastObservedRouteDistance else { return }
        let regression = previous - projection.distanceAlongRouteMeters
        guard regression > 50 else { return }

        let likelyRealGPS = observation.isSimulatedBySoftware == false
        await recorder.record(
            category: "POSSIBLE_SNAP_BACK",
            component: "DriveDiagnostics",
            previousState: nil,
            newState: likelyRealGPS ? "real_gps_returned" : "stale_or_regressed_simulation",
            errorCode: "POSSIBLE_SNAP_BACK",
            message: "observed route progress decreased while driving",
            metadata: [
                "drive_session_id": sessionID,
                "writer_id": writerID,
                "previous_route_progress_m": String(format: "%.2f", previous),
                "current_route_progress_m": String(format: "%.2f", projection.distanceAlongRouteMeters),
                "expected_route_progress_m": String(format: "%.2f", latestExpectedRouteDistance ?? -1),
                "connection_generation": "\(connectionGeneration)",
                "application_lifecycle_state": applicationLifecycleState,
                "background_session_active": "\(backgroundSessionActive)",
                "is_simulated_by_software": String(describing: observation.isSimulatedBySoftware)
            ]
        )
    }

    private func appendObservationMetadata(
        _ observation: LocationObservation?,
        projection: RouteProjection?,
        metadata: inout [String: String]
    ) {
        guard let observation else {
            metadata["observed_latitude"] = "UNKNOWN"
            metadata["observed_longitude"] = "UNKNOWN"
            metadata["observed_nearest_route_distance_m"] = "UNKNOWN"
            return
        }
        metadata["observed_latitude"] = String(format: "%.6f", observation.latitude)
        metadata["observed_longitude"] = String(format: "%.6f", observation.longitude)
        metadata["horizontal_accuracy_m"] = String(format: "%.1f", observation.horizontalAccuracy)
        metadata["vertical_accuracy_m"] = String(format: "%.1f", observation.verticalAccuracy)
        metadata["cllocation_speed_mps"] = observation.speed.map { String(format: "%.3f", $0) } ?? "UNKNOWN"
        metadata["cllocation_speed_accuracy_mps"] = observation.speedAccuracy.map { String(format: "%.3f", $0) } ?? "UNKNOWN"
        metadata["cllocation_course_deg"] = observation.course.map { String(format: "%.3f", $0) } ?? "UNKNOWN"
        metadata["cllocation_course_accuracy_deg"] = observation.courseAccuracy.map { String(format: "%.3f", $0) } ?? "UNKNOWN"
        metadata["source_is_simulated_by_software"] = String(describing: observation.isSimulatedBySoftware)
        metadata["source_is_produced_by_accessory"] = String(describing: observation.isProducedByAccessory)
        if let projection {
            metadata["observed_nearest_route_distance_m"] = String(format: "%.2f", projection.distanceAlongRouteMeters)
            metadata["observed_distance_from_route_m"] = String(format: "%.2f", projection.distanceFromRouteMeters)
        }
    }
}

