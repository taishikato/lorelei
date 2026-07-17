//
//  AXDictationSelectionEditor.swift
//  Lorelei
//
//  Edit-mode AX layer: reads the focused element's selection at press time and
//  later splices the Codex-edited text over it, but only when the captured
//  selection is still byte-identical at its captured range. Trusts a
//  successful splice without readback verification (Chrome readback lies).
//

import AppKit
import ApplicationServices
import Foundation

enum DictationEditApplyOutcome: String, Equatable, Sendable {
    case applied
    case checkFailed = "check_failed"
}

@MainActor
protocol DictationSelectionEditing: AnyObject {
    func readSelection(targetProcessID: pid_t?) -> DictationSelectionSnapshot?
    func applyEdit(
        snapshot: DictationSelectionSnapshot,
        editedText: String,
        targetProcessID: pid_t?
    ) async -> DictationEditApplyOutcome
}

@MainActor
final class AXDictationSelectionEditor: DictationSelectionEditing {
    nonisolated init() {}

    func readSelection(targetProcessID: pid_t?) -> DictationSelectionSnapshot? {
        guard let targetProcessID,
              let element = Self.focusedElement(processID: targetProcessID) else {
            return nil
        }

        var selectedObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedObject
        ) == .success,
            let selectedText = selectedObject as? String,
            !selectedText.isEmpty else {
            return nil
        }

        guard let range = Self.selectedRange(of: element),
              range.length == (selectedText as NSString).length else {
            return nil
        }

        return DictationSelectionSnapshot(text: selectedText, range: range)
    }

    func applyEdit(
        snapshot: DictationSelectionSnapshot,
        editedText: String,
        targetProcessID: pid_t?
    ) async -> DictationEditApplyOutcome {
        guard let targetProcessID,
              let element = Self.focusedElement(processID: targetProcessID) else {
            LoreleiDiagLog.log("dictationEdit: no focused element → clipboard fallback")
            return .checkFailed
        }

        var valueObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        ) == .success,
            let fieldValue = valueObject as? String else {
            LoreleiDiagLog.log("dictationEdit: unreadable value → clipboard fallback")
            return .checkFailed
        }

        guard let plan = DictationEditSplicePlanner.plan(
            fieldValue: fieldValue,
            snapshot: snapshot,
            editedText: editedText
        ) else {
            LoreleiDiagLog.log("dictationEdit: selection changed → clipboard fallback")
            return .checkFailed
        }

        var selectRange = CFRange(location: plan.range.location, length: plan.range.length)
        guard let axRange = AXValueCreate(.cfRange, &selectRange),
              AXUIElementSetAttributeValue(
                  element,
                  kAXSelectedTextRangeAttribute as CFString,
                  axRange
              ) == .success,
              AXUIElementSetAttributeValue(
                  element,
                  kAXSelectedTextAttribute as CFString,
                  plan.replacement as CFString
              ) == .success else {
            LoreleiDiagLog.log("dictationEdit: splice rejected → clipboard fallback")
            return .checkFailed
        }

        LoreleiDiagLog.log(
            "dictationEdit: applied chars=\(plan.range.length)→\(editedText.count)"
        )
        return .applied
    }

    private static func focusedElement(processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)
        var focusedObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
            let focusedObject,
            CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedObject as! AXUIElement)
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var rangeObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeObject
        ) == .success,
            let rangeObject,
            CFGetTypeID(rangeObject) == AXValueGetTypeID() else {
            return nil
        }
        var cfRange = CFRange()
        guard AXValueGetValue(rangeObject as! AXValue, .cfRange, &cfRange) else {
            return nil
        }
        return NSRange(location: cfRange.location, length: cfRange.length)
    }
}
