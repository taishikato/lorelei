//
//  DictationPasteInserterTests.swift
//  LoreleiTests
//

import AppKit
import Foundation
import Testing
@testable import Lorelei

@MainActor
struct DictationPasteInserterTests {
    @Test func pasteboardSnapshotRoundTripsStringItem() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("prior clipboard", forType: .string)

        let snapshot = DictationPasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        #expect(pasteboard.string(forType: .string) == "temporary")

        DictationPasteboardSnapshot.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "prior clipboard")
    }

    @Test func insertPostsPasteAndRestoresClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        var activatedPIDs: [pid_t] = []
        var pastePostCount = 0

        let inserter = DictationPasteInserter(
            pasteboard: pasteboard,
            activateProcess: { pid in
                activatedPIDs.append(pid)
                return true
            },
            postCommandV: {
                pastePostCount += 1
                return true
            },
            activateSettlingDelay: .milliseconds(1),
            pasteSettlingDelay: .milliseconds(1)
        )

        let outcome = await inserter.insert("hello dictation", targetProcessID: 4242)
        #expect(outcome == .inserted)
        #expect(activatedPIDs == [4242])
        #expect(pastePostCount == 1)
        #expect(pasteboard.string(forType: .string) == "keep me")
    }

    @Test func insertLeavesTranscriptWhenPastePostFails() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)

        let inserter = DictationPasteInserter(
            pasteboard: pasteboard,
            activateProcess: { _ in true },
            postCommandV: { false },
            activateSettlingDelay: .milliseconds(1),
            pasteSettlingDelay: .milliseconds(1)
        )

        let outcome = await inserter.insert("leave on clipboard", targetProcessID: 7)
        #expect(outcome == .leftOnClipboard)
        #expect(pasteboard.string(forType: .string) == "leave on clipboard")
    }
}
