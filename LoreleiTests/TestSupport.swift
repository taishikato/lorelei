//
//  TestSupport.swift
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

func makeTemporaryDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

func textContent(_ result: CodexAppServerDynamicToolCallResult) -> String? {
    guard result.contentItems.count == 1,
          case .text(let text) = result.contentItems[0] else {
        return nil
    }
    return text
}

@MainActor
final class FakeDesktopActionExecutor: DesktopActionExecuting {
    var snapshotResult: Result<DesktopSnapshotResult, DesktopActionError> =
        .success(DesktopSnapshotResult(text: "[e1] AXWindow \"Demo\" (0,0 100x100)", elementCount: 1))
    var performCalls: [(DesktopElementAction, String)] = []
    var setTextCalls: [(String, String, DesktopSetTextMode)] = []
    var outcome = DesktopActionOutcome(success: true, message: "ok")
    var screenshotResult: Result<Data, DesktopActionError> = .success(Data([0x89, 0x50]))
    var snapshotAppNames: [String?] = []

    func snapshot(appName: String?) async -> Result<DesktopSnapshotResult, DesktopActionError> {
        snapshotAppNames.append(appName)
        return snapshotResult
    }

    func perform(_ action: DesktopElementAction, elementID: String) async -> DesktopActionOutcome {
        performCalls.append((action, elementID))
        return outcome
    }

    func setText(
        _ text: String,
        elementID: String,
        mode: DesktopSetTextMode
    ) async -> DesktopActionOutcome {
        setTextCalls.append((text, elementID, mode))
        return outcome
    }

    func screenshot() async -> Result<Data, DesktopActionError> {
        screenshotResult
    }
}

final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

actor AsyncCounter {
    private var count = 0

    var value: Int {
        count
    }

    func increment() {
        count += 1
    }
}

final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: String) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

actor FakeCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var recordedSentLines: [String] = []
    private var terminated = false

    init(lines: [String]) {
        self.lines = lines
    }

    var sentLines: [String] {
        recordedSentLines
    }

    var sentMethods: [String] {
        sentLines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = root["method"] as? String else {
                return nil
            }
            return method
        }
    }

    var didTerminate: Bool {
        terminated
    }

    func sentJSONMessages() throws -> [[String: Any]] {
        try recordedSentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    func send(line: String) async throws {
        recordedSentLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextLine() async throws -> String? {
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func terminate() async {
        terminated = true
    }
}

actor AppServerTransportFactoryRecorder {
    private var transports: [CodexAppServerTransporting]
    private var calls = 0

    init(transports: [CodexAppServerTransporting]) {
        self.transports = transports
    }

    var callCount: Int {
        calls
    }

    func next() throws -> CodexAppServerTransporting {
        calls += 1
        guard !transports.isEmpty else {
            throw CodexAppServerTestError.missingTransport
        }
        return transports.removeFirst()
    }
}

actor ThrowingSendCodexAppServerTransport: CodexAppServerTransporting {
    private var terminated = false

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {
        throw CodexAppServerTestError.sendFailed
    }

    func nextLine() async throws -> String? {
        nil
    }

    func terminate() async {
        terminated = true
    }
}

enum CodexAppServerTestError: Error {
    case missingTransport
    case sendFailed
}

actor HangingCodexAppServerTransport: CodexAppServerTransporting {
    private var terminated = false

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {}

    func nextLine() async throws -> String? {
        while !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func terminate() async {
        terminated = true
    }
}

actor HangingAfterLinesCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var initialLinesRemaining: Int
    private var recordedSentLines: [String] = []
    private var terminated = false
    private let onInitialLinesDrained: (@Sendable () -> Void)?

    init(lines: [String], onInitialLinesDrained: (@Sendable () -> Void)? = nil) {
        self.lines = lines
        self.initialLinesRemaining = lines.count
        self.onInitialLinesDrained = onInitialLinesDrained
    }

    func sentJSONMessages() throws -> [[String: Any]] {
        try recordedSentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {
        recordedSentLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextLine() async throws -> String? {
        if !lines.isEmpty {
            let line = lines.removeFirst()
            if initialLinesRemaining > 0 {
                initialLinesRemaining -= 1
                if initialLinesRemaining == 0 {
                    onInitialLinesDrained?()
                }
            }
            return line
        }

        while !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func terminate() async {
        terminated = true
    }
}

actor InterruptCompletingCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var initialLinesRemaining: Int
    private var interruptCompletionLines: [String]
    private var recordedSentLines: [String] = []
    private var terminated = false
    private let onInitialLinesDrained: (@Sendable () -> Void)?

    init(
        initialLines: [String],
        interruptCompletionLines: [String],
        onInitialLinesDrained: (@Sendable () -> Void)? = nil
    ) {
        self.lines = initialLines
        self.initialLinesRemaining = initialLines.count
        self.interruptCompletionLines = interruptCompletionLines
        self.onInitialLinesDrained = onInitialLinesDrained
    }

    var didTerminate: Bool {
        terminated
    }

    func sentJSONMessages() throws -> [[String: Any]] {
        try recordedSentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    func send(line: String) async throws {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        recordedSentLines.append(trimmedLine)
        guard let data = trimmedLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["method"] as? String == "turn/interrupt" else {
            return
        }

        lines.append(contentsOf: interruptCompletionLines)
        interruptCompletionLines = []
    }

    func nextLine() async throws -> String? {
        if !lines.isEmpty {
            let line = lines.removeFirst()
            if initialLinesRemaining > 0 {
                initialLinesRemaining -= 1
                if initialLinesRemaining == 0 {
                    onInitialLinesDrained?()
                }
            }
            return line
        }

        while !terminated && lines.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard !terminated else { return nil }
        return lines.removeFirst()
    }

    func terminate() async {
        terminated = true
    }
}

actor SleepGate {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var releasedCount = 0

    /// Suspends until `release()` is called for this waiter (FIFO), or the
    /// task is cancelled.
    func wait() async throws {
        if releasedCount > 0 {
            releasedCount -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func release() {
        if continuations.isEmpty {
            releasedCount += 1
        } else {
            continuations.removeFirst().resume()
        }
    }

    private func cancelAll() {
        let waiting = continuations
        continuations = []
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }
}

actor ThrowingAfterTerminateCodexAppServerTransport: CodexAppServerTransporting {
    private var terminated = false

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {}

    func nextLine() async throws -> String? {
        while !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw CodexAppServerProtocolError.invalidJSON
    }

    func terminate() async {
        terminated = true
    }
}

final class AppServerTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [CodexAppServerTraceEvent] = []

    var events: [CodexAppServerTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var eventLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.map { event in event.logLine }
    }

    func record(_ event: CodexAppServerTraceEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }
}

final class AppServerProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProgress: [CodexAppServerTurnProgress] = []

    var progress: [CodexAppServerTurnProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProgress
    }

    func record(_ progress: CodexAppServerTurnProgress) {
        lock.lock()
        defer { lock.unlock() }
        recordedProgress.append(progress)
    }
}

final class RunStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LoreleiRunStatus] = []

    var statuses: [LoreleiRunStatus] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ status: LoreleiRunStatus) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(status)
    }
}

actor BlockingCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var recordedSentLines: [String] = []
    private var terminated = false

    init(lines: [String]) {
        self.lines = lines
    }

    var sentLines: [String] {
        recordedSentLines
    }

    var didTerminate: Bool {
        terminated
    }

    func enqueue(_ line: String) {
        lines.append(line)
    }

    func send(line: String) async throws {
        recordedSentLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextLine() async throws -> String? {
        while lines.isEmpty && !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard !terminated else { return nil }
        return lines.removeFirst()
    }

    func terminate() async {
        terminated = true
    }
}

@MainActor
final class SilentSpeechOutput: SpeechOutputing {
    func speak(_ text: String) {}
}

struct FakeAudioInputDeviceEnumerator: AudioInputDeviceEnumerating {
    let devices: [AudioInputDevice]

    func availableInputDevices() -> [AudioInputDevice] {
        devices
    }

    func defaultInputDeviceUID() -> String? {
        devices.first?.id
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        guard let first = devices.first else { return nil }
        return deviceID(for: first.id)
    }

    func deviceID(for uid: String) -> AudioDeviceID? {
        guard let index = devices.firstIndex(where: { $0.id == uid }) else {
            return nil
        }

        return AudioDeviceID(index + 1)
    }
}

@MainActor
final class BuddyAudioFeedbackRecorder: BuddyAudioFeedbacking {
    struct Event: Equatable {
        let cue: BuddyAudioCue
        let spokenSummary: String?
    }

    private(set) var events: [Event] = []

    func play(_ cue: BuddyAudioCue, spokenSummary: String?) {
        events.append(Event(cue: cue, spokenSummary: spokenSummary))
    }
}

@MainActor
final class AppServerDesktopActionRecorder {
    private let result: WorkspaceCommandResult
    var onRun: ((String, String) -> Void)?
    private(set) var calls: [(prompt: String, cwd: String)] = []

    init(result: WorkspaceCommandResult) {
        self.result = result
    }

    func run(_ prompt: String, _ cwd: String) async -> WorkspaceCommandResult {
        calls.append((prompt, cwd))
        onRun?(prompt, cwd)
        return result
    }
}

@MainActor
final class OverlayWindowManagerRecorder: OverlayWindowManaging {
    private(set) var events: [String] = []
    private var isShowing = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        events.append("show")
        isShowing = true
    }

    func hideOverlay() {
        events.append("hide")
        isShowing = false
    }

    func fadeOutAndHideOverlay(duration: TimeInterval) {
        events.append("fadeOut")
        isShowing = false
    }

    func isShowingOverlay() -> Bool {
        isShowing
    }
}

@MainActor
final class ForegroundEnvironmentRecorder {
    private var onscreenResults: [Bool]
    private(set) var events: [String] = []
    private(set) var spaceDirections: [CodexAppServerDesktopSpaceDirection] = []

    init(onscreenResults: [Bool]) {
        self.onscreenResults = onscreenResults
    }

    func environment() -> CodexAppServerDesktopForegroundEnvironment {
        CodexAppServerDesktopForegroundEnvironment(
            openURLInApp: { [weak self] url, appName, bundleIdentifier in
                self?.events.append("open:\(url.absoluteString):\(appName ?? "nil"):\(bundleIdentifier ?? "nil")")
                return true
            },
            activateApp: { [weak self] appName, bundleIdentifier in
                self?.events.append("activate:\(appName ?? "nil"):\(bundleIdentifier ?? "nil")")
                return .success()
            },
            appHasOnscreenWindow: { [weak self] appName, bundleIdentifier in
                self?.events.append("check:\(appName ?? "nil"):\(bundleIdentifier ?? "nil")")
                guard let self, !self.onscreenResults.isEmpty else { return false }
                return self.onscreenResults.removeFirst()
            },
            switchSpace: { [weak self] direction in
                self?.spaceDirections.append(direction)
                self?.events.append("switch:\(direction.rawValue)")
            },
            sleep: { _ in }
        )
    }
}
