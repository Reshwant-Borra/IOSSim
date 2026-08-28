import Foundation

/// Thin SwiftUI-observable wrapper around the pure, unit-tested SavedPlace /
/// JSONFilePlaceStore logic in the engine package. Deliberately has no
/// knowledge of LocationCoordinator, DVT, or Drive — favorites/recents are
/// local convenience state, not part of the validated simulation engine.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var places: [SavedPlace] = []

    private let persistence: JSONFilePlaceStore

    init(persistence: JSONFilePlaceStore = JSONFilePlaceStore(fileName: "favorites.json")) {
        self.persistence = persistence
        self.places = persistence.load()
    }

    func isFavorite(_ coordinate: SavedPlace) -> Bool {
        places.contains { $0.isNear(coordinate) }
    }

    func add(_ place: SavedPlace) {
        guard !places.contains(where: { $0.isNear(place) }) else { return }
        places.insert(place, at: 0)
        persistence.save(places)
    }

    func remove(_ id: UUID) {
        places.removeAll { $0.id == id }
        persistence.save(places)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].name = name
        persistence.save(places)
    }
}

@MainActor
final class RecentsStore: ObservableObject {
    @Published private(set) var places: [SavedPlace] = []

    private let persistence: JSONFilePlaceStore
    private let limit: Int

    init(persistence: JSONFilePlaceStore = JSONFilePlaceStore(fileName: "recents.json"), limit: Int = 20) {
        self.persistence = persistence
        self.limit = limit
        self.places = persistence.load()
    }

    func record(_ place: SavedPlace) {
        places = RecentsList.inserting(place, into: places, limit: limit)
        persistence.save(places)
    }

    func clear() {
        places = []
        persistence.save(places)
    }
}
