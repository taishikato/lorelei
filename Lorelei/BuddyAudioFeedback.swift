//
//  BuddyAudioFeedback.swift
//  Lorelei
//

import AppKit
import Foundation

nonisolated enum BuddyAudioCue: Equatable, Sendable {
    case listeningStarted
    case listeningEnded
    case runSucceeded
    case runFailed
    case approvalRequested
}

@MainActor
protocol BuddyAudioFeedbacking: AnyObject {
    func play(_ cue: BuddyAudioCue, spokenSummary: String?)
}

@MainActor
final class BuddyAudioFeedback: BuddyAudioFeedbacking {
    private let speechOutput: SpeechOutputing
    private let readBackFullResponses: () -> Bool

    init(
        speechOutput: SpeechOutputing,
        readBackFullResponses: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "LoreleiReadBackFullResponses")
        }
    ) {
        self.speechOutput = speechOutput
        self.readBackFullResponses = readBackFullResponses
    }

    func play(_ cue: BuddyAudioCue, spokenSummary: String?) {
        if cue == .listeningStarted {
            speechOutput.stopSpeaking()
            if let soundName = soundName(for: cue) {
                NSSound(named: soundName)?.play()
            }
            return
        }

        if let soundName = soundName(for: cue) {
            NSSound(named: soundName)?.play()
        }

        if cue == .approvalRequested {
            speechOutput.speak("Needs approval")
            return
        }

        guard let spokenSummary else { return }

        if readBackFullResponses() {
            let trimmed = spokenSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            speechOutput.speak(trimmed)
            return
        }

        let sentence = Self.firstSentence(spokenSummary)
        guard !sentence.isEmpty else { return }
        speechOutput.speak(sentence)
    }

    static func firstSentence(_ text: String, maxCharacters: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminators: Set<Character> = ["。", ".", "!", "?", "！", "？"]
        let sentence: String

        if let terminatorIndex = trimmed.firstIndex(where: { terminators.contains($0) }) {
            sentence = String(trimmed[...terminatorIndex])
        } else {
            sentence = trimmed
        }

        guard sentence.count > maxCharacters else { return sentence }
        guard maxCharacters > 0 else { return "…" }
        let endIndex = sentence.index(sentence.startIndex, offsetBy: maxCharacters - 1)
        return "\(sentence[..<endIndex])…"
    }

    private func soundName(for cue: BuddyAudioCue) -> NSSound.Name? {
        switch cue {
        case .listeningStarted:
            return NSSound.Name("Pop")
        case .listeningEnded:
            return NSSound.Name("Bottle")
        case .runSucceeded:
            return NSSound.Name("Glass")
        case .runFailed:
            return NSSound.Name("Basso")
        case .approvalRequested:
            return NSSound.Name("Funk")
        }
    }
}
