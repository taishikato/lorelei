//
//  LoreleiToolbarController.swift
//  Lorelei
//
//  Owns the always-visible floating toolbar panel.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LoreleiToolbarExpansionState: ObservableObject {
    @Published var isExpanded = false
    /// The island's true size for the current screen, published by the
    /// controller so the view never has to re-derive it from window bounds
    /// (the expanded window is wider than the island).
    @Published var islandSize: CGSize = .zero
}

@MainActor
final class LoreleiToolbarController {
    private enum Metrics {
        static let topInset: CGFloat = 8
    }

    private let companionManager: CompanionManager
    private let expansionState = LoreleiToolbarExpansionState()
    private var runStatusCancellable: AnyCancellable?
    private var panel: NSPanel?
    private weak var islandHostingView: IslandClickRegionHostingView<LoreleiToolbarView>?
    var onOpenSettings: (() -> Void)?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        runStatusCancellable = companionManager.$runStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runStatus in
                guard let self else { return }
                self.islandHostingView?.trayVisible =
                    IslandActivity.activity(for: runStatus).showsTray
                if case .needsApproval = runStatus {
                    self.setExpanded(true)
                } else if let panel = self.panel, !self.expansionState.isExpanded {
                    // The collapsed window only spans the island band while no
                    // tray is showing (clicks below must reach other apps);
                    // grow it for the tray, shrink it back after.
                    self.positionPanel(panel)
                }
            }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    var isExpanded: Bool {
        expansionState.isExpanded
    }

    func setExpanded(_ expanded: Bool) {
        islandHostingView?.clickRegionEnabled = !expanded
        guard expansionState.isExpanded != expanded else { return }
        if expanded {
            // Grow the window first - it is transparent, so the resize is
            // invisible - then let SwiftUI slide the panel out from under
            // the island. The window frame itself never animates.
            expansionState.isExpanded = true
            if let panel { positionPanel(panel) }
            LoreleiAnalytics.capture(.toolbarExpanded)
        } else {
            expansionState.isExpanded = false
            // Let the retract transition play inside the still-tall window,
            // then shrink the window back to the island band.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.expansionState.isExpanded, let panel = self.panel else { return }
                self.positionPanel(panel)
            }
        }
    }

    /// Top-centered collapsed island window, flush with the screen's top edge.
    static func collapsedIslandFrame(screenFrame: CGRect, windowSize: CGSize) -> CGRect {
        CGRect(
            x: screenFrame.midX - (windowSize.width / 2),
            y: screenFrame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    static func collapsedWindowSize(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?
    ) -> CGSize {
        let notchWidth = IslandGeometry.notchWidth(
            screenFrame: screenFrame,
            auxiliaryTopLeftWidth: auxiliaryTopLeftWidth,
            auxiliaryTopRightWidth: auxiliaryTopRightWidth
        )
        let islandSize = IslandGeometry.islandSize(
            notchWidth: notchWidth,
            safeAreaTop: safeAreaTop
        )
        return IslandGeometry.windowSize(islandSize: islandSize)
    }

    private func makePanel() -> NSPanel {
        let screen = screenContainingMouse()
        let size = currentSize(for: screen)
        let frame = Self.collapsedIslandFrame(
            screenFrame: screen.frame,
            windowSize: size
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.ignoresMouseEvents = false

        let rootView = LoreleiToolbarView(
            companionManager: companionManager,
            expansionState: expansionState,
            toggleExpansion: { [weak self] in
                guard let self else { return }
                setExpanded(!isExpanded)
            },
            openSettings: { [weak self] in
                self?.onOpenSettings?()
            }
        )
        let hostingView = IslandClickRegionHostingView(rootView: rootView)
        // Manual window sizing: the hosting view must never drive the window
        // (see plan 033 crash anatomy).
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.clickRegionEnabled = !expansionState.isExpanded
        hostingView.trayVisible = IslandActivity.activity(for: companionManager.runStatus).showsTray

        // The hosting view is NOT the contentView: AppKit force-resizes the
        // contentView with the window, and the collapsed window is shorter
        // than the SwiftUI layout (island band only while no tray shows, so
        // clicks under the island reach other apps). A passthrough container
        // holds the full-size hosting view top-aligned; the window edge clips
        // the rest.
        let container = PassthroughContainerView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(hostingView)
        panel.contentView = container
        islandHostingView = hostingView
        panel.setContentSize(size)

        return panel
    }

    private func currentSize(for screen: NSScreen) -> CGSize {
        if expansionState.isExpanded {
            let island = islandSizeForScreen(screen)
            return CGSize(
                width: IslandGeometry.expandedPanelSize.width,
                height: island.height + IslandGeometry.expandedPanelSize.height
            )
        }
        return Self.collapsedWindowSize(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: Self.auxiliaryWidth(screen.auxiliaryTopLeftArea),
            auxiliaryTopRightWidth: Self.auxiliaryWidth(screen.auxiliaryTopRightArea)
        )
    }

    private func islandSizeForScreen(_ screen: NSScreen) -> CGSize {
        IslandGeometry.islandSize(
            notchWidth: IslandGeometry.notchWidth(
                screenFrame: screen.frame,
                auxiliaryTopLeftWidth: Self.auxiliaryWidth(screen.auxiliaryTopLeftArea),
                auxiliaryTopRightWidth: Self.auxiliaryWidth(screen.auxiliaryTopRightArea)
            ),
            safeAreaTop: screen.safeAreaInsets.top
        )
    }

    private static func auxiliaryWidth(_ area: NSRect?) -> CGFloat? {
        guard let area, area.width > 0 else { return nil }
        return area.width
    }

    private func positionPanel(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenContainingMouse()
        let size = currentSize(for: screen)

        let island = islandSizeForScreen(screen)
        if expansionState.islandSize != island {
            expansionState.islandSize = island
        }

        let frame: CGRect
        if expansionState.isExpanded {
            // Same top-flush centered placement as collapsed: the expanded
            // panel hangs from the island, it does not float below it.
            frame = Self.collapsedIslandFrame(
                screenFrame: screen.frame,
                windowSize: size
            )
        } else {
            let trayVisible = IslandActivity
                .activity(for: companionManager.runStatus).showsTray
            let windowHeight = trayVisible
                ? size.height
                : max(size.height - IslandGeometry.trayHeight, 1)
            frame = Self.collapsedIslandFrame(
                screenFrame: screen.frame,
                windowSize: CGSize(width: size.width, height: windowHeight)
            )
        }

        // Island shadow lives on the SwiftUI shape; a window shadow would
        // outline the notch-matching region and break the merge illusion.
        panel.hasShadow = false

        panel.setFrame(frame, display: true, animate: false)
        // Full SwiftUI layout size, top-aligned inside the (possibly shorter)
        // window; AppKit clips whatever extends past the window's bottom.
        islandHostingView?.frame = NSRect(
            x: 0,
            y: frame.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func screenContainingMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}


/// Hosting view that refuses clicks outside the island's visual region at the
/// AppKit level: SwiftUI contentShape alone still let the transparent part of
/// the fixed-size panel swallow clicks meant for windows underneath (owner
/// report: clicks below the island opened the panel). While collapsed, only
/// the top island band (which contains the peeking head) and - when a tray is
/// showing - the tray strip below it are hittable; everything else passes
/// through to the desktop.
final class IslandClickRegionHostingView<Content: View>: NSHostingView<Content> {
    var clickRegionEnabled = false
    var trayVisible = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard clickRegionEnabled else {
            return super.hitTest(point)
        }
        let local = convert(point, from: superview)
        let yFromTop = isFlipped ? local.y : bounds.height - local.y
        let islandHeight = max(bounds.height - IslandGeometry.trayHeight, 1)

        if yFromTop <= islandHeight {
            return super.hitTest(point)
        }
        if trayVisible,
           yFromTop <= islandHeight + IslandGeometry.trayHeight,
           abs(local.x - bounds.midX) <= IslandGeometry.trayWidth / 2 {
            return super.hitTest(point)
        }
        return nil
    }
}


/// Container that never swallows clicks itself: only results from subviews
/// (the island hosting view with its own hit gating) are returned.
final class PassthroughContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
