import CoreLocation
import Foundation
import MapKit

/// Product-facing state for the Location tab. Thin by design: all it does is
/// translate user actions (search, tap, current-location, favorite/recent
/// selection) into a `ResolvedPlace`, then hand arbitrary coordinates to the
/// existing `OnDeviceDVTExperimentRunner.setAndVerify` / `.clear()` calls —
/// the same LocationCoordinator-mediated static-location path the original
/// developer console used. No new engine path is introduced.
@MainActor
final class LocationViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var selection: ResolvedPlace?
    @Published var showingSelectionSheet = false
    @Published var isResolvingSelection = false
    @Published var isSettingLocation = false
    @Published var errorMessage: String?
    @Published var activeSimulation: ResolvedPlace?

    let search = PlaceSearchService()
    let favorites = POCAppDependencies.favoritesStore
    let recents = POCAppDependencies.recentsStore
    let connectionStatus = POCAppDependencies.connectionStatus

    private let runner = POCAppDependencies.runner
    private let currentLocationProvider = CurrentLocationProvider()

    func updateSearch(_ text: String) {
        searchText = text
        search.updateQuery(text)
    }

    func submitSearchText() {
        let text = searchText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            isResolvingSelection = true
            defer { isResolvingSelection = false }
            do {
                let place = try await search.resolveFreeText(text)
                present(place)
            } catch {
                errorMessage = display(error)
            }
        }
    }

    func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        Task {
            isResolvingSelection = true
            defer { isResolvingSelection = false }
            do {
                let place = try await search.resolve(completion)
                present(place)
            } catch {
                errorMessage = display(error)
            }
        }
    }

    func selectMapPoint(_ coordinate: CLLocationCoordinate2D) {
        Task {
            isResolvingSelection = true
            defer { isResolvingSelection = false }
            let place = await search.reverseGeocode(coordinate)
            present(place)
        }
    }

    func selectSaved(_ saved: SavedPlace) {
        present(ResolvedPlace(name: saved.name, subtitle: saved.subtitle, coordinate: saved.coordinate))
    }

    func useCurrentLocation() {
        Task {
            isResolvingSelection = true
            defer { isResolvingSelection = false }
            do {
                let coordinate = try await currentLocationProvider.requestCurrentCoordinate()
                let place = await search.reverseGeocode(coordinate)
                present(ResolvedPlace(name: "Current Location", subtitle: place.name, coordinate: coordinate))
            } catch {
                errorMessage = "Couldn't get your current location. Check Location Services access for IOSSim in Settings."
            }
        }
    }

    private func present(_ place: ResolvedPlace) {
        selection = place
        showingSelectionSheet = true
        errorMessage = nil
    }

    var isFavoriteSelection: Bool {
        guard let selection else { return false }
        return favorites.places.contains { place in
            abs(place.latitude - selection.coordinate.latitude) < 0.0001
                && abs(place.longitude - selection.coordinate.longitude) < 0.0001
        }
    }

    func setLocation() {
        guard let selection else { return }
        Task {
            isSettingLocation = true
            defer { isSettingLocation = false }
            let ready = await connectionStatus.ensureReady()
            guard ready else {
                errorMessage = readinessErrorMessage()
                return
            }
            do {
                _ = try await runner.setAndVerify(
                    latitude: selection.coordinate.latitude,
                    longitude: selection.coordinate.longitude
                )
                activeSimulation = selection
                recents.record(
                    SavedPlace(
                        name: selection.name,
                        subtitle: selection.subtitle,
                        latitude: selection.coordinate.latitude,
                        longitude: selection.coordinate.longitude
                    )
                )
                showingSelectionSheet = false
                errorMessage = nil
            } catch {
                errorMessage = display(error)
            }
        }
    }

    func stopSimulation() {
        Task {
            do {
                try await runner.clear()
                activeSimulation = nil
            } catch {
                errorMessage = display(error)
            }
        }
    }

    func toggleFavorite() {
        guard let selection else { return }
        let saved = SavedPlace(
            name: selection.name,
            subtitle: selection.subtitle,
            latitude: selection.coordinate.latitude,
            longitude: selection.coordinate.longitude
        )
        if let existing = favorites.places.first(where: { $0.isNear(saved) }) {
            favorites.remove(existing.id)
        } else {
            favorites.add(saved)
        }
    }

    func driveHere() {
        guard let selection else { return }
        POCAppDependencies.driveModel.setDestination(selection)
        POCAppDependencies.router.selectedTab = .drive
        showingSelectionSheet = false
    }

    private func readinessErrorMessage() -> String {
        for step in [
            connectionStatus.pairingStep,
            connectionStatus.localDevVPNStep,
            connectionStatus.endpointStep,
            connectionStatus.sessionStep
        ] {
            if case .fail(let code, let detail) = step {
                return HumanReadableError.describe(code: code, detail: detail)
            }
        }
        return "IOSSim isn't ready yet. Open Settings to finish setup, then try again."
    }

    private func display(_ error: Error) -> String {
        if let error = error as? POCError {
            return HumanReadableError.describe(code: error.code.rawValue, detail: error.message)
        }
        return String(describing: error)
    }
}
