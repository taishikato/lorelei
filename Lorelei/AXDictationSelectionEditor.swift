//
//  AXDictationSelectionEditor.swift
//  Lorelei
//
//  Edit-mode AX layer: reads the focused element's selection at press time and
//  later prepares that range for paste by selecting and verifying the selection
//  text. Content lands via the controller's paste inserter - AX never writes
//  text (Electron rich editors report text-set success without applying).
//

import AppKit
import ApplicationServices
import Foundation

enum DictationPastePreparationOutcome: String, Equatable, Sendable {
    case ready
    case checkFailed = "check_failed"
}

@MainActor
protocol DictationSelectionEditing: AnyObject {
    func readSelection(targetProcessID: pid_t?) -> DictationSelectionSnapshot?
    func prepareSelectionForPaste(
        snapshot: DictationSelectionSnapshot,
        editedText: String,
        targetProcessID: pid_t?
    ) async -> DictationPastePreparationOutcome
}

@MainActor
final class AXDictationSelectionEditor: DictationSelectionEditing {
    nonisolated init() {}

    /// The element readSelection captured, paired with the snapshot it
    /// produced. prepareSelectionForPaste prefers this element - Chromium
    /// focus reads flicker to containers (AXWebArea/AXGroup) seconds later,
    /// but the captured element stays valid. Consumed by the next prepare.
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

    func prepareSelectionForPaste(
        snapshot: DictationSelectionSnapshot,
        editedText: String,
        targetProcessID: pid_t?
    ) async -> DictationPastePreparationOutcome {
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
                if Self.selectAndVerify(
                    range: plan.range,
                    expectedText: snapshot.text,
                    on: captured.element
                ) {
                    LoreleiDiagLog.log(
                        "dictationEdit: ready via=captured selectedChars=\(snapshot.text.count)"
                    )
                    return .ready
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

        guard Self.selectAndVerify(
            range: plan.range,
            expectedText: snapshot.text,
            on: element
        ) else {
            LoreleiDiagLog.log("dictationEdit: splice rejected → clipboard fallback")
            return .checkFailed
        }

        LoreleiDiagLog.log(
            "dictationEdit: ready via=refocused selectedChars=\(snapshot.text.count)"
        )
        return .ready
    }

    /// Select the plan range, then trust only the SELECTION readback: the
    /// selection must read back as exactly the text we are about to replace.
    /// AX text sets lie in Electron rich editors (031 field data); AX
    /// selection reads are the same primitive readSelection already trusts.
    /// The set status is deliberately ignored: if the range-set no-ops while
    /// the user's original selection is still active, the readback still
    /// matches and the paste lands correctly.
    private static func selectAndVerify(
        range: NSRange,
        expectedText: String,
        on element: AXUIElement
    ) -> Bool {
        var selectRange = CFRange(location: range.location, length: range.length)
        if let axRange = AXValueCreate(.cfRange, &selectRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                axRange
            )
        }

        var selectedObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedObject
        ) == .success,
            let selectedText = selectedObject as? String,
            selectedText == expectedText else {
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
