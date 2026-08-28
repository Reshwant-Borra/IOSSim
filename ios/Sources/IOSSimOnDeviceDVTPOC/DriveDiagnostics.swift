import CoreLocation
import Foundation

public struct DriveLiveMetrics: Codable, Equatable, Sendable {
    public let lifecycleState: String
    public let lastSchedulerIntervalMs: Double?
    public let lastSchedulerJitterMs: Double?
    public let lastDVTSetLatencyMs: Double?
    public let lastCoreLocationLatencyMs: Double?
    public let selectedSpeedMps: Double?
    public let lastCLLocationSpeedMps: Double?
    public let lastObservedGeometricSpeedMps: Double?
    public let connectionGeneration: Int
    public let schedulerStallCount: Int
    public let dvtSetStallCount: Int
    public let coreLocationObservationStallCount: Int
    public let burstyProgressCount: Int
    public let snapBackCount: Int

    public static let empty = DriveLiveMetrics(
        lifecycleState: "unknown",
        lastSchedulerIntervalMs: nil,
        lastSchedulerJitterMs: nil,
        lastDVTSetLatencyMs: nil,
        lastCoreLocationLatencyMs: nil,
        selectedSpeedMps: nil,
        lastCLLocationSpeedMps: nil,
        lastObservedGeometricSpeedMps: nil,
        connectionGeneration: 0,
        schedulerStallCount: 0,
        dvtSetStallCount: 0,
        coreLocationObservationStallCount: 0,
        burstyProgressCount: 0,
        snapBackCount: 0
    )
}

public actor DriveDiagnostics {
    private let recorder: SessionDiagnosticRecorder
    private let processInfo: ProcessInfo
    private let sampleLimit: Int
    private var sessionID: String = "NO_DRIVE_SESSION"
    private var writerID: String = "NO_WRITER"
    private var route: RouteResampler?
    private var sessionStartMonotonic: TimeInterval?
    private var selectedSpeedMps: Double?
    private var updateCadence: DriveUpdateCadence = .baseline1Hz

    private var lastObservedRouteDistance: CLLocationDistance?
    private var lastObservedCoordinate: CLLocationCoordinate2D?
    private var lastObservationMonotonic: TimeInterval?
    private var latestExpectedRouteDistance: CLLocationDistance?
    private var latestExpectedCoordinate: SimulatedCoordinate?
    private var latestConnectionGeneration = 0
    private var latestLifecycleState = "unknown"

    private var latestRequestedBySequence: [Int: RequestedTrace] = [:]
    private var latestDVTBySequence: [Int: DriveDVTSetTrace] = [:]
    private var latestRequestedSequence: Int?
    private var latestDVTSetSequence: Int?
    private var latestCLLocationSequence = 0
    private var heartbeatSequence = 0

    private var schedulerIntervalsMs: [Double] = []
    private var schedulerJitterMs: [Double] = []
    private var expectedDistanceDeltasMeters: [Double] = []
    private var dvtSetDurationsMs: [Double] = []
    private var propagationLatenciesMs: [Double] = []
    private var requestedGeometricSpeedsMps: [Double] = []
    private var observedGeometricSpeedsMps: [Double] = []
    private var validCLLocationSpeedsMps: [Double] = []
    private var validCLLocationCourseCount = 0
    private var foregroundIntervalsMs: [Double] = []
    private var backgroundIntervalsMs: [Double] = []
    private var lockedIntervalsMs: [Double] = []

    private var schedulerTickCount = 0
    private var dvtSetCount = 0
    private var clLocationCount = 0
    private var schedulerStallCount = 0
    private var dvtSetStallCount = 0
    private var coreLocationObservationStallCount = 0
    private var burstyProgressCount = 0
    private var snapBackCount = 0

    private var liveMetricsValue = DriveLiveMetrics.empty

    public init(
        recorder: SessionDiagnosticRecorder = .shared,
        processInfo: ProcessInfo = .processInfo,
        sampleLimit: Int = 4096
    ) {
        self.recorder = recorder
        self.processInfo = processInfo
        self.sampleLimit = sampleLimit
    }

    public func start(
        sessionID: UUID,
        writerID: String,
        route: RouteResampler,
        selectedSpeedMps: Double? = nil,
        updateCadence: DriveUpdateCadence = .baseline1Hz
    ) async {
        self.sessionID = sessionID.uuidString
        self.writerID = writerID
        self.route = route
        self.selectedSpeedMps = selectedSpeedMps
        self.updateCadence = updateCadence
        sessionStartMonotonic = processInfo.systemUptime
        resetSamples()
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
                "route_distance_m": String(format: "%.1f", route.totalDistanceMeters),
                "selected_speed_mps": format(selectedSpeedMps),
                "update_cadence_name": updateCadence.diagnosticName,
                "target_interval_ms": format(updateCadence.targetIntervalMs),
                "effective_update_frequency_hz": format(updateCadence.effectiveUpdateFrequencyHz)
            ]
        )
    }

    public func recordSchedulerTick(
        tickTraceID: String,
        tickSequence: Int,
        monotonicTimestamp: TimeInterval,
        expectedTickOffset: TimeInterval,
        actualTickOffset: TimeInterval,
        previousActualTickOffset: TimeInterval?,
        activeElapsedSeconds: TimeInterval,
        expectedRouteDistanceMeters: CLLocationDistance,
        previousExpectedRouteDistanceMeters: CLLocationDistance?,
        selectedSpeedMetersPerSecond: Double,
        expectedCoordinate: CLLocationCoordinate2D,
        previousExpectedCoordinate: CLLocationCoordinate2D?,
        lifecycleState: String,
        connectionGeneration: Int,
        updateCadence: DriveUpdateCadence,
        missedDeadlineCount: Int
    ) async {
        let targetIntervalSeconds = updateCadence.intervalSeconds
        schedulerTickCount += 1
        self.updateCadence = updateCadence
        latestConnectionGeneration = connectionGeneration
        latestLifecycleState = lifecycleState
        latestExpectedRouteDistance = expectedRouteDistanceMeters
        latestExpectedCoordinate = SimulatedCoordinate(expectedCoordinate)
        selectedSpeedMps = selectedSpeedMetersPerSecond

        let jitter = DriveTraceMetrics.schedulerWakeJitterMs(
            expectedWake: expectedTickOffset,
            actualWake: actualTickOffset
        )
        append(&schedulerJitterMs, jitter)

        var elapsedSincePreviousTickMs: Double?
        var distanceDelta: Double?
        var effectiveSchedulerSpeed: Double?
        if let previous = previousExpectedRouteDistanceMeters {
            distanceDelta = max(0, expectedRouteDistanceMeters - previous)
            if let distanceDelta {
                append(&expectedDistanceDeltasMeters, distanceDelta)
            }
            effectiveSchedulerSpeed = DriveTraceMetrics.speedMetersPerSecond(
                distanceDeltaMeters: distanceDelta ?? 0,
                elapsedSeconds: previousActualTickOffset.map { max(0, actualTickOffset - $0) } ?? targetIntervalSeconds
            )
            if let effectiveSchedulerSpeed {
                append(&requestedGeometricSpeedsMps, effectiveSchedulerSpeed)
            }
        }

        if let previousActualTickOffset {
            let interval = max(0, actualTickOffset - previousActualTickOffset) * 1000
            elapsedSincePreviousTickMs = interval
            append(&schedulerIntervalsMs, interval)
            appendSegmentInterval(interval, lifecycleState: lifecycleState)
            if DriveTraceMetrics.isSchedulerStall(intervalMs: interval, targetIntervalMs: targetIntervalSeconds * 1000) {
                schedulerStallCount += 1
                await recordDetector(
                    category: "SCHEDULER_STALL",
                    traceID: tickTraceID,
                    metadata: [
                        "scheduler_interval_ms": format(interval),
                        "target_interval_ms": format(targetIntervalSeconds * 1000),
                        "lifecycle_state": lifecycleState
                    ]
                )
            }
            if let distanceDelta,
               DriveTraceMetrics.isBurstyProgress(
                actualDistanceDelta: distanceDelta,
                expectedDistanceDelta: selectedSpeedMetersPerSecond * targetIntervalSeconds,
                previousTickIntervalMs: interval,
                targetIntervalMs: targetIntervalSeconds * 1000
               ) {
                burstyProgressCount += 1
                await recordDetector(
                    category: "BURSTY_PROGRESS",
                    traceID: tickTraceID,
                    metadata: [
                        "previous_tick_interval_ms": format(interval),
                        "current_distance_delta_m": format(distanceDelta),
                        "expected_distance_delta_m": format(selectedSpeedMetersPerSecond * targetIntervalSeconds),
                        "lifecycle_state": lifecycleState,
                        "connection_generation": "\(connectionGeneration)"
                    ]
                )
            }
        }

        let expectedBearing = previousExpectedCoordinate.flatMap {
            DriveTraceMetrics.bearingDegrees(from: $0, to: expectedCoordinate)
        }
        liveMetricsValue = liveMetricsValue.replacing(
            lifecycleState: lifecycleState,
            schedulerInterval: elapsedSincePreviousTickMs,
            schedulerJitter: jitter,
            selectedSpeed: selectedSpeedMetersPerSecond,
            connectionGeneration: connectionGeneration,
            schedulerStalls: schedulerStallCount,
            dvtStalls: dvtSetStallCount,
            clStalls: coreLocationObservationStallCount,
            bursts: burstyProgressCount,
            snapBacks: snapBackCount
        )

        await recorder.record(
            category: "SCHEDULER_TICK",
            component: "DriveScheduler",
            previousState: nil,
            newState: "tick",
            message: "scheduler tick",
            metadata: [
                "drive_session_id": sessionID,
                "writer_id": writerID,
                "tick_trace_id": tickTraceID,
                "tick_sequence": "\(tickSequence)",
                "monotonic_timestamp": format(monotonicTimestamp),
                "expected_tick_offset": format(expectedTickOffset),
                "actual_tick_offset": format(actualTickOffset),
                "scheduler_wake_jitter_ms": format(jitter),
                "missed_deadline_count": "\(missedDeadlineCount)",
                "active_elapsed_seconds": format(activeElapsedSeconds),
                "expected_route_distance_m": format(expectedRouteDistanceMeters),
                "previous_expected_route_distance_m": format(previousExpectedRouteDistanceMeters),
                "distance_delta_since_previous_tick_m": format(distanceDelta),
                "spatial_step_meters": format(distanceDelta),
                "elapsed_since_previous_tick_ms": format(elapsedSincePreviousTickMs),
                "effective_scheduler_speed_mps": format(effectiveSchedulerSpeed),
                "selected_speed_mps": format(selectedSpeedMetersPerSecond),
                "update_cadence_name": updateCadence.diagnosticName,
                "target_interval_ms": format(updateCadence.targetIntervalMs),
                "effective_update_frequency_hz": format(updateCadence.effectiveUpdateFrequencyHz),
                "expected_latitude": format(expectedCoordinate.latitude),
                "expected_longitude": format(expectedCoordinate.longitude),
                "expected_route_bearing_deg": format(expectedBearing),
                "lifecycle_state": lifecycleState,
                "connection_generation": "\(connectionGeneration)"
            ]
        )
    }

    public func recordCoordinatorUpdateRequested(context: DriveTraceContext, writerID: String, connectionGeneration: Int) async {
        latestRequestedSequence = context.requestSequence
        latestRequestedBySequence[context.requestSequence] = RequestedTrace(
            sequence: context.requestSequence,
            tickTraceID: context.tickTraceID,
            coordinate: context.expectedCoordinate,
            expectedRouteDistance: context.expectedRouteDistanceMeters,
            requestedMonotonicTime: context.updateRequestMonotonicTime,
            dvtSetEndMonotonicTime: nil
        )
        trimTraceDictionaries()
        await recorder.record(
            category: "COORDINATOR_UPDATE_REQUESTED",
            component: "LocationCoordinator",
            previousState: nil,
            newState: "requested",
            message: "coordinator update requested",
            metadata: coordinatorMetadata(context: context, writerID: writerID, connectionGeneration: connectionGeneration)
        )
    }

    public func recordCoordinatorUpdateEntered(
        context: DriveTraceContext,
        writerID: String,
        connectionGeneration: Int,
        enteredMonotonicTime: TimeInterval
    ) async {
        let delay = DriveTraceMetrics.durationMs(begin: context.updateRequestMonotonicTime, end: enteredMonotonicTime)
        await recorder.record(
            category: "COORDINATOR_UPDATE_ENTERED",
            component: "LocationCoordinator",
            previousState: nil,
            newState: "entered",
            message: "coordinator actor began processing update",
            metadata: coordinatorMetadata(context: context, writerID: writerID, connectionGeneration: connectionGeneration).merging([
                "actor_queue_delay_ms": format(delay),
                "actor_entered_monotonic_timestamp": format(enteredMonotonicTime)
            ]) { _, new in new }
        )
    }

    public func recordDVTSetBegin(context: DriveTraceContext?, writerID: String, connectionGeneration: Int, beginMonotonicTime: TimeInterval) async {
        await recorder.record(
            category: "DVT_SET_BEGIN",
            component: "LocationCoordinator",
            previousState: nil,
            newState: "begin",
            message: "dvt set call beginning",
            metadata: dvtMetadata(context: context, writerID: writerID, connectionGeneration: connectionGeneration).merging([
                "dvt_set_begin_monotonic_timestamp": format(beginMonotonicTime)
            ]) { _, new in new }
        )
    }

    public func recordDVTSetEnd(
        context: DriveTraceContext?,
        writerID: String,
        connectionGeneration: Int,
        beginMonotonicTime: TimeInterval,
        endMonotonicTime: TimeInterval,
        success: Bool,
        nativeErrorCategory: String?
    ) async {
        dvtSetCount += 1
        let trace = DriveDVTSetTrace(
            tickTraceID: context?.tickTraceID,
            requestSequence: context?.requestSequence,
            driveSessionID: context?.driveSessionID,
            writerID: writerID,
            connectionGeneration: connectionGeneration,
            beginMonotonicTime: beginMonotonicTime,
            endMonotonicTime: endMonotonicTime,
            success: success,
            nativeErrorCategory: nativeErrorCategory
        )
        append(&dvtSetDurationsMs, trace.durationMs)
        if let requestSequence = context?.requestSequence {
            latestDVTSetSequence = requestSequence
            latestDVTBySequence[requestSequence] = trace
            if var requested = latestRequestedBySequence[requestSequence] {
                requested.dvtSetEndMonotonicTime = endMonotonicTime
                latestRequestedBySequence[requestSequence] = requested
            }
        }
        if DriveTraceMetrics.isDVTSetStall(durationMs: trace.durationMs) {
            dvtSetStallCount += 1
            await recordDetector(
                category: "DVT_SET_STALL",
                traceID: context?.tickTraceID,
                metadata: [
                    "dvt_set_duration_ms": format(trace.durationMs),
                    "connection_generation": "\(connectionGeneration)",
                    "native_error_category": nativeErrorCategory ?? "none"
                ]
            )
        }
        liveMetricsValue = liveMetricsValue.replacing(
            dvtLatency: trace.durationMs,
            schedulerStalls: schedulerStallCount,
            dvtStalls: dvtSetStallCount,
            clStalls: coreLocationObservationStallCount,
            bursts: burstyProgressCount,
            snapBacks: snapBackCount
        )
        await recorder.record(
            category: "DVT_SET_END",
            component: "LocationCoordinator",
            previousState: "begin",
            newState: success ? "success" : "failed",
            errorCode: success ? nil : nativeErrorCategory,
            message: "dvt set call ended",
            metadata: dvtMetadata(context: context, writerID: writerID, connectionGeneration: connectionGeneration).merging([
                "dvt_set_begin_monotonic_timestamp": format(beginMonotonicTime),
                "dvt_set_end_monotonic_timestamp": format(endMonotonicTime),
                "dvt_set_duration_ms": format(trace.durationMs),
                "success": "\(success)",
                "native_error_category": nativeErrorCategory ?? "none"
            ]) { _, new in new }
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
        backgroundSessionActive: Bool,
        tickTraceID: String? = nil
    ) async {
        latestExpectedRouteDistance = expectedRouteDistanceMeters
        latestExpectedCoordinate = SimulatedCoordinate(expectedCoordinate)
        let observedProjection = observed.flatMap { observation -> RouteProjection? in
            route?.nearestProjection(to: CLLocationCoordinate2D(latitude: observation.latitude, longitude: observation.longitude))
        }
        var metadata: [String: String] = [
            "drive_session_id": sessionID,
            "writer_id": writerID,
            "tick_trace_id": tickTraceID ?? "none",
            "sequence_number": "\(sequenceNumber)",
            "scheduler_tick_number": "\(tickNumber)",
            "monotonic_elapsed_time": format(monotonicElapsedTime),
            "connection_generation": "\(connectionGeneration)",
            "expected_route_distance_m": format(expectedRouteDistanceMeters),
            "expected_latitude": format(expectedCoordinate.latitude),
            "expected_longitude": format(expectedCoordinate.longitude),
            "requested_latitude": format(requestedCoordinate.latitude),
            "requested_longitude": format(requestedCoordinate.longitude),
            "calculated_route_speed_mps": format(calculatedRouteSpeedMetersPerSecond),
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
        clLocationCount += 1
        latestCLLocationSequence += 1
        latestConnectionGeneration = connectionGeneration
        latestLifecycleState = applicationLifecycleState
        let receiveMonotonic = processInfo.systemUptime
        let coordinate = CLLocationCoordinate2D(latitude: observation.latitude, longitude: observation.longitude)
        let projection = route?.nearestProjection(to: coordinate)
        let matched = latestRequestedSequence.flatMap { latestRequestedBySequence[$0] }
        let dvtTrace = latestDVTSetSequence.flatMap { latestDVTBySequence[$0] }
        let propagationLatency = dvtTrace.map {
            DriveTraceMetrics.durationMs(begin: $0.endMonotonicTime, end: receiveMonotonic)
        }
        if let propagationLatency {
            append(&propagationLatenciesMs, propagationLatency)
        }
        let timeSinceLastSet = dvtTrace.map {
            DriveTraceMetrics.durationMs(begin: $0.endMonotonicTime, end: receiveMonotonic)
        }
        let distanceFromLastRequested = matched.map {
            RouteResampler.distance(from: coordinate, to: $0.coordinate)
        }
        var observedGeometricSpeed: Double?
        if let previous = lastObservedCoordinate, let previousTime = lastObservationMonotonic {
            let distance = RouteResampler.distance(from: previous, to: coordinate)
            let elapsed = receiveMonotonic - previousTime
            observedGeometricSpeed = DriveTraceMetrics.speedMetersPerSecond(distanceDeltaMeters: distance, elapsedSeconds: elapsed)
            if let observedGeometricSpeed {
                append(&observedGeometricSpeedsMps, observedGeometricSpeed)
            }
            let observationIntervalMs = elapsed * 1000
            if DriveTraceMetrics.isCoreLocationObservationStall(intervalMs: observationIntervalMs) {
                coreLocationObservationStallCount += 1
                await recordDetector(
                    category: "CORELOCATION_OBSERVATION_STALL",
                    traceID: matched?.tickTraceID,
                    metadata: [
                        "observation_interval_ms": format(observationIntervalMs),
                        "last_requested_sequence": matched.map { "\($0.sequence)" } ?? "none",
                        "connection_generation": "\(connectionGeneration)",
                        "lifecycle_state": applicationLifecycleState
                    ]
                )
            }
        }
        if DriveTraceMetrics.validCLLocationSpeed(observation.speed) {
            append(&validCLLocationSpeedsMps, observation.speed ?? 0)
        }
        if DriveTraceMetrics.validCLLocationCourse(observation.course) {
            validCLLocationCourseCount += 1
        }

        var metadata: [String: String] = [
            "drive_session_id": sessionID,
            "writer_id": writerID,
            "tick_trace_id": matched?.tickTraceID ?? "unmatched_latest",
            "observation_sequence": "\(latestCLLocationSequence)",
            "last_requested_sequence": matched.map { "\($0.sequence)" } ?? "none",
            "last_dvt_set_sequence": latestDVTSetSequence.map { "\($0)" } ?? "none",
            "monotonic_receive_timestamp": format(receiveMonotonic),
            "cllocation_timestamp": ISO8601DateFormatter().string(from: observation.locationTimestamp),
            "observed_latitude": format(observation.latitude),
            "observed_longitude": format(observation.longitude),
            "connection_generation": "\(connectionGeneration)",
            "application_lifecycle_state": applicationLifecycleState,
            "background_session_active": "\(backgroundSessionActive)",
            "time_since_last_dvt_set_ms": format(timeSinceLastSet),
            "distance_from_last_requested_coordinate_m": format(distanceFromLastRequested),
            "corelocation_propagation_latency_ms": format(propagationLatency),
            "selected_drive_speed_mps": format(selectedSpeedMps),
            "observed_geometric_speed_mps": format(observedGeometricSpeed),
            "matching_strategy": "latest_dvt_set_sequence"
        ]
        appendObservationMetadata(observation, projection: projection, metadata: &metadata)
        if let expected = latestExpectedRouteDistance {
            metadata["expected_route_distance_m"] = format(expected)
        }
        if let expectedCoordinate = latestExpectedCoordinate {
            metadata["expected_latitude"] = format(expectedCoordinate.latitude)
            metadata["expected_longitude"] = format(expectedCoordinate.longitude)
        }
        await recorder.record(
            category: "CLLOCATION_OBSERVED",
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
            connectionGeneration: connectionGeneration,
            tickTraceID: matched?.tickTraceID,
            propagationLatencyMs: propagationLatency
        )
        lastObservedCoordinate = coordinate
        lastObservationMonotonic = receiveMonotonic
        liveMetricsValue = liveMetricsValue.replacing(
            lifecycleState: applicationLifecycleState,
            clLatency: propagationLatency,
            clSpeed: observation.speed,
            observedGeometricSpeed: observedGeometricSpeed,
            connectionGeneration: connectionGeneration,
            schedulerStalls: schedulerStallCount,
            dvtStalls: dvtSetStallCount,
            clStalls: coreLocationObservationStallCount,
            bursts: burstyProgressCount,
            snapBacks: snapBackCount
        )
    }

    public func recordHeartbeat(
        expectedRouteDistance: CLLocationDistance?,
        lifecycleState: String,
        connectionGeneration: Int
    ) async {
        heartbeatSequence += 1
        await recorder.record(
            category: "DRIVE_HEARTBEAT",
            component: "DriveDiagnostics",
            previousState: nil,
            newState: "alive",
            message: "drive diagnostic heartbeat",
            metadata: [
                "drive_session_id": sessionID,
                "writer_id": writerID,
                "heartbeat_sequence": "\(heartbeatSequence)",
                "monotonic_timestamp": format(processInfo.systemUptime),
                "lifecycle_state": lifecycleState,
                "expected_route_distance_m": format(expectedRouteDistance),
                "latest_dvt_set_sequence": latestDVTSetSequence.map { "\($0)" } ?? "none",
                "latest_cllocation_sequence": "\(latestCLLocationSequence)",
                "connection_generation": "\(connectionGeneration)"
            ]
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
                "writer_id": writerID,
                "monotonic_timestamp": format(processInfo.systemUptime),
                "connection_generation": "\(latestConnectionGeneration)"
            ]) { _, new in new }
        )
    }

    public func recordLifecycle(
        _ state: String,
        schedulerState: String,
        backgroundSessionActive: Bool,
        connectionGeneration: Int
    ) async {
        latestLifecycleState = state
        latestConnectionGeneration = connectionGeneration
        await recorder.record(
            category: "APPLICATION_LIFECYCLE",
            component: "DriveLifecycle",
            previousState: nil,
            newState: state,
            message: "drive lifecycle event",
            metadata: [
                "drive_session_id": sessionID,
                "writer_id": writerID,
                "monotonic_timestamp": format(processInfo.systemUptime),
                "scheduler_state": schedulerState,
                "background_session_active": "\(backgroundSessionActive)",
                "connection_generation": "\(connectionGeneration)"
            ]
        )
    }

    public func recordBackgroundEvent(_ event: String, metadata: [String: String] = [:]) async {
        await recorder.record(
            category: "BACKGROUND_EXECUTION",
            component: "DriveBackground",
            previousState: nil,
            newState: event,
            message: "drive background execution event",
            metadata: metadata.merging([
                "drive_session_id": sessionID,
                "writer_id": writerID,
                "monotonic_timestamp": format(processInfo.systemUptime)
            ]) { _, new in new }
        )
    }

    public func finalizeSummary() async -> DriveCharacterizationSummary {
        let duration = sessionStartMonotonic.map { max(0, processInfo.systemUptime - $0) } ?? 0
        let recorderMetrics = await recorder.metrics()
        let summary = DriveCharacterizationSummary(
            updateCadenceName: updateCadence.diagnosticName,
            targetIntervalMs: updateCadence.targetIntervalMs,
            effectiveUpdateFrequencyHz: updateCadence.effectiveUpdateFrequencyHz,
            totalDriveDuration: duration,
            totalSchedulerTicks: schedulerTickCount,
            totalDVTSetCalls: dvtSetCount,
            totalObservedCLLocations: clLocationCount,
            schedulerIntervals: DriveTraceMetrics.timingStatistics(milliseconds: schedulerIntervalsMs),
            schedulerWakeJitter: DriveTraceMetrics.timingStatistics(milliseconds: schedulerJitterMs.map(abs)),
            expectedDistanceDeltaPerTickMeters: DriveTraceMetrics.timingStatistics(milliseconds: expectedDistanceDeltasMeters),
            dvtSetDurations: DriveTraceMetrics.timingStatistics(milliseconds: dvtSetDurationsMs),
            coreLocationPropagationLatencies: DriveTraceMetrics.timingStatistics(milliseconds: propagationLatenciesMs),
            selectedSpeedMps: selectedSpeedMps,
            meanRequestedGeometricSpeedMps: mean(requestedGeometricSpeedsMps),
            meanObservedGeometricSpeedMps: mean(observedGeometricSpeedsMps),
            percentageOfCLLocationsWithValidSpeed: clLocationCount > 0 ? Double(validCLLocationSpeedsMps.count) / Double(clLocationCount) * 100 : nil,
            percentageOfCLLocationsWithValidCourse: clLocationCount > 0 ? Double(validCLLocationCourseCount) / Double(clLocationCount) * 100 : nil,
            meanCLLocationSpeedWhenValid: mean(validCLLocationSpeedsMps),
            foregroundSchedulerIntervals: DriveTraceMetrics.timingStatistics(milliseconds: foregroundIntervalsMs),
            backgroundSchedulerIntervals: DriveTraceMetrics.timingStatistics(milliseconds: backgroundIntervalsMs),
            lockedSchedulerIntervals: DriveTraceMetrics.timingStatistics(milliseconds: lockedIntervalsMs),
            diagnosticEventCount: recorderMetrics.eventCount,
            diagnosticEventsWritten: recorderMetrics.eventsWritten,
            diagnosticFlushCount: recorderMetrics.flushCount,
            diagnosticMeanWriteDurationMs: recorderMetrics.meanWriteDurationMs,
            diagnosticMaxWriteDurationMs: recorderMetrics.maxWriteDurationMs,
            schedulerStallCount: schedulerStallCount,
            dvtSetStallCount: dvtSetStallCount,
            coreLocationObservationStallCount: coreLocationObservationStallCount,
            burstyProgressCount: burstyProgressCount,
            snapBackCount: snapBackCount
        )
        await recorder.record(
            category: "DRIVE_CHARACTERIZATION_SUMMARY",
            component: "DriveDiagnostics",
            previousState: nil,
            newState: "generated",
            message: "drive characterization summary generated",
            metadata: summaryMetadata(summary)
        )
        await recorder.finalizeCurrentSession()
        return summary
    }

    public func liveMetrics() -> DriveLiveMetrics {
        liveMetricsValue
    }

    public func exportURLs() async -> [URL] {
        await recorder.exportURLs()
    }

    private func detectSnapBackIfNeeded(
        projection: RouteProjection?,
        observation: LocationObservation,
        applicationLifecycleState: String,
        backgroundSessionActive: Bool,
        connectionGeneration: Int,
        tickTraceID: String?,
        propagationLatencyMs: Double?
    ) async {
        guard let projection else { return }
        defer {
            lastObservedRouteDistance = projection.distanceAlongRouteMeters
        }
        guard let previous = lastObservedRouteDistance else { return }
        let regression = previous - projection.distanceAlongRouteMeters
        guard regression > 50 else { return }

        snapBackCount += 1
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
                "tick_trace_id": tickTraceID ?? "none",
                "last_requested_sequence": latestRequestedSequence.map { "\($0)" } ?? "none",
                "previous_route_progress_m": format(previous),
                "current_route_progress_m": format(projection.distanceAlongRouteMeters),
                "expected_route_progress_m": format(latestExpectedRouteDistance),
                "connection_generation": "\(connectionGeneration)",
                "application_lifecycle_state": applicationLifecycleState,
                "background_session_active": "\(backgroundSessionActive)",
                "corelocation_propagation_latency_ms": format(propagationLatencyMs),
                "latest_dvt_set_sequence": latestDVTSetSequence.map { "\($0)" } ?? "none",
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
        metadata["observed_latitude"] = format(observation.latitude)
        metadata["observed_longitude"] = format(observation.longitude)
        metadata["horizontal_accuracy_m"] = format(observation.horizontalAccuracy)
        metadata["vertical_accuracy_m"] = format(observation.verticalAccuracy)
        metadata["cllocation_speed_mps"] = observation.speed.map(format) ?? "UNKNOWN"
        metadata["cllocation_speed_accuracy_mps"] = observation.speedAccuracy.map(format) ?? "UNKNOWN"
        metadata["cllocation_course_deg"] = observation.course.map(format) ?? "UNKNOWN"
        metadata["cllocation_course_accuracy_deg"] = observation.courseAccuracy.map(format) ?? "UNKNOWN"
        metadata["altitude_m"] = observation.altitude.map(format) ?? "UNKNOWN"
        metadata["source_is_simulated_by_software"] = String(describing: observation.isSimulatedBySoftware)
        metadata["source_is_produced_by_accessory"] = String(describing: observation.isProducedByAccessory)
        if let projection {
            metadata["observed_nearest_route_distance_m"] = format(projection.distanceAlongRouteMeters)
            metadata["observed_distance_from_route_m"] = format(projection.distanceFromRouteMeters)
        }
    }

    private func coordinatorMetadata(context: DriveTraceContext, writerID: String, connectionGeneration: Int) -> [String: String] {
        [
            "drive_session_id": context.driveSessionID,
            "writer_id": writerID,
            "tick_trace_id": context.tickTraceID,
            "request_sequence": "\(context.requestSequence)",
            "tick_sequence": "\(context.tickSequence)",
            "connection_generation": "\(connectionGeneration)",
            "requested_latitude": format(context.expectedCoordinate.latitude),
            "requested_longitude": format(context.expectedCoordinate.longitude),
            "expected_route_distance_m": format(context.expectedRouteDistanceMeters),
            "update_request_monotonic_timestamp": format(context.updateRequestMonotonicTime),
            "lifecycle_state": context.lifecycleState,
            "selected_speed_mps": format(context.selectedSpeedMetersPerSecond)
        ]
    }

    private func dvtMetadata(context: DriveTraceContext?, writerID: String, connectionGeneration: Int) -> [String: String] {
        [
            "drive_session_id": context?.driveSessionID ?? sessionID,
            "writer_id": writerID,
            "tick_trace_id": context?.tickTraceID ?? "none",
            "request_sequence": context.map { "\($0.requestSequence)" } ?? "none",
            "connection_generation": "\(connectionGeneration)",
            "expected_route_distance_m": format(context?.expectedRouteDistanceMeters)
        ]
    }

    private func summaryMetadata(_ summary: DriveCharacterizationSummary) -> [String: String] {
        [
            "total_drive_duration_s": format(summary.totalDriveDuration),
            "update_cadence_name": summary.updateCadenceName,
            "target_interval_ms": format(summary.targetIntervalMs),
            "effective_update_frequency_hz": format(summary.effectiveUpdateFrequencyHz),
            "total_scheduler_ticks": "\(summary.totalSchedulerTicks)",
            "total_dvt_set_calls": "\(summary.totalDVTSetCalls)",
            "total_observed_cllocations": "\(summary.totalObservedCLLocations)",
            "scheduler_mean_interval_ms": format(summary.schedulerIntervals.meanMs),
            "scheduler_median_interval_ms": format(summary.schedulerIntervals.medianMs),
            "scheduler_p95_interval_ms": format(summary.schedulerIntervals.p95Ms),
            "scheduler_max_interval_ms": format(summary.schedulerIntervals.maxMs),
            "scheduler_mean_wake_jitter_ms": format(summary.schedulerWakeJitter.meanMs),
            "scheduler_p95_wake_jitter_ms": format(summary.schedulerWakeJitter.p95Ms),
            "scheduler_max_wake_jitter_ms": format(summary.schedulerWakeJitter.maxMs),
            "mean_expected_distance_delta_per_tick_m": format(summary.expectedDistanceDeltaPerTickMeters.meanMs),
            "median_expected_distance_delta_per_tick_m": format(summary.expectedDistanceDeltaPerTickMeters.medianMs),
            "p95_expected_distance_delta_per_tick_m": format(summary.expectedDistanceDeltaPerTickMeters.p95Ms),
            "max_expected_distance_delta_per_tick_m": format(summary.expectedDistanceDeltaPerTickMeters.maxMs),
            "dvt_mean_set_duration_ms": format(summary.dvtSetDurations.meanMs),
            "dvt_p95_set_duration_ms": format(summary.dvtSetDurations.p95Ms),
            "dvt_max_set_duration_ms": format(summary.dvtSetDurations.maxMs),
            "corelocation_mean_propagation_latency_ms": format(summary.coreLocationPropagationLatencies.meanMs),
            "corelocation_p95_propagation_latency_ms": format(summary.coreLocationPropagationLatencies.p95Ms),
            "corelocation_max_propagation_latency_ms": format(summary.coreLocationPropagationLatencies.maxMs),
            "selected_speed_mps": format(summary.selectedSpeedMps),
            "mean_requested_geometric_speed_mps": format(summary.meanRequestedGeometricSpeedMps),
            "mean_observed_geometric_speed_mps": format(summary.meanObservedGeometricSpeedMps),
            "percentage_cllocations_with_valid_speed": format(summary.percentageOfCLLocationsWithValidSpeed),
            "percentage_cllocations_with_valid_course": format(summary.percentageOfCLLocationsWithValidCourse),
            "mean_cllocation_speed_when_valid": format(summary.meanCLLocationSpeedWhenValid),
            "foreground_scheduler_mean_interval_ms": format(summary.foregroundSchedulerIntervals.meanMs),
            "foreground_scheduler_p95_interval_ms": format(summary.foregroundSchedulerIntervals.p95Ms),
            "background_scheduler_mean_interval_ms": format(summary.backgroundSchedulerIntervals.meanMs),
            "background_scheduler_p95_interval_ms": format(summary.backgroundSchedulerIntervals.p95Ms),
            "locked_scheduler_mean_interval_ms": format(summary.lockedSchedulerIntervals.meanMs),
            "locked_scheduler_p95_interval_ms": format(summary.lockedSchedulerIntervals.p95Ms),
            "diagnostic_event_count": "\(summary.diagnosticEventCount)",
            "diagnostic_events_written": "\(summary.diagnosticEventsWritten)",
            "diagnostic_flush_count": "\(summary.diagnosticFlushCount)",
            "diagnostic_mean_write_duration_ms": format(summary.diagnosticMeanWriteDurationMs),
            "diagnostic_max_write_duration_ms": format(summary.diagnosticMaxWriteDurationMs),
            "scheduler_stall_count": "\(summary.schedulerStallCount)",
            "dvt_set_stall_count": "\(summary.dvtSetStallCount)",
            "corelocation_observation_stall_count": "\(summary.coreLocationObservationStallCount)",
            "bursty_progress_count": "\(summary.burstyProgressCount)",
            "snap_back_count": "\(summary.snapBackCount)"
        ]
    }

    private func recordDetector(category: String, traceID: String?, metadata: [String: String]) async {
        await recorder.record(
            category: category,
            component: "DriveDiagnostics",
            previousState: nil,
            newState: "detected",
            errorCode: category,
            message: "drive diagnostic detector fired",
            metadata: metadata.merging([
                "drive_session_id": sessionID,
                "writer_id": writerID,
                "tick_trace_id": traceID ?? "none"
            ]) { _, new in new }
        )
    }

    private func appendSegmentInterval(_ interval: Double, lifecycleState: String) {
        let normalized = lifecycleState.lowercased()
        if normalized.contains("background") {
            append(&backgroundIntervalsMs, interval)
        } else if normalized.contains("lock") || normalized.contains("inactive") {
            append(&lockedIntervalsMs, interval)
        } else {
            append(&foregroundIntervalsMs, interval)
        }
    }

    private func append(_ values: inout [Double], _ value: Double) {
        guard value.isFinite else { return }
        values.append(value)
        if values.count > sampleLimit {
            values.removeFirst(values.count - sampleLimit)
        }
    }

    private func trimTraceDictionaries() {
        if latestRequestedBySequence.count > 256 {
            let keys = latestRequestedBySequence.keys.sorted().prefix(latestRequestedBySequence.count - 256)
            for key in keys {
                latestRequestedBySequence.removeValue(forKey: key)
                latestDVTBySequence.removeValue(forKey: key)
            }
        }
    }

    private func resetSamples() {
        lastObservedRouteDistance = nil
        lastObservedCoordinate = nil
        lastObservationMonotonic = nil
        latestExpectedRouteDistance = nil
        latestExpectedCoordinate = nil
        latestConnectionGeneration = 0
        latestLifecycleState = "unknown"
        latestRequestedBySequence = [:]
        latestDVTBySequence = [:]
        latestRequestedSequence = nil
        latestDVTSetSequence = nil
        latestCLLocationSequence = 0
        heartbeatSequence = 0
        schedulerIntervalsMs = []
        schedulerJitterMs = []
        expectedDistanceDeltasMeters = []
        dvtSetDurationsMs = []
        propagationLatenciesMs = []
        requestedGeometricSpeedsMps = []
        observedGeometricSpeedsMps = []
        validCLLocationSpeedsMps = []
        validCLLocationCourseCount = 0
        foregroundIntervalsMs = []
        backgroundIntervalsMs = []
        lockedIntervalsMs = []
        schedulerTickCount = 0
        dvtSetCount = 0
        clLocationCount = 0
        schedulerStallCount = 0
        dvtSetStallCount = 0
        coreLocationObservationStallCount = 0
        burstyProgressCount = 0
        snapBackCount = 0
        liveMetricsValue = .empty
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "insufficient data" }
        return String(format: "%.3f", value)
    }
}

private struct RequestedTrace: Sendable {
    let sequence: Int
    let tickTraceID: String
    let coordinate: CLLocationCoordinate2D
    let expectedRouteDistance: CLLocationDistance
    let requestedMonotonicTime: TimeInterval
    var dvtSetEndMonotonicTime: TimeInterval?
}

private extension DriveLiveMetrics {
    func replacing(
        lifecycleState: String? = nil,
        schedulerInterval: Double? = nil,
        schedulerJitter: Double? = nil,
        dvtLatency: Double? = nil,
        clLatency: Double? = nil,
        selectedSpeed: Double? = nil,
        clSpeed: Double? = nil,
        observedGeometricSpeed: Double? = nil,
        connectionGeneration: Int? = nil,
        schedulerStalls: Int? = nil,
        dvtStalls: Int? = nil,
        clStalls: Int? = nil,
        bursts: Int? = nil,
        snapBacks: Int? = nil
    ) -> DriveLiveMetrics {
        DriveLiveMetrics(
            lifecycleState: lifecycleState ?? self.lifecycleState,
            lastSchedulerIntervalMs: schedulerInterval ?? lastSchedulerIntervalMs,
            lastSchedulerJitterMs: schedulerJitter ?? lastSchedulerJitterMs,
            lastDVTSetLatencyMs: dvtLatency ?? lastDVTSetLatencyMs,
            lastCoreLocationLatencyMs: clLatency ?? lastCoreLocationLatencyMs,
            selectedSpeedMps: selectedSpeed ?? selectedSpeedMps,
            lastCLLocationSpeedMps: clSpeed ?? lastCLLocationSpeedMps,
            lastObservedGeometricSpeedMps: observedGeometricSpeed ?? lastObservedGeometricSpeedMps,
            connectionGeneration: connectionGeneration ?? self.connectionGeneration,
            schedulerStallCount: schedulerStalls ?? schedulerStallCount,
            dvtSetStallCount: dvtStalls ?? dvtSetStallCount,
            coreLocationObservationStallCount: clStalls ?? coreLocationObservationStallCount,
            burstyProgressCount: bursts ?? burstyProgressCount,
            snapBackCount: snapBacks ?? snapBackCount
        )
    }
}
