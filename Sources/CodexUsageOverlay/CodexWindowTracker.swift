import AppKit
import ApplicationServices
import CodexUsageCore

/// Main-thread owner of workspace/AX subscriptions. No Accessibility prompt is issued.
/// The consumer must honor nil by hiding its panel; frames use AppKit screen coordinates.
final class CodexWindowTracker {
    var onPlacementChange: ((CGRect?) -> Void)?
    var panelSize = CGSize(width: 250, height: 30) { didSet { refreshIfRunning() } }
    var offset = CGPoint.zero { didSet { refreshIfRunning() } }

    private let workspace: NSWorkspace
    private var workspaceTokens: [NSObjectProtocol] = []
    private var screenToken: NSObjectProtocol?
    private var isRunning = false
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedPID: pid_t?
    private var observedWindows: [AXUIElement] = []
    private var movementTimer: Timer?
    private var fallbackTimer: Timer?
    private var movementStarted: TimeInterval = 0
    private var lastMotionEvent: TimeInterval = -.infinity
    private var lastPolledFrame: CGRect?
    private var stableSamples = 0
    private var placement: CGRect?

    private static let bundleIdentifiers: Set<String> = ["com.openai.codex", "com.openai.chatgpt"]
    private static let applicationEvents = [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification]
    private static let windowEvents = [kAXUIElementDestroyedNotification, kAXMovedNotification,
                                       kAXResizedNotification, kAXWindowMiniaturizedNotification,
                                       kAXWindowDeminiaturizedNotification]

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    func start() {
        precondition(Thread.isMainThread)
        guard !isRunning else { return }
        isRunning = true
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification
        ]
        workspaceTokens = names.map { name in
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stopMovementPolling()
                self?.lastMotionEvent = -.infinity
                self?.refreshIfRunning()
            }
        }
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshIfRunning() }
        refresh()
        // An initial nil is meaningful even when there was never a valid window.
        if placement == nil { onPlacementChange?(nil) }
    }

    func stop() {
        precondition(Thread.isMainThread)
        isRunning = false
        tearDownSubscriptions()
        publish(nil)
    }

    deinit { tearDownSubscriptions() }

    private func tearDownSubscriptions() {
        workspaceTokens.forEach(workspace.notificationCenter.removeObserver)
        workspaceTokens.removeAll()
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        screenToken = nil
        stopMovementPolling()
        stopFallbackPolling()
        detachAccessibility()
    }

    private func refreshIfRunning() {
        precondition(Thread.isMainThread)
        if isRunning { refresh() }
    }

    private func refresh() {
        guard let app = workspace.frontmostApplication, !app.isHidden, !app.isTerminated,
              let bundleID = app.bundleIdentifier, Self.bundleIdentifiers.contains(bundleID) else {
            stopMovementPolling()
            stopFallbackPolling()
            detachAccessibility()
            publish(nil)
            return
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { stopFallbackPolling(); publish(nil); return }
        let visibleFrames = screens.map(\.visibleFrame)
        let cgCandidates = quartzWindows(pid: app.processIdentifier, primaryDisplayTop: primary.frame.maxY)
        let trusted = AXIsProcessTrusted()
        if trusted { attachAccessibility(pid: app.processIdentifier) }
        else { detachAccessibility() }

        var candidates = cgCandidates
        var canFollowWindow = false
        var accessibilityAvailable = false
        if trusted, let application = observedApplication {
            let axWindows = attribute(application, kAXWindowsAttribute) as? [AXUIElement]
            accessibilityAvailable = axWindows != nil
            let windows = axWindows ?? []
            // AX timeouts belong to individual element instances. Refreshes may
            // return new instances even for windows we already observe.
            for window in windows { AXUIElementSetMessagingTimeout(window, 0.2) }
            synchronizeWindowSubscriptions(windows)
            if !windows.isEmpty {
                let focus = attribute(application, kAXFocusedWindowAttribute)
                candidates = windows.compactMap { element in
                    guard let frame = accessibilityFrame(element, primaryDisplayTop: primary.frame.maxY),
                          let cg = cgCandidates.first(where: { approximatelyEqual($0.frame, frame) }) else { return nil }
                    return WindowCandidate(id: cg.id, frame: frame,
                        isFocused: focus.map { CFEqual($0, element) } ?? false,
                        isMinimized: attribute(element, kAXMinimizedAttribute) as? Bool ?? false,
                        isOnScreen: cg.isOnScreen,
                        isStandardWindow: attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                        layer: cg.layer)
                }
                canFollowWindow = true
            }
        }
        configureFallbackPolling(accessibilityAvailable: accessibilityAvailable)
        guard let selected = WindowCandidate.select(from: candidates, visibleFrames: visibleFrames),
              let screen = screens.max(by: {
                  intersectionArea($0.visibleFrame, selected.frame) < intersectionArea($1.visibleFrame, selected.frame)
              }) else { stopMovementPolling(); publish(nil); return }
        // Denied/unsupported AX: a plausible on-screen window must exist, but the
        // capsule stays fixed in that display's corner instead of guessing a title bar.
        let anchor = canFollowWindow ? selected.frame : screen.visibleFrame
        let frame = OverlayPlacement.frame(window: anchor, panelSize: panelSize,
                                           offset: offset, visibleFrame: screen.visibleFrame)
        publish(frame.isNull ? nil : frame)
    }

    private func configureFallbackPolling(accessibilityAvailable: Bool) {
        guard let interval = WindowObservationPolicy.fallbackRevalidationInterval(
            isRunning: isRunning, foreground: true, accessibilityAvailable: accessibilityAvailable) else {
            stopFallbackPolling()
            return
        }
        guard fallbackTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refreshIfRunning() }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFallbackPolling() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func publish(_ frame: CGRect?) {
        guard frame != placement else { return }
        placement = frame
        onPlacementChange?(frame)
    }

    private func quartzWindows(pid: pid_t, primaryDisplayTop: CGFloat) -> [WindowCandidate] {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let id = record[kCGWindowNumber as String] as? NSNumber,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let layer = record[kCGWindowLayer as String] as? NSNumber else { return nil }
            return WindowCandidate(id: id.uint32Value,
                frame: OverlayPlacement.appKitFrame(fromQuartz: frame, primaryDisplayTop: primaryDisplayTop),
                isOnScreen: record[kCGWindowIsOnscreen as String] as? Bool ?? false, layer: layer.intValue)
        }
    }

    private func attachAccessibility(pid: pid_t) {
        guard observedPID != pid else { return }
        detachAccessibility()
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            let tracker = Unmanaged<CodexWindowTracker>.fromOpaque(context).takeUnretainedValue()
            tracker.accessibilityChanged(notification as String)
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }
        let application = AXUIElementCreateApplication(pid)
        // Avoid a stalled external application blocking the overlay indefinitely.
        AXUIElementSetMessagingTimeout(application, 0.2)
        observer = newObserver
        observedApplication = application
        observedPID = pid
        for event in Self.applicationEvents { addNotification(event, element: application) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func detachAccessibility() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for element in observedWindows {
                for event in Self.windowEvents { AXObserverRemoveNotification(observer, element, event as CFString) }
            }
            if let application = observedApplication {
                for event in Self.applicationEvents { AXObserverRemoveNotification(observer, application, event as CFString) }
            }
        }
        observedWindows.removeAll()
        observer = nil
        observedApplication = nil
        observedPID = nil
    }

    private func synchronizeWindowSubscriptions(_ windows: [AXUIElement]) {
        guard let observer else { return }
        for old in observedWindows where !windows.contains(where: { CFEqual($0, old) }) {
            for event in Self.windowEvents { AXObserverRemoveNotification(observer, old, event as CFString) }
        }
        for new in windows where !observedWindows.contains(where: { CFEqual($0, new) }) {
            for event in Self.windowEvents { addNotification(event, element: new) }
        }
        observedWindows = windows
    }

    private func addNotification(_ event: String, element: AXUIElement) {
        guard let observer else { return }
        // Unsupported notifications are harmless; workspace events still refresh.
        AXObserverAddNotification(observer, element, event as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

    private func accessibilityChanged(_ event: String) {
        guard isRunning else { return }
        refresh()
        if event == kAXMovedNotification || event == kAXResizedNotification {
            beginMovementPolling()
        } else {
            stopMovementPolling()
            lastMotionEvent = -.infinity
        }
    }

    private func beginMovementPolling() {
        guard placement != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let newGesture = now - lastMotionEvent > 0.2
        lastMotionEvent = now
        // Continuous notifications cannot renew the one-second polling budget.
        guard movementTimer == nil, newGesture else { return }
        movementStarted = now
        lastPolledFrame = placement
        stableSamples = 0
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard ProcessInfo.processInfo.systemUptime - self.movementStarted < 1 else {
                self.stopMovementPolling(); return
            }
            self.refreshIfRunning()
            self.stableSamples = self.placement == self.lastPolledFrame ? self.stableSamples + 1 : 0
            self.lastPolledFrame = self.placement
            if self.stableSamples >= 2 { self.stopMovementPolling() }
        }
        movementTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMovementPolling() {
        movementTimer?.invalidate()
        movementTimer = nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func accessibilityFrame(_ element: AXUIElement, primaryDisplayTop: CGFloat) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return OverlayPlacement.appKitFrame(fromQuartz: CGRect(origin: point, size: dimensions),
                                            primaryDisplayTop: primaryDisplayTop)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2 &&
        abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isEmpty ? 0 : intersection.width * intersection.height
    }
}
