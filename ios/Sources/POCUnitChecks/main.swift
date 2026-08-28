import Foundation
import CoreLocation
import IOSSimOnDeviceDVTPOC

@main
struct POCUnitChecks {
    static func main() async throws {
        try validSemanticRPPairingPlistPasses()
        try missingPrivateKeyFailsWithoutLeakingValues()
        try wrongAltIRKLengthFails()
        try topLevelArrayIsRejected()
        try inMemoryStoreValidatesBeforeSaving()
        try deleteRemovesPairing()
        try localDevVPNRouteDetection()
        await routeProbeSurfacesEndpointAndTCPResult()
        try await diagnosticStateRecordsStatusAndTiming()
        try await sessionRecorderRedactsAndClassifies()
        try await bridgeReportsUnavailableWhenIdeviceIsNotLinked()
        try routeInterpolation()
        try constantSpeedDistanceCalculations()
        try driveCadenceConfiguration()
        try absoluteDeadlineSchedulerCalculations()
        try missedDeadlineCalculationsSkipReplay()
        try cadenceDoesNotChangeRouteTraversalTime()
        try spatialStepAt35MPH()
        try pauseDoesNotAdvanceRouteProgress()
        try resumeUsesActiveElapsedTime()
        try pauseResumeDeadlineCalculations()
        try backgroundDelayCalculationsCollapseMissedTicks()
        try suspensionTickSkipsMissedPoints()
        try monotonicRouteProgression()
        try completedHoldingDoesNotClearSimulation()
        try await staleWriterCannotSendAfterOwnershipChanges()
        try await staleGenerationCallbackCannotAffectCurrentConnection()
        try await reconnectRestoresCurrentDrivePosition()
        try await stopPreventsDelayedWrites()
        try routeDistanceClamping()
        try await driveDiagnosticsSerialize()
        try driveTraceMetricCalculations()
        try await driveDiagnosticsTraceSerializationAndSummary()
        try await driveDiagnosticsDetectorEvents()
        try await sessionRecorderBatchesAndTransitions()
        try coordinateParsingAcceptsValidPairs()
        try coordinateParsingRejectsOutOfRangeAndMalformedText()
        try mapKitSearchProviderParsesCoordinatesWithoutNetworkLookup()
        try recentsListDedupesNearbyPlacesAndMovesToFront()
        try recentsListCapsAtLimit()
        try jsonFilePlaceStoreRoundTripsAndOverwrites()
        print("POCUnitChecks passed")
    }

    static func validSemanticRPPairingPlistPasses() throws {
        let data = try makePairingPlist(identifier: "12345678-1234-1234-1234-123456789abc")
        let summary = try RPPairingValidator.validate(data)
        try require(summary.pairingLoaded, "pairing should be loaded")
        try require(summary.publicKeyPresent, "public key present")
        try require(summary.privateKeyPresent, "private key present")
        try require(summary.altIRKPresent, "alt_irk present")
        try require(summary.identifierRedacted == "1234...9abc (36 chars)", "identifier redacted")
    }

    static func missingPrivateKeyFailsWithoutLeakingValues() throws {
        let data = try makePairingPlist(omit: "private_key")
        do {
            _ = try RPPairingValidator.validate(data)
            throw CheckError("expected validation failure")
        } catch let error as POCError {
            try require(error.code == .pairingCredentialMissing, "missing key error code")
            try require(!error.message.contains("12345678"), "error should not leak identifier")
        }
    }

    static func wrongAltIRKLengthFails() throws {
        let data = try plistData([
            "public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32),
            "identifier": "12345678-1234-1234-1234-123456789abc",
            "alt_irk": Data(repeating: 3, count: 15)
        ])
        do {
            _ = try RPPairingValidator.validate(data)
            throw CheckError("expected validation failure")
        } catch let error as POCError {
            try require(error.code == .pairingCredentialMissing, "wrong alt_irk error code")
        }
    }

    static func topLevelArrayIsRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [["not": "a pairing"]], format: .xml, options: 0)
        do {
            _ = try RPPairingValidator.validate(data)
            throw CheckError("expected validation failure")
        } catch let error as POCError {
            try require(error.code == .pairingFileInvalid, "array rejected")
        }
    }

    static func inMemoryStoreValidatesBeforeSaving() throws {
        let store = InMemoryRPPairingStore()
        try expectThrows { _ = try store.importPairingData(Data("not plist".utf8)) }
        try expectThrows { _ = try store.loadPairingData() }

        let data = try makePairingPlist()
        _ = try store.importPairingData(data)
        let loaded = try store.loadPairingData()
        let summary = try store.pairingSummary()
        try require(loaded == data, "store returns imported data")
        try require(summary != nil, "store returns summary")
    }

    static func deleteRemovesPairing() throws {
        let store = InMemoryRPPairingStore(data: try makePairingPlist())
        try store.deletePairingData()
        let summary = try store.pairingSummary()
        try require(summary == nil, "delete removes pairing")
    }

    static func localDevVPNRouteDetection() throws {
        try require(DeveloperRouteProbe.localDevVPNAppearsActive(in: [
            NetworkInterfaceSnapshot(name: "utun7", address: "10.7.0.0", family: "IPv4")
        ]), "10.7.0.0 route visible")
        try require(!DeveloperRouteProbe.localDevVPNAppearsActive(in: [
            NetworkInterfaceSnapshot(name: "en0", address: "192.168.1.10", family: "IPv4")
        ]), "normal LAN is not LocalDevVPN")
    }

    static func routeProbeSurfacesEndpointAndTCPResult() async {
        let probe = DeveloperRouteProbe(
            interfaceProvider: FakeInterfaces(values: [
                NetworkInterfaceSnapshot(name: "utun2", address: "10.7.0.1", family: "IPv4")
            ]),
            tcpProber: FakeTCPProber(result: TCPProbeResult(
                endpoint: DeveloperEndpoint(),
                connected: true,
                latencyMs: 12.5,
                error: nil
            ))
        )
        let result = await probe.run()
        precondition(result.localDevVPNAppearsActive)
        precondition(result.tcpResult.connected)
        precondition(result.tcpResult.latencyMs == 12.5)
    }

    static func diagnosticStateRecordsStatusAndTiming() async throws {
        let state = DiagnosticState()
        await state.start(.endpointReachable)
        await state.succeed(.endpointReachable, message: "connected")

        let snapshot = await state.snapshot()
        guard let record = snapshot.stages.first(where: { $0.stage == .endpointReachable }) else {
            throw CheckError("missing endpoint record")
        }
        try require(record.status == .success, "endpoint should be success")
        try require(record.durationMs != nil, "duration should be recorded")
        try require(snapshot.events.contains { $0.message == "connected" }, "event should be recorded")
    }

    static func sessionRecorderRedactsAndClassifies() async throws {
        let recorder = SessionDiagnosticRecorder(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("iossim-poc-unit-\(UUID().uuidString)", isDirectory: true)
        )
        _ = await recorder.startSession(prefix: "UNIT")
        await recorder.record(
            category: "ERROR",
            component: "Pairing",
            previousState: "validating",
            newState: "failed",
            errorCode: "PAIRING_CREDENTIAL_MISSING",
            message: "private_key should not be persisted",
            metadata: ["detail": "psk material hidden"]
        )

        let snapshot = await recorder.snapshot()
        try require(snapshot.firstAbnormalEvent?.component == "Pairing", "first abnormal event recorded")
        let urls = await recorder.exportURLs()
        try require(urls.contains { $0.pathExtension == "jsonl" }, "jsonl export available")
        guard let logURL = urls.first(where: { $0.pathExtension == "jsonl" }) else {
            throw CheckError("missing jsonl url")
        }
        let text = try String(contentsOf: logURL, encoding: .utf8)
        try require(text.contains("[REDACTED]"), "sensitive message redacted")
        try require(!text.contains("private_key should not be persisted"), "raw sensitive message absent")
        try require(!text.contains("psk material hidden"), "raw sensitive metadata absent")
    }

    static func bridgeReportsUnavailableWhenIdeviceIsNotLinked() async throws {
        guard !IdeviceOnDeviceTunnelClient.ideviceLinked else {
            return
        }

        let bridge = IdeviceOnDeviceTunnelClient()
        do {
            try await bridge.connect(pairingData: try makePairingPlist(), endpoint: DeveloperEndpoint())
            throw CheckError("expected bridge unavailable error")
        } catch let error as POCError {
            try require(error.code == .ideviceBridgeUnavailable, "bridge unavailable error code")
        }
    }

    static func routeInterpolation() throws {
        let route = try testRoute()
        let midpoint = route.coordinate(atDistance: route.totalDistanceMeters / 2)
        try require(abs(midpoint.longitude - 0.005) < 0.001, "route midpoint should interpolate by distance")
        let projection = route.nearestProjection(to: CLLocationCoordinate2D(latitude: 0.001, longitude: 0.005))
        try require(abs(projection.distanceAlongRouteMeters - route.totalDistanceMeters / 2) < 25, "projection returns nearest route progress")
    }

    static func constantSpeedDistanceCalculations() throws {
        let controller = DriveSessionController(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let route = try driveRoute()
        controller.prepareRoute(route, speedMPH: 60)
        try controller.startDrive(now: 0)
        let position = try requireValue(controller.expectedPosition(now: 10), "position exists")
        try require(abs(position.expectedDistanceMeters - 268.224) < 1, "60 mph for 10s advances constant distance")
    }

    static func driveCadenceConfiguration() throws {
        try require(DriveUpdateCadence.baseline1Hz.intervalSeconds == 1, "baseline cadence is 1 Hz")
        try require(DriveUpdateCadence.smooth2Hz.intervalSeconds == 0.5, "smooth test cadence is 2 Hz")
        try require(DriveUpdateCadence.baseline1Hz.effectiveUpdateFrequencyHz == 1, "baseline frequency")
        try require(DriveUpdateCadence.smooth2Hz.effectiveUpdateFrequencyHz == 2, "smooth frequency")
    }

    static func absoluteDeadlineSchedulerCalculations() throws {
        let baseline = (0...3).map {
            DriveSchedulerTimeline.deadlineOffset(sequence: $0, intervalSeconds: DriveUpdateCadence.baseline1Hz.intervalSeconds)
        }
        try require(baseline == [0, 1, 2, 3], "1 Hz deadlines are absolute offsets")

        let smooth = (0...3).map {
            DriveSchedulerTimeline.deadlineOffset(sequence: $0, intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds)
        }
        try require(smooth == [0, 0.5, 1.0, 1.5], "2 Hz deadlines are absolute offsets")

        let deadlineAfterWork = DriveSchedulerTimeline.deadline(
            start: 10,
            sequence: 2,
            intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds
        )
        try require(deadlineAfterWork == 11.0, "work duration does not accumulate into absolute deadlines")
    }

    static func missedDeadlineCalculationsSkipReplay() throws {
        let next = DriveSchedulerTimeline.nextFutureSequence(
            start: 0,
            intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds,
            now: 1.38,
            minimumSequence: 2
        )
        try require(next == 3, "delayed wake selects next future deadline")

        let missed = DriveSchedulerTimeline.missedDeadlineCount(
            start: 0,
            intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds,
            now: 1.38,
            scheduledSequence: 1
        )
        try require(missed == 1, "missed intermediate deadlines are counted, not replayed")
    }

    static func cadenceDoesNotChangeRouteTraversalTime() throws {
        let route = try driveRoute()
        let speed = DriveSpeed.metersPerSecond(fromMPH: 35)
        let expectedTraversal = route.routeDistanceMeters / speed
        let baselineTicks = expectedTraversal / DriveUpdateCadence.baseline1Hz.intervalSeconds
        let smoothTicks = expectedTraversal / DriveUpdateCadence.smooth2Hz.intervalSeconds
        try require(abs((smoothTicks / baselineTicks) - 2) < 0.001, "2 Hz doubles update count only")

        let baselineController = DriveSessionController()
        baselineController.prepareRoute(route, speedMPH: 35)
        try baselineController.startDrive(now: 0)
        let smoothController = DriveSessionController()
        smoothController.prepareRoute(route, speedMPH: 35)
        try smoothController.startDrive(now: 0)
        let baselinePosition = try requireValue(baselineController.expectedPosition(now: 12), "baseline position")
        let smoothPosition = try requireValue(smoothController.expectedPosition(now: 12), "smooth position")
        try require(abs(baselinePosition.expectedDistanceMeters - smoothPosition.expectedDistanceMeters) < 0.001, "same active elapsed gives same route distance regardless of cadence")
    }

    static func spatialStepAt35MPH() throws {
        let speed = DriveSpeed.metersPerSecond(fromMPH: 35)
        let baselineStep = DriveUpdateCadence.baseline1Hz.expectedDistancePerUpdateMeters(speedMetersPerSecond: speed)
        let smoothStep = DriveUpdateCadence.smooth2Hz.expectedDistancePerUpdateMeters(speedMetersPerSecond: speed)
        try require(abs(baselineStep - 15.6464) < 0.01, "35 mph at 1 Hz is about 15.65m per update")
        try require(abs(smoothStep - 7.8232) < 0.01, "35 mph at 2 Hz is about 7.82m per update")
        try require(abs((baselineStep / smoothStep) - 2) < 0.001, "2 Hz halves spatial step")
    }

    static func pauseDoesNotAdvanceRouteProgress() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        let paused = try requireValue(controller.pause(now: 10), "paused position")
        let later = try requireValue(controller.expectedPosition(now: 30), "paused later")
        try require(abs(paused.expectedDistanceMeters - later.expectedDistanceMeters) < 0.1, "paused progress must not advance")
    }

    static func resumeUsesActiveElapsedTime() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        _ = controller.pause(now: 10)
        controller.resume(now: 30)
        let position = try requireValue(controller.expectedPosition(now: 40), "resumed position")
        let expected = DriveSpeed.metersPerSecond(fromMPH: 30) * 20
        try require(abs(position.expectedDistanceMeters - expected) < 1, "resume excludes paused duration")
    }

    static func pauseResumeDeadlineCalculations() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        let beforePause = try requireValue(controller.expectedPosition(now: 10), "before pause")
        _ = controller.pause(now: 10)
        let duringPause = try requireValue(controller.expectedPosition(now: 90), "during pause")
        try require(abs(beforePause.expectedDistanceMeters - duringPause.expectedDistanceMeters) < 0.001, "pause stops route progress")
        controller.resume(now: 90)
        let resumedDeadline = DriveSchedulerTimeline.deadline(
            start: 90,
            sequence: 1,
            intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds
        )
        try require(resumedDeadline == 90.5, "resume establishes future absolute deadline without catch-up")
        let afterResume = try requireValue(controller.expectedPosition(now: 90.5), "after resume")
        try require(afterResume.expectedDistanceMeters >= duringPause.expectedDistanceMeters, "resume remains monotonic")
    }

    static func backgroundDelayCalculationsCollapseMissedTicks() throws {
        let next = DriveSchedulerTimeline.nextFutureSequence(
            start: 0,
            intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds,
            now: 2.0,
            minimumSequence: 1
        )
        try require(next == 5, "2s delay at 2 Hz skips to next future deadline")
        let missed = DriveSchedulerTimeline.missedDeadlineCount(
            start: 0,
            intervalSeconds: DriveUpdateCadence.smooth2Hz.intervalSeconds,
            now: 2.0,
            scheduledSequence: 1
        )
        try require(missed == 3, "background delay collapses missed deadlines into one current tick")
    }

    static func suspensionTickSkipsMissedPoints() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 45)
        try controller.startDrive(now: 0)
        let first = try requireValue(controller.expectedPosition(now: 1), "first")
        let delayed = try requireValue(controller.expectedPosition(now: 9), "delayed")
        let expected = DriveSpeed.metersPerSecond(fromMPH: 45) * 9
        try require(delayed.expectedDistanceMeters > first.expectedDistanceMeters, "delayed tick advances")
        try require(abs(delayed.expectedDistanceMeters - expected) < 1, "delayed tick jumps to elapsed-time position")
    }

    static func monotonicRouteProgression() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 45)
        try controller.startDrive(now: 10)
        let later = try requireValue(controller.expectedPosition(now: 20), "later")
        let earlier = try requireValue(controller.expectedPosition(now: 12), "earlier")
        try require(earlier.expectedDistanceMeters >= later.expectedDistanceMeters, "route progress never regresses while driving")
    }

    static func completedHoldingDoesNotClearSimulation() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 70)
        try controller.startDrive(now: 0)
        let complete = try requireValue(controller.expectedPosition(now: 10_000), "complete")
        try require(complete.completed, "route completes")
        _ = controller.completeHolding(now: 10_000)
        try require(controller.currentState() == .completedHolding, "destination held after completion")
    }

    static func staleWriterCannotSendAfterOwnershipChanges() async throws {
        let tunnel = MockTunnelClient()
        let store = InMemoryRPPairingStore(data: try makePairingPlist())
        let recorder = testRecorder()
        _ = await recorder.startSession(prefix: "UNIT")
        let coordinator = LocationCoordinator(pairingStore: store, tunnelClient: tunnel, recorder: recorder)
        try await coordinator.startSimulation(writerID: "static:old", mode: .staticLocation(nil))
        try await coordinator.startSimulation(writerID: "drive:new", mode: .drive(sessionID: UUID(), current: nil))
        do {
            try await coordinator.updateLocation(latitude: 1, longitude: 1, writerID: "static:old")
            throw CheckError("expected stale writer")
        } catch let error as POCError {
            try require(error.code == .staleWriter, "stale writer rejected")
        }
        let count = await tunnel.setCount()
        try require(count == 0, "stale writer did not issue native set")
        let urls = await recorder.exportURLs()
        let jsonl = try requireValue(urls.first(where: { $0.pathExtension == "jsonl" }), "stale writer jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        try require(text.contains("SIMULATION_OWNER_CHANGED"), "owner change serialized")
        try require(text.contains("STALE_WRITER_UPDATE_IGNORED"), "stale writer event serialized")
    }

    static func staleGenerationCallbackCannotAffectCurrentConnection() async throws {
        let tunnel = MockTunnelClient()
        let recorder = testRecorder()
        _ = await recorder.startSession(prefix: "UNIT")
        let coordinator = LocationCoordinator(
            pairingStore: InMemoryRPPairingStore(data: try makePairingPlist()),
            tunnelClient: tunnel,
            recorder: recorder
        )
        try await coordinator.startSimulation(writerID: "drive:1", mode: .drive(sessionID: UUID(), current: nil))
        let firstGeneration = await coordinator.currentConnectionGeneration()
        await tunnel.forceState(.disconnected)
        await coordinator.reconnectIfNeeded()
        let secondGeneration = await coordinator.currentConnectionGeneration()
        try require(secondGeneration > firstGeneration, "reconnect increments generation")
        await coordinator.handleConnectionLost(generation: firstGeneration, reason: "unit stale callback")
        let currentGeneration = await coordinator.currentConnectionGeneration()
        let currentState = await coordinator.currentConnectionState()
        try require(currentGeneration == secondGeneration, "stale generation ignored")
        try require(currentState == .connected, "current connection remains connected")
        let urls = await recorder.exportURLs()
        let jsonl = try requireValue(urls.first(where: { $0.pathExtension == "jsonl" }), "stale generation jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        try require(text.contains("STALE_GENERATION_EVENT_IGNORED"), "stale generation event serialized")
    }

    static func reconnectRestoresCurrentDrivePosition() async throws {
        let tunnel = MockTunnelClient()
        let coordinator = LocationCoordinator(
            pairingStore: InMemoryRPPairingStore(data: try makePairingPlist()),
            tunnelClient: tunnel,
            recorder: testRecorder()
        )
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 60)
        try controller.startDrive(now: 0)
        try await coordinator.startSimulation(writerID: controller.writerID, mode: .drive(sessionID: controller.sessionID, current: nil))
        await coordinator.setReconnectRestoreProvider(writerID: controller.writerID) {
            SimulatedCoordinate(controller.expectedPosition(now: 20)!.coordinate)
        }
        await tunnel.forceState(.disconnected)
        await coordinator.reconnectIfNeeded()
        let set = try requireValue(await tunnel.sets.last, "restored set exists")
        let restored = controller.expectedPosition(now: 20)!.coordinate
        try require(abs(set.latitude - restored.latitude) < 0.0001, "reconnect restores current route latitude")
        try require(abs(set.longitude - restored.longitude) < 0.0001, "reconnect restores current route longitude")
    }

    static func stopPreventsDelayedWrites() async throws {
        let tunnel = MockTunnelClient()
        let coordinator = LocationCoordinator(
            pairingStore: InMemoryRPPairingStore(data: try makePairingPlist()),
            tunnelClient: tunnel,
            recorder: testRecorder()
        )
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        try await coordinator.startSimulation(writerID: controller.writerID, mode: .drive(sessionID: controller.sessionID, current: nil))
        try await coordinator.stopSimulation(writerID: controller.writerID, clearLocation: true)
        do {
            try await coordinator.updateLocation(latitude: 0, longitude: 0.001, writerID: controller.writerID)
            throw CheckError("expected stopped writer failure")
        } catch let error as POCError {
            try require(error.code == .staleWriter, "stopped writer cannot write")
        }
        let setCount = await tunnel.setCount()
        let clearCount = await tunnel.totalClearCount()
        try require(setCount == 0, "no delayed set after stop")
        try require(clearCount == 1, "stop clears exactly once")
    }

    static func routeDistanceClamping() throws {
        let route = try testRoute()
        let before = route.coordinate(atDistance: -100)
        let after = route.coordinate(atDistance: route.totalDistanceMeters + 10_000)
        try require(abs(before.longitude) < 0.0001, "negative distance clamps to origin")
        try require(abs(after.longitude - 0.01) < 0.0001, "overshoot clamps to destination")
    }

    static func driveDiagnosticsSerialize() async throws {
        let recorder = testRecorder()
        let diagnostics = DriveDiagnostics(recorder: recorder)
        let route = try testRoute()
        await diagnostics.start(sessionID: UUID(), writerID: "drive:unit", route: route)
        await diagnostics.recordRequestedUpdate(
            sequenceNumber: 1,
            tickNumber: 1,
            monotonicElapsedTime: 1,
            connectionGeneration: 3,
            expectedRouteDistanceMeters: 10,
            expectedCoordinate: route.coordinate(atDistance: 10),
            requestedCoordinate: route.coordinate(atDistance: 10),
            calculatedRouteSpeedMetersPerSecond: 10,
            observed: LocationObservation(
                latitude: 0,
                longitude: 0.0001,
                horizontalAccuracy: 5,
                verticalAccuracy: 8,
                speed: 10,
                speedAccuracy: 1,
                course: 90,
                courseAccuracy: 3,
                locationTimestamp: Date(),
                isSimulatedBySoftware: true,
                isProducedByAccessory: false
            ),
            applicationLifecycleState: "foreground",
            backgroundSessionActive: true
        )
        let urls = await diagnostics.exportURLs()
        let jsonl = try requireValue(urls.first(where: { $0.pathExtension == "jsonl" }), "drive jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        try require(text.contains("DRIVE_LOCATION_UPDATE"), "drive event serialized")
        try require(text.contains("connection_generation"), "generation serialized")
        try require(text.contains("cllocation_speed_mps"), "speed serialized")
    }

    static func driveTraceMetricCalculations() throws {
        try require(DriveTraceMetrics.schedulerWakeJitterMs(expectedWake: 1, actualWake: 1.25) == 250, "scheduler jitter calculated")
        let stats = DriveTraceMetrics.timingStatistics(milliseconds: [100, 200, 300, 400])
        try require(stats.count == 4, "statistics count")
        try require(stats.meanMs == 250, "statistics mean")
        try require(stats.medianMs == 250, "statistics median")
        try require(abs((stats.p95Ms ?? 0) - 385) < 0.01, "statistics p95")
        try require(DriveTraceMetrics.durationMs(begin: 10, end: 10.25) == 250, "DVT latency duration")
        try require(abs(DriveTraceMetrics.durationMs(begin: 20, end: 20.4) - 400) < 0.01, "Core Location propagation duration")
        try require(DriveTraceMetrics.validCLLocationSpeed(12), "valid speed accepted")
        try require(!DriveTraceMetrics.validCLLocationSpeed(-1), "invalid speed rejected")
        try require(DriveTraceMetrics.speedMetersPerSecond(distanceDeltaMeters: 30, elapsedSeconds: 3) == 10, "geometric speed")
        let bearing = try requireValue(DriveTraceMetrics.bearingDegrees(
            from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            to: CLLocationCoordinate2D(latitude: 0, longitude: 1)
        ), "bearing")
        try require(abs(bearing - 90) < 0.01, "bearing east")
        try require(DriveTraceMetrics.isSchedulerStall(intervalMs: 2600, targetIntervalMs: 1000), "scheduler stall detected")
        try require(DriveTraceMetrics.isDVTSetStall(durationMs: 1000), "DVT stall detected")
        try require(DriveTraceMetrics.isCoreLocationObservationStall(intervalMs: 4000), "CL stall detected")
        try require(DriveTraceMetrics.isBurstyProgress(
            actualDistanceDelta: 90,
            expectedDistanceDelta: 20,
            previousTickIntervalMs: 3000,
            targetIntervalMs: 1000
        ), "bursty progress detected")
    }

    static func driveDiagnosticsTraceSerializationAndSummary() async throws {
        let recorder = testRecorder()
        let diagnostics = DriveDiagnostics(recorder: recorder, sampleLimit: 3)
        let route = try testRoute()
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        await diagnostics.start(
            sessionID: sessionID,
            writerID: "drive:trace",
            route: route,
            selectedSpeedMps: 10,
            updateCadence: .smooth2Hz
        )
        for tick in 1...5 {
            let actualOffset = Double(tick - 1)
            let coordinate = route.coordinate(atDistance: Double(tick) * 10)
            await diagnostics.recordSchedulerTick(
                tickTraceID: "trace-\(tick)",
                tickSequence: tick,
                monotonicTimestamp: actualOffset,
                expectedTickOffset: actualOffset,
                actualTickOffset: actualOffset,
                previousActualTickOffset: tick == 1 ? nil : Double(tick - 2),
                activeElapsedSeconds: actualOffset,
                expectedRouteDistanceMeters: Double(tick) * 10,
                previousExpectedRouteDistanceMeters: tick == 1 ? nil : Double(tick - 1) * 10,
                selectedSpeedMetersPerSecond: 10,
                expectedCoordinate: coordinate,
                previousExpectedCoordinate: tick == 1 ? nil : route.coordinate(atDistance: Double(tick - 1) * 10),
                lifecycleState: tick < 4 ? "foreground" : "background",
                connectionGeneration: 2,
                updateCadence: .smooth2Hz,
                missedDeadlineCount: 0
            )
        }
        let context = DriveTraceContext(
            tickTraceID: "trace-5",
            driveSessionID: sessionID.uuidString,
            tickSequence: 5,
            requestSequence: 5,
            updateRequestMonotonicTime: 100,
            expectedRouteDistanceMeters: 50,
            previousExpectedRouteDistanceMeters: 40,
            expectedCoordinate: route.coordinate(atDistance: 50),
            selectedSpeedMetersPerSecond: 10,
            lifecycleState: "background"
        )
        await diagnostics.recordCoordinatorUpdateRequested(context: context, writerID: "drive:trace", connectionGeneration: 2)
        await diagnostics.recordCoordinatorUpdateEntered(context: context, writerID: "drive:trace", connectionGeneration: 2, enteredMonotonicTime: 100.02)
        await diagnostics.recordDVTSetBegin(context: context, writerID: "drive:trace", connectionGeneration: 2, beginMonotonicTime: 100.03)
        await diagnostics.recordDVTSetEnd(
            context: context,
            writerID: "drive:trace",
            connectionGeneration: 2,
            beginMonotonicTime: 100.03,
            endMonotonicTime: 100.04,
            success: true,
            nativeErrorCategory: nil
        )
        await diagnostics.recordObservation(
            LocationObservation(
                latitude: route.coordinate(atDistance: 50).latitude,
                longitude: route.coordinate(atDistance: 50).longitude,
                horizontalAccuracy: 5,
                verticalAccuracy: 6,
                altitude: 11,
                speed: 9.5,
                speedAccuracy: 1,
                course: 89,
                courseAccuracy: 2,
                locationTimestamp: Date(),
                isSimulatedBySoftware: true,
                isProducedByAccessory: false
            ),
            applicationLifecycleState: "background",
            backgroundSessionActive: true,
            connectionGeneration: 2
        )
        let summary = await diagnostics.finalizeSummary()
        try require(summary.totalSchedulerTicks == 5, "summary counts scheduler ticks even with bounded samples")
        try require(summary.totalDVTSetCalls == 1, "summary counts DVT calls")
        try require(summary.totalObservedCLLocations == 1, "summary counts observations")
        try require(summary.updateCadenceName == DriveUpdateCadence.smooth2Hz.diagnosticName, "cadence metadata in summary")
        try require(summary.targetIntervalMs == 500, "target interval in summary")
        try require(summary.effectiveUpdateFrequencyHz == 2, "effective update frequency in summary")
        try require(summary.schedulerIntervals.count == 3, "bounded scheduler interval sample")
        try require(summary.expectedDistanceDeltaPerTickMeters.count == 3, "bounded spatial step sample")
        try require(summary.expectedDistanceDeltaPerTickMeters.meanMs == 10, "spatial step statistics preserved")
        try require(summary.foregroundSchedulerIntervals.count > 0, "foreground segmentation")
        try require(summary.backgroundSchedulerIntervals.count > 0, "background segmentation")
        try require(summary.percentageOfCLLocationsWithValidSpeed == 100, "valid CLLocation.speed percentage")
        try require(summary.percentageOfCLLocationsWithValidCourse == 100, "valid CLLocation.course percentage")
        try require(summary.diagnosticEventsWritten > 0, "diagnostic write count present")
        try require(summary.diagnosticFlushCount > 0, "diagnostic flush count present")
        let urls = await diagnostics.exportURLs()
        let jsonl = try requireValue(urls.first(where: { $0.pathExtension == "jsonl" }), "trace jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        try require(text.contains("SCHEDULER_TICK"), "scheduler tick serialized")
        try require(text.contains("COORDINATOR_UPDATE_REQUESTED"), "coordinator request serialized")
        try require(text.contains("COORDINATOR_UPDATE_ENTERED"), "coordinator entry serialized")
        try require(text.contains("DVT_SET_BEGIN"), "DVT begin serialized")
        try require(text.contains("DVT_SET_END"), "DVT end serialized")
        try require(text.contains("CLLOCATION_OBSERVED"), "CL observation serialized")
        try require(text.contains("DRIVE_CHARACTERIZATION_SUMMARY"), "summary serialized")
        try require(text.contains("trace-5"), "trace ID propagated")
        try require(text.contains("corelocation_propagation_latency_ms"), "propagation latency field serialized")
        try require(text.contains("update_cadence_name"), "cadence metadata serialized")
        try require(text.contains("mean_expected_distance_delta_per_tick_m"), "spatial metric serialized")
        try require(text.contains("percentage_cllocations_with_valid_course"), "course percentage serialized")
        try require(text.contains("diagnostic_flush_count"), "diagnostic overhead serialized")
    }

    static func driveDiagnosticsDetectorEvents() async throws {
        let recorder = testRecorder()
        let diagnostics = DriveDiagnostics(recorder: recorder)
        let route = try testRoute()
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        await diagnostics.start(sessionID: sessionID, writerID: "drive:detectors", route: route, selectedSpeedMps: 10)
        await diagnostics.recordSchedulerTick(
            tickTraceID: "trace-stall",
            tickSequence: 2,
            monotonicTimestamp: 3,
            expectedTickOffset: 1,
            actualTickOffset: 3,
            previousActualTickOffset: 0,
            activeElapsedSeconds: 3,
            expectedRouteDistanceMeters: 80,
            previousExpectedRouteDistanceMeters: 10,
            selectedSpeedMetersPerSecond: 10,
            expectedCoordinate: route.coordinate(atDistance: 80),
            previousExpectedCoordinate: route.coordinate(atDistance: 10),
            lifecycleState: "background",
            connectionGeneration: 4,
            updateCadence: .baseline1Hz,
            missedDeadlineCount: 1
        )
        let context = DriveTraceContext(
            tickTraceID: "trace-stale",
            driveSessionID: sessionID.uuidString,
            tickSequence: 3,
            requestSequence: 3,
            updateRequestMonotonicTime: 5,
            expectedRouteDistanceMeters: 100,
            previousExpectedRouteDistanceMeters: 80,
            expectedCoordinate: route.coordinate(atDistance: 100),
            selectedSpeedMetersPerSecond: 10,
            lifecycleState: "foreground"
        )
        await diagnostics.recordCoordinatorUpdateRequested(context: context, writerID: "drive:detectors", connectionGeneration: 4)
        await diagnostics.recordDVTSetBegin(context: context, writerID: "drive:detectors", connectionGeneration: 4, beginMonotonicTime: 5)
        await diagnostics.recordDVTSetEnd(
            context: context,
            writerID: "drive:detectors",
            connectionGeneration: 4,
            beginMonotonicTime: 5,
            endMonotonicTime: 6,
            success: true,
            nativeErrorCategory: nil
        )
        await diagnostics.recordObservation(
            LocationObservation(
                latitude: route.coordinate(atDistance: 120).latitude,
                longitude: route.coordinate(atDistance: 120).longitude,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                speed: nil,
                speedAccuracy: nil,
                course: nil,
                courseAccuracy: nil,
                locationTimestamp: Date(),
                isSimulatedBySoftware: true,
                isProducedByAccessory: false
            ),
            applicationLifecycleState: "foreground",
            backgroundSessionActive: false,
            connectionGeneration: 4
        )
        await diagnostics.recordObservation(
            LocationObservation(
                latitude: route.coordinate(atDistance: 10).latitude,
                longitude: route.coordinate(atDistance: 10).longitude,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                speed: nil,
                speedAccuracy: nil,
                course: nil,
                courseAccuracy: nil,
                locationTimestamp: Date(),
                isSimulatedBySoftware: true,
                isProducedByAccessory: false
            ),
            applicationLifecycleState: "foreground",
            backgroundSessionActive: false,
            connectionGeneration: 4
        )
        let summary = await diagnostics.finalizeSummary()
        try require(summary.schedulerStallCount == 1, "scheduler stall counted")
        try require(summary.dvtSetStallCount == 1, "DVT stall counted")
        try require(summary.burstyProgressCount == 1, "burst counted")
        try require(summary.snapBackCount == 1, "snap-back counted")
        try require(summary.percentageOfCLLocationsWithValidSpeed == 0, "invalid native speed remains represented")
        try require(summary.percentageOfCLLocationsWithValidCourse == 0, "invalid native course remains represented")
        let urls = await diagnostics.exportURLs()
        let jsonl = try requireValue(urls.first(where: { $0.pathExtension == "jsonl" }), "detector jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        try require(text.contains("SCHEDULER_STALL"), "scheduler stall serialized")
        try require(text.contains("DVT_SET_STALL"), "DVT stall serialized")
        try require(text.contains("BURSTY_PROGRESS"), "burst serialized")
        try require(text.contains("POSSIBLE_SNAP_BACK"), "snap-back serialized")
        try require(text.contains("tick_trace_id"), "snap-back enrichment includes trace field")
    }

    static func sessionRecorderBatchesAndTransitions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-recorder-unit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = SessionDiagnosticRecorder(
            baseDirectory: directory,
            eventLimit: 3,
            flushEveryEvents: 3
        )
        _ = await recorder.startSession(prefix: "UNITA")
        for index in 1...5 {
            await recorder.record(
                category: "ORDER",
                component: "Test",
                newState: "event_\(index)",
                message: "event \(index)"
            )
        }
        var snapshot = await recorder.snapshot()
        try require(snapshot.eventCount == 6, "total event count includes bounded-out events")
        try require(snapshot.diagnosticEventsWritten == 6, "all events written to JSONL")
        try require(snapshot.diagnosticFlushCount >= 2, "batched flushes recorded")
        try require(snapshot.retainedJSONLHandleOpen, "retained handle stays open during session")
        let recentTimelineCount = await recorder.recentTimeline(limit: 10).count
        try require(recentTimelineCount == 3, "recent timeline is bounded")

        let firstURLs = await recorder.exportURLs()
        let firstJSONL = try requireValue(firstURLs.first(where: { $0.pathExtension == "jsonl" }), "first jsonl")
        let firstText = try String(contentsOf: firstJSONL, encoding: .utf8)
        let event1Range = try requireValue(firstText.range(of: "event_1"), "first event serialized")
        let event5Range = try requireValue(firstText.range(of: "event_5"), "last event serialized")
        try require(event1Range.lowerBound < event5Range.lowerBound, "JSONL event order preserved")
        try require(firstURLs.contains { $0.lastPathComponent.contains("summary") }, "summary export available")

        await recorder.endSession(reason: "unit transition")
        snapshot = await recorder.snapshot()
        try require(!snapshot.retainedJSONLHandleOpen, "retained handle closes at endSession")

        _ = await recorder.startSession(prefix: "UNITB")
        await recorder.record(category: "NEW_SESSION_ONLY", component: "Test", newState: "new")
        let secondURLs = await recorder.exportURLs()
        let secondJSONL = try requireValue(secondURLs.first(where: { $0.pathExtension == "jsonl" }), "second jsonl")
        let oldAfterTransition = try String(contentsOf: firstJSONL, encoding: .utf8)
        let secondText = try String(contentsOf: secondJSONL, encoding: .utf8)
        try require(!oldAfterTransition.contains("NEW_SESSION_ONLY"), "session transition does not append to previous file")
        try require(secondText.contains("NEW_SESSION_ONLY"), "new session writes to new file")
    }

    static func makePairingPlist(identifier: String = "12345678-1234-1234-1234-123456789abc", omit: String? = nil) throws -> Data {
        var plist: [String: Any] = [
            "public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32),
            "identifier": identifier,
            "alt_irk": Data(repeating: 3, count: 16)
        ]
        if let omit {
            plist.removeValue(forKey: omit)
        }
        return try plistData(plist)
    }

    static func plistData(_ plist: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func expectThrows(_ body: () throws -> Void) throws {
        do {
            try body()
            throw CheckError("expected throw")
        } catch is CheckError {
            throw CheckError("expected throw")
        } catch {
            return
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw CheckError(message)
        }
    }

    static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckError(message)
        }
        return value
    }

    // MARK: - Location product-surface pure logic (SavedPlace.swift)

    static func coordinateParsingAcceptsValidPairs() throws {
        let a = try requireValue(CoordinateParsing.parse("40.7580,-73.9855"), "plain pair should parse")
        try require(abs(a.latitude - 40.7580) < 0.0001, "latitude parsed")
        try require(abs(a.longitude - (-73.9855)) < 0.0001, "longitude parsed")

        let b = try requireValue(CoordinateParsing.parse(" 40.7580 , -73.9855 "), "pair with whitespace should parse")
        try require(abs(b.latitude - 40.7580) < 0.0001, "latitude parsed with whitespace")

        let boundary = try requireValue(CoordinateParsing.parse("90,-180"), "boundary values should parse")
        try require(boundary.latitude == 90 && boundary.longitude == -180, "boundary values exact")
    }

    static func coordinateParsingRejectsOutOfRangeAndMalformedText() throws {
        try require(CoordinateParsing.parse("Times Square") == nil, "place name is not a coordinate")
        try require(CoordinateParsing.parse("91,0") == nil, "latitude out of range rejected")
        try require(CoordinateParsing.parse("0,181") == nil, "longitude out of range rejected")
        try require(CoordinateParsing.parse("40.75") == nil, "single value rejected")
        try require(CoordinateParsing.parse("40.75,-73.98,extra") == nil, "extra component rejected")
        try require(CoordinateParsing.parse("") == nil, "empty text rejected")
    }

    /// Regression check for the Bug A fix: `MapKitSearchProvider.coordinate(for:)`
    /// must still short-circuit a raw "lat,lon" pair before falling through to
    /// an MKLocalSearch network lookup, and a business/POI name like "Popeyes"
    /// must not be mistaken for a coordinate pair.
    static func mapKitSearchProviderParsesCoordinatesWithoutNetworkLookup() throws {
        let coordinate = try requireValue(
            MapKitSearchProvider.parseCoordinate("40.7580,-73.9855"),
            "plain pair should parse"
        )
        try require(abs(coordinate.latitude - 40.7580) < 0.0001, "latitude parsed")
        try require(abs(coordinate.longitude - (-73.9855)) < 0.0001, "longitude parsed")
        try require(MapKitSearchProvider.parseCoordinate("Popeyes") == nil, "business name is not a coordinate")
    }

    static func recentsListDedupesNearbyPlacesAndMovesToFront() throws {
        let timesSquare = SavedPlace(name: "Times Square", latitude: 40.7580, longitude: -73.9855)
        let centralPark = SavedPlace(name: "Central Park", latitude: 40.7851, longitude: -73.9683)
        var list = RecentsList.inserting(timesSquare, into: [], limit: 20)
        list = RecentsList.inserting(centralPark, into: list, limit: 20)
        try require(list.count == 2, "two distinct places kept")
        try require(list.first?.name == "Central Park", "most recent is first")

        // Re-visiting a near-duplicate coordinate should move it to the front,
        // not create a second entry.
        let timesSquareAgain = SavedPlace(name: "Times Square", latitude: 40.75801, longitude: -73.98551)
        list = RecentsList.inserting(timesSquareAgain, into: list, limit: 20)
        try require(list.count == 2, "near-duplicate does not grow the list")
        try require(list.first?.name == "Times Square", "re-visited place moves to front")
    }

    static func recentsListCapsAtLimit() throws {
        var list: [SavedPlace] = []
        for index in 0..<25 {
            let place = SavedPlace(name: "Place \(index)", latitude: Double(index), longitude: Double(index))
            list = RecentsList.inserting(place, into: list, limit: 20)
        }
        try require(list.count == 20, "list capped at limit")
        try require(list.first?.name == "Place 24", "newest place kept at front")
        try require(!list.contains { $0.name == "Place 0" }, "oldest place evicted")
    }

    static func jsonFilePlaceStoreRoundTripsAndOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONFilePlaceStore(fileName: "favorites.json", directory: directory)
        try require(store.load().isEmpty, "new store starts empty")

        let places = [
            SavedPlace(name: "Times Square", latitude: 40.7580, longitude: -73.9855),
            SavedPlace(name: "Golden Gate Bridge", latitude: 37.8199, longitude: -122.4783)
        ]
        store.save(places)

        let reloaded = JSONFilePlaceStore(fileName: "favorites.json", directory: directory)
        let loaded = reloaded.load()
        try require(loaded.count == 2, "round trip preserves count")
        try require(loaded.map(\.name) == ["Times Square", "Golden Gate Bridge"], "round trip preserves order")

        store.save([places[0]])
        let afterOverwrite = JSONFilePlaceStore(fileName: "favorites.json", directory: directory).load()
        try require(afterOverwrite.count == 1, "save overwrites rather than appends")
    }

    static func testRoute() throws -> RouteResampler {
        try RouteResampler(coordinates: [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        ])
    }

    static func driveRoute() throws -> DriveRoute {
        let resampler = try testRoute()
        return DriveRoute(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            resampler: resampler,
            expectedTravelTime: 120
        )
    }

    static func testRecorder() -> SessionDiagnosticRecorder {
        SessionDiagnosticRecorder(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("iossim-drive-unit-\(UUID().uuidString)", isDirectory: true)
        )
    }
}

struct CheckError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct FakeInterfaces: InterfaceSnapshotProvider {
    let values: [NetworkInterfaceSnapshot]

    func snapshots() -> [NetworkInterfaceSnapshot] {
        values
    }
}

private struct FakeTCPProber: TCPProbing {
    let result: TCPProbeResult

    func probe(endpoint: DeveloperEndpoint, timeout: TimeInterval) async -> TCPProbeResult {
        result
    }
}

private actor MockTunnelClient: OnDeviceTunnelClient {
    private var state: TunnelState = .disconnected
    private(set) var sets: [(latitude: Double, longitude: Double)] = []
    private(set) var clearCount = 0
    private var connectCount = 0

    func connect(pairingData: Data, endpoint: DeveloperEndpoint) async throws {
        connectCount += 1
        state = .locationSimulationConnected
    }

    func set(latitude: Double, longitude: Double) async throws {
        guard state == .locationSimulationConnected || state == .simulating else {
            throw POCError(.disconnected, "mock disconnected")
        }
        sets.append((latitude, longitude))
        state = .simulating
    }

    func clear() async throws {
        clearCount += 1
        state = .disconnected
    }

    func disconnect() async {
        state = .disconnected
    }

    func status() async -> DvtBridgeStatus {
        DvtBridgeStatus(
            state: state,
            endpoint: DeveloperEndpoint(),
            ideviceLinked: true,
            timings: [],
            lastError: nil
        )
    }

    func forceState(_ state: TunnelState) {
        self.state = state
    }

    func setCount() -> Int {
        sets.count
    }

    func totalClearCount() -> Int {
        clearCount
    }
}
