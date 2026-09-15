import AppKit

final class StatusItemController: NSObject {
    var onVisibilityChange: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    var onOffsetChange: ((CGPoint) -> Void)?
    var onPermissionHelp: (() -> Void)?
    var onAboutDataSources: (() -> Void)?
    var onQuit: (() -> Void)?
    private(set) var offset: CGPoint
    private var overlayEnabled = true
    private let defaults: UserDefaults
    private let statusItem: NSStatusItem
    private let visibilityItem = NSMenuItem(title: "隐藏", action: nil, keyEquivalent: "")
    private static let offsetXKey = "overlayOffsetX"
    private static let offsetYKey = "overlayOffsetY"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let x = defaults.double(forKey: Self.offsetXKey), y = defaults.double(forKey: Self.offsetYKey)
        offset = CGPoint(x: x.isFinite ? x : 0, y: y.isFinite ? y : 0)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Codex 用量")
        statusItem.button?.setAccessibilityLabel("Codex 用量菜单")
        statusItem.button?.toolTip = "Codex 用量"
        let menu = NSMenu()
        visibilityItem.target = self
        visibilityItem.action = #selector(toggleVisibility)
        menu.addItem(visibilityItem)
        menu.addItem(item("刷新", #selector(refresh)))
        let position = NSMenuItem(title: "位置偏移", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, title) in ["左移", "右移", "上移", "下移", "重置位置"].enumerated() {
            let entry = item(title, #selector(adjustOffset(_:)))
            entry.tag = index
            submenu.addItem(entry)
        }
        position.submenu = submenu
        menu.addItem(position)
        menu.addItem(.separator())
        menu.addItem(item("辅助功能权限", #selector(permissionHelp)))
        menu.addItem(item("关于数据来源", #selector(aboutDataSources)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit)))
        statusItem.menu = menu
    }

    func setOverlayEnabled(_ enabled: Bool) {
        overlayEnabled = enabled
        visibilityItem.title = enabled ? "隐藏" : "显示"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleVisibility() {
        setOverlayEnabled(!overlayEnabled)
        onVisibilityChange?(overlayEnabled)
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func permissionHelp() { onPermissionHelp?() }
    @objc private func aboutDataSources() { onAboutDataSources?() }
    @objc private func quit() { onQuit?() }

    @objc private func adjustOffset(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: offset.x -= 8
        case 1: offset.x += 8
        case 2: offset.y += 8
        case 3: offset.y -= 8
        case 4: offset = .zero
        default: return
        }
        // Deliberately the only persisted values: no snapshots or task identifiers.
        defaults.set(Double(offset.x), forKey: Self.offsetXKey)
        defaults.set(Double(offset.y), forKey: Self.offsetYKey)
        onOffsetChange?(offset)
    }

    deinit { NSStatusBar.system.removeStatusItem(statusItem) }
}
