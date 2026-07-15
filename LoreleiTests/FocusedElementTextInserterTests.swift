//
//  FocusedElementTextInserterTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct FocusedElementTextInserterTests {
    @Test func splicesAtCaretWhenNothingIsSelected() {
        let result = DictationAXTextMutation.splicing(
            value: "hello world",
            location: 5,
            length: 0,
            insertion: " there"
        )
        #expect(result == "hello there world")
    }

    @Test func replacesSelectedRange() {
        let result = DictationAXTextMutation.splicing(
            value: "hello world",
            location: 6,
            length: 5,
            insertion: "there"
        )
        #expect(result == "hello there")
    }

    @Test func clampsOutOfRangeCaretToEnd() {
        let result = DictationAXTextMutation.splicing(
            value: "hi",
            location: 99,
            length: 0,
            insertion: "!"
        )
        #expect(result == "hi!")
    }

    @Test func treatsUnchangedValueAfterSelectedTextSetAsUnverified() {
        #expect(
            DictationAXTextMutation.didSelectedTextInsertLikelyApply(
                beforeValue: "abc",
                afterValue: "abc",
                insertion: "x"
            ) == false
        )
    }

    @Test func acceptsValueGrowthContainingInsertion() {
        #expect(
            DictationAXTextMutation.didSelectedTextInsertLikelyApply(
                beforeValue: "ab",
                afterValue: "axb",
                insertion: "x"
            )
        )
    }
}
