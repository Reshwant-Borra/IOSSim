import MapKit
import SwiftUI

/// The primary Location experience: search, tap-to-select, current location,
/// and a clear "Simulating <place>" state with an obvious way to stop. This
/// replaces the old developer-console root screen as the app's default view;
/// all the diagnostic capability that used to live here now lives under
/// Settings -> Developer, unchanged.
struct LocationView: View {
    @StateObject private var model = LocationViewModel()
    @ObservedObject private var connectionStatus = POCAppDependencies.connectionStatus
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showingSavedPlaces = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LocationMapView(
                cameraPosition: $cameraPosition,
                selection: model.selection,
                activeSimulation: model.activeSimulation,
                onTap: { coordinate in
                    searchFocused = false
                    model.selectMapPoint(coordinate)
                }
            )
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                searchBar

                if searchFocused, !model.search.suggestions.isEmpty {
                    SearchSuggestionsList(suggestions: model.search.suggestions) { suggestion in
                        model.selectSuggestion(suggestion)
                        searchFocused = false
                    }
                }

                if let activeSimulation = model.activeSimulation {
                    SimulationStatusBanner(
                        placeName: activeSimulation.name,
                        onStop: { model.stopSimulation() }
                    )
                } else if !connectionStatus.allStepsPass {
                    NavigationLink {
                        SetupView()
                    } label: {
                        Label("Set up IOSSim to enable location simulation", systemImage: "gearshape")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSavedPlaces = true
                } label: {
                    Image(systemName: "star")
                }
                .accessibilityLabel("Favorites and Recents")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchFocused = false
                    model.useCurrentLocation()
                } label: {
                    if model.isResolvingSelection {
                        ProgressView()
                    } else {
                        Image(systemName: "location.circle")
                    }
                }
                .accessibilityLabel("Use Current Location")
            }
        }
        .task {
            await connectionStatus.refreshFromCurrentState()
        }
        .onChange(of: model.selection) { _, selection in
            guard let coordinate = selection?.coordinate else { return }
            withAnimation {
                cameraPosition = .region(
                    MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
                )
            }
        }
        .sheet(isPresented: $model.showingSelectionSheet) {
            LocationSelectionSheet(model: model)
        }
        .sheet(isPresented: $showingSavedPlaces) {
            SavedPlacesSheet(model: model, isPresented: $showingSavedPlaces)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search for a place or enter lat, lon", text: $model.searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .onChange(of: model.searchText) { _, newValue in
                    model.updateSearch(newValue)
                }
                .onSubmit {
                    model.submitSearchText()
                    searchFocused = false
                }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    model.updateSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Small, reusable "actively simulating" indicator with an obvious way to
/// stop. Shared shape used by both Location and (later) Drive so the two
/// screens speak a consistent visual language.
struct SimulationStatusBanner: View {
    let placeName: String
    let onStop: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Simulating")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(placeName)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Button("Stop", role: .destructive, action: onStop)
                .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
