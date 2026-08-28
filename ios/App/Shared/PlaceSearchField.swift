import MapKit
import SwiftUI

/// Reusable search-as-you-type field: a text field backed by PlaceSearchService,
/// with a suggestions dropdown shown while focused. Used by Drive's start/
/// destination fields so search behaves consistently with the rest of the app.
struct PlaceSearchField: View {
    let placeholder: String
    @Binding var text: String
    @ObservedObject var search: PlaceSearchService
    var onSelect: (ResolvedPlace) -> Void

    @FocusState private var focused: Bool
    @State private var resolveError: String?
    @State private var resolveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onChange(of: text) { _, newValue in
                        resolveError = nil
                        search.updateQuery(newValue)
                    }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if let resolveError {
                Text(resolveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            if focused, !search.suggestions.isEmpty {
                SearchSuggestionsList(suggestions: search.suggestions) { suggestion in
                    select(suggestion)
                }
                .padding(.top, 4)
            }
        }
        .onDisappear {
            resolveTask?.cancel()
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                resolveTask?.cancel()
            }
        }
    }

    /// Resolves the tapped suggestion via `MKLocalSearch` and only commits it
    /// (updating the field text, calling `onSelect`, collapsing the list) on
    /// success. A failed resolution used to be swallowed by `try?` while the
    /// list still collapsed as if a selection had been made, leaving the
    /// field's stale, unresolved text as the only record of what the user
    /// typed — which then fed a route generation fallback that could still
    /// fail. Any previous in-flight resolution is cancelled first so a slow
    /// earlier tap can't overwrite a newer one.
    private func select(_ suggestion: MKLocalSearchCompletion) {
        resolveTask?.cancel()
        resolveError = nil
        resolveTask = Task {
            do {
                let place = try await search.resolve(suggestion)
                guard !Task.isCancelled else { return }
                text = place.name
                onSelect(place)
                search.clearSuggestions()
                focused = false
            } catch {
                guard !Task.isCancelled else { return }
                resolveError = (error as? POCError)?.message ?? "Couldn't find that location. Try another search."
            }
        }
    }
}
