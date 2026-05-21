//
//  LoreleiCommandRouter.swift
//  leanring-buddy
//
//  Maps final voice transcripts to the small read-only command surface
//  currently supported by Lorelei.
//

import Foundation

enum LoreleiCommandAction: Equatable, Sendable {
    case gitStatus
    case gitDiff
    case runTests
    case unsupported(String)

    var requiresWorkspace: Bool {
        switch self {
        case .gitStatus, .gitDiff, .runTests:
            return true
        case .unsupported:
            return false
        }
    }
}

struct LoreleiCommandRouter {
    func route(_ transcript: String) -> LoreleiCommandAction {
        let command = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if command.contains("git status") || command.contains("status") {
            return .gitStatus
        }

        if command.contains("what changed")
            || command.contains("diff")
            || command.contains("changes")
            || command.contains("changed") {
            return .gitDiff
        }

        if command.contains("run tests")
            || command.contains("tests")
            || command.contains("test") {
            return .runTests
        }

        return .unsupported("Only status, diff, and test are wired yet.")
    }
}
