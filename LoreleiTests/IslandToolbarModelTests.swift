//
//  IslandToolbarModelTests.swift
//  LoreleiTests
//

import Foundation
import CoreGraphics
import Testing
@testable import Lorelei

struct IslandToolbarModelTests {

    @Test func activityMapsEveryRunStatus() {
        #expect(IslandActivity.activity(for: .idle) == .idlePeek)
        #expect(IslandActivity.activity(for: .listening) == .listening)
        #expect(IslandActivity.activity(for: .transcribing) == .transcribing)
        #expect(IslandActivity.activity(for: .working("lorelei.set_text")) == .working)
        #expect(IslandActivity.activity(for: .needsApproval("Run command")) == .needsApproval)
        #expect(IslandActivity.activity(for: .finished(success: true)) == .finished(success: true))
        #expect(IslandActivity.activity(for: .finished(success: false)) == .finished(success: false))
    }

    @Test func activityVisibilityFlags() {
        #expect(IslandActivity.idlePeek.showsHead)
        #expect(!IslandActivity.idlePeek.showsTray)
        #expect(!IslandActivity.listening.showsHead)
        #expect(IslandActivity.listening.showsTray)
        #expect(IslandActivity.finished(success: true).showsHead)
        #expect(!IslandActivity.finished(success: true).showsTray)
    }

    @Test func notchWidthUsesBothAuxiliaryAreasAndClamps() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let matched = IslandGeometry.notchWidth(
            screenFrame: screen,
            auxiliaryTopLeftWidth: 661,
            auxiliaryTopRightWidth: 661
        )
        #expect(matched == 190)

        let wide = IslandGeometry.notchWidth(
            screenFrame: screen,
            auxiliaryTopLeftWidth: 600,
            auxiliaryTopRightWidth: 600
        )
        #expect(wide == 260)

        let narrow = IslandGeometry.notchWidth(
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            auxiliaryTopLeftWidth: 340,
            auxiliaryTopRightWidth: 340
        )
        #expect(narrow == 150)
    }

    @Test func notchWidthFallsBackWhenAuxiliaryMissing() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(
            IslandGeometry.notchWidth(
                screenFrame: screen,
                auxiliaryTopLeftWidth: nil,
                auxiliaryTopRightWidth: 661
            ) == IslandGeometry.fallbackNotchWidth
        )
        #expect(
            IslandGeometry.notchWidth(
                screenFrame: screen,
                auxiliaryTopLeftWidth: 661,
                auxiliaryTopRightWidth: nil
            ) == IslandGeometry.fallbackNotchWidth
        )
        #expect(
            IslandGeometry.notchWidth(
                screenFrame: screen,
                auxiliaryTopLeftWidth: nil,
                auxiliaryTopRightWidth: nil
            ) == IslandGeometry.fallbackNotchWidth
        )
    }

    @Test func islandHeightUsesSafeAreaOrFlatFallback() {
        let notched = IslandGeometry.islandSize(notchWidth: 190, safeAreaTop: 32)
        #expect(notched == CGSize(width: 190, height: 32))

        let flat = IslandGeometry.islandSize(notchWidth: 190, safeAreaTop: 0)
        #expect(flat == CGSize(width: 190, height: IslandGeometry.flatScreenIslandHeight))
    }

    @Test func windowSizeFitsHeadFlanksAndTray() {
        let island = CGSize(width: 190, height: 32)
        let window = IslandGeometry.windowSize(islandSize: island)
        let flank = IslandGeometry.headRestProtrusion + IslandGeometry.headHoverExtra
        #expect(window.width == island.width + flank * 2)
        #expect(window.height == island.height + IslandGeometry.trayHeight)
    }

    @Test func sideSchedulerUsesInjectedRandomAndFlipsOnIdleReturn() {
        final class CallBox: @unchecked Sendable {
            var ranges: [ClosedRange<TimeInterval>] = []
        }
        let box = CallBox()
        var scheduler = IslandSideScheduler { range in
            box.ranges.append(range)
            return 42
        }

        #expect(scheduler.nextSwitchDelay() == 42)
        #expect(box.ranges.count == 1)
        #expect(box.ranges[0] == 20...60)
        #expect(scheduler.sideAfterReturnToIdle(current: IslandSide.left) == IslandSide.right)
        #expect(scheduler.sideAfterReturnToIdle(current: IslandSide.right) == IslandSide.left)
    }
}
