/// Composition policy: a remembered route is selected even after unfollowing;
/// only a disconnected IPC client or absent route selects a fallback rollout.
public enum ContextSelection: Equatable {
    case selected(String)
    case fallback

    public init(status: ActiveThreadStatus) {
        if status.connected, let threadID = status.threadID {
            self = .selected(threadID)
        } else {
            self = .fallback
        }
    }
}
