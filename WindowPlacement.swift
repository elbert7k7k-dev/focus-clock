import Foundation
import CoreGraphics

/// Screen geometry in logical points, independent of AppKit and display scale.
/// The left half is used on screens without a notch so the clock stays away
/// from the system clock and the right-hand status items.
struct FocusScreenGeometry {
    var frame: CGRect
    var menuBarHeight: CGFloat
    var topLeftSafeArea: CGRect?
}

struct FocusOverlayPlacement {
    let frame: CGRect
    let safeArea: CGRect
    let scale: CGFloat
    let horizontalRatio: Double
}

enum FocusWindowPlacement {
    static let naturalOverlaySize = CGSize(width: 232, height: 28)
    static let defaultHorizontalRatio = 0.70

    static func overlay(screen: FocusScreenGeometry, ratio: Double = defaultHorizontalRatio,
                        proposedX: CGFloat? = nil) -> FocusOverlayPlacement {
        let menuHeight = min(max(1, screen.menuBarHeight), max(1, screen.frame.height))
        let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - menuHeight,
                          width: max(1, screen.frame.width), height: menuHeight)
        var safeArea = CGRect(x: band.minX, y: band.minY,
                              width: max(1, band.width / 2), height: band.height)
        if let supplied = screen.topLeftSafeArea, supplied.width > 0, supplied.height > 0 {
            let intersection = supplied.intersection(band)
            if !intersection.isNull && !intersection.isEmpty { safeArea = intersection }
        }
        let margin = min(8, safeArea.width / 4)
        let availableWidth = max(0.5, safeArea.width - margin * 2)
        let scale = min(1, safeArea.height / naturalOverlaySize.height,
                        availableWidth / naturalOverlaySize.width)
        let size = CGSize(width: naturalOverlaySize.width * scale,
                          height: naturalOverlaySize.height * scale)
        let travel = max(0, availableWidth - size.width)
        let boundedRatio = ratio.isFinite ? min(1, max(0, ratio)) : defaultHorizontalRatio
        let lowerX = safeArea.minX + margin
        let requestedX = proposedX.flatMap { $0.isFinite ? $0 : nil }
            ?? (lowerX + travel * boundedRatio)
        let x = min(lowerX + travel, max(lowerX, requestedX))
        let actualRatio = travel > 0.001 ? Double((x - lowerX) / travel) : boundedRatio
        return FocusOverlayPlacement(frame: CGRect(x: x, y: safeArea.midY - size.height / 2,
                                                     width: size.width, height: size.height),
                                     safeArea: safeArea, scale: scale,
                                     horizontalRatio: actualRatio)
    }

    /// A smaller viewport scrolls over the unchanged content, preserving readable
    /// text and access to the bottom buttons instead of clipping them offscreen.
    static func viewport(natural: CGSize, visible: CGRect, titleBarHeight: CGFloat) -> CGSize {
        CGSize(width: min(natural.width, max(1, visible.width - 24)),
               height: min(natural.height, max(1, visible.height - 24 - titleBarHeight)))
    }

    static func clampedWindow(_ frame: CGRect, visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(visible.minX, result.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(visible.minY, result.minY), max(visible.minY, visible.maxY - result.height))
        return result
    }
}
