import AppKit
import CodexUsageCore

/// Owns all UI on main. Service callbacks publish to main before touching the store.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var appServer: AppServerClient?
    private var ipc: CodexIPCClient?
    private var contextMonitor: ContextLogMonitor?
    private var panel: OverlayPanelController?
    private var tracker: CodexWindowTracker?
    private var statusItem: StatusItemController?
    private var displayTimer: Timer?
    private var contextSelection: ContextSelection?
    private var codexForeground = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        self.store = store
        let appServer = AppServerClient()
        self.appServer = appServer
        appServer.onSnapshot = { [weak self] value in
            guard let self, !self.terminating else { return }
            self.store?.updateAccount(value)
        }
        appServer.onError = { [weak self] error in
            guard let self, !self.terminating else { return }
            self.store?.failAccount(Self.accountErrorMessage(error))
        }

        let environment = ProcessInfo.processInfo.environment
        let codexHome: URL
        if let path = environment["CODEX_HOME"], path.hasPrefix("/") {
            codexHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        let contextMonitor = ContextLogMonitor(codexHome: codexHome)
        self.contextMonitor = contextMonitor
        let ipc = CodexIPCClient()
        self.ipc = ipc
        ipc.onStatus = { [weak self] status in
            guard let self, !self.terminating else { return }
            self.selectContext(ContextSelection(status: status))
        }
        contextMonitor.onSnapshot = { [weak self] value in
            guard let self, !self.terminating else { return }
            self.store?.updateContext(value)
        }
        contextMonitor.onError = { [weak self] error in
            guard let self, !self.terminating else { return }
            // The monitor publishes an aged value first. Preserve it as stale.
            let reason = (error as? ContextLogMonitorError) == .staleSnapshot
                ? "任务用量已超过五分钟未更新" : "任务用量暂不可用；请检查本地会话日志"
            self.store?.failContext(reason)
        }

        let panel = OverlayPanelController()
        self.panel = panel
        store.onChange = { [weak self] snapshot in
            guard let self, !self.terminating else { return }
            self.panel?.render(snapshot)
        }
        let tracker = CodexWindowTracker()
        self.tracker = tracker
        panel.onSizeChange = { [weak tracker] size in
            // didSet synchronously refreshes placement before panel uses its target.
            tracker?.panelSize = size
        }
        tracker.panelSize = panel.preferredSize
        tracker.onPlacementChange = { [weak self] frame in
            guard let self, !self.terminating else { return }
            self.codexForeground = frame != nil
            self.appServer?.setForegroundActive(self.codexForeground)
            if self.codexForeground { self.appServer?.start() }
            // A nil placement is authoritative even if the menu says "显示".
            self.panel?.setTargetFrame(frame)
            self.updateDisplayTimer()
        }

        let statusItem = StatusItemController()
        self.statusItem = statusItem
        tracker.offset = statusItem.offset
        statusItem.onVisibilityChange = { [weak self] enabled in
            guard let self, !self.terminating else { return }
            if enabled {
                self.refreshDisplay()
                self.panel?.show()
            } else {
                self.panel?.hide()
            }
            self.updateDisplayTimer()
        }
        statusItem.onOffsetChange = { [weak tracker] offset in tracker?.offset = offset }
        statusItem.onRefresh = { [weak self] in self?.refreshData() }
        panel.onRefresh = { [weak self] in self?.refreshData() }
        statusItem.onPermissionHelp = { [weak self] in self?.showPermissionHelp() }
        statusItem.onAboutDataSources = { [weak self] in self?.showDataSources() }
        statusItem.onQuit = { NSApplication.shared.terminate(nil) }

        panel.render(store.snapshot)
        selectContext(.fallback)
        ipc.start()
        tracker.start()
    }

    private func selectContext(_ selection: ContextSelection, force: Bool = false) {
        guard force || selection != contextSelection else { return }
        contextSelection = selection
        store?.failContext("正在读取任务用量")
        switch selection {
        case .selected(let threadID): contextMonitor?.select(threadID: threadID, provenance: .selectedThread)
        case .fallback: contextMonitor?.selectFallbackRootSession(provenance: .fallbackThread)
        }
    }

    private func refreshData() {
        guard !terminating else { return }
        if codexForeground { appServer?.start() }
        appServer?.refreshNow()
        // Re-resolve a missing/rotated rollout and pick a newer fallback if available.
        selectContext(contextSelection ?? .fallback, force: true)
        contextMonitor?.refreshNow()
        refreshDisplay()
    }

    private func refreshDisplay() {
        guard let store, !terminating else { return }
        store.refreshStaleness()
        // Reset countdowns also change when snapshot equality suppresses onChange.
        panel?.render(store.snapshot)
    }

    private func updateDisplayTimer() {
        guard panel?.isVisible == true, !terminating else {
            displayTimer?.invalidate()
            displayTimer = nil
            return
        }
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplay() }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshDisplay()
    }

    private func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "辅助功能权限"
        alert.informativeText = "允许 Codex Usage Overlay 读取 Codex 窗口的位置与大小，即可跟随窗口。请在系统设置 → 隐私与安全性 → 辅助功能中手动添加并启用本应用。未授权时使用屏幕角落位置。授权后切换一次前台应用或重启悬浮窗。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showDataSources() {
        let alert = NSAlert()
        alert.messageText = "关于 Codex Usage Overlay"
        alert.informativeText = "账号额度来自本地 Codex App Server；任务上下文来自本地会话日志的 token_count 事件。IPC 仅用于当前任务路由。无法确定当前任务时会标记“可能非当前任务”。仅保存位置偏移，不记录消息、工具输出或账号标识。本项目独立开发，未经 OpenAI 背书。"
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    private static func accountErrorMessage(_ error: AppServerClientError) -> String {
        switch error {
        case .executableNotFound: return "未找到 Codex 可执行文件"
        case .initializationFailed, .requestFailed: return "账号额度暂不可用；请检查 Codex 登录状态"
        case .launchFailed, .transportFailed, .requestEncodingFailed: return "Codex App Server 暂不可用"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        displayTimer?.invalidate()
        displayTimer = nil
        store?.onChange = nil
        panel?.onSizeChange = nil
        panel?.hide() // Removes both local and global mouse monitors.
        tracker?.stop() // Removes workspace, screen and AX observers and motion timer.
        ipc?.stop() // Cancels socket, retries and connection timeout synchronously.
        contextMonitor?.stop() // Cancels debounce/watcher; watcher closes its descriptor.
        appServer?.stop() // Cancels refresh/restart work and reaps the owned child.
        statusItem = nil // Removes the NSStatusItem.
        panel = nil
        tracker = nil
        ipc = nil
        contextMonitor = nil
        appServer = nil
        contextSelection = nil
        store = nil
    }
}
