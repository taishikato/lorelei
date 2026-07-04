//
//  GlobalPushToTalkShortcutMonitor.swift
//  Lorelei
//
//  Captures push-to-talk keyboard shortcuts while Lorelei is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var releaseWatchdogTimer: Timer?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        stopReleaseWatchdog()

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            LoreleiDiagLog.log("shortcut: event tap disabled (\(eventType.rawValue)), re-enabling")
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            // Any key-up that happened while the tap was disabled is gone;
            // resync immediately so a released shortcut doesn't stay stuck.
            synthesizeReleaseIfShortcutNoLongerHeld()
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            LoreleiDiagLog.log("shortcut: pressed")
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
            startReleaseWatchdog()
        case .released:
            LoreleiDiagLog.log("shortcut: released")
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
            stopReleaseWatchdog()
        }

        return Unmanaged.passUnretained(event)
    }

    /// macOS disables the event tap when the main thread stalls past the
    /// tap timeout (model load, audio engine startup). A key-up delivered
    /// in that window is lost forever, which used to leave dictation
    /// listening indefinitely. While the shortcut is held, poll the live
    /// modifier state and synthesize the release once the keys are up.
    private func startReleaseWatchdog() {
        releaseWatchdogTimer?.invalidate()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.synthesizeReleaseIfShortcutNoLongerHeld()
        }
        releaseWatchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopReleaseWatchdog() {
        releaseWatchdogTimer?.invalidate()
        releaseWatchdogTimer = nil
    }

    private func synthesizeReleaseIfShortcutNoLongerHeld() {
        guard isShortcutCurrentlyPressed else {
            stopReleaseWatchdog()
            return
        }
        guard !BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: NSEvent.modifierFlags) else {
            return
        }

        print("⚠️ Global push-to-talk: synthesizing missed release (event tap dropped the key-up)")
        LoreleiDiagLog.log("shortcut: synthesizing missed release")
        isShortcutCurrentlyPressed = false
        shortcutTransitionPublisher.send(.released)
        stopReleaseWatchdog()
    }
}
