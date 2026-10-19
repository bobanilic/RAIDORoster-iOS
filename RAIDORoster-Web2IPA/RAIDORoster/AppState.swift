import Combine
import Foundation

/// Only availability changes affect the root welcome/briefing decision.
/// Calendar selection, download progress and reminder status belong to leaves.
@MainActor
final class AppState: ObservableObject {
    struct Availability: Equatable {
        let hasCache: Bool
        let isRestoring: Bool
    }
    let rosterStore: RosterStore
    let browser: RosterBrowserModel
    @Published private(set) var availability: Availability
    private var rosterObservation: AnyCancellable?

    init(store: RosterStore? = nil) {
        let store = store ?? RosterStore(deferLoading: true)
        rosterStore = store
        browser = RosterBrowserModel(store: store)
        availability = Availability(hasCache: store.hasCache, isRestoring: store.isRestoring)
        rosterObservation = Publishers.CombineLatest(store.$snapshot, store.$isRestoring)
            .map { Availability(hasCache: !($0.0?.items.isEmpty ?? true), isRestoring: $0.1) }
            .removeDuplicates()
            .sink { [weak self] value in
                guard self?.availability != value else { return }
                self?.availability = value
            }
    }
}
