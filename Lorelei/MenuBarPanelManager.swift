//
//  MenuBarPanelManager.swift
//  Lorelei
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let loreleiDismissPanel = Notification.Name("loreleiDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 340
    private let minimumPanelHeight: CGFloat = 1

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .loreleiDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeLoreleiMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the Lorelei face as a template menu bar icon so it adapts to the
    /// current menu bar appearance.
    private func makeLoreleiMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        NSColor.black.setFill()
        NSColor.black.setStroke()

        let faceRect = NSRect(x: 2.25, y: 3.4, width: 13.5, height: 11.2)
        let outline = NSBezierPath(roundedRect: faceRect, xRadius: 5.2, yRadius: 5.2)
        outline.lineWidth = 1.6
        outline.stroke()

        let eyeSize: CGFloat = 2.2
        NSBezierPath(ovalIn: NSRect(x: 5.0, y: 8.3, width: eyeSize, height: eyeSize)).fill()
        NSBezierPath(ovalIn: NSRect(x: 10.8, y: 8.3, width: eyeSize, height: eyeSize)).fill()

        let mouth = NSBezierPath()
        mouth.move(to: CGPoint(x: 6.4, y: 6.5))
        mouth.curve(
            to: CGPoint(x: 11.6, y: 6.5),
            controlPoint1: CGPoint(x: 7.6, y: 5.7),
            controlPoint2: CGPoint(x: 10.4, y: 5.7)
        )
        mouth.lineWidth = 1.25
        mouth.lineCapStyle = .round
        mouth.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = AnyView(
            CompanionPanelView(companionManager: companionManager)
                .frame(width: panelWidth)
        )

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: minimumPanelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = .clear

        let panelSize = Self.fittingPanelSize(for: hostingView, width: panelWidth, minimumHeight: minimumPanelHeight)
        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        // A window shadow on a translucent panel draws a rectangular outline
        // around the rounded glass - the SwiftUI shape carries its own shadow.
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        let gapBelowMenuBar: CGFloat = 6

        let panelSize: CGSize
        if let hostingView = panel.contentView as? NSHostingView<AnyView> {
            panelSize = Self.fittingPanelSize(for: hostingView, width: panelWidth, minimumHeight: minimumPanelHeight)
            hostingView.setFrameSize(panelSize)
        } else {
            panelSize = panel.frame.size
        }
        let buttonWindow = statusItem?.button?.window
        let screenFrame = (buttonWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(origin: .zero, size: panelSize)

        let frame = Self.settingsPanelFrame(
            anchorFrame: buttonWindow?.frame,
            screenFrame: screenFrame,
            panelSize: panelSize,
            gapBelowMenuBar: gapBelowMenuBar
        )

        panel.setFrame(frame, display: true)
    }

    private static func fittingPanelSize(
        for hostingView: NSHostingView<AnyView>,
        width: CGFloat,
        minimumHeight: CGFloat
    ) -> CGSize {
        hostingView.setFrameSize(CGSize(width: width, height: minimumHeight))
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        return CGSize(
            width: width,
            height: max(minimumHeight, ceil(fittingSize.height))
        )
    }

    static func settingsPanelFrame(
        anchorFrame: CGRect?,
        screenFrame: CGRect,
        panelSize: CGSize,
        gapBelowMenuBar: CGFloat = 6
    ) -> CGRect {
        // Status items live in the menu bar, ABOVE the visible frame, so an
        // intersection test always fails. Treat the anchor as usable when it
        // is horizontally within the screen.
        guard let anchorFrame,
              anchorFrame.midX >= screenFrame.minX,
              anchorFrame.midX <= screenFrame.maxX else {
            return CGRect(
                x: screenFrame.midX - (panelSize.width / 2),
                y: screenFrame.midY - (panelSize.height / 2),
                width: panelSize.width,
                height: panelSize.height
            )
        }

        let proposedX = anchorFrame.maxX - panelSize.width
        let minX = screenFrame.minX
        let maxX = max(screenFrame.maxX - panelSize.width, minX)
        let clampedX = min(max(proposedX, minX), maxX)
        let proposedY = anchorFrame.minY - panelSize.height - gapBelowMenuBar
        let clampedY = max(proposedY, screenFrame.minY)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
