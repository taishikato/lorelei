//
//  OnboardingWindowController.swift
//  Lorelei
//
//  Owns the guided first-run onboarding window shown before the settings
//  window on a fresh install (or after permissions/workspace were never set
//  up). Mirrors SettingsWindowController's window lifecycle exactly.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private var window: NSWindow?
    private var hasCapturedStart = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    func show() {
        let onboardingWindow = window ?? makeWindow()
        window = onboardingWindow

        // LSUIElement keeps Lorelei dockless by default; regular activation
        // gives the onboarding window standard app-menu and key-window behavior.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow.makeKeyAndOrderFront(nil)

        if !hasCapturedStart {
            hasCapturedStart = true
            LoreleiAnalytics.capture(.onboardingStarted)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        // Content-fitted window without SwiftUI's built-in window sizing,
        // which crashes on this OS - see WindowFittingHostingView.
        let hostingView = WindowFittingHostingView(
            rootView: OnboardingView(companionManager: companionManager) { [weak self] in
                self?.window?.close()
            }
        )
        hostingView.sizingOptions = []
        let onboardingWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        onboardingWindow.contentView = hostingView
        onboardingWindow.setContentSize(hostingView.fittingSize)

        onboardingWindow.title = "Welcome to Lorelei"
        onboardingWindow.isReleasedWhenClosed = false
        // Let the user drag the window by its background, not just the thin
        // title bar - interactive controls still capture their own drags.
        onboardingWindow.isMovableByWindowBackground = true
        onboardingWindow.delegate = self
        onboardingWindow.center()

        return onboardingWindow
    }
}
