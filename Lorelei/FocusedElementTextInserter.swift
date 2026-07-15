//
//  FocusedElementTextInserter.swift
//  Lorelei
//
//  Inserts dictation text into the system-wide focused AX element.
//  Prefer caret insert via kAXSelectedTextAttribute; when browsers/Electron
//  acknowledge that write without mutating the field, fall back to splicing
//  into kAXValueAttribute at the caret. Never synthesizes keystrokes.
//

import ApplicationServices
import Foundation

enum DictationInsertionOutcome: Equatable, Sendable {
    case inserted
    case noEditableTarget
    case axError(AXError)
}

/// Pure string mutation helpers shared by the AX inserter and its tests.
enum DictationAXTextMutation {
    static func splicing(
        value: String,
        location: Int,
        length: Int,
        insertion: String
    ) -> String {
        let nsValue = value as NSString
        let clampedLocation = min(max(location, 0), nsValue.length)
        let clampedLength = min(max(length, 0), nsValue.length - clampedLocation)
        let prefix = nsValue.substring(to: clampedLocation)
        let suffix = nsValue.substring(from: clampedLocation + clampedLength)
        return prefix + insertion + suffix
    }

    /// Best-effort check that a selected-text write actually changed AXValue.
    /// Browsers often return AX success while leaving the value untouched.
    static func didSelectedTextInsertLikelyApply(
        beforeValue: String?,
        afterValue: String?,
        insertion: String
    ) -> Bool {
        guard !insertion.isEmpty else { return true }
        guard let afterValue else { return false }
        if let beforeValue, afterValue == beforeValue {
            return false
        }
        return afterValue.contains(insertion)
    }
}

protocol DictationTextInserting: AnyObject {
    func insert(_ text: String) async -> DictationInsertionOutcome
}

/// Thin AX adapter: resolve the system-wide focused element and insert text.
/// Unit tests cover mutation helpers; live AX stays behind this seam.
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
        let role = stringAttribute(kAXRoleAttribute as CFString, of: focusedElement) ?? "unknown"
        LoreleiDiagLog.log("systemDictation: insert target role=\(role)")

        let beforeValue = stringAttribute(kAXValueAttribute as CFString, of: focusedElement)

        if isAttributeSettable(kAXSelectedTextAttribute as CFString, of: focusedElement) {
            let setError = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            switch setError {
            case .success:
                let afterValue = stringAttribute(kAXValueAttribute as CFString, of: focusedElement)
                if DictationAXTextMutation.didSelectedTextInsertLikelyApply(
                    beforeValue: beforeValue,
                    afterValue: afterValue,
                    insertion: text
                ) {
                    LoreleiDiagLog.log("systemDictation: insert via selectedText")
                    return .inserted
                }
                LoreleiDiagLog.log("systemDictation: selectedText write unverified; trying AXValue splice")
            case .attributeUnsupported, .failure, .actionUnsupported:
                break
            default:
                return .axError(setError)
            }
        }

        if let spliced = splicedValue(for: focusedElement, insertion: text, beforeValue: beforeValue),
           isAttributeSettable(kAXValueAttribute as CFString, of: focusedElement) {
            let setError = AXUIElementSetAttributeValue(
                focusedElement,
                kAXValueAttribute as CFString,
                spliced as CFString
            )
            if setError == .success {
                let afterValue = stringAttribute(kAXValueAttribute as CFString, of: focusedElement)
                if afterValue == spliced
                    || DictationAXTextMutation.didSelectedTextInsertLikelyApply(
                        beforeValue: beforeValue,
                        afterValue: afterValue,
                        insertion: text
                    ) {
                    LoreleiDiagLog.log("systemDictation: insert via AXValue splice")
                    return .inserted
                }
                LoreleiDiagLog.log("systemDictation: AXValue splice unverified")
            } else {
                return .axError(setError)
            }
        }

        return .noEditableTarget
    }

    private func splicedValue(
        for element: AXUIElement,
        insertion: String,
        beforeValue: String?
    ) -> String? {
        let base = beforeValue ?? stringAttribute(kAXValueAttribute as CFString, of: element) ?? ""
        if let range = selectedTextRange(of: element) {
            return DictationAXTextMutation.splicing(
                value: base,
                location: range.location,
                length: range.length,
                insertion: insertion
            )
        }
        // No caret range - append. Better than silently dropping the transcript.
        return base + insertion
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var rangeObject: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeObject
        )
        guard error == .success, let rangeObject else { return nil }
        let axValue = rangeObject as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func isAttributeSettable(_ attribute: CFString, of element: AXUIElement) -> Bool {
        var isSettable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return error == .success && isSettable.boolValue
    }

    private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var object: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute, &object)
        guard error == .success, let object else { return nil }
        return object as? String
    }
}
