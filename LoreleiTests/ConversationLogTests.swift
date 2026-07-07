//
//  ConversationLogTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct ConversationLogTests {
    @Test func appendStoresRoleAndTextInOrderAndOpensAssistantEntry() {
        var log = ConversationLog()

        log.append(role: .user, text: "Question")
        log.append(role: .assistant, text: "Answer")
        log.appendAssistantDelta(" continued")

        #expect(log.entries.map(\.role) == [.user, .assistant])
        #expect(log.entries.map(\.text) == ["Question", "Answer continued"])
    }

    @Test func appendAssistantDeltaConcatenatesOntoOpenAssistantEntry() {
        var log = ConversationLog()

        log.append(role: .assistant, text: "Hel")
        log.appendAssistantDelta("lo")

        #expect(log.entries.count == 1)
        #expect(log.entries[0].text == "Hello")
    }

    @Test func appendAssistantDeltaWithoutOpenEntryCreatesAssistantEntry() {
        var log = ConversationLog()

        log.appendAssistantDelta("Hello")

        #expect(log.entries.count == 1)
        #expect(log.entries[0].role == .assistant)
        #expect(log.entries[0].text == "Hello")
    }

    @Test func appendAssistantDeltaWithEmptyStringChangesNothing() {
        var log = ConversationLog()
        log.append(role: .user, text: "Question")
        let before = log

        log.appendAssistantDelta("")

        #expect(log == before)
    }

    @Test func updateAssistantEntryReplacesOpenEntryText() {
        var log = ConversationLog()

        log.append(role: .assistant, text: "Draft")
        log.updateAssistantEntry(text: "Final")

        #expect(log.entries.count == 1)
        #expect(log.entries[0].text == "Final")
    }

    @Test func updateAssistantEntryWithOnlyWhitespaceChangesNothing() {
        var log = ConversationLog()
        log.append(role: .assistant, text: "Draft")
        let before = log

        log.updateAssistantEntry(text: " \n\t ")

        #expect(log == before)
    }

    @Test func closeAssistantEntryThenDeltaCreatesNewEntry() {
        var log = ConversationLog()

        log.append(role: .assistant, text: "First")
        log.closeAssistantEntry()
        log.appendAssistantDelta("Second")

        #expect(log.entries.count == 2)
        #expect(log.entries.map(\.role) == [.assistant, .assistant])
        #expect(log.entries.map(\.text) == ["First", "Second"])
    }

    @Test func capKeepsNewestTwoHundredEntries() {
        var log = ConversationLog()

        for index in 0..<201 {
            log.append(role: .user, text: "User \(index)")
        }

        #expect(log.entries.count == 200)
        #expect(log.entries[0].text == "User 1")
        #expect(log.entries.last?.text == "User 200")
    }

    @Test func capDropsOpenAssistantEntrySoFollowingDeltaCreatesNewEntry() {
        var log = ConversationLog()

        log.append(role: .assistant, text: "Dropped")
        for index in 0..<200 {
            log.append(role: .user, text: "User \(index)")
        }
        log.appendAssistantDelta("New")

        #expect(log.entries.count == 200)
        #expect(log.entries.last?.role == .assistant)
        #expect(log.entries.last?.text == "New")
        #expect(log.entries.allSatisfy { $0.text != "DroppedNew" })
    }

    @Test func removeAllEmptiesEntriesAndClosesAssistantEntry() {
        var log = ConversationLog()

        log.append(role: .assistant, text: "Draft")
        log.removeAll()

        #expect(log.entries.isEmpty)

        log.appendAssistantDelta("Fresh")

        #expect(log.entries.count == 1)
        #expect(log.entries[0].role == .assistant)
        #expect(log.entries[0].text == "Fresh")
    }
}
