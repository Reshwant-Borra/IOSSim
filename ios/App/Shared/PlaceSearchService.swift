import CoreLocation
import Foundation
import MapKit

/// A resolved place: a display name plus a coordinate. Used by both the
/// Location and Drive product screens so search results, map taps, favorites,
/// and recents all converge on the same shape.
struct ResolvedPlace: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: ResolvedPlace, rhs: ResolvedPlace) -> Bool {
        lhs.id == rhs.id
    }
}

/// Live search-as-you-type suggestions backed by MKLocalSearchCompleter, plus
/// resolution of a suggestion (or free-typed text/coordinates) to a concrete
/// coordinate via MKLocalSearch. This is UI-facing search infrastructure
/// shared by Location and Drive; it does not touch DVT/LocationCoordinator at
/// all and is safe to instantiate per-screen.
@MainActor
final class PlaceSearchService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
        // `region` on MKLocalSearchCompleter is a bias, not a hard filter —
        // it still returns strong global matches (e.g. "Times Square" from
        // Florida), it just ranks/prefers nearby results, which is what
        // fixes "Popeyes" surfacing a distant unrelated result first. Reading
        // `.location` only returns an already-authorized, already-cached
        // value; it never triggers a new permission prompt or starts updates.
        if let coordinate = CLLocationManager().location?.coordinate {
            completer.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }
    }

    func updateQuery(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestions = []
            return
        }
        completer.queryFragment = query
    }

    func clearSuggestions() {
        suggestions = []
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.suggestions = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedPlace {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw POCError(.invalidRoute, "No location found for \"\(completion.title)\".")
        }
        return ResolvedPlace(
            name: item.name ?? completion.title,
            subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle,
            coordinate: item.placemark.coordinate
        )
    }

    /// Resolves free-typed text: a raw "lat,lon" pair first, otherwise a
    /// MapKit natural-language search (place name, address, business).
    func resolveFreeText(_ query: String) async throws -> ResolvedPlace {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let coordinate = CoordinateParsing.parse(trimmed) {
            return ResolvedPlace(name: Self.coordinateText(coordinate), subtitle: "Coordinate", coordinate: coordinate)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw POCError(.invalidRoute, "No location found for \"\(trimmed)\".")
        }
        return ResolvedPlace(name: item.name ?? trimmed, subtitle: nil, coordinate: item.placemark.coordinate)
    }

    /// Reverse-geocodes a coordinate (e.g. from a map tap) into a display name.
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> ResolvedPlace {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
            let name = [placemark.name].compactMap { $0 }.first ?? Self.coordinateText(coordinate)
            let subtitle = [placemark.locality, placemark.administrativeArea]
                .compactMap { $0 }
                .joined(separator: ", ")
            return ResolvedPlace(
                name: name,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                coordinate: coordinate
            )
        }
        return ResolvedPlace(name: Self.coordinateText(coordinate), subtitle: nil, coordinate: coordinate)
    }

    static func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
