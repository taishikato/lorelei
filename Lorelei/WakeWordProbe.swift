//
//  WakeWordProbe.swift
//  Lorelei
//
//  Pure wake-word matcher plus a DEBUG-only measurement probe.
//

import Foundation

enum WakeWordMatcher {
    /// Whole-token, case-insensitive match: 'Lorelei,' and 'hey lorelei'
    /// match; substrings inside longer words do not.
    static func containsWakeWord(
        _ transcript: String,
        wakeWord: String = "lorelei"
    ) -> Bool {
        let target = wakeWord.lowercased()
        guard !target.isEmpty else { return false }

        return transcript
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == target }
    }
}
