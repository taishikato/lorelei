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
