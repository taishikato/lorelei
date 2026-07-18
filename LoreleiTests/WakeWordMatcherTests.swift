//
//  WakeWordMatcherTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct WakeWordMatcherTests {
    @Test func matchesExactWord() {
        #expect(WakeWordMatcher.containsWakeWord("lorelei"))
    }

    @Test func matchesCapitalizedWord() {
        #expect(WakeWordMatcher.containsWakeWord("Lorelei"))
    }

    @Test func matchesTrailingPunctuation() {
        #expect(WakeWordMatcher.containsWakeWord("Lorelei,"))
        #expect(WakeWordMatcher.containsWakeWord("lorelei!"))
    }

    @Test func matchesEmbeddedInSentence() {
        #expect(WakeWordMatcher.containsWakeWord("hey lorelei please help"))
        #expect(WakeWordMatcher.containsWakeWord("Hey Lorelei, open Safari."))
    }

    @Test func doesNotMatchLongerTokenWithWakeWordPrefix() {
        #expect(!WakeWordMatcher.containsWakeWord("loreleis"))
    }

    @Test func doesNotMatchMidTokenSubstring() {
        #expect(!WakeWordMatcher.containsWakeWord("folklorelei"))
        #expect(!WakeWordMatcher.containsWakeWord("xloreleiy"))
    }

    @Test func doesNotMatchEmptyTranscript() {
        #expect(!WakeWordMatcher.containsWakeWord(""))
    }

    @Test func doesNotMatchWhenWakeWordAbsent() {
        #expect(!WakeWordMatcher.containsWakeWord("hello world"))
        #expect(!WakeWordMatcher.containsWakeWord("please open the browser"))
    }

    @Test func matchesCommonSpeechAnalyzerSpellingsForDefaultWakeWord() {
        #expect(WakeWordMatcher.containsWakeWord("lorelai"))
        #expect(WakeWordMatcher.containsWakeWord("Hey Lorelai,"))
        #expect(WakeWordMatcher.containsWakeWord("loreley"))
    }

    @Test func customWakeWordDoesNotAcceptLoreleiAliases() {
        #expect(!WakeWordMatcher.containsWakeWord("lorelai", wakeWord: "buddy"))
        #expect(WakeWordMatcher.containsWakeWord("buddy", wakeWord: "buddy"))
    }
}
