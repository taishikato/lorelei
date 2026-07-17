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
            if Self.selectionIsIntact(
                currentSelectedText: readSelectedText(captured.element),
                snapshot: snapshot
            ) {
                LoreleiDiagLog.log(
                    "dictationEdit: ready via=intact-captured selectedChars=\(snapshot.text.count)"
                )
                return .ready
            }
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

        if Self.selectionIsIntact(
            currentSelectedText: readSelectedText(element),
            snapshot: snapshot
        ) {
            LoreleiDiagLog.log(
                "dictationEdit: ready via=intact-refocused selectedChars=\(snapshot.text.count)"
            )
            return .ready
        }

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
            Self.logSpliceMismatchDiagnostics(fieldValue: fieldValue, snapshot: snapshot)
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

    /// The live selection still reads exactly as the press-time snapshot -
    /// paste can replace it directly, no re-selection or value math needed.
    /// Same-API comparison (kAXSelectedText vs kAXSelectedText) cancels
    /// Electron's kAXValue newline-normalization differences (plan 035).
    nonisolated static func selectionIsIntact(
        currentSelectedText: String?,
        snapshot: DictationSelectionSnapshot
    ) -> Bool {
        guard let currentSelectedText, !currentSelectedText.isEmpty else { return false }
        return currentSelectedText == snapshot.text
    }

    /// Read kAXSelectedTextAttribute; nil on any AX failure (falls through).
    private func readSelectedText(_ element: AXUIElement) -> String? {
        var selectedObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedObject
        ) == .success else {
            return nil
        }
        return selectedObject as? String
    }

    /// DEBUG-only forensic detail for splice-plan rejections: where the field
    /// content first diverges from the press-time snapshot, as UTF-16 code
    /// units (numbers only - never text content, even in the local diag log).
    private static func logSpliceMismatchDiagnostics(
        fieldValue: String,
        snapshot: DictationSelectionSnapshot
    ) {
        let field = fieldValue as NSString
        let expected = snapshot.text as NSString
        let range = snapshot.range
        guard range.location >= 0, range.location + range.length <= field.length else {
            LoreleiDiagLog.log("dictationEdit: mismatch=range-out-of-bounds")
            return
        }
        let actual = field.substring(
            with: NSRange(location: range.location, length: range.length)
        ) as NSString
        guard actual.length == expected.length else {
            LoreleiDiagLog.log(
                "dictationEdit: mismatch=length actual=\(actual.length) expected=\(expected.length)"
            )
            return
        }
        for index in 0..<expected.length where actual.character(at: index) != expected.character(at: index) {
            LoreleiDiagLog.log(
                "dictationEdit: mismatch=content firstDiffAt=\(index) "
                + "actualUnit=\(actual.character(at: index)) expectedUnit=\(expected.character(at: index))"
            )
            return
        }
        LoreleiDiagLog.log("dictationEdit: mismatch=none (planner rejected for another reason)")
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
