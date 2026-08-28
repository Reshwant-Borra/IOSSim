import SwiftUI

/// Favorites and Recents, both backed by local-only JSON persistence
/// (Sources/IOSSimOnDeviceDVTPOC/SavedPlace.swift). Selecting a row presents
/// the same LocationSelectionSheet used by search/map-tap, so every entry
/// point converges on one "Set Location" action.
struct SavedPlacesSheet: View {
    @ObservedObject var model: LocationViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    if model.favorites.places.isEmpty {
                        ContentUnavailableView(
                            "No Favorites Yet",
                            systemImage: "star",
                            description: Text("Favorite a place from its selection card.")
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(model.favorites.places) { place in
                            Button {
                                model.selectSaved(place)
                                isPresented = false
                            } label: {
                                SavedPlaceRow(place: place)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                model.favorites.remove(model.favorites.places[index].id)
                            }
                        }
                    }
                }

                Section("Recents") {
                    if model.recents.places.isEmpty {
                        ContentUnavailableView(
                            "No Recent Locations",
                            systemImage: "clock",
                            description: Text("Locations you simulate will show up here.")
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(model.recents.places) { place in
                            Button {
                                model.selectSaved(place)
                                isPresented = false
                            } label: {
                                SavedPlaceRow(place: place)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Favorites & Recents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SavedPlaceRow: View {
    let place: SavedPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(place.name)
                .foregroundStyle(.primary)
            if let subtitle = place.subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
