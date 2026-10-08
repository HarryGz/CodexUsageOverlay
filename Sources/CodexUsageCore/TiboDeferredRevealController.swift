import Foundation

@MainActor
public final class TiboDeferredRevealController {
    private let store: TiboAlertStore
    private let present: () -> Bool
    private var isAttempting = false

    public init(store: TiboAlertStore, present: @escaping () -> Bool) {
        self.store = store
        self.present = present
    }

    public func attempt() {
        guard !isAttempting,
              let pendingID = store.snapshot.pendingRevealID else { return }
        isAttempting = true
        defer { isAttempting = false }
        guard present() else { return }
        store.consumePendingReveal(for: pendingID)
    }
}
