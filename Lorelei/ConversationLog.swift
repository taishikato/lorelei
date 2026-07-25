//
//  ConversationLog.swift
//  Lorelei
//

import Foundation

struct ConversationEntry: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
}

struct ConversationLog: Equatable, Sendable {
    private(set) var entries: [ConversationEntry] = []
    private var currentAssistantEntryID: UUID?
    private let maximumEntries = 200

    mutating func append(role: ConversationEntry.Role, text: String) {
        let entry = ConversationEntry(id: UUID(), role: role, text: text)
        entries.append(entry)
        if role == .assistant {
            currentAssistantEntryID = entry.id
        }
        cap()
    }

    mutating func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let currentAssistantEntryID,
           let index = entries.firstIndex(where: { $0.id == currentAssistantEntryID }) {
            entries[index].text += delta
        } else {
            append(role: .assistant, text: delta)
        }
    }

    mutating func updateAssistantEntry(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let currentAssistantEntryID,
           let index = entries.firstIndex(where: { $0.id == currentAssistantEntryID }) {
            entries[index].text = text
        } else {
            append(role: .assistant, text: text)
        }
    }

    mutating func closeAssistantEntry() {
        currentAssistantEntryID = nil
    }

    /// Identifier of the most recent `.user` entry. The panel shows its edit
    /// affordance on this entry only - editing older turns would imply a
    /// rewind the Codex session cannot perform.
    var latestUserEntryID: UUID? {
        entries.last(where: { $0.role == .user })?.id
    }

    /// Rewrites the trailing user entry in place, so a corrected utterance
    /// replaces the original instead of piling a near-duplicate onto the log.
    /// Returns whether the replacement happened.
    ///
    /// 'Trailing' is all this checks: an assistant entry after the user's
    /// means the message was answered and must not be rewritten. Whether a
    /// turn is still in flight is the caller's business.
    mutating func replaceLatestUserEntryTextIfUnanswered(_ text: String) -> Bool {
        guard let index = entries.indices.last, entries[index].role == .user else {
            return false
        }
        entries[index].text = text
        return true
    }

    mutating func removeAll() {
        entries.removeAll()
        currentAssistantEntryID = nil
    }

    private mutating func cap() {
        guard entries.count > maximumEntries else { return }
        entries.removeFirst(entries.count - maximumEntries)
        if let currentAssistantEntryID,
           !entries.contains(where: { $0.id == currentAssistantEntryID }) {
            self.currentAssistantEntryID = nil
        }
    }
}
