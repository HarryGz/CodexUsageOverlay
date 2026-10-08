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
    private var tiboStore: TiboAlertStore?
    private var tiboCoordinator: TiboAlertCoordinator?
    private var tiboNotificationController: TiboNotificationController?
    private var wakeObserver: NSObjectProtocol?
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
            if case .unavailable = error as? ContextLogMonitorError {
                self.store?.invalidateContext(reason)
            } else { self.store?.failContext(reason) }
        }

        let panel = OverlayPanelController()
        self.panel = panel
        let tiboStore = TiboAlertStore(defaults: .standard)
        self.tiboStore = tiboStore
        let tiboTransport = TiboURLSessionTransport()
        let tiboFeed = TiboFeedClient(transport: tiboTransport, defaults: .standard)
        let tiboVerifier = TiboSourceVerifier(transport: tiboTransport)
        let tiboNotifications = TiboNotificationController()
        self.tiboNotificationController = tiboNotifications
        let tiboCoordinator = TiboAlertCoordinator(
            store: tiboStore,
            feed: tiboFeed,
            verifier: tiboVerifier,
            notifier: tiboNotifications
        )
        self.tiboCoordinator = tiboCoordinator
        store.onChange = { [weak self] snapshot in
            guard let self, !self.terminating else { return }
            self.panel?.render(snapshot)
        }
        tiboStore.onChange = { [weak self] snapshot in
            guard let self, !self.terminating else { return }
            self.panel?.renderTibo(snapshot)
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
            if self.codexForeground { self.contextMonitor?.start() }
            else { self.contextMonitor?.stop() }
            // A nil placement is authoritative even if the menu says "显示".
            self.panel?.setTargetFrame(frame)
            if frame != nil,
               let pendingID = self.tiboStore?.snapshot.pendingRevealID,
               self.panel?.revealTiboDetails() == true {
                self.tiboStore?.consumePendingReveal(for: pendingID)
            }
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
        panel.onTiboPresented = { [weak tiboStore] in tiboStore?.markRead() }
        panel.onOpenTiboPost = { [weak self] url in self?.openTiboLink(url) }
        statusItem.onPermissionHelp = { [weak self] in self?.showPermissionHelp() }
        statusItem.onNotificationPermissionHelp = { [weak self] in self?.showNotificationPermissionHelp() }
        statusItem.onAboutDataSources = { [weak self] in self?.showDataSources() }
        statusItem.onQuit = { NSApplication.shared.terminate(nil) }

        panel.render(store.snapshot)
        panel.renderTibo(tiboStore.snapshot)
        selectContext(.hidden)
        ipc.start()
        tracker.start()
        tiboCoordinator.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.terminating else { return }
                self.tiboCoordinator?.handleWake()
            }
        }
    }

    private func selectContext(_ selection: ContextSelection) {
        guard selection != contextSelection else { return }
        contextSelection = selection
        store?.invalidateContext("正在读取任务用量")
        switch selection {
        case .selected(let threadID): contextMonitor?.select(threadID: threadID, provenance: .selectedThread)
        case .hidden: contextMonitor?.clearSelection()
        }
    }

    private func refreshData() {
        guard !terminating else { return }
        if codexForeground { appServer?.start() }
        appServer?.refreshNow()
        // The monitor re-resolves the retained selection only while foreground.
        contextMonitor?.refreshNow()
        tiboCoordinator?.refreshNow()
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
        alert.informativeText = "账号额度来自本地 Codex App Server，是当前登录账号的权威数据；任务上下文来自本地会话日志。Tibo 动态每五分钟读取独立社区服务 codex-reset.com，并通过 X 的公开 oEmbed 二次确认作者。公开公告不代表额度已经发放到你的账号。应用仅保存位置偏移和有限的提醒状态，不会向外发送账号额度、任务或会话内容。本项目独立开发，未经 OpenAI 背书。"
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    private func showNotificationPermissionHelp() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openTiboLink(_ url: URL) {
        let attribution = "https://codex-reset.com/"
        let currentPost = tiboStore?.snapshot.latest?.canonicalURL?.absoluteString
        guard url.absoluteString == attribution || url.absoluteString == currentPost else { return }
        NSWorkspace.shared.open(url)
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
        tiboStore?.onChange = nil
        tiboCoordinator?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        panel?.onSizeChange = nil
        panel?.hide() // Removes both local and global mouse monitors.
        tracker?.stop() // Removes workspace, screen and AX observers and motion timer.
        ipc?.stop() // Cancels socket, retries and connection timeout synchronously.
        contextMonitor?.stop() // Cancels debounce/watcher; watcher closes its descriptor.
        appServer?.stop() // Cancels refresh/restart work and reaps the owned child.
        statusItem = nil // Removes the NSStatusItem.
        tiboCoordinator = nil
        tiboNotificationController = nil
        tiboStore = nil
        panel = nil
        tracker = nil
        ipc = nil
        contextMonitor = nil
        appServer = nil
        contextSelection = nil
        store = nil
    }
}
