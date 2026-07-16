//
//  DictationAppContextTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct DictationAppContextTests {
    @Test func emailBundleIDsMapToEmail() {
        #expect(DictationAppCategory(bundleIdentifier: "com.apple.mail") == .email)
        #expect(DictationAppCategory(bundleIdentifier: "com.microsoft.Outlook") == .email)
    }

    @Test func chatBundleIDsMapToChat() {
        #expect(DictationAppCategory(bundleIdentifier: "com.tinyspeck.slackmacgap") == .chat)
        #expect(DictationAppCategory(bundleIdentifier: "com.hnc.Discord") == .chat)
        #expect(DictationAppCategory(bundleIdentifier: "com.apple.MobileSMS") == .chat)
    }

    @Test func codeAndTerminalBundleIDsMapToCodeEditorOrTerminal() {
        #expect(DictationAppCategory(bundleIdentifier: "com.microsoft.VSCode") == .codeEditorOrTerminal)
        #expect(DictationAppCategory(bundleIdentifier: "com.todesktop.230313mzl4w4u92") == .codeEditorOrTerminal)
        #expect(DictationAppCategory(bundleIdentifier: "com.apple.dt.Xcode") == .codeEditorOrTerminal)
        #expect(DictationAppCategory(bundleIdentifier: "com.apple.Terminal") == .codeEditorOrTerminal)
        #expect(DictationAppCategory(bundleIdentifier: "com.googlecode.iterm2") == .codeEditorOrTerminal)
        #expect(DictationAppCategory(bundleIdentifier: "com.mitchellh.ghostty") == .codeEditorOrTerminal)
    }

    @Test func unknownAndNilBundleIDsMapToUnknown() {
        #expect(DictationAppCategory(bundleIdentifier: "com.example.someapp") == .unknown)
        #expect(DictationAppCategory(bundleIdentifier: nil) == .unknown)
        #expect(DictationAppCategory(bundleIdentifier: "") == .unknown)
    }

    @Test func unknownHasNoStyleHintOthersDo() {
        #expect(DictationAppCategory.unknown.styleHint == nil)
        #expect(DictationAppCategory.email.styleHint?.isEmpty == false)
        #expect(DictationAppCategory.chat.styleHint?.isEmpty == false)
        #expect(DictationAppCategory.codeEditorOrTerminal.styleHint?.isEmpty == false)
    }

    @Test func styleHintsNeverRelaxMeaningPreservation() {
        for category in [DictationAppCategory.email, .chat, .codeEditorOrTerminal] {
            let hint = category.styleHint ?? ""
            #expect(!hint.localizedCaseInsensitiveContains("reword"))
            #expect(!hint.localizedCaseInsensitiveContains("rewrite"))
        }
    }

    @Test func contextExposesCategory() {
        let context = DictationAppContext(
            bundleIdentifier: "com.apple.mail",
            localizedName: "Mail"
        )
        #expect(context.category == .email)
    }
}
