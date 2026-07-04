//
//  BuddyPushToTalkShortcutTests.swift
//  LoreleiTests
//

import AppKit
import Testing
@testable import Lorelei

struct BuddyPushToTalkShortcutTests {
    // The current shortcut is ctrl + option; these pin the release
    // watchdog's held-state check to that configuration.
    @Test func shortcutStillHeldWhileRequiredModifiersAreDown() async throws {
        #expect(BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: [.control, .option]))
        #expect(BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: [.control, .option, .shift]))
    }

    @Test func shortcutNoLongerHeldOnceAnyRequiredModifierIsUp() async throws {
        #expect(!BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: []))
        #expect(!BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: [.control]))
        #expect(!BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: [.option]))
        #expect(!BuddyPushToTalkShortcut.isShortcutStillHeld(modifierFlags: [.shift, .command]))
    }
}
