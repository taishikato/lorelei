//
//  DictationAppContext.swift
//  Lorelei
//
//  Frontmost-app context captured at Ctrl+Shift press so dictation cleanup
//  can match the target app's writing style. Category mapping is an exact
//  bundle-ID table: unknown apps get no hint and keep plan-020 behavior.
//

import Foundation

struct DictationAppContext: Equatable, Sendable {
    let bundleIdentifier: String?
    let localizedName: String?

    var category: DictationAppCategory {
        DictationAppCategory(bundleIdentifier: bundleIdentifier)
    }
}

enum DictationAppCategory: String, Equatable, Sendable {
    case email
    case chat
    case codeEditorOrTerminal = "code_editor_or_terminal"
    case unknown

    private static let emailBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-macOS",
        "com.superhuman.electron"
    ]

    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp"
    ]

    private static let codeEditorOrTerminalBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm"
    ]

    init(bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            self = .unknown
            return
        }
        if Self.emailBundleIDs.contains(bundleIdentifier) {
            self = .email
        } else if Self.chatBundleIDs.contains(bundleIdentifier) {
            self = .chat
        } else if Self.codeEditorOrTerminalBundleIDs.contains(bundleIdentifier) {
            self = .codeEditorOrTerminal
        } else {
            self = .unknown
        }
    }

    /// Style-only guidance appended to the cleanup prompt. Never permits
    /// changing meaning; `.unknown` returns nil so the prompt stays
    /// byte-identical to the plan-020 prompt.
    var styleHint: String? {
        switch self {
        case .email:
            return """
            The text will be pasted into an email compose field.
            Use complete sentences, proper capitalization, punctuation, and paragraph breaks.
            Do not invent greetings, sign-offs, or signatures.
            """
        case .chat:
            return """
            The text will be pasted into a chat message field.
            Keep the casual register and the speaker's phrasing.
            Do not add a trailing period to a short single-sentence message.
            Do not force formal capitalization.
            """
        case .codeEditorOrTerminal:
            return """
            The text will be pasted into a code editor or terminal.
            Remove filler words only.
            Never introduce smart quotes, typographic dashes, or extra punctuation.
            Never 'correct' identifiers, commands, flags, or paths.
            """
        case .unknown:
            return nil
        }
    }
}
