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
        static let collapsedSize = CGSize(width: 140, height: 40)
        static let expandedSize = CGSize(width: 460, height: 430)
        static let topInset: CGFloat = 8
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

    var isExpanded: Bool {
        expansionState.isExpanded
    }

    func setExpanded(_ expanded: Bool) {
        guard expansionState.isExpanded != expanded else { return }
        expansionState.isExpanded = expanded
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
        let size = currentSize
        let frame = Self.panelFrame(
            screenFrame: screenContainingMouse().visibleFrame,
            size: size,
            topInset: Metrics.topInset
        )

        panel.setFrame(frame, display: true, animate: animated)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    private func screenContainingMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}
