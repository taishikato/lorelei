//
//  BuddyAudioFeedbackTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

@MainActor
struct BuddyAudioFeedbackTests {
    @Test func toggleOffSpeaksOnlyFirstSentence() {
        let speech = FakeSpeechOutput()
        let feedback = BuddyAudioFeedback(speechOutput: speech, readBackFullResponses: { false })

        feedback.play(.runSucceeded, spokenSummary: "Opened Gmail. Then waited.")

        #expect(speech.spoken == ["Opened Gmail."])
        #expect(speech.stopCount == 0)
    }

    @Test func toggleOnSpeaksFullTrimmedSummary() {
        let speech = FakeSpeechOutput()
        let feedback = BuddyAudioFeedback(speechOutput: speech, readBackFullResponses: { true })

        feedback.play(.runSucceeded, spokenSummary: "  Opened Gmail. Then waited.  ")

        #expect(speech.spoken == ["Opened Gmail. Then waited."])
        #expect(speech.stopCount == 0)
    }

    @Test func toggleOnSkipsWhitespaceOnlySummary() {
        let speech = FakeSpeechOutput()
        let feedback = BuddyAudioFeedback(speechOutput: speech, readBackFullResponses: { true })

        feedback.play(.runSucceeded, spokenSummary: "   \n\t  ")

        #expect(speech.spoken.isEmpty)
        #expect(speech.stopCount == 0)
    }

    @Test func listeningStartedStopsSpeechWithoutSpeaking() {
        let speech = FakeSpeechOutput()
        let feedback = BuddyAudioFeedback(speechOutput: speech, readBackFullResponses: { true })

        feedback.play(.listeningStarted, spokenSummary: "Should not be spoken.")

        #expect(speech.stopCount == 1)
        #expect(speech.spoken.isEmpty)
    }

    @Test func approvalRequestedIgnoresToggleAndSpeaksNeedsApproval() {
        let speech = FakeSpeechOutput()
        let feedback = BuddyAudioFeedback(speechOutput: speech, readBackFullResponses: { true })

        feedback.play(.approvalRequested, spokenSummary: "Detailed approval request.")

        #expect(speech.spoken == ["Needs approval"])
        #expect(speech.stopCount == 0)
    }
}

@MainActor
private final class FakeSpeechOutput: SpeechOutputing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    func speak(_ text: String) {
        spoken.append(text)
    }

    func stopSpeaking() {
        stopCount += 1
    }
}
