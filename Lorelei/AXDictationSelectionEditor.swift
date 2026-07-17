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

    /// The element readSelection captured, paired with the snapshot it
    /// produced. applyEdit prefers this element - Chromium focus reads
    /// flicker to containers (AXWebArea/AXGroup) seconds later, but the
    /// captured element stays valid. Consumed by the next applyEdit.
    private var capturedSelection: (element: AXUIElement, snapshot: DictationSelectionSnapshot)?

    func readSelection(targetProcessID: pid_t?) -> DictationSelectionSnapshot? {
        guard let targetProcessID else {
            LoreleiDiagLog.log("dictationEdit: readSelection nil")
            capturedSelection = nil
            return nil
        }

        let focused = AXAccessibilityWaker.focusedElementWakingImmediately(
            processID: targetProcessID
        )
        guard let element = focused.element else {
            LoreleiDiagLog.log("dictationEdit: readSelection nil")
            capturedSelection = nil
            return nil
        }
        let role = Self.role(of: element)

        var selectedObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedObject
        ) == .success,
            let selectedText = selectedObject as? String,
            !selectedText.isEmpty else {
            LoreleiDiagLog.log("dictationEdit: readSelection nil role=\(role)")
            capturedSelection = nil
            return nil
        }

        guard let range = Self.selectedRange(of: element),
              range.length == (selectedText as NSString).length else {
            LoreleiDiagLog.log("dictationEdit: readSelection nil role=\(role)")
            capturedSelection = nil
            return nil
        }

        let snapshot = DictationSelectionSnapshot(text: selectedText, range: range)
        capturedSelection = (element, snapshot)
        return snapshot
    }

    func applyEdit(
        snapshot: DictationSelectionSnapshot,
        editedText: String,
        targetProcessID: pid_t?
    ) async -> DictationEditApplyOutcome {
        guard let targetProcessID else {
            LoreleiDiagLog.log("dictationEdit: no focused element → clipboard fallback")
            return .checkFailed
        }

        let captured = capturedSelection
        capturedSelection = nil
        if let captured, captured.snapshot == snapshot {
            var capturedValueObject: AnyObject?
            if AXUIElementCopyAttributeValue(
                captured.element,
                kAXValueAttribute as CFString,
                &capturedValueObject
            ) == .success,
                let capturedFieldValue = capturedValueObject as? String,
                let plan = DictationEditSplicePlanner.plan(
                    fieldValue: capturedFieldValue,
                    snapshot: snapshot,
                    editedText: editedText
                ) {
                if Self.splice(plan: plan, on: captured.element) {
                    LoreleiDiagLog.log(
                        "dictationEdit: applied via=captured chars=\(plan.range.length)→\(editedText.count)"
                    )
                    return .applied
                }
                LoreleiDiagLog.log("dictationEdit: captured splice rejected → refocus")
            } else {
                LoreleiDiagLog.log("dictationEdit: captured element stale → refocus")
            }
        }

        let focused = await AXAccessibilityWaker.focusedElementWakingIfNeeded(
            processID: targetProcessID
        )
        guard let element = focused.element else {
            LoreleiDiagLog.log(
                "dictationEdit: no focused element status=\(focused.status.rawValue) → clipboard fallback"
            )
            return .checkFailed
        }
        let role = Self.role(of: element)

        var valueObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        ) == .success,
            let fieldValue = valueObject as? String else {
            LoreleiDiagLog.log("dictationEdit: unreadable value role=\(role) → clipboard fallback")
            return .checkFailed
        }

        guard let plan = DictationEditSplicePlanner.plan(
            fieldValue: fieldValue,
            snapshot: snapshot,
            editedText: editedText
        ) else {
            LoreleiDiagLog.log(
                "dictationEdit: selection changed role=\(role) valueLength=\((fieldValue as NSString).length) snapshotLength=\((snapshot.text as NSString).length) rangeLocation=\(snapshot.range.location) rangeLength=\(snapshot.range.length) → clipboard fallback"
            )
            return .checkFailed
        }

        guard Self.splice(plan: plan, on: element) else {
            LoreleiDiagLog.log("dictationEdit: splice rejected → clipboard fallback")
            return .checkFailed
        }

        LoreleiDiagLog.log(
            "dictationEdit: applied via=refocused chars=\(plan.range.length)→\(editedText.count)"
        )
        return .applied
    }

    private static func splice(plan: DictationReplacementPlan, on element: AXUIElement) -> Bool {
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
            return false
        }
        return true
    }

    private static func role(of element: AXUIElement) -> String {
        var object: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &object)
        return (object as? String) ?? "nil"
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
