/// Context is eligible only when IPC identifies exactly one active route.
public enum ContextSelection: Equatable {
    case selected(String)
    case hidden

    public init(status: ActiveThreadStatus) {
        guard status.connected, status.activeWindowCount == 1,
              let threadID = status.threadID else { self = .hidden; return }
        self = .selected(threadID)
    }
}
