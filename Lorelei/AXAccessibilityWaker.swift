//
//  AXAccessibilityWaker.swift
//  Lorelei
//
//  Electron keeps its accessibility tree dormant until an assistive client
//  announces itself; the documented wake-up is setting AXManualAccessibility
//  = true on the application element (plans/027-findings.md). This helper
//  owns that wake: strictly on-demand (only after a focused-element read
//  fails with a dormant-tree status), single bounded retry, no loops.
//

import ApplicationServices
import Foundation

@MainActor
enum AXAccessibilityWaker {
    static let manualAccessibilityAttribute = "AXManualAccessibility"

    nonisolated static func isWakeable(_ status: AXError) -> Bool {
        status == .noValue || status == .cannotComplete
    }

    @discardableResult
    static func wake(processID: pid_t) -> AXError {
        let appElement = AXUIElementCreateApplication(processID)
        let status = AXUIElementSetAttributeValue(
            appElement,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        LoreleiDiagLog.log("axWake: set AXManualAccessibility pid=\(processID) status=\(status.rawValue)")
        return status
    }

    static func focusedElement(processID: pid_t) -> (element: AXUIElement?, status: AXError) {
        let appElement = AXUIElementCreateApplication(processID)
        var focusedObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard status == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return (nil, status)
        }
        return (focusedObject as! AXUIElement, status)
    }

    static func focusedElementWakingIfNeeded(
        processID: pid_t
    ) async -> (element: AXUIElement?, status: AXError) {
        let first = focusedElement(processID: processID)
        guard first.element == nil, isWakeable(first.status) else { return first }
        wake(processID: processID)
        try? await Task.sleep(for: .milliseconds(150))
        let second = focusedElement(processID: processID)
        LoreleiDiagLog.log("axWake: waited retry status=\(second.status.rawValue)")
        return second
    }

    static func focusedElementWakingImmediately(
        processID: pid_t
    ) -> (element: AXUIElement?, status: AXError) {
        let first = focusedElement(processID: processID)
        guard first.element == nil, isWakeable(first.status) else { return first }
        wake(processID: processID)
        let second = focusedElement(processID: processID)
        LoreleiDiagLog.log("axWake: immediate retry status=\(second.status.rawValue)")
        return second
    }
}
