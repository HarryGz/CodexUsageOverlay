import AppKit
import CodexUsageCore

extension CapacityColor {
    var nsColor: NSColor {
        switch self {
        case .healthy: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unavailable: return .secondaryLabelColor
        }
    }
}

/// Handles first clicks while keeping the editor's application and responder active.
final class OverlayActionButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String, accessibilityLabel: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        onPress = action
        target = self
        self.action = #selector(pressed)
        bezelStyle = .rounded
        focusRingType = .none
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic UI only") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func pressed() { onPress?() }
}

final class CompactOverlayView: NSVisualEffectView {
    init(segments: [CompactUsageSegment], expand: @escaping () -> Void) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "·")
                separator.textColor = .tertiaryLabelColor
                separator.setAccessibilityElement(false)
                stack.addArrangedSubview(separator)
            }
            let label = NSTextField(labelWithString: segment.text)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = segment.color.nsColor
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setAccessibilityElement(false)
            stack.addArrangedSubview(label)
        }
        let button = OverlayActionButton(title: "", accessibilityLabel: "展开用量详情", action: expand)
        button.isBordered = false
        button.setAccessibilityValue(segments.map(\.text).joined(separator: " · "))
        button.toolTip = "点击展开用量详情"
        for view in [stack, button] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Programmatic UI only") }
}

final class ExpandedOverlayView: NSVisualEffectView {
    init(rows: [UsageDetailRow], refresh: @escaping () -> Void, collapse: @escaping () -> Void) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for section in DisplayFormatter.visibleDetailSections(rows: rows) {
            let heading = NSTextField(labelWithString: section == .account ? "账号额度" : "任务上下文")
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.textColor = .labelColor
            stack.addArrangedSubview(heading)
            for row in rows where row.section == section {
                let label = NSTextField(wrappingLabelWithString: "\(row.label)：\(row.value)")
                label.font = .systemFont(ofSize: 12)
                label.textColor = row.color.nsColor
                label.setAccessibilityLabel(row.label)
                label.setAccessibilityValue(row.value)
                stack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        let controls = NSStackView(views: [
            OverlayActionButton(title: "刷新", accessibilityLabel: "刷新用量", action: refresh),
            OverlayActionButton(title: "收起", accessibilityLabel: "收起用量详情", action: collapse)
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        stack.addArrangedSubview(controls)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Programmatic UI only") }
}
