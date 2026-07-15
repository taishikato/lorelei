//
//  FocusedElementTextInserter.swift
//  Lorelei
//
//  Inserts dictation text into the system-wide focused AX element via
//  kAXSelectedTextAttribute (caret insert). Never synthesizes keystrokes.
//

import ApplicationServices
import Foundation

enum DictationInsertionOutcome: Equatable, Sendable {
    case inserted
    case noEditableTarget
    case axError(AXError)
}

protocol DictationTextInserting: AnyObject {
    func insert(_ text: String) async -> DictationInsertionOutcome
}

/// Thin AX adapter: resolve the system-wide focused element and set
/// `kAXSelectedTextAttribute`. Unit tests fake `DictationTextInserting`
/// rather than driving real Accessibility.
@MainActor
final class FocusedElementTextInserter: DictationTextInserting {
    func insert(_ text: String) async -> DictationInsertionOutcome {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedError == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return .noEditableTarget
        }

        let focusedElement = focusedObject as! AXUIElement
        var isSettable: DarwinBoolean = false
        let settableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableError == .success, isSettable.boolValue else {
            return .noEditableTarget
        }

        let setError = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if setError == .success {
            return .inserted
        }
        return .axError(setError)
    }
}
