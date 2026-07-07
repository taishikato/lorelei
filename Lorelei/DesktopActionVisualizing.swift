//
//  DesktopActionVisualizing.swift
//  Lorelei
//

import CoreGraphics
import Foundation

/// Visualizes desktop actions before they execute - Lorelei's on-screen cursor.
/// The real pointer is never moved.
@MainActor
protocol DesktopActionVisualizing: AnyObject {
    /// Fly the orb to the element frame (AX top-left-origin global coords) and
    /// play the landing pulse, returning when the action may proceed.
    func animateAction(toAXFrame frame: CGRect) async

    /// Hide the orb instantly so it never appears in lorelei.screenshot captures.
    func concealForScreenshot()

    func revealAfterScreenshot()
}

enum LoreleiCursorOrbGeometry {
    static func appKitPoint(fromAXFrameCenter frame: CGRect, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: frame.midX, y: primaryScreenHeight - frame.midY)
    }

    static func travelDuration(from: CGPoint, to: CGPoint) -> TimeInterval {
        let distance = TimeInterval(hypot(to.x - from.x, to.y - from.y))
        return max(0.18, min(0.45, distance / 2200))
    }
}
