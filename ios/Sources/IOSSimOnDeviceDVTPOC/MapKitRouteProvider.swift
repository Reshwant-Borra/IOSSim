import CoreLocation
import Foundation
import MapKit

public struct MapKitRouteResult {
    public let route: MKRoute
    public let polyline: MKPolyline
    public let driveRoute: DriveRoute
}

public final class MapKitRouteProvider: @unchecked Sendable {
    public init() {}

    public func route(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) async throws -> MapKitRouteResult {
        guard CLLocationCoordinate2DIsValid(origin), CLLocationCoordinate2DIsValid(destination) else {
            throw POCError(.invalidRoute, "Origin and destination must be valid coordinates.")
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        guard let route = response.routes.first else {
            throw POCError(.routeCalculationFailed, "MapKit returned no automobile routes.")
        }
        let resampler = try RouteResampler(polyline: route.polyline)
        let driveRoute = DriveRoute(
            origin: origin,
            destination: destination,
            resampler: resampler,
            routeDistanceMeters: route.distance,
            expectedTravelTime: route.expectedTravelTime
        )
        return MapKitRouteResult(route: route, polyline: route.polyline, driveRoute: driveRoute)
    }
}

public final class MapKitSearchProvider: @unchecked Sendable {
    private let geocoder = CLGeocoder()

    public init() {}

    public func coordinate(for query: String) async throws -> CLLocationCoordinate2D {
        if let coordinate = Self.parseCoordinate(query) {
            return coordinate
        }
        let placemarks = try await geocoder.geocodeAddressString(query)
        guard let coordinate = placemarks.first?.location?.coordinate else {
            throw POCError(.routeCalculationFailed, "No location found for \(query).")
        }
        return coordinate
    }

    public static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else {
            return nil
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}
