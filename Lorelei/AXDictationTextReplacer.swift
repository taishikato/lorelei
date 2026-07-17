//
//  AXDictationTextReplacer.swift
//  Lorelei
//
//  Replace-on-arrival executor: verifies via the accessibility API that the
//  raw dictation paste is still untouched at the caret, then splices in the
//  cleaned text by setting the selected range and selected text. Trusts a
//  successful splice without readback verification (Chrome readback lies).
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
    func replaceRawWithCleaned(
        rawText: String,
        cleanedText: String,
        targetProcessID: pid_t?
    ) async -> DictationReplacementOutcome
}

@MainActor
final class AXDictationTextReplacer: DictationTextReplacing {
    nonisolated init() {}

    func replaceRawWithCleaned(
        rawText: String,
        cleanedText: String,
        targetProcessID: pid_t?
    ) async -> DictationReplacementOutcome {
        guard cleanedText != rawText else { return .keptIdentical }
        guard let targetProcessID else { return .keptCheckFailed }

        let appElement = AXUIElementCreateApplication(targetProcessID)
        var focusedObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
            let focusedObject,
            CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            LoreleiDiagLog.log("dictationReplace: no focused element → keep raw")
            return .keptCheckFailed
        }
        let element = focusedObject as! AXUIElement

        var valueObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        ) == .success,
            let fieldValue = valueObject as? String else {
            LoreleiDiagLog.log("dictationReplace: unreadable value → keep raw")
            return .keptCheckFailed
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
            LoreleiDiagLog.log("dictationReplace: safety check failed → keep raw")
            return .keptCheckFailed
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
            LoreleiDiagLog.log("dictationReplace: splice rejected → keep raw")
            return .keptCheckFailed
        }

        LoreleiDiagLog.log(
            "dictationReplace: replaced chars=\(plan.range.length)→\(cleanedText.count)"
        )
        return .replaced
    }
}
