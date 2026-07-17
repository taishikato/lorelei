//
//  AXDictationTextReplacer.swift
//  Lorelei
//
//  Replace-on-arrival executor: verifies via the accessibility API that the
//  raw dictation paste is still untouched at the caret, then selects that
//  range for paste. Content lands via the controller's paste inserter - AX
//  never writes text (Electron rich editors report text-set success without
//  applying).
//

import AppKit
import ApplicationServices
import Foundation

enum DictationReplacementOutcome: String, Equatable, Sendable {
    case replaced
    case keptCheckFailed = "kept_check_failed"
    case keptIdentical = "kept_identical"
}

@MainActor
protocol DictationTextReplacing: AnyObject {
    func prepareRawForPaste(
        rawText: String,
        cleanedText: String,
        targetProcessID: pid_t?
    ) async -> DictationPastePreparationOutcome
}

@MainActor
final class AXDictationTextReplacer: DictationTextReplacing {
    nonisolated init() {}

    func prepareRawForPaste(
        rawText: String,
        cleanedText: String,
        targetProcessID: pid_t?
    ) async -> DictationPastePreparationOutcome {
        guard cleanedText != rawText else { return .checkFailed }
        guard let targetProcessID else { return .checkFailed }

        let focused = await AXAccessibilityWaker.focusedElementWakingIfNeeded(
            processID: targetProcessID
        )
        guard let element = focused.element else {
            LoreleiDiagLog.log("dictationReplace: no focused element status=\(focused.status.rawValue) → keep raw")
            return .checkFailed
        }
        let role = {
            var object: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &object)
            return object as? String
        }() ?? "nil"

        var valueObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        ) == .success,
            let fieldValue = valueObject as? String else {
            LoreleiDiagLog.log("dictationReplace: unreadable value role=\(role) → keep raw")
            return .checkFailed
        }

        var rangeObject: AnyObject?
        var caretLocation: Int?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeObject
        ) == .success,
            let rangeObject,
            CFGetTypeID(rangeObject) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(rangeObject as! AXValue, .cfRange, &cfRange),
               cfRange.length == 0 {
                caretLocation = cfRange.location
            }
        }

        guard let plan = DictationReplacementPlanner.plan(
            fieldValue: fieldValue,
            caretLocation: caretLocation,
            rawText: rawText,
            cleanedText: cleanedText
        ) else {
            LoreleiDiagLog.log("dictationReplace: safety check failed role=\(role) valueLength=\((fieldValue as NSString).length) caret=\(caretLocation.map(String.init) ?? "nil") rawLength=\((rawText as NSString).length) → keep raw")
            return .checkFailed
        }

        guard Self.selectAndVerify(
            range: plan.range,
            expectedText: rawText,
            on: element
        ) else {
            LoreleiDiagLog.log("dictationReplace: splice rejected → keep raw")
            return .checkFailed
        }

        LoreleiDiagLog.log(
            "dictationReplace: ready rawLength=\((rawText as NSString).length)"
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
}
