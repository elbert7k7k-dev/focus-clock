import Foundation
import CoreGraphics

private struct PlacementFailure: Error { let message: String }

@main
struct WindowPlacementTestRunner {
    static func main() throws {
        var assertions = 0
        var cases = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !value() { throw PlacementFailure(message: message) }
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ message: String) throws {
            try expect(abs(a - b) < 0.000001, message)
        }
        func check(_ title: String, _ body: () throws -> Void) throws {
            try body(); cases += 1; print("PASS \(title)")
        }
        let notched = FocusScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
            menuBarHeight: 37, topLeftSafeArea: CGRect(x: 0, y: 1206, width: 856, height: 37))
        try check("notched display uses left safe area, centered in menu band") {
            let p = FocusWindowPlacement.overlay(screen: notched)
            try expect(p.safeArea.contains(p.frame), "Clock must fit inside top-left safe area")
            try expect(p.frame.maxX < 856, "Clock must remain left of the notch")
            try near(p.frame.minX, 433.6, "Use a relative initial position")
            try near(p.frame.minY, 1210.5, "Center the 28-point clock in the 37-point menu bar")
            try near(p.scale, 1, "Normal displays preserve the original size")
        }
        try check("no-notch display uses measured 22-point menu band") {
            let p = FocusWindowPlacement.overlay(screen: FocusScreenGeometry(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900), menuBarHeight: 22))
            try expect(p.frame.maxX <= 720, "Keep the overlay away from right-hand status items")
            try near(p.frame.height, 22, "Fit actual menu height instead of overflowing it")
            try near(p.frame.maxY, 900, "Keep overlay at the actual screen top")
            try expect(p.safeArea.contains(p.frame), "Scaled overlay fits safe area")
        }
        try check("relative location survives display and scaling changes") {
            let stored = FocusWindowPlacement.overlay(screen: notched, proposedX: 500)
            let smaller = FocusScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                menuBarHeight: 37, topLeftSafeArea: CGRect(x: 0, y: 945, width: 674, height: 37))
            let p = FocusWindowPlacement.overlay(screen: smaller, ratio: stored.horizontalRatio)
            try expect(p.safeArea.contains(p.frame), "Changed resolution must remain safe")
            try expect(p.frame.minX < stored.frame.minX, "A smaller safe area proportionally changes x")
            try near(CGFloat(p.horizontalRatio), CGFloat(stored.horizontalRatio), "Keep the saved proportion")
        }
        try check("external display with negative origin") {
            let screen = FocusScreenGeometry(frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                              menuBarHeight: 24)
            let p = FocusWindowPlacement.overlay(screen: screen)
            try expect(p.safeArea.contains(p.frame), "Negative origin must not be clamped to primary screen")
            try expect(p.frame.maxX < 0, "Clock remains on the selected external display")
            try near(p.frame.maxY, 980, "Top respects selected screen origin")
        }
        try check("dragged positions clamp to both safe edges") {
            let left = FocusWindowPlacement.overlay(screen: notched, proposedX: -500)
            let right = FocusWindowPlacement.overlay(screen: notched, proposedX: 5000)
            try near(left.frame.minX, 8, "Clamp left with margin")
            try near(right.frame.maxX, 848, "Clamp right before notch")
            try near(CGFloat(left.horizontalRatio), 0, "Left ratio is zero")
            try near(CGFloat(right.horizontalRatio), 1, "Right ratio is one")
        }
        try check("invalid stored ratio cannot create an offscreen window") {
            for ratio in [Double.nan, Double.infinity, -5, 5] {
                let p = FocusWindowPlacement.overlay(screen: notched, ratio: ratio)
                try expect(p.frame.minX.isFinite && p.frame.minY.isFinite, "Position must stay finite")
                try expect(p.safeArea.contains(p.frame), "Invalid ratio remains clamped")
            }
        }
        try check("narrow safe area proportionally scales complete controls") {
            let screen = FocusScreenGeometry(frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                menuBarHeight: 20, topLeftSafeArea: CGRect(x: 0, y: 480, width: 150, height: 20))
            let p = FocusWindowPlacement.overlay(screen: screen)
            try expect(p.scale > 0 && p.scale < 1, "Shrink when width does not fit")
            try expect(p.safeArea.contains(p.frame), "All scaled controls remain visible")
            try near(p.frame.width / p.frame.height, 232 / 28, "Preserve alarm and controls proportions")
        }
        try check("supplied auxiliary geometry is intersected with actual menu band") {
            let screen = FocusScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                menuBarHeight: 30, topLeftSafeArea: CGRect(x: -20, y: 750, width: 480, height: 60))
            let p = FocusWindowPlacement.overlay(screen: screen)
            try expect(p.safeArea.minX >= 0 && p.safeArea.maxY <= 800, "Normalize platform auxiliary area")
            try expect(p.safeArea.contains(p.frame), "Clock stays in the normalized band")
        }
        try check("full-size dashboard remains unchanged on large displays") {
            let size = FocusWindowPlacement.viewport(natural: CGSize(width: 900, height: 740),
                visible: CGRect(x: 0, y: 0, width: 1920, height: 1150), titleBarHeight: 28)
            try expect(size == CGSize(width: 900, height: 740), "Preserve original readable layout")
        }
        try check("small-screen viewport reserves title bar and margins") {
            let size = FocusWindowPlacement.viewport(natural: CGSize(width: 900, height: 740),
                visible: CGRect(x: 0, y: 0, width: 800, height: 550), titleBarHeight: 28)
            try expect(size == CGSize(width: 776, height: 498), "Scroll instead of clipping content")
            try expect(size.height + 28 + 24 <= 550, "Window frame must fit screen height")
        }
        try check("detached-screen windows clamp to available primary screen") {
            let p = FocusWindowPlacement.clampedWindow(CGRect(x: -1900, y: 2000, width: 900, height: 700),
                visible: CGRect(x: 0, y: 50, width: 1440, height: 800))
            try near(p.minX, 0, "Recover left edge")
            try near(p.maxY, 850, "Recover top edge")
        }
        print("Window placement: \(cases) cases, \(assertions) assertions passed")
    }
}
