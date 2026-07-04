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
    @Published var showsNotchPeek = false
}

@MainActor
final class LoreleiToolbarController {
    private enum Metrics {
        static let collapsedSize = CGSize(width: 140, height: 40)
        static let expandedSize = CGSize(width: 460, height: 430)
        static let topInset: CGFloat = 8
        static let peekWidth: CGFloat = 104
        static let peekChinHeight: CGFloat = 22
    }

    private let companionManager: CompanionManager
    private let expansionState = LoreleiToolbarExpansionState()
    private var runStatusCancellable: AnyCancellable?
    private var panel: NSPanel?

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

    /// Temporarily hides the capsule while the settings dropdown is open so
    /// the two glass surfaces never overlap on narrow screens.
    func setConcealed(_ concealed: Bool) {
        guard let panel else { return }
        if concealed {
            panel.orderOut(nil)
        } else {
            positionPanel(panel)
            panel.orderFrontRegardless()
        }
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

    /// Frame for the collapsed "peeking from behind the notch" window.
    ///
    /// The window spans from the very top of the screen (`screenFrame`, not
    /// `visibleFrame`) so the head shape runs seamlessly into the camera
    /// housing: everything inside the notch is physically invisible, and only
    /// the chin below it shows, which sells the peeking illusion. The notch
    /// is always centered on the screen, so centering on midX is enough.
    static func collapsedPeekFrame(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        width: CGFloat,
        chinHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.maxY - safeAreaTop - chinHeight,
            width: width,
            height: safeAreaTop + chinHeight
        )
    }

    private func makePanel() -> NSPanel {
        let screen = screenContainingMouse()
        let size = currentSize
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
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setContentSize(size)

        return panel
    }

    private var currentSize: CGSize {
        expansionState.isExpanded ? Metrics.expandedSize : Metrics.collapsedSize
    }

    private func positionPanel(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenContainingMouse()
        let usesPeek = !expansionState.isExpanded && screen.safeAreaInsets.top > 0
        if expansionState.showsNotchPeek != usesPeek {
            expansionState.showsNotchPeek = usesPeek
        }

        let frame: CGRect
        if usesPeek {
            frame = Self.collapsedPeekFrame(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                width: Metrics.peekWidth,
                chinHeight: Metrics.peekChinHeight
            )
        } else {
            frame = Self.panelFrame(
                screenFrame: screen.visibleFrame,
                size: currentSize,
                topInset: Metrics.topInset
            )
        }

        // The peek window extends into the menu bar region; a window shadow
        // there would outline the part of the head that is supposed to be
        // hidden behind the notch and break the illusion.
        panel.hasShadow = !usesPeek

        panel.setFrame(frame, display: true, animate: animated)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func screenContainingMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}
