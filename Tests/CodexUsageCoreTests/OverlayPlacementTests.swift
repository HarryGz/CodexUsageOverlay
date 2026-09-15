import CoreGraphics
import XCTest
@testable import CodexUsageCore

final class OverlayPlacementTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
    private let panel = CGSize(width: 250, height: 30)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 1000)

    func testPlacesCapsuleInsideUpperRightWithTwelvePointInset() {
        XCTAssertEqual(place(window), CGRect(x: 1038, y: 858, width: 250, height: 30))
    }

    func testClampsToVisibleScreenWhenWindowExtendsBeyondIt() {
        XCTAssertEqual(place(CGRect(x: 1100, y: 900, width: 1200, height: 800)),
                       CGRect(x: 1190, y: 970, width: 250, height: 30))
    }

    func testSupportsNegativeDisplayOrigin() {
        XCTAssertEqual(OverlayPlacement.frame(
            window: CGRect(x: -1400, y: 100, width: 1200, height: 800),
            panelSize: panel, offset: .zero,
            visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 1000)),
            CGRect(x: -462, y: 858, width: 250, height: 30))
    }

    func testConvertsQuartzTopLeftCoordinatesAcrossDisplayOrigins() {
        XCTAssertEqual(OverlayPlacement.appKitFrame(fromQuartz:
            CGRect(x: 100, y: 200, width: 1200, height: 800), primaryDisplayTop: 1080),
            CGRect(x: 100, y: 80, width: 1200, height: 800))
        XCTAssertEqual(OverlayPlacement.appKitFrame(fromQuartz:
            CGRect(x: -1400, y: -900, width: 1200, height: 800), primaryDisplayTop: 1080),
            CGRect(x: -1400, y: 1180, width: 1200, height: 800))
    }

    func testPreservesOffsetWhenFullyVisible() {
        XCTAssertEqual(place(window, offset: CGPoint(x: -40, y: -20)),
                       CGRect(x: 998, y: 838, width: 250, height: 30))
    }

    func testClampsOffsetAtBothWindowEdges() {
        XCTAssertEqual(place(window, offset: CGPoint(x: 100, y: 100)),
                       CGRect(x: 1050, y: 870, width: 250, height: 30))
        XCTAssertEqual(place(window, offset: CGPoint(x: -2000, y: -2000)),
                       CGRect(x: 100, y: 100, width: 250, height: 30))
    }

    func testShrinksCapsuleWiderThanAvailableVisibleArea() {
        XCTAssertEqual(place(CGRect(x: 1340, y: 100, width: 1200, height: 800)),
                       CGRect(x: 1340, y: 858, width: 100, height: 30))
    }

    func testOffscreenWindowAndInvalidPanelHaveNoPlacement() {
        XCTAssertTrue(place(CGRect(x: 2000, y: 0, width: 1200, height: 800)).isNull)
        XCTAssertTrue(OverlayPlacement.frame(window: window, panelSize: .zero,
                                             offset: .zero, visibleFrame: screen).isNull)
    }

    func testFocusedVisibleMainWindowWinsOverLargerWindow() {
        XCTAssertEqual(WindowCandidate.select(from: [candidate(1), candidate(2, focused: true)],
                                               visibleFrames: [screen])?.id, 2)
    }

    func testSmallMinimizedAndOffscreenWindowsAreIgnoredEvenWhenFocused() {
        let rejected = [
            candidate(1, frame: CGRect(x: 0, y: 0, width: 499, height: 800), focused: true),
            candidate(2, frame: CGRect(x: 0, y: 0, width: 1000, height: 299), focused: true),
            candidate(3, focused: true, minimized: true),
            candidate(4, focused: true, onScreen: false),
            candidate(5, frame: CGRect(x: 2000, y: 0, width: 1200, height: 800), focused: true)
        ]
        for invalid in rejected {
            XCTAssertEqual(WindowCandidate.select(from: [invalid, candidate(6)],
                                                   visibleFrames: [screen])?.id, 6)
        }
        XCTAssertNil(WindowCandidate.select(from: rejected, visibleFrames: [screen]))
    }

    func testStandardWindowWinsOverFocusedUtilityOrFloatingWindow() {
        XCTAssertEqual(WindowCandidate.select(from: [candidate(1, focused: true, standard: false),
                                                       candidate(2, focused: true, layer: 3), candidate(3)],
                                               visibleFrames: [screen])?.id, 3)
    }

    func testLargestPlausibleWindowWinsWithoutFocusAndTiesKeepFrontmost() {
        let smaller = candidate(1, frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(WindowCandidate.select(from: [smaller, candidate(2), candidate(3)],
                                               visibleFrames: [screen])?.id, 2)
        XCTAssertEqual(WindowCandidate.select(from: [smaller], visibleFrames: [screen])?.id, 1)
    }

    private func place(_ frame: CGRect, offset: CGPoint = .zero) -> CGRect {
        OverlayPlacement.frame(window: frame, panelSize: panel, offset: offset, visibleFrame: screen)
    }

    private func candidate(_ id: UInt32, frame: CGRect? = nil, focused: Bool = false,
                           minimized: Bool = false, onScreen: Bool = true,
                           standard: Bool = true, layer: Int = 0) -> WindowCandidate {
        WindowCandidate(id: id, frame: frame ?? window, isFocused: focused,
                        isMinimized: minimized, isOnScreen: onScreen,
                        isStandardWindow: standard, layer: layer)
    }
}
