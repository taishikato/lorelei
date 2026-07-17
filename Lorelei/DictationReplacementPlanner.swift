//
//  DictationReplacementPlanner.swift
//  Lorelei
//
//  Pure decision logic for replace-on-arrival: the cleaned dictation text may
//  replace the raw paste ONLY when the raw text still sits, unmodified, ending
//  exactly at the caret. Anything else keeps the raw text (safe by design).
//  All offsets are UTF-16 (NSString/AX convention).
//

import Foundation

struct DictationReplacementPlan: Equatable, Sendable {
    let range: NSRange
    let replacement: String
}

enum DictationReplacementPlanner {
    static func plan(
        fieldValue: String,
        caretLocation: Int?,
        rawText: String,
        cleanedText: String
    ) -> DictationReplacementPlan? {
        guard cleanedText != rawText else { return nil }
        guard let caretLocation else { return nil }

        let field = fieldValue as NSString
        let rawLength = (rawText as NSString).length
        guard rawLength > 0,
              caretLocation >= rawLength,
              caretLocation <= field.length else { return nil }

        let range = NSRange(location: caretLocation - rawLength, length: rawLength)
        guard field.substring(with: range) == rawText else { return nil }

        return DictationReplacementPlan(range: range, replacement: cleanedText)
    }
}
