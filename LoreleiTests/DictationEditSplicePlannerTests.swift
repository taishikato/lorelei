//
//  DictationEditSplicePlannerTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct DictationEditSplicePlannerTests {
    @Test func plansSpliceWhenSelectionUnchanged() {
        let field = "before SELECTED after"
        let snapshot = DictationSelectionSnapshot(
            text: "SELECTED",
            range: NSRange(location: 7, length: 8)
        )
        let plan = DictationEditSplicePlanner.plan(
            fieldValue: field, snapshot: snapshot, editedText: "edited")
        #expect(plan == DictationReplacementPlan(
            range: NSRange(location: 7, length: 8), replacement: "edited"))
    }

    @Test func refusesWhenFieldEditedUnderSelection() {
        let snapshot = DictationSelectionSnapshot(
            text: "SELECTED", range: NSRange(location: 7, length: 8))
        #expect(DictationEditSplicePlanner.plan(
            fieldValue: "before CHANGED! after", snapshot: snapshot, editedText: "edited") == nil)
    }

    @Test func refusesWhenRangeOutOfBounds() {
        let snapshot = DictationSelectionSnapshot(
            text: "SELECTED", range: NSRange(location: 7, length: 8))
        #expect(DictationEditSplicePlanner.plan(
            fieldValue: "short", snapshot: snapshot, editedText: "edited") == nil)
    }

    @Test func plansWhenEditedEqualsOriginal() {
        // Identity is decided by the CONTROLLER (no_change outcome), not the planner.
        let field = "abc SELECTED xyz"
        let snapshot = DictationSelectionSnapshot(
            text: "SELECTED", range: NSRange(location: 4, length: 8))
        #expect(DictationEditSplicePlanner.plan(
            fieldValue: field, snapshot: snapshot, editedText: "SELECTED") != nil)
    }

    @Test func utf16RangesHandleJapaneseAndEmoji() {
        let selected = "こんにちは 👋"
        let field = "メモ: " + selected + " 続き"
        let location = ("メモ: " as NSString).length
        let snapshot = DictationSelectionSnapshot(
            text: selected,
            range: NSRange(location: location, length: (selected as NSString).length)
        )
        let plan = DictationEditSplicePlanner.plan(
            fieldValue: field, snapshot: snapshot, editedText: "やあ")
        #expect(plan?.range == snapshot.range)
    }

    @Test func usableSnapshotFiltersEmptyWhitespaceAndOversized() {
        #expect(DictationEditSplicePlanner.usableSnapshot(nil) == nil)
        #expect(DictationEditSplicePlanner.usableSnapshot(
            DictationSelectionSnapshot(text: "", range: NSRange(location: 0, length: 0))) == nil)
        #expect(DictationEditSplicePlanner.usableSnapshot(
            DictationSelectionSnapshot(text: "  \n ", range: NSRange(location: 0, length: 4))) == nil)
        let oversized = String(repeating: "a", count: 8001)
        #expect(DictationEditSplicePlanner.usableSnapshot(
            DictationSelectionSnapshot(
                text: oversized,
                range: NSRange(location: 0, length: 8001))) == nil)
        let ok = DictationSelectionSnapshot(text: "hi", range: NSRange(location: 3, length: 2))
        #expect(DictationEditSplicePlanner.usableSnapshot(ok) == ok)
    }
}

@Suite("Intact selection shortcut")
struct IntactSelectionShortcutTests {
    private let snapshot = DictationSelectionSnapshot(
        text: "SELECTED",
        range: NSRange(location: 7, length: 8)
    )

    @Test func exactMatchIsIntact() {
        #expect(AXDictationSelectionEditor.selectionIsIntact(
            currentSelectedText: "SELECTED",
            snapshot: snapshot
        ))
    }

    @Test func differentTextIsNotIntact() {
        #expect(!AXDictationSelectionEditor.selectionIsIntact(
            currentSelectedText: "CHANGED!",
            snapshot: snapshot
        ))
    }

    @Test func nilSelectedTextIsNotIntact() {
        #expect(!AXDictationSelectionEditor.selectionIsIntact(
            currentSelectedText: nil,
            snapshot: snapshot
        ))
    }

    @Test func emptySelectedTextIsNotIntact() {
        #expect(!AXDictationSelectionEditor.selectionIsIntact(
            currentSelectedText: "",
            snapshot: snapshot
        ))
    }

    @Test func trailingNewlineDifferenceIsNotIntact() {
        #expect(!AXDictationSelectionEditor.selectionIsIntact(
            currentSelectedText: "SELECTED\n",
            snapshot: snapshot
        ))
    }
}
