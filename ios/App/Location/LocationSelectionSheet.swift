import SwiftUI

/// Bottom sheet shown after a place is selected (search, map tap, current
/// location, favorite, or recent). Single authoritative "Set Location" action
/// — everything converges here before reaching the engine.
struct LocationSelectionSheet: View {
    @ObservedObject var model: LocationViewModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let selection = model.selection {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selection.name)
                            .font(.title3.bold())
                        if let subtitle = selection.subtitle {
                            Text(subtitle)
                                .foregroundStyle(.secondary)
                        }
                        Text(PlaceSearchService.coordinateText(selection.coordinate))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    VStack(spacing: 10) {
                        Button {
                            model.setLocation()
                        } label: {
                            HStack {
                                if model.isSettingLocation {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "location.fill")
                                }
                                Text("Set Location")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isSettingLocation)

                        HStack(spacing: 10) {
                            Button {
                                model.toggleFavorite()
                            } label: {
                                Label(
                                    model.isFavoriteSelection ? "Favorited" : "Favorite",
                                    systemImage: model.isFavoriteSelection ? "star.fill" : "star"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                model.driveHere()
                            } label: {
                                Label("Drive Here", systemImage: "car.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Selected Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.showingSelectionSheet = false
                    }
                }
            }
        }
        .presentationDetents([.height(320), .medium])
        .presentationDragIndicator(.visible)
    }
}
