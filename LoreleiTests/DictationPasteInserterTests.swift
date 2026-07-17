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

    @Test func swapReplacesPasteboardWhenStillRaw() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("raw words", forType: .string)

        let swapped = DictationPasteboardSwap.swapIfStillRaw(
            rawText: "raw words",
            cleanedText: "Clean words.",
            pasteboard: pasteboard
        )

        #expect(swapped)
        #expect(pasteboard.string(forType: .string) == "Clean words.")
    }

    @Test func swapRefusesWhenPasteboardChanged() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("user copied something else", forType: .string)

        let swapped = DictationPasteboardSwap.swapIfStillRaw(
            rawText: "raw words",
            cleanedText: "Clean words.",
            pasteboard: pasteboard
        )

        #expect(!swapped)
        #expect(pasteboard.string(forType: .string) == "user copied something else")
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
            shouldAttemptPaste: { true },
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
            shouldAttemptPaste: { true },
            activateSettlingDelay: .milliseconds(1),
            pasteSettlingDelay: .milliseconds(1)
        )

        let outcome = await inserter.insert("leave on clipboard", targetProcessID: 7)
        #expect(outcome == .leftOnClipboard)
        #expect(pasteboard.string(forType: .string) == "leave on clipboard")
    }

    @Test func insertLeavesTranscriptWhenFocusIsNotEditable() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)

        var pastePostCount = 0
        let inserter = DictationPasteInserter(
            pasteboard: pasteboard,
            activateProcess: { _ in true },
            postCommandV: {
                pastePostCount += 1
                return true
            },
            shouldAttemptPaste: { false },
            activateSettlingDelay: .milliseconds(1),
            pasteSettlingDelay: .milliseconds(1)
        )

        let outcome = await inserter.insert("finder case", targetProcessID: 11)
        #expect(outcome == .leftOnClipboard)
        #expect(pastePostCount == 0)
        #expect(pasteboard.string(forType: .string) == "finder case")
    }

    @Test func heuristicSkipsFinderStyleListRoles() {
        #expect(
            DictationPasteTargetHeuristic.shouldAttemptPaste(
                role: "AXList",
                selectedTextSettable: false,
                valueSettable: false,
                hasFocusedElement: true
            ) == false
        )
    }

    @Test func heuristicPastesWhenNoFocusedElement() {
        #expect(
            DictationPasteTargetHeuristic.shouldAttemptPaste(
                role: nil,
                selectedTextSettable: false,
                valueSettable: false,
                hasFocusedElement: false
            )
        )
    }

    @Test func heuristicPastesUnknownGroupRoles() {
        #expect(
            DictationPasteTargetHeuristic.shouldAttemptPaste(
                role: "AXGroup",
                selectedTextSettable: false,
                valueSettable: false,
                hasFocusedElement: true
            )
        )
    }

    @Test func heuristicPastesWhenSelectedTextIsSettable() {
        #expect(
            DictationPasteTargetHeuristic.shouldAttemptPaste(
                role: "AXList",
                selectedTextSettable: true,
                valueSettable: false,
                hasFocusedElement: true
            )
        )
    }
}
