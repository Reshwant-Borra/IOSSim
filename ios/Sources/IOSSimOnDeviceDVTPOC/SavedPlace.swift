import CoreLocation
import Foundation

/// A user-saved place (favorite or recent). Deliberately independent of the
/// DVT/session engine: it is pure local state describing "a coordinate the
/// user cared about," not a claim about what is currently simulated.
public struct SavedPlace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let subtitle: String?
    public let latitude: Double
    public let longitude: Double
    public let savedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String? = nil,
        latitude: Double,
        longitude: Double,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.savedAt = savedAt
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Two places are treated as "the same place" for dedup purposes when
    /// they are within ~10 meters of each other.
    public func isNear(_ other: SavedPlace, toleranceDegrees: Double = 0.0001) -> Bool {
        abs(latitude - other.latitude) < toleranceDegrees && abs(longitude - other.longitude) < toleranceDegrees
    }
}

/// Pure list-management logic for the Recents feature, kept free of any I/O
/// so it can be unit tested directly.
public enum RecentsList {
    /// Inserts `place` at the front, removing any existing near-duplicate
    /// first (so re-visiting a place moves it to the top instead of creating
    /// a second entry), then caps the list length at `limit`.
    public static func inserting(_ place: SavedPlace, into existing: [SavedPlace], limit: Int = 20) -> [SavedPlace] {
        var result = existing.filter { !$0.isNear(place) }
        result.insert(place, at: 0)
        if result.count > limit {
            result.removeLast(result.count - limit)
        }
        return result
    }
}

/// Parses free-typed coordinate text ("lat,lon") into a coordinate, kept pure
/// and separate from MapKit search so it is directly unit testable.
public enum CoordinateParsing {
    public static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Simple JSON-file-backed persistence for a list of SavedPlace, used by both
/// Favorites and Recents. Thread-safe via a lock since it may be touched from
/// SwiftUI's main actor today and could reasonably move off it later.
public final class JSONFilePlaceStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(fileName: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent(fileName)
    }

    public func load() -> [SavedPlace] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
    }

    public func save(_ places: [SavedPlace]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(places) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
