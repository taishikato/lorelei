//
//  ConversationHistoryStoreTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct ConversationHistoryStoreTests {
    @Test func appendRoundTripsInOrder() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("history", isDirectory: true)
        let store = ConversationHistoryStore(rootDirectoryURL: rootDirectoryURL)

        try store.append(role: "user", text: "one")
        try store.append(role: "assistant", text: "two")
        try store.append(role: "user", text: "three")

        let records = try store.readAll()
        #expect(records.map(\.role) == ["user", "assistant", "user"])
        #expect(records.map(\.text) == ["one", "two", "three"])
        #expect(records.allSatisfy { !$0.ts.isEmpty })
    }

    @Test func textWithNewlinesQuotesAndEmojiRoundTrips() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("history", isDirectory: true)
        let store = ConversationHistoryStore(rootDirectoryURL: rootDirectoryURL)
        let text = "line1\nline2 \"quoted\" 🎉"

        try store.append(role: "user", text: text)

        let records = try store.readAll()
        #expect(records.count == 1)
        #expect(records[0].text == text)
        #expect(records[0].role == "user")
    }

    @Test func clearRemovesFileAndReadAllReturnsEmpty() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("history", isDirectory: true)
        let store = ConversationHistoryStore(rootDirectoryURL: rootDirectoryURL)
        try store.append(role: "user", text: "keep me briefly")

        try store.clear()

        #expect(try store.readAll().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: rootDirectoryURL.appendingPathComponent("history.jsonl").path
        ))
    }

    @Test func readAllSkipsCorruptLines() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        let fileURL = rootDirectoryURL.appendingPathComponent("history.jsonl")
        let contents = """
        {"ts":"2026-07-17T12:00:00.000Z","role":"user","text":"ok"}
        not-json
        {"ts":"2026-07-17T12:00:01.000Z","role":"assistant","text":"also ok"}

        """
        try Data(contents.utf8).write(to: fileURL, options: .atomic)

        let store = ConversationHistoryStore(rootDirectoryURL: rootDirectoryURL)
        let records = try store.readAll()
        #expect(records.map(\.text) == ["ok", "also ok"])
        #expect(records.map(\.role) == ["user", "assistant"])
    }

    @Test func tinyCapTrimKeepsNewestLines() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("history", isDirectory: true)
        let store = ConversationHistoryStore(rootDirectoryURL: rootDirectoryURL, maxFileBytes: 180)

        try store.append(role: "user", text: String(repeating: "a", count: 40))
        try store.append(role: "assistant", text: String(repeating: "b", count: 40))
        try store.append(role: "user", text: String(repeating: "c", count: 40))
        try store.append(role: "assistant", text: String(repeating: "d", count: 40))

        let records = try store.readAll()
        #expect(!records.isEmpty)
        #expect(records.last?.text == String(repeating: "d", count: 40))
        #expect(!records.contains(where: { $0.text == String(repeating: "a", count: 40) }))

        let fileURL = rootDirectoryURL.appendingPathComponent("history.jsonl")
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        #expect(fileSize <= 180 / 2 + 40)
    }

    @Test func readAllReturnsEmptyWhenFileAbsent() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("history", isDirectory: true)
        let store = ConversationHistoryStore(rootDirectoryURL: rootDirectoryURL)

        #expect(try store.readAll().isEmpty)
    }
}
