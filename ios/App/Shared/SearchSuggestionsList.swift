import MapKit
import SwiftUI

/// Bounded, scrollable list of `MKLocalSearchCompletion` suggestions shared by
/// the Location search bar and Drive's start/destination fields. Previously
/// each screen rendered its own plain `VStack` of every suggestion with no
/// height limit and no `ScrollView`, so a query with many results (e.g.
/// "Popeyes") grew a translucent panel that covered nearly the whole screen
/// and couldn't be scrolled. This caps the panel height and makes it scroll.
struct SearchSuggestionsList: View {
    let suggestions: [MKLocalSearchCompletion]
    let onSelect: (MKLocalSearchCompletion) -> Void

    private let rowHeight: CGFloat = 56
    private let maxVisibleRows: CGFloat = 5.5

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions.indices, id: \.self) { index in
                    let suggestion = suggestions[index]
                    Button {
                        onSelect(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index != suggestions.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: min(CGFloat(suggestions.count), maxVisibleRows) * rowHeight)
        .scrollDismissesKeyboard(.interactively)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
