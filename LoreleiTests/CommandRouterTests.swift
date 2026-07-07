//
//  CommandRouterTests.swift
//  LoreleiTests
//

import Testing
import AppKit
import Combine
import CoreAudio
import Foundation
import CoreGraphics
import ServiceManagement
@testable import Lorelei

@MainActor
struct CommandRouterTests {

    @Test func routerMapsShowGitStatusToStatus() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("show git status") == .gitStatus)
    }

    @Test func routerMapsWhatChangedToDiff() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("what changed?") == .gitDiff)
    }

    @Test func routerMapsRunTestsToTests() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("run tests") == .runTests)
    }

    @Test func routerMapsTestToTests() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("test") == .runTests)
    }

    @Test func routerMapsTestsToTests() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("tests") == .runTests)
    }

    @Test func routerReturnsUnsupportedForUnknownText() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("") == .unsupported("I didn't catch a command."))
    }

    @Test func routerMapsGenericReadOnlyQuestionToCodexReadOnly() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("why is auth failing?") == .codexReadOnly("why is auth failing?"))
    }

    @Test func routerMapsMutatingRequestToCodexWorkspaceWrite() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("fix the failing test") == .codexWorkspaceWrite("fix the failing test"))
    }

    @Test func routerMapsAdditionalMutatingRequestsToCodexWorkspaceWrite() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("update docs") == .codexWorkspaceWrite("update docs"))
        #expect(router.route("add a test") == .codexWorkspaceWrite("add a test"))
        #expect(router.route("rename file") == .codexWorkspaceWrite("rename file"))
    }

    @Test func routerPreservesClearLocalStatusDiffAndTestCommandsBeforeMutatingWords() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("status update") == .gitStatus)
        #expect(router.route("diff update") == .gitDiff)
        #expect(router.route("test update") == .runTests)
    }

    @Test func routerMapsScreenRequestToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("look at my screen") == .codexScreen("look at my screen"))
    }

    @Test func routerDoesNotMapAmbiguousWhatDoYouSeeToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("what do you see in this error?") == .codexReadOnly("what do you see in this error?"))
    }

    @Test func routerDoesNotMapAppWindowCommandToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("open the app window") == .codexDesktopAction("open the app window"))
    }

    @Test func routerDoesNotMapDesktopCommandToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("switch desktop") == .codexReadOnly("switch desktop"))
    }

    @Test func routerMapsClickRequestToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("click the submit button") == .codexDesktopAction("click the submit button"))
    }

    @Test func routerMapsBrowserOperationToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("open the browser and search for Swift concurrency") == .codexDesktopAction("open the browser and search for Swift concurrency"))
    }

    @Test func routerMapsBrowserRequestsToDesktopAction() async throws {
        let router = LoreleiCommandRouter()
        let openTranscript = "open gmail in chrome"
        let typingTranscript = "type hello into the search box in chrome"

        #expect(router.route(openTranscript) == .codexDesktopAction(openTranscript))
        #expect(router.route(typingTranscript) == .codexDesktopAction(typingTranscript))
    }

    @Test func routerMapsExplicitComputerUsePhraseToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("use computer use to open System Settings") == .codexDesktopAction("use computer use to open System Settings"))
    }

    @Test func routerKeepsQuestionsReadOnlyAndEscalatesOnlyClearLeadingCommands() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("should I add error handling here?") == .codexReadOnly("should I add error handling here?"))
        #expect(router.route("what would you add to this file?") == .codexReadOnly("what would you add to this file?"))
        #expect(router.route("can you search the git history for the bug?") == .codexDesktopAction("can you search the git history for the bug?"))
        #expect(router.route("open textedit and write a story") == .codexDesktopAction("open textedit and write a story"))
        #expect(router.route("can you open textedit") == .codexDesktopAction("can you open textedit"))
        #expect(router.route("please fix the failing test") == .codexWorkspaceWrite("please fix the failing test"))
        #expect(router.route("fix the login bug") == .codexWorkspaceWrite("fix the login bug"))
        #expect(router.route("tell me about the codebase and how files are added") == .codexReadOnly("tell me about the codebase and how files are added"))
        #expect(router.route("what's on my screen?") == .codexScreen("what's on my screen?"))
        #expect(router.route("what changed?") == .gitDiff)
        #expect(router.route("is it safe to delete the cache?") == .codexReadOnly("is it safe to delete the cache?"))
        #expect(router.route("update the readme with the new install steps") == .codexWorkspaceWrite("update the readme with the new install steps"))
        // 'will' is in the interrogative list, so the polite-command form
        // must be rescued by prefix stripping, not swallowed by the guard.
        #expect(router.route("will you fix the failing test?") == .codexWorkspaceWrite("will you fix the failing test?"))
        #expect(router.route("will you open chrome?") == .codexDesktopAction("will you open chrome?"))
        // Imperative preambles are stripped so the verb lands inside the
        // leading-token window instead of falling through to read-only.
        #expect(router.route("I need you to fix the failing test") == .codexWorkspaceWrite("I need you to fix the failing test"))
        #expect(router.route("I want you to open chrome") == .codexDesktopAction("I want you to open chrome"))
        // A leading auxiliary is a question only with a subject after it -
        // imperative 'do ...' commands must keep routing to their action.
        #expect(router.route("do a google search for swift concurrency") == .codexDesktopAction("do a google search for swift concurrency"))
        #expect(router.route("do you see any bugs here?") == .codexReadOnly("do you see any bugs here?"))
    }

    @Test func workspaceWritePromptIncludesNoCommitGuard() async throws {
        let prompt = CodexPromptBuilder.workspaceWritePrompt(for: "fix the test")

        #expect(prompt.contains("Do not commit changes."))
        #expect(prompt.contains("fix the test"))
    }

    @Test func desktopActionPromptRequiresAppServerControlPlaneAndScopedDesktopActions() async throws {
        let prompt = CodexPromptBuilder.desktopActionPrompt(for: "open TextEdit and type hello")

        #expect(prompt.contains("Codex App Server"))
        #expect(prompt.contains("lorelei.desktop_snapshot"))
        #expect(prompt.contains("lorelei.desktop_action"))
        #expect(prompt.contains("open/select/showMenu"))
        #expect(prompt.contains("lorelei.set_text"))
        #expect(prompt.contains("elementId \"focused\""))
        #expect(prompt.contains("lorelei.screenshot"))
        #expect(prompt.contains("Do not simulate keyboard shortcuts."))
        #expect(prompt.contains("Shell commands may prepare files/data but must NEVER be used to drive UI"))
        #expect(prompt.contains("AppleScript/osascript UI automation is unavailable"))
        #expect(prompt.contains("Do not commit changes."))
        #expect(!prompt.contains("non-interactive codex exec"))
        #expect(prompt.contains("open TextEdit and type hello"))
    }
}
