import AppKit
import CodexUsageCore

private final class UsageOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// All entry points are called on the main thread. The tracker owns screen clamping.
final class OverlayPanelController {
    var onRefresh: (() -> Void)?
    /// Wire to CodexWindowTracker.panelSize so expansions are placed within the screen.
    var onSizeChange: ((CGSize) -> Void)?
    private(set) var preferredSize = CGSize(width: 250, height: 30)
    private(set) var isExpanded = false
    private(set) var isEnabled = true
    var isVisible: Bool { panel.isVisible }

    private let panel: NSPanel
    private var targetFrame: CGRect?
    private var snapshot = CombinedUsageSnapshot(account: .unavailable(reason: "等待账号数据"),
                                                  context: .unavailable(reason: "等待任务数据"))
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init() {
        panel = UsageOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.setAccessibilityLabel("Codex 用量")
        rebuildContent()
    }

    func render(_ snapshot: CombinedUsageSnapshot) {
        precondition(Thread.isMainThread)
        self.snapshot = snapshot
        rebuildContent()
    }

    /// Receives the tracker's final panel placement, in AppKit screen coordinates.
    func setTargetFrame(_ frame: CGRect?) {
        precondition(Thread.isMainThread)
        targetFrame = frame.flatMap {
            !$0.isEmpty && !$0.isInfinite && $0.origin.x.isFinite && $0.origin.y.isFinite ? $0 : nil
        }
        updateVisibility()
    }

    func show() { isEnabled = true; updateVisibility() }

    func hide() {
        isEnabled = false
        orderOutAndCleanUp()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        removeMouseMonitors()
        rebuildContent()
    }

    private func expand() {
        guard panel.isVisible, !isExpanded else { return }
        isExpanded = true
        rebuildContent()
        installMouseMonitors()
    }

    private func rebuildContent() {
        let now = Date()
        let content: NSView
        if isExpanded {
            content = ExpandedOverlayView(rows: DisplayFormatter.detailRows(snapshot: snapshot, now: now),
                refresh: { [weak self] in self?.onRefresh?() }, collapse: { [weak self] in self?.collapse() })
        } else {
            content = CompactOverlayView(segments: DisplayFormatter.compactSegments(snapshot: snapshot, now: now),
                expand: { [weak self] in self?.expand() })
        }
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if size != preferredSize {
            preferredSize = size
            onSizeChange?(size)
        }
        updateVisibility()
    }

    private func updateVisibility() {
        guard isEnabled, let targetFrame else { orderOutAndCleanUp(); return }
        panel.setFrame(targetFrame, display: true)
        panel.orderFrontRegardless()
        if isExpanded { installMouseMonitors() }
    }

    private func orderOutAndCleanUp() {
        panel.orderOut(nil)
        removeMouseMonitors()
        // Do not reopen old expanded details after leaving and returning to Codex.
        if isExpanded { isExpanded = false; rebuildContent() }
    }

    private func installMouseMonitors() {
        guard panel.isVisible, isExpanded, globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.collapseIfOutside()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.collapseIfOutside()
            return event
        }
    }

    private func collapseIfOutside() {
        if !panel.frame.contains(NSEvent.mouseLocation) { collapse() }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    deinit {
        removeMouseMonitors()
        panel.orderOut(nil)
    }
}
