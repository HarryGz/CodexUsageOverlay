import CoreGraphics

/// AX supplies window events when available. Otherwise bound visibility checks
/// to a quiet two-second foreground timer, including when no window is visible.
public enum WindowObservationPolicy {
    public static func fallbackRevalidationInterval(isRunning: Bool, foreground: Bool,
                                                     accessibilityAvailable: Bool) -> Double? {
        isRunning && foreground && !accessibilityAvailable ? 2 : nil
    }
}

/// A window in AppKit screen coordinates (origin at the bottom left).
public struct WindowCandidate: Equatable {
    public let id: UInt32
    public let frame: CGRect
    public let isFocused: Bool
    public let isMinimized: Bool
    public let isOnScreen: Bool
    public let isStandardWindow: Bool
    public let layer: Int

    public init(id: UInt32, frame: CGRect, isFocused: Bool = false,
                isMinimized: Bool = false, isOnScreen: Bool = true,
                isStandardWindow: Bool = true, layer: Int = 0) {
        self.id = id
        self.frame = frame
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
        self.isStandardWindow = isStandardWindow
        self.layer = layer
    }

    /// Input order is front-to-back, used to break otherwise equal choices.
    public static func select(from candidates: [Self], visibleFrames: [CGRect]) -> Self? {
        var best: Self?
        for candidate in candidates {
            guard candidate.isOnScreen, !candidate.isMinimized,
                  candidate.isStandardWindow, candidate.layer == 0,
                  candidate.frame.width >= 500, candidate.frame.height >= 300,
                  visibleFrames.contains(where: { !$0.intersection(candidate.frame).isEmpty }) else { continue }
            guard let current = best else { best = candidate; continue }
            if (candidate.isFocused && !current.isFocused) ||
                (candidate.isFocused == current.isFocused &&
                 candidate.frame.width * candidate.frame.height > current.frame.width * current.frame.height) {
                best = candidate
            }
        }
        return best
    }
}

public enum OverlayPlacement {
    /// Quartz/Accessibility use a top-left origin relative to the primary display.
    public static func appKitFrame(fromQuartz frame: CGRect, primaryDisplayTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryDisplayTop - frame.maxY,
               width: frame.width, height: frame.height)
    }

    /// Positive offsets move right/up. Oversized panels shrink to the visible
    /// intersection; `.null` means there is no space in which to show a panel.
    public static func frame(window: CGRect, panelSize: CGSize, offset: CGPoint,
                             visibleFrame: CGRect) -> CGRect {
        let available = window.intersection(visibleFrame)
        guard !available.isEmpty, !available.isInfinite,
              panelSize.width.isFinite, panelSize.height.isFinite,
              panelSize.width > 0, panelSize.height > 0,
              offset.x.isFinite, offset.y.isFinite else { return .null }
        let width = min(panelSize.width, available.width)
        let height = min(panelSize.height, available.height)
        return CGRect(
            x: min(max(window.maxX - width - 12 + offset.x, available.minX), available.maxX - width),
            y: min(max(window.maxY - height - 12 + offset.y, available.minY), available.maxY - height),
            width: width, height: height)
    }
}
