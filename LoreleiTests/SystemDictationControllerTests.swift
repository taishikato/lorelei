//
//  SystemDictationControllerTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

@MainActor
final class FakeSystemDictationListener: SystemDictationListening {
    var isDictationInProgress = false
    var startCallCount = 0
    var stopCallCount = 0
    var startDelayNanoseconds: UInt64 = 0
    private(set) var submitDraftText: ((String) -> Void)?
    private var startGate: CheckedContinuation<Void, Never>?

    func startListening(
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        startCallCount += 1
        self.submitDraftText = submitDraftText
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        if Task.isCancelled {
            return
        }
        isDictationInProgress = true
        if let startGate {
            self.startGate = nil
            startGate.resume()
        }
    }

    func stopListening() {
        stopCallCount += 1
        isDictationInProgress = false
    }

    func emitTranscript(_ text: String) {
        submitDraftText?(text)
    }

    func waitUntilStartBegins() async {
        await withCheckedContinuation { continuation in
            if isDictationInProgress {
                continuation.resume()
            } else {
                startGate = continuation
            }
        }
    }
}

@MainActor
final class FakeDictationTextFormatter: DictationTextFormatting {
    var result: DictationFormatterResult = .formatted("cleaned")
    var prewarmCallCount = 0
    var formatCallCount = 0
    private(set) var lastRawTranscript: String?

    func format(_ rawTranscript: String) async -> DictationFormatterResult {
        formatCallCount += 1
        lastRawTranscript = rawTranscript
        return result
    }

    func prewarm() {
        prewarmCallCount += 1
    }
}

@MainActor
final class FakeDictationTextInserter: DictationTextInserting {
    var outcome: DictationInsertionOutcome = .inserted
    var insertCallCount = 0
    private(set) var lastInsertedText: String?

    func insert(_ text: String) async -> DictationInsertionOutcome {
        insertCallCount += 1
        lastInsertedText = text
        return outcome
    }
}

@MainActor
struct SystemDictationControllerTests {
    @Test func happyPathInsertsFormattedText() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Hello world.")
        let inserter = FakeDictationTextInserter()
        var pasteboardWrites: [String] = []
        var hudMessages: [String] = []
        var overlayVisible = false
        var sessionFinishedCount = 0

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { pasteboardWrites.append($0) },
            presentHUD: { hudMessages.append($0) },
            showOverlay: { overlayVisible = true },
            hideOverlay: { overlayVisible = false },
            markSessionFinished: { sessionFinishedCount += 1 }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        #expect(formatter.prewarmCallCount == 1)
        #expect(overlayVisible)

        controller.handleShortcutTransition(.released)
        #expect(!overlayVisible)
        listener.emitTranscript("um hello world")

        for _ in 0..<50 {
            if inserter.insertCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inserter.lastInsertedText == "Hello world.")
        #expect(pasteboardWrites.isEmpty)
        #expect(hudMessages.isEmpty)
        #expect(sessionFinishedCount == 1)
    }

    @Test func fallbackInsertsRawTranscript() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .fallbackToRaw(reason: "timeout")
        let inserter = FakeDictationTextInserter()

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { _ in },
            presentHUD: { _ in },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw transcript")

        for _ in 0..<50 {
            if inserter.insertCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inserter.lastInsertedText == "raw transcript")
    }

    @Test func noEditableTargetCopiesToPasteboardAndShowsHUD() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Clipboard text")
        let inserter = FakeDictationTextInserter()
        inserter.outcome = .noEditableTarget
        var pasteboardWrites: [String] = []
        var hudMessages: [String] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { pasteboardWrites.append($0) },
            presentHUD: { hudMessages.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("say this")

        for _ in 0..<50 {
            if !pasteboardWrites.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(pasteboardWrites == ["Clipboard text"])
        #expect(hudMessages == ["Copied to clipboard"])
    }

    @Test func silenceDoesNothing() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        var pasteboardWrites: [String] = []
        var sessionFinishedCount = 0

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { pasteboardWrites.append($0) },
            presentHUD: { _ in },
            showOverlay: {},
            hideOverlay: {},
            markSessionFinished: { sessionFinishedCount += 1 }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("   ")

        for _ in 0..<50 {
            if sessionFinishedCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(formatter.formatCallCount == 0)
        #expect(inserter.insertCallCount == 0)
        #expect(pasteboardWrites.isEmpty)
        #expect(sessionFinishedCount == 1)
    }

    @Test func pressWhileCommandPTTActiveIsIgnored() async throws {
        let listener = FakeSystemDictationListener()
        listener.isDictationInProgress = true
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        var overlayShown = false

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { _ in },
            presentHUD: { _ in },
            showOverlay: { overlayShown = true },
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)

        #expect(listener.startCallCount == 0)
        #expect(formatter.prewarmCallCount == 0)
        #expect(!overlayShown)
    }

    @Test func quickPressReleaseDoesNotStartSession() async throws {
        let listener = FakeSystemDictationListener()
        listener.startDelayNanoseconds = 200_000_000
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        var overlayVisible = false
        var sessionFinishedCount = 0

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { _ in },
            presentHUD: { _ in },
            showOverlay: { overlayVisible = true },
            hideOverlay: { overlayVisible = false },
            markSessionFinished: { sessionFinishedCount += 1 }
        )

        controller.handleShortcutTransition(.pressed)
        #expect(overlayVisible)
        controller.handleShortcutTransition(.released)
        #expect(!overlayVisible)
        #expect(sessionFinishedCount == 1)

        try await Task.sleep(for: .milliseconds(250))

        #expect(listener.startCallCount == 1)
        #expect(!listener.isDictationInProgress)
        #expect(listener.stopCallCount == 1)
        #expect(sessionFinishedCount == 1)
    }

    @Test func silenceWithoutTranscriptEndsSessionUI() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        var sessionFinishedCount = 0

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            writeToPasteboard: { _ in },
            presentHUD: { _ in },
            showOverlay: {},
            hideOverlay: {},
            markSessionFinished: { sessionFinishedCount += 1 }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)

        for _ in 0..<400 {
            if sessionFinishedCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(formatter.formatCallCount == 0)
        #expect(inserter.insertCallCount == 0)
        #expect(sessionFinishedCount == 1)
    }
}
