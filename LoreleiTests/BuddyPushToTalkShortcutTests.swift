//
//  BuddyPushToTalkShortcutTests.swift
//  LoreleiTests
//

import AppKit
import CoreGraphics
import Testing
@testable import Lorelei

struct BuddyPushToTalkShortcutTests {
    // The command shortcut is ctrl + option; these pin the release
    // watchdog's held-state check to that configuration.
    @Test func commandShortcutStillHeldWhileRequiredModifiersAreDown() async throws {
        #expect(
            BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [.control, .option],
                option: .controlOption
            )
        )
        #expect(
            BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [.control, .option, .shift],
                option: .controlOption
            )
        )
    }

    @Test func commandShortcutNoLongerHeldOnceAnyRequiredModifierIsUp() async throws {
        #expect(
            !BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [],
                option: .controlOption
            )
        )
        #expect(
            !BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [.control],
                option: .controlOption
            )
        )
        #expect(
            !BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [.option],
                option: .controlOption
            )
        )
        #expect(
            !BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [.shift, .command],
                option: .controlOption
            )
        )
    }

    @Test func dictationShortcutStillHeldWhileShiftControlAreDown() async throws {
        #expect(
            BuddyPushToTalkShortcut.isShortcutStillHeld(
                modifierFlags: [.shift, .control],
                option: .shiftControl
            )
        )
        #expect(BuddyPushToTalkShortcut.dictationShortcutOption == .shiftControl)
    }

    @Test func commandPressAndRelease() async throws {
        let pressed = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([.control, .option]).rawValue),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: false
        )
        #expect(pressed == [
            .init(kind: .command, transition: .pressed)
        ])

        let released = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([.control]).rawValue),
            wasCommandShortcutPressed: true,
            wasDictationShortcutPressed: false
        )
        #expect(released == [
            .init(kind: .command, transition: .released)
        ])
    }

    @Test func dictationPressAndRelease() async throws {
        let pressed = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([.shift, .control]).rawValue),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: false
        )
        #expect(pressed == [
            .init(kind: .dictation, transition: .pressed)
        ])

        let released = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([.control]).rawValue),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: true
        )
        #expect(released == [
            .init(kind: .dictation, transition: .released)
        ])
    }

    @Test func controlOptionShiftPrefersCommand() async throws {
        let tagged = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(
                NSEvent.ModifierFlags([.control, .option, .shift]).rawValue
            ),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: false
        )
        #expect(tagged == [
            .init(kind: .command, transition: .pressed)
        ])
    }

    @Test func suppressesDictationPressWhileCommandIsHeld() async throws {
        let tagged = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(
                NSEvent.ModifierFlags([.control, .option, .shift]).rawValue
            ),
            wasCommandShortcutPressed: true,
            wasDictationShortcutPressed: false
        )
        #expect(tagged.isEmpty)
    }

    @Test func suppressesCommandPressWhileDictationIsHeld() async throws {
        let tagged = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(
                NSEvent.ModifierFlags([.control, .option, .shift]).rawValue
            ),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: true
        )
        #expect(tagged.isEmpty)
    }

    @Test func releaseOnlyFiresWhenKindWasPressed() async throws {
        let commandReleaseWithoutPress = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([]).rawValue),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: false
        )
        #expect(commandReleaseWithoutPress.isEmpty)

        let dictationReleaseWithoutPress = BuddyPushToTalkShortcut.taggedShortcutTransitions(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([.control]).rawValue),
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: false
        )
        #expect(dictationReleaseWithoutPress.isEmpty)
    }

    @Test func disambiguateHelperGivesCommandPriorityWhenBothWouldPress() async throws {
        let resolved = BuddyPushToTalkShortcut.disambiguateTransitions(
            command: .pressed,
            dictation: .pressed,
            wasCommandShortcutPressed: false,
            wasDictationShortcutPressed: false
        )
        #expect(resolved.command == .pressed)
        #expect(resolved.dictation == .none)
    }
}
