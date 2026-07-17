//
//  SettingsWindowController.swift
//  Lorelei
//
//  Owns the standard macOS settings window opened from the floating toolbar.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private var window: NSWindow?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    func show() {
        let settingsWindow = window ?? makeWindow()
        window = settingsWindow

        // LSUIElement keeps Lorelei dockless by default; regular activation
        // gives the settings window standard app-menu and key-window behavior.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
        LoreleiAnalytics.capture(.settingsPanelOpened)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        // A hosting controller sizes the window to the SwiftUI content, so the
        // window fits the settings snugly with no dead space below them.
        let hostingController = NSHostingController(
            rootView: CompanionPanelView(companionManager: companionManager)
        )
        // Content-driven window sizing via preferredContentSize only. The
        // default options add min/max window extrema, whose update path
        // re-marks constraints during the window's own updateConstraints pass
        // and crashes when the panel content updates mid-display-cycle
        // (owner-reproduced with this window open during an edit; plan 033/034).
        hostingController.sizingOptions = [.preferredContentSize]
        let settingsWindow = NSWindow(contentViewController: hostingController)
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable]

        settingsWindow.title = "Lorelei Settings"
        settingsWindow.isReleasedWhenClosed = false
        // Let the user drag the window by its background, not just the thin
        // title bar - interactive controls still capture their own drags.
        settingsWindow.isMovableByWindowBackground = true
        settingsWindow.delegate = self
        settingsWindow.center()

        return settingsWindow
    }
}
