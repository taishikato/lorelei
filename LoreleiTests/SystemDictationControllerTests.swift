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
    var editResult: DictationFormatterResult = .formatted("EDITED")
    var prewarmCallCount = 0
    var formatCallCount = 0
    private(set) var editCallCount = 0
    var formatDelayNanoseconds: UInt64 = 0
    private(set) var lastRawTranscript: String?
    private(set) var lastAppContext: DictationAppContext?
    private(set) var lastEditInstruction: String?
    private(set) var lastEditSelectedText: String?

    func format(
        _ rawTranscript: String,
        appContext: DictationAppContext?
    ) async -> DictationFormatterResult {
        formatCallCount += 1
        lastRawTranscript = rawTranscript
        lastAppContext = appContext
        if formatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: formatDelayNanoseconds)
        }
        return result
    }

    func formatEdit(
        instruction: String,
        selectedText: String,
        appContext: DictationAppContext?
    ) async -> DictationFormatterResult {
        editCallCount += 1
        lastEditInstruction = instruction
        lastEditSelectedText = selectedText
        lastAppContext = appContext
        if formatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: formatDelayNanoseconds)
        }
        return editResult
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
    private(set) var lastTargetProcessID: pid_t?

    func insert(_ text: String, targetProcessID: pid_t?) async -> DictationInsertionOutcome {
        insertCallCount += 1
        lastInsertedText = text
        lastTargetProcessID = targetProcessID
        return outcome
    }
}

@MainActor
final class FakeDictationTextReplacer: DictationTextReplacing {
    var outcome: DictationReplacementOutcome = .replaced
    private(set) var calls: [(raw: String, cleaned: String, pid: pid_t?)] = []

    func replaceRawWithCleaned(
        rawText: String,
        cleanedText: String,
        targetProcessID: pid_t?
    ) async -> DictationReplacementOutcome {
        calls.append((rawText, cleanedText, targetProcessID))
        return outcome
    }
}

@MainActor
struct SystemDictationControllerTests {
    @Test func happyPathInsertsRawThenReplaces() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Hello world.")
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        var hudMessages: [String] = []
        var overlayVisible = false
        var sessionFinishedCount = 0

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            presentHUD: { hudMessages.append($0) },
            showOverlay: { overlayVisible = true },
            hideOverlay: { overlayVisible = false },
            markSessionFinished: { sessionFinishedCount += 1 },
            frontmostProcessID: { 999 }
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

        #expect(inserter.lastInsertedText == "um hello world")
        #expect(inserter.lastTargetProcessID == 999)
        #expect(replacer.calls.count == 1)
        #expect(hudMessages.isEmpty)
        #expect(sessionFinishedCount == 1)
    }

    @Test func rawFirstInsertsRawImmediatelyThenReplaces() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Clean.")
        formatter.formatDelayNanoseconds = 200_000_000
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {},
            frontmostProcessID: { 4242 }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw words")

        for _ in 0..<50 {
            if inserter.insertCallCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(inserter.insertCallCount == 1)
        #expect(inserter.lastInsertedText == "raw words")
        #expect(replacer.calls.isEmpty)

        for _ in 0..<50 {
            if trackedEvents.count > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let call = try #require(replacer.calls.first)
        #expect(call.raw == "raw words")
        #expect(call.cleaned == "Clean.")
        #expect(call.pid == 4242)
        #expect(trackedEvents.contains(where: { event in
            if case .inserted(_, _, _, _, _, "replaced") = event {
                return true
            }
            return false
        }))
    }

    @Test func rawFirstKeepsRawWhenReplacerRefuses() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Clean.")
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        replacer.outcome = .keptCheckFailed
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw words")

        for _ in 0..<50 {
            if trackedEvents.count > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inserter.insertCallCount == 1)
        #expect(inserter.lastInsertedText == "raw words")
        #expect(replacer.calls.count == 1)
        #expect(trackedEvents.contains(where: { event in
            if case .inserted(_, _, _, _, _, "kept_check_failed") = event {
                return true
            }
            return false
        }))
    }

    @Test func rawFirstFormatFallbackSkipsReplacement() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .fallbackToRaw(reason: "x")
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw words")

        for _ in 0..<50 {
            if trackedEvents.count > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inserter.insertCallCount == 1)
        #expect(replacer.calls.isEmpty)
        #expect(trackedEvents.contains(where: { event in
            if case .inserted(true, _, _, _, _, "kept_format_fallback") = event {
                return true
            }
            return false
        }))
    }

    @Test func rawFirstClipboardPathSwapsInsteadOfReplacing() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Clean.")
        let inserter = FakeDictationTextInserter()
        inserter.outcome = .leftOnClipboard
        let replacer = FakeDictationTextReplacer()
        var swaps: [(raw: String, cleaned: String)] = []
        var hudMessages: [String] = []
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            swapClipboard: { raw, cleaned in
                swaps.append((raw, cleaned))
                return true
            },
            presentHUD: { hudMessages.append($0) },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw words")

        for _ in 0..<50 {
            if trackedEvents.count > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(hudMessages == ["Copied to clipboard"])
        #expect(replacer.calls.isEmpty)
        #expect(swaps.count == 1)
        #expect(swaps.first?.raw == "raw words")
        #expect(swaps.first?.cleaned == "Clean.")
        #expect(trackedEvents.contains(where: { event in
            if case .copiedToClipboard(_, _, "replaced") = event {
                return true
            }
            return false
        }))
    }

    @Test func rawFirstClipboardPathKeepsIdenticalText() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("raw words")
        let inserter = FakeDictationTextInserter()
        inserter.outcome = .leftOnClipboard
        let replacer = FakeDictationTextReplacer()
        var swapCallCount = 0
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            swapClipboard: { _, _ in
                swapCallCount += 1
                return true
            },
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw words")

        for _ in 0..<50 {
            if trackedEvents.count > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(swapCallCount == 0)
        #expect(replacer.calls.isEmpty)
        #expect(trackedEvents.contains(where: { event in
            if case .copiedToClipboard(_, _, "kept_identical") = event {
                return true
            }
            return false
        }))
    }

    @Test func killSwitchRestoresLegacyOrder() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Clean.")
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            rawInsertFirstEnabled: { false },
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("raw words")

        for _ in 0..<50 {
            if trackedEvents.count > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inserter.insertCallCount == 1)
        #expect(inserter.lastInsertedText == "Clean.")
        #expect(replacer.calls.isEmpty)
        #expect(trackedEvents.contains(where: { event in
            if case .inserted(false, _, _, _, 0, "legacy_disabled") = event {
                return true
            }
            return false
        }))
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

    @Test func pasteFailureShowsClipboardHUD() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Clipboard text")
        let inserter = FakeDictationTextInserter()
        inserter.outcome = .leftOnClipboard
        var hudMessages: [String] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            swapClipboard: { _, _ in false },
            presentHUD: { hudMessages.append($0) },
            showOverlay: {},
            hideOverlay: {}
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("say this")

        for _ in 0..<50 {
            if !hudMessages.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inserter.insertCallCount == 1)
        #expect(hudMessages == ["Copied to clipboard"])
    }

    @Test func silenceDoesNothing() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        var sessionFinishedCount = 0

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
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

    @Test func secondPressDuringFormatIsIgnored() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("first")
        formatter.formatDelayNanoseconds = 200_000_000
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        var overlayShowCount = 0
        var capturedPIDs: [pid_t] = []

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            presentHUD: { _ in },
            showOverlay: { overlayShowCount += 1 },
            hideOverlay: {},
            frontmostProcessID: {
                let next = pid_t(1000 + capturedPIDs.count)
                capturedPIDs.append(next)
                return next
            }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("one")

        // While format is still running, mic is idle so a naive guard would
        // allow another session. Pipeline busy must block it.
        try await Task.sleep(for: .milliseconds(20))
        controller.handleShortcutTransition(.pressed)

        for _ in 0..<50 {
            if replacer.calls.count > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(overlayShowCount == 1)
        #expect(listener.startCallCount == 1)
        #expect(inserter.insertCallCount == 1)
        #expect(inserter.lastInsertedText == "one")
        #expect(inserter.lastTargetProcessID == 1000)
        #expect(formatter.formatCallCount == 1)
    }

    @Test func pressBlockedWhenCommandTurnOwnsUI() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        var overlayShown = false

        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            presentHUD: { _ in },
            showOverlay: { overlayShown = true },
            hideOverlay: {},
            canStartSession: { false }
        )

        controller.handleShortcutTransition(.pressed)

        #expect(listener.startCallCount == 0)
        #expect(formatter.prewarmCallCount == 0)
        #expect(!overlayShown)
    }

    @Test func formatReceivesAppContextCapturedAtPress() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        let inserter = FakeDictationTextInserter()
        let slack = DictationAppContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            localizedName: "Slack"
        )
        var contextToReturn: DictationAppContext? = slack
        var trackedEvents: [SystemDictationAnalyticsEvent] = []
        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {},
            frontmostProcessID: { 4242 },
            frontmostAppContext: { contextToReturn }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        // Frontmost app changes after press must not affect this session.
        contextToReturn = nil
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("hello team")

        for _ in 0..<50 {
            if trackedEvents.contains(where: { event in
                if case .inserted(_, "chat", _, _, _, _) = event {
                    return true
                }
                return false
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(formatter.lastAppContext == slack)
        #expect(trackedEvents.contains(where: { event in
            if case .inserted(false, "chat", _, _, _, _) = event {
                return true
            }
            return false
        }))
    }

    @Test func insertedEventCarriesMeasuredDurations() async throws {
        let listener = FakeSystemDictationListener()
        let formatter = FakeDictationTextFormatter()
        formatter.result = .formatted("Hello.")
        let inserter = FakeDictationTextInserter()
        let replacer = FakeDictationTextReplacer()
        var trackedEvents: [SystemDictationAnalyticsEvent] = []

        // Deterministic fake clock: each call advances 100ms.
        var tick = 0
        let base = ContinuousClock.now
        let controller = SystemDictationController(
            listener: listener,
            formatter: formatter,
            inserter: inserter,
            replacer: replacer,
            presentHUD: { _ in },
            trackAnalytics: { trackedEvents.append($0) },
            showOverlay: {},
            hideOverlay: {},
            now: {
                defer { tick += 1 }
                return base.advanced(by: .milliseconds(100 * tick))
            }
        )

        controller.handleShortcutTransition(.pressed)
        await listener.waitUntilStartBegins()
        controller.handleShortcutTransition(.released)
        listener.emitTranscript("hello")

        for _ in 0..<50 {
            if trackedEvents.contains(where: { event in
                if case .inserted(_, _, _, _, _, _) = event { return true }
                return false
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let inserted = trackedEvents.compactMap { event -> (Int, Int, Int)? in
            if case .inserted(_, _, let formatMs, let totalMs, let rawVisibleMs, _) = event {
                return (formatMs, totalMs, rawVisibleMs)
            }
            return nil
        }.first
        let unwrapped = try #require(inserted)
        // now() call order: totalStart, rawInsertEnd, formatStart, formatEnd, totalEnd.
        #expect(unwrapped.0 == 100)
        #expect(unwrapped.1 == 400)
        #expect(unwrapped.2 == 100)
    }
}
