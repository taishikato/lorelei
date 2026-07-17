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
        // Content-fitted window without SwiftUI's built-in window sizing,
        // which crashes on this OS - see WindowFittingHostingView.
        let hostingView = WindowFittingHostingView(
            rootView: CompanionPanelView(companionManager: companionManager)
        )
        hostingView.sizingOptions = []
        let settingsWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.contentView = hostingView
        settingsWindow.setContentSize(hostingView.fittingSize)

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
