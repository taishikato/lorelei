//
//  LoreleiApp.swift
//  Lorelei
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import SwiftUI

enum LoreleiDebugURLHandler {
    static func debugPrompt(fromURL url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "lorelei",
              components.host == "run",
              let prompt = components.queryItems?.first(where: { $0.name == "prompt" })?.value
        else {
            return nil
        }

        return prompt
    }
}

@main
struct LoreleiApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var toolbarController: LoreleiToolbarController?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Lorelei: Starting...")
        print("🎯 Lorelei: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        toolbarController = LoreleiToolbarController(companionManager: companionManager)
        menuBarPanelManager?.onPanelVisibilityChanged = { [weak self] visible in
            self?.toolbarController?.setConcealed(visible)
        }
        companionManager.start()
#if DEBUG
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
#endif
        toolbarController?.show()
        // Auto-open the panel only when permissions are missing or revoked.
        if !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

#if DEBUG
    /// Modern AppKit delivers scheme opens here; the kAEGetURL handler below
    /// stays as a fallback for Apple-Event senders.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let prompt = LoreleiDebugURLHandler.debugPrompt(fromURL: url) else { continue }
            companionManager.handleDebugPrompt(prompt)
        }
    }
#endif

#if DEBUG
    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              let prompt = LoreleiDebugURLHandler.debugPrompt(fromURL: url)
        else {
            return
        }

        companionManager.handleDebugPrompt(prompt)
    }
#endif

}
