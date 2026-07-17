//
//  DictationEditSplicePlanner.swift
//  Lorelei
//
//  Pure decision logic for Edit mode: the edited text may replace the captured
//  selection ONLY when that selection still sits, byte-identical, at its
//  captured range inside the current field value. Anything else refuses, and
//  the controller falls back to the clipboard. Offsets are UTF-16 throughout.
//

import Foundation

struct DictationSelectionSnapshot: Equatable, Sendable {
    let text: String
    let range: NSRange
}

enum DictationEditSplicePlanner {
    static let maxSelectionUTF16Length = 8000

    static func usableSnapshot(
        _ snapshot: DictationSelectionSnapshot?
    ) -> DictationSelectionSnapshot? {
        guard let snapshot else { return nil }
        let length = (snapshot.text as NSString).length
        guard length > 0,
              length <= maxSelectionUTF16Length,
              !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return snapshot
    }

    static func plan(
        fieldValue: String,
        snapshot: DictationSelectionSnapshot,
        editedText: String
    ) -> DictationReplacementPlan? {
        let field = fieldValue as NSString
        let range = snapshot.range
        guard range.length == (snapshot.text as NSString).length,
              range.location >= 0,
              range.location + range.length <= field.length,
              field.substring(with: range) == snapshot.text else {
            return nil
        }
        return DictationReplacementPlan(range: range, replacement: editedText)
    }
}
