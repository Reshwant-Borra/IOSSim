import MapKit
import SwiftUI

/// Reusable search-as-you-type field: a text field backed by PlaceSearchService,
/// with a suggestions dropdown shown while focused. Used by Drive's start/
/// destination fields so search behaves consistently with the rest of the app.
struct PlaceSearchField: View {
    let placeholder: String
    @Binding var text: String
    @ObservedObject var search: PlaceSearchService
    var trailingSystemImage: String?
    var onTrailingTap: (() -> Void)?
    var onSelect: (ResolvedPlace) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onChange(of: text) { _, newValue in
                        search.updateQuery(newValue)
                    }
                if let trailingSystemImage {
                    Button {
                        focused = false
                        onTrailingTap?()
                    } label: {
                        Image(systemName: trailingSystemImage)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if focused, !search.suggestions.isEmpty {
                let suggestions = search.suggestions
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.indices, id: \.self) { index in
                        let suggestion = suggestions[index]
                        Button {
                            Task {
                                if let place = try? await search.resolve(suggestion) {
                                    text = place.name
                                    onSelect(place)
                                }
                                search.clearSuggestions()
                                focused = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                        }
                        if index != suggestions.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 4)
            }
        }
    }
}
