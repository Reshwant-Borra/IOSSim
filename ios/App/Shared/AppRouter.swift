import Foundation

/// App-wide tab selection, so cross-feature actions (e.g. "Drive Here" from
/// the Location tab) can switch tabs programmatically without any tab owning
/// or recreating another tab's state.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case location
        case drive
        case settings
    }

    @Published var selectedTab: Tab = .location
}
