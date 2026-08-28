import CoreLocation
import Foundation

public struct LocationObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let speed: Double?
    public let speedAccuracy: Double?
    public let course: Double?
    public let courseAccuracy: Double?
    public let locationTimestamp: Date
    public let isSimulatedBySoftware: Bool?
    public let isProducedByAccessory: Bool?
    public let requestedLatitude: Double?
    public let requestedLongitude: Double?
    public let distanceMetersFromRequested: Double?
    public let classification: String?

    public init(
        id: UUID = UUID(),
        observedAt: Date = Date(),
        location: CLLocation,
        requestedLatitude: Double? = nil,
        requestedLongitude: Double? = nil,
        toleranceMeters: CLLocationDistance = 75
    ) {
        self.id = id
        self.observedAt = observedAt
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.speed = location.speed >= 0 ? location.speed : nil
        if #available(iOS 10.0, macOS 10.15, *) {
            self.speedAccuracy = location.speedAccuracy >= 0 ? location.speedAccuracy : nil
        } else {
            self.speedAccuracy = nil
        }
        self.course = location.course >= 0 ? location.course : nil
        if #available(iOS 13.4, macOS 10.15, *) {
            self.courseAccuracy = location.courseAccuracy >= 0 ? location.courseAccuracy : nil
        } else {
            self.courseAccuracy = nil
        }
        self.locationTimestamp = location.timestamp
        if #available(iOS 15.0, macOS 12.0, *) {
            self.isSimulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware
            self.isProducedByAccessory = location.sourceInformation?.isProducedByAccessory
        } else {
            self.isSimulatedBySoftware = nil
            self.isProducedByAccessory = nil
        }
        self.requestedLatitude = requestedLatitude
        self.requestedLongitude = requestedLongitude
        if let requestedLatitude, let requestedLongitude {
            let distance = Self.distanceMeters(
                fromLatitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                toLatitude: requestedLatitude,
                longitude: requestedLongitude
            )
            self.distanceMetersFromRequested = distance
            if distance <= toleranceMeters, self.isSimulatedBySoftware == true {
                self.classification = "EXPECTED_SIMULATED_LOCATION"
            } else if self.isSimulatedBySoftware == true {
                self.classification = "OTHER_LOCATION"
            } else {
                self.classification = "REAL_LOCATION"
            }
        } else {
            self.distanceMetersFromRequested = nil
            self.classification = "NO_LOCATION"
        }
    }

    public init(
        id: UUID = UUID(),
        observedAt: Date = Date(),
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double? = nil,
        speedAccuracy: Double? = nil,
        course: Double? = nil,
        courseAccuracy: Double? = nil,
        locationTimestamp: Date,
        isSimulatedBySoftware: Bool?,
        isProducedByAccessory: Bool?,
        requestedLatitude: Double? = nil,
        requestedLongitude: Double? = nil,
        distanceMetersFromRequested: Double? = nil,
        classification: String? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.locationTimestamp = locationTimestamp
        self.isSimulatedBySoftware = isSimulatedBySoftware
        self.isProducedByAccessory = isProducedByAccessory
        self.requestedLatitude = requestedLatitude
        self.requestedLongitude = requestedLongitude
        self.distanceMetersFromRequested = distanceMetersFromRequested
        self.classification = classification
    }

    private static func distanceMeters(
        fromLatitude: Double,
        longitude fromLongitude: Double,
        toLatitude: Double,
        longitude toLongitude: Double
    ) -> CLLocationDistance {
        let a = CLLocation(latitude: fromLatitude, longitude: fromLongitude)
        let b = CLLocation(latitude: toLatitude, longitude: toLongitude)
        return a.distance(from: b)
    }
}

public final class CoreLocationVerifier: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var observations: [LocationObservation] = []
    private var waiters: [LocationWaiter] = []
    private var requestedLatitude: Double?
    private var requestedLongitude: Double?
    private var lastLoggedObservation: LocationObservation?
    private var observationHandler: (@Sendable (LocationObservation) -> Void)?
    private let duplicateMinimumInterval: TimeInterval = 1.0
    private let duplicateMinimumDistance: CLLocationDistance = 10

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public func start(backgroundCapable: Bool = false) {
        manager.requestWhenInUseAuthorization()
        #if os(iOS)
        if backgroundCapable {
            manager.requestAlwaysAuthorization()
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        #endif
        manager.startUpdatingLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
    }

    public func allObservations() -> [LocationObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    public func latestObservation() -> LocationObservation? {
        lock.lock()
        defer { lock.unlock() }
        return observations.last
    }

    public func setObservationHandler(_ handler: (@Sendable (LocationObservation) -> Void)?) {
        lock.lock()
        observationHandler = handler
        lock.unlock()
    }

    public func setRequestedCoordinate(latitude: Double, longitude: Double) {
        lock.lock()
        requestedLatitude = latitude
        requestedLongitude = longitude
        lock.unlock()
    }

    public func waitForCoordinate(
        latitude: Double,
        longitude: Double,
        toleranceMeters: CLLocationDistance = 75,
        timeout: TimeInterval = 8
    ) async -> LocationObservation? {
        if let existing = latestMatching(latitude: latitude, longitude: longitude, toleranceMeters: toleranceMeters) {
            return existing
        }

        return await withCheckedContinuation { continuation in
            let id = UUID()
            lock.lock()
            waiters.append(LocationWaiter(
                id: id,
                latitude: latitude,
                longitude: longitude,
                toleranceMeters: toleranceMeters,
                continuation: continuation
            ))
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire(id: id)
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let requested = currentRequestedCoordinate()
            record(LocationObservation(
                location: location,
                requestedLatitude: requested.latitude,
                requestedLongitude: requested.longitude
            ))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // The DiagnosticState owns structured stage errors; this verifier keeps raw observations only.
    }

    private func record(_ observation: LocationObservation) {
        lock.lock()
        observations.append(observation)

        let pending = waiters
        waiters.removeAll()
        var unresolved: [LocationWaiter] = []
        var resolved: [CheckedContinuation<LocationObservation?, Never>] = []

        for waiter in pending {
            if Self.distanceMeters(
                fromLatitude: observation.latitude,
                longitude: observation.longitude,
                toLatitude: waiter.latitude,
                longitude: waiter.longitude
            ) <= waiter.toleranceMeters {
                resolved.append(waiter.continuation)
            } else {
                unresolved.append(waiter)
            }
        }

        waiters = unresolved
        let handler = shouldPublishLocked(observation) ? observationHandler : nil
        if handler != nil {
            lastLoggedObservation = observation
        }
        lock.unlock()

        for waiter in resolved {
            waiter.resume(returning: observation)
        }
        handler?(observation)
    }

    private func currentRequestedCoordinate() -> (latitude: Double?, longitude: Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (requestedLatitude, requestedLongitude)
    }

    private func shouldPublishLocked(_ observation: LocationObservation) -> Bool {
        guard let last = lastLoggedObservation else { return true }
        if last.classification != observation.classification { return true }
        if observation.observedAt.timeIntervalSince(last.observedAt) >= duplicateMinimumInterval {
            return true
        }
        let distance = Self.distanceMeters(
            fromLatitude: observation.latitude,
            longitude: observation.longitude,
            toLatitude: last.latitude,
            longitude: last.longitude
        )
        return distance >= duplicateMinimumDistance
    }

    private func expire(id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }

    private func latestMatching(latitude: Double, longitude: Double, toleranceMeters: CLLocationDistance) -> LocationObservation? {
        lock.lock()
        defer { lock.unlock() }
        return observations.reversed().first { observation in
            Self.distanceMeters(
                fromLatitude: observation.latitude,
                longitude: observation.longitude,
                toLatitude: latitude,
                longitude: longitude
            ) <= toleranceMeters
        }
    }

    public static func distanceMeters(
        fromLatitude: Double,
        longitude fromLongitude: Double,
        toLatitude: Double,
        longitude toLongitude: Double
    ) -> CLLocationDistance {
        let a = CLLocation(latitude: fromLatitude, longitude: fromLongitude)
        let b = CLLocation(latitude: toLatitude, longitude: toLongitude)
        return a.distance(from: b)
    }
}

private struct LocationWaiter {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let toleranceMeters: CLLocationDistance
    let continuation: CheckedContinuation<LocationObservation?, Never>
}
