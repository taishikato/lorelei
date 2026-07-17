//
//  DictationReplacementPlannerTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct DictationReplacementPlannerTests {
    @Test func plansReplacementWhenRawEndsExactlyAtCaret() {
        let field = "notes: hello world raw text"
        let raw = "raw text"
        let plan = DictationReplacementPlanner.plan(
            fieldValue: field,
            caretLocation: (field as NSString).length,
            rawText: raw,
            cleanedText: "clean text."
        )
        #expect(plan == DictationReplacementPlan(
            range: NSRange(
                location: (field as NSString).length - (raw as NSString).length,
                length: (raw as NSString).length
            ),
            replacement: "clean text."
        ))
    }

    @Test func refusesWhenCaretUnknown() {
        #expect(DictationReplacementPlanner.plan(
            fieldValue: "abc raw",
            caretLocation: nil,
            rawText: "raw",
            cleanedText: "x"
        ) == nil)
    }

    @Test func refusesWhenUserTypedAfterRaw() {
        let field = "raw text and more typing"
        #expect(DictationReplacementPlanner.plan(
            fieldValue: field,
            caretLocation: (field as NSString).length,
            rawText: "raw text",
            cleanedText: "clean"
        ) == nil)
    }

    @Test func refusesWhenCaretMovedInsideRaw() {
        let field = "say raw text"
        #expect(DictationReplacementPlanner.plan(
            fieldValue: field,
            caretLocation: 7,
            rawText: "raw text",
            cleanedText: "clean"
        ) == nil)
    }

    @Test func refusesWhenCleanedEqualsRaw() {
        let field = "raw text"
        #expect(DictationReplacementPlanner.plan(
            fieldValue: field,
            caretLocation: (field as NSString).length,
            rawText: "raw text",
            cleanedText: "raw text"
        ) == nil)
    }

    @Test func refusesWhenFieldShorterThanRaw() {
        #expect(DictationReplacementPlanner.plan(
            fieldValue: "raw",
            caretLocation: 3,
            rawText: "raw text",
            cleanedText: "clean"
        ) == nil)
    }

    @Test func handlesUTF16CorrectlyForJapaneseAndEmoji() {
        let raw = "こんにちは 👋 世界"
        let field = "メモ: " + raw
        let caret = (field as NSString).length
        let plan = DictationReplacementPlanner.plan(
            fieldValue: field,
            caretLocation: caret,
            rawText: raw,
            cleanedText: "こんにちは、世界。"
        )
        #expect(plan?.range == NSRange(
            location: caret - (raw as NSString).length,
            length: (raw as NSString).length
        ))
    }
}
