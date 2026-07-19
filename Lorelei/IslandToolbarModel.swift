//
//  IslandToolbarModel.swift
//  Lorelei
//
//  Pure geometry and activity helpers for the island toolbar.
//

import CoreGraphics
import Foundation

nonisolated enum IslandSide: Equatable, Sendable {
    case left
    case right
}

nonisolated enum IslandActivity: Equatable, Sendable {
    case idlePeek
    case listening
    case transcribing
    case working
    case needsApproval
    case finished(success: Bool)

    static func activity(for status: LoreleiRunStatus) -> IslandActivity {
        switch status {
        case .idle:
            .idlePeek
        case .listening:
            .listening
        case .transcribing:
            .transcribing
        case .working:
            .working
        case .needsApproval:
            .needsApproval
        case .finished(let success):
            .finished(success: success)
        }
    }

    var showsTray: Bool {
        switch self {
        case .listening, .transcribing, .working, .needsApproval:
            true
        case .idlePeek, .finished:
            false
        }
    }

    var showsHead: Bool {
        switch self {
        case .idlePeek, .finished:
            true
        case .listening, .transcribing, .working, .needsApproval:
            false
        }
    }
}

nonisolated enum IslandGeometry {
    static let headSize = CGSize(width: 34, height: 21)
    static let trayWidth: CGFloat = 132
    static let trayHeight: CGFloat = 40
    static let trayCornerRadius: CGFloat = 17
    static let islandBottomRadius: CGFloat = 14
    /// How far the head capsule protrudes past the island flank at rest.
    static let headRestProtrusion: CGFloat = 22
    /// Extra lean-out on hover.
    static let headHoverExtra: CGFloat = 4
    static let expandedPanelSize = CGSize(width: 460, height: 430)
    static let minNotchWidth: CGFloat = 150
    static let maxNotchWidth: CGFloat = 260
    static let fallbackNotchWidth: CGFloat = 190
    static let flatScreenIslandHeight: CGFloat = 24

    /// Physical notch width from screen auxiliary top areas when both sides
    /// are present; otherwise the fallback. Clamped to 150...260.
    static func notchWidth(
        screenFrame: CGRect,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?
    ) -> CGFloat {
        guard let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth else {
            return fallbackNotchWidth
        }
        let raw = screenFrame.width - left - right
        return min(max(raw, minNotchWidth), maxNotchWidth)
    }

    /// The island extends slightly past the physical cutout on each side so
    /// hairline mismatches between the computed and real notch width are
    /// absorbed, and the island reads as a deliberate extension of the notch
    /// (owner-observed sliver during visual QA).
    static let edgeOverhang: CGFloat = 4

    /// Island body size. Height matches the menu-bar/notch safe area when
    /// present; flat screens use a compact 24pt bar.
    static func islandSize(notchWidth: CGFloat, safeAreaTop: CGFloat) -> CGSize {
        let height = safeAreaTop > 0 ? safeAreaTop : flatScreenIslandHeight
        return CGSize(width: notchWidth + edgeOverhang * 2, height: height)
    }

    /// One fixed window that fits the island plus head flanks on both sides
    /// and the tray drop below - never resized by SwiftUI state.
    static func windowSize(islandSize: CGSize) -> CGSize {
        let flank = headRestProtrusion + headHoverExtra
        let width = islandSize.width + (flank * 2)
        let height = islandSize.height + trayHeight
        return CGSize(width: width, height: height)
    }
}

nonisolated struct IslandSideScheduler: Sendable {
    private let random: @Sendable (ClosedRange<TimeInterval>) -> TimeInterval

    init(random: @escaping @Sendable (ClosedRange<TimeInterval>) -> TimeInterval = { range in
        TimeInterval.random(in: range)
    }) {
        self.random = random
    }

    mutating func nextSwitchDelay() -> TimeInterval {
        random(20...60)
    }

    mutating func sideAfterReturnToIdle(current: IslandSide) -> IslandSide {
        switch current {
        case .left:
            .right
        case .right:
            .left
        }
    }
}
