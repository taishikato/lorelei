//
//  LoreleiApp.swift
//  Lorelei
//
//  Accessory companion app. The always-visible floating buddy is the primary
//  entry point, and its toolbar opens a standard macOS settings window.
//

import AppKit
import SwiftUI

struct AXProbeRequest: Equatable {
    let wake: Bool
}

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

    static func axProbeRequest(url: URL) -> AXProbeRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "lorelei",
              components.host == "ax-probe" else {
            return nil
        }
        let wake = components.queryItems?.first(where: { $0.name == "wake" })?.value == "1"
        return AXProbeRequest(wake: wake)
    }

    /// Parses `lorelei://wake-probe?on=1|0`. Returns nil when the host is not
    /// wake-probe; otherwise the desired on/off state (default on).
    static func wakeProbeRequest(url: URL) -> Bool? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "lorelei",
              components.host == "wake-probe" else {
            return nil
        }
        guard let onValue = components.queryItems?.first(where: { $0.name == "on" })?.value else {
            return true
        }
        return onValue != "0"
    }
}

@main
struct LoreleiApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app is driven by AppKit windows managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene while LSUIElement=true keeps the Dock icon hidden by default.
        Settings {
            EmptyView()
        }
        .commands {
            // The real settings live in an AppKit window opened from the
            // floating toolbar's gear button. Remove the default "Settings…"
            // menu item (and its Cmd-, shortcut) so the placeholder SwiftUI
            // Settings scene is never surfaced when the app is .regular.
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

/// Manages the companion lifecycle: creates the floating buddy, settings
/// window controller, and companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var toolbarController: LoreleiToolbarController?
    private let companionManager = CompanionManager()
#if DEBUG
    private let wakeWordProbe = WakeWordProbe()
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Lorelei: Starting...")
        print("🎯 Lorelei: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        LoreleiAnalytics.capture(.appLaunched)

        settingsWindowController = SettingsWindowController(companionManager: companionManager)
        onboardingWindowController = OnboardingWindowController(companionManager: companionManager)
        toolbarController = LoreleiToolbarController(companionManager: companionManager)
        toolbarController?.onOpenSettings = { [weak self] in
            // Collapse the floating panel so it doesn't sit over the settings
            // window the user just opened from it.
            self?.toolbarController?.setExpanded(false)
            self?.settingsWindowController?.show()
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
        // Guide fresh installs through a first-run flow before falling back
        // to auto-opening settings when permissions are missing or revoked.
        if LoreleiOnboarding.shouldShow() {
            onboardingWindowController?.show()
        } else if !companionManager.allPermissionsGranted {
            settingsWindowController?.show()
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
            if let request = LoreleiDebugURLHandler.axProbeRequest(url: url) {
                AXFocusProbe.runAndLog(wake: request.wake)
                continue
            }
            if let enabled = LoreleiDebugURLHandler.wakeProbeRequest(url: url) {
                if enabled {
                    wakeWordProbe.start()
                } else {
                    wakeWordProbe.stop()
                }
                continue
            }
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
              let url = URL(string: urlString)
        else {
            return
        }

        if let request = LoreleiDebugURLHandler.axProbeRequest(url: url) {
            AXFocusProbe.runAndLog(wake: request.wake)
            return
        }

        if let enabled = LoreleiDebugURLHandler.wakeProbeRequest(url: url) {
            if enabled {
                wakeWordProbe.start()
            } else {
                wakeWordProbe.stop()
            }
            return
        }

        guard let prompt = LoreleiDebugURLHandler.debugPrompt(fromURL: url) else {
            return
        }

        companionManager.handleDebugPrompt(prompt)
    }
#endif

}
