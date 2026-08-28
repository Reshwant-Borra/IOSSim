import CoreLocation
import Foundation
import MapKit

public struct RouteSample: Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let distanceAlongRouteMeters: CLLocationDistance

    public init(coordinate: CLLocationCoordinate2D, distanceAlongRouteMeters: CLLocationDistance) {
        self.coordinate = coordinate
        self.distanceAlongRouteMeters = distanceAlongRouteMeters
    }
}

public struct RouteProjection: Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let distanceAlongRouteMeters: CLLocationDistance
    public let distanceFromRouteMeters: CLLocationDistance
}

public struct RouteResampler: Sendable {
    public let samples: [RouteSample]
    public let totalDistanceMeters: CLLocationDistance

    public init(coordinates: [CLLocationCoordinate2D]) throws {
        guard coordinates.count >= 2 else {
            throw POCError(.invalidRoute, "Route requires at least two coordinates.")
        }
        guard coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else {
            throw POCError(.invalidRoute, "Route contains invalid coordinates.")
        }

        var built: [RouteSample] = [RouteSample(coordinate: coordinates[0], distanceAlongRouteMeters: 0)]
        var cumulative: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            let segment = Self.distance(from: previous, to: current)
            guard segment > 0 else { continue }
            cumulative += segment
            built.append(RouteSample(coordinate: current, distanceAlongRouteMeters: cumulative))
        }

        guard built.count >= 2, cumulative > 0 else {
            throw POCError(.invalidRoute, "Route distance must be greater than zero.")
        }
        samples = built
        totalDistanceMeters = cumulative
    }

    public init(polyline: MKPolyline) throws {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        try self.init(coordinates: coordinates)
    }

    public func coordinate(atDistance meters: CLLocationDistance) -> CLLocationCoordinate2D {
        let clamped = min(max(0, meters), totalDistanceMeters)
        if clamped <= 0 {
            return samples[0].coordinate
        }
        if clamped >= totalDistanceMeters {
            return samples[samples.count - 1].coordinate
        }

        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if samples[mid].distanceAlongRouteMeters <= clamped {
                low = mid
            } else {
                high = mid
            }
        }

        let start = samples[low]
        let end = samples[high]
        let segmentDistance = end.distanceAlongRouteMeters - start.distanceAlongRouteMeters
        guard segmentDistance > 0 else {
            return end.coordinate
        }
        let fraction = (clamped - start.distanceAlongRouteMeters) / segmentDistance
        return CLLocationCoordinate2D(
            latitude: start.coordinate.latitude + (end.coordinate.latitude - start.coordinate.latitude) * fraction,
            longitude: start.coordinate.longitude + (end.coordinate.longitude - start.coordinate.longitude) * fraction
        )
    }

    public func nearestProjection(to coordinate: CLLocationCoordinate2D) -> RouteProjection {
        var bestCoordinate = samples[0].coordinate
        var bestRouteDistance: CLLocationDistance = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude

        for index in 1..<samples.count {
            let start = samples[index - 1]
            let end = samples[index]
            let projected = Self.project(
                coordinate,
                ontoStart: start.coordinate,
                end: end.coordinate
            )
            let segmentLength = end.distanceAlongRouteMeters - start.distanceAlongRouteMeters
            let routeDistance = start.distanceAlongRouteMeters + projected.fraction * segmentLength
            if projected.distanceMeters < bestDistance {
                bestDistance = projected.distanceMeters
                bestCoordinate = projected.coordinate
                bestRouteDistance = routeDistance
            }
        }

        return RouteProjection(
            coordinate: bestCoordinate,
            distanceAlongRouteMeters: min(max(0, bestRouteDistance), totalDistanceMeters),
            distanceFromRouteMeters: bestDistance
        )
    }

    public static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    private static func project(
        _ point: CLLocationCoordinate2D,
        ontoStart start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, fraction: Double, distanceMeters: CLLocationDistance) {
        let origin = start
        let metersPerDegreeLatitude = 111_132.0
        let metersPerDegreeLongitude = 111_320.0 * cos(origin.latitude * .pi / 180)

        let sx = 0.0
        let sy = 0.0
        let ex = (end.longitude - origin.longitude) * metersPerDegreeLongitude
        let ey = (end.latitude - origin.latitude) * metersPerDegreeLatitude
        let px = (point.longitude - origin.longitude) * metersPerDegreeLongitude
        let py = (point.latitude - origin.latitude) * metersPerDegreeLatitude

        let dx = ex - sx
        let dy = ey - sy
        let denominator = dx * dx + dy * dy
        let fraction = denominator == 0 ? 0 : min(1, max(0, ((px - sx) * dx + (py - sy) * dy) / denominator))
        let projectedX = sx + fraction * dx
        let projectedY = sy + fraction * dy
        let projected = CLLocationCoordinate2D(
            latitude: origin.latitude + projectedY / metersPerDegreeLatitude,
            longitude: origin.longitude + projectedX / metersPerDegreeLongitude
        )
        let distance = hypot(px - projectedX, py - projectedY)
        return (projected, fraction, distance)
    }
}
