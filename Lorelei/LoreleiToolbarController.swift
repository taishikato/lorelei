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
}

@MainActor
final class LoreleiToolbarController {
    private enum Metrics {
        static let expandedSize = CGSize(width: 460, height: 430)
        static let topInset: CGFloat = 8
    }

    private let companionManager: CompanionManager
    private let expansionState = LoreleiToolbarExpansionState()
    private var runStatusCancellable: AnyCancellable?
    private var panel: NSPanel?
    var onOpenSettings: (() -> Void)?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        runStatusCancellable = companionManager.$runStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runStatus in
                guard case .needsApproval = runStatus else { return }
                self?.setExpanded(true)
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
        guard expansionState.isExpanded != expanded else { return }
        expansionState.isExpanded = expanded
        if expanded {
            LoreleiAnalytics.capture(.toolbarExpanded)
        }
        guard let panel else { return }
        positionPanel(panel, animated: true)
    }

    static func panelFrame(screenFrame: CGRect, size: CGSize, topInset: CGFloat) -> CGRect {
        CGRect(
            x: screenFrame.midX - (size.width / 2),
            y: screenFrame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        )
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
        let frame = Self.panelFrame(
            screenFrame: screen.visibleFrame,
            size: size,
            topInset: Metrics.topInset
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
        let hostingView = NSHostingView(rootView: rootView)
        // Manual window sizing: the hosting view must never drive the window
        // (see plan 033 crash anatomy).
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setContentSize(size)

        return panel
    }

    private func currentSize(for screen: NSScreen) -> CGSize {
        if expansionState.isExpanded {
            return Metrics.expandedSize
        }
        return Self.collapsedWindowSize(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: Self.auxiliaryWidth(screen.auxiliaryTopLeftArea),
            auxiliaryTopRightWidth: Self.auxiliaryWidth(screen.auxiliaryTopRightArea)
        )
    }

    private static func auxiliaryWidth(_ area: NSRect?) -> CGFloat? {
        guard let area, area.width > 0 else { return nil }
        return area.width
    }

    private func positionPanel(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenContainingMouse()
        let size = currentSize(for: screen)

        let frame: CGRect
        if expansionState.isExpanded {
            frame = Self.panelFrame(
                screenFrame: screen.visibleFrame,
                size: size,
                topInset: Metrics.topInset
            )
        } else {
            frame = Self.collapsedIslandFrame(
                screenFrame: screen.frame,
                windowSize: size
            )
        }

        // Island shadow lives on the SwiftUI shape; a window shadow would
        // outline the notch-matching region and break the merge illusion.
        panel.hasShadow = expansionState.isExpanded

        panel.setFrame(frame, display: true, animate: animated)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        panel.setContentSize(frame.size)
    }

    private func screenContainingMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}
