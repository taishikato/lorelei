//
//  WakeWordProbe.swift
//  Lorelei
//
//  Pure wake-word matcher plus a DEBUG-only measurement probe.
//

import Foundation

enum WakeWordMatcher {
    /// Whole-token, case-insensitive match: 'Lorelei,' and 'hey lorelei'
    /// match; substrings inside longer words do not.
    ///
    /// When using the default wake word, also accept common STT spellings
    /// ('lorelai', 'loreley') so spoken detections are measurable.
    static func containsWakeWord(
        _ transcript: String,
        wakeWord: String = "lorelei"
    ) -> Bool {
        let targets = acceptedTokens(for: wakeWord)
        guard !targets.isEmpty else { return false }

        return transcript
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { targets.contains(String($0)) }
    }

    private static func acceptedTokens(for wakeWord: String) -> Set<String> {
        let primary = wakeWord.lowercased()
        guard !primary.isEmpty else { return [] }
        if primary == "lorelei" {
            return ["lorelei", "lorelai", "loreley"]
        }
        return [primary]
    }
}

#if DEBUG
import AVFoundation

/// DEBUG-only ambient wake-word measurement probe.
///
/// Owns a private audio engine and a streaming STT session. Detection is
/// logged (lengths only - never transcript content) and never wired to
/// dictation or turns.
@MainActor
final class WakeWordProbe {
    private enum ProbeError: LocalizedError {
        case inputDeviceProvidesNoAudio

        var errorDescription: String? {
            switch self {
            case .inputDeviceProvidesNoAudio:
                return "Input device provides no audio"
            }
        }
    }

    /// Lock-guarded sink so the audio tap can forward buffers without hopping
    /// onto the main actor.
    private final class SessionBufferSink: @unchecked Sendable {
        private let lock = NSLock()
        private var session: (any BuddyStreamingTranscriptionSession)?

        func setSession(_ session: (any BuddyStreamingTranscriptionSession)?) {
            lock.lock()
            self.session = session
            lock.unlock()
        }

        func append(_ audioBuffer: AVAudioPCMBuffer) {
            lock.lock()
            let session = self.session
            lock.unlock()
            session?.appendAudioBuffer(audioBuffer)
        }
    }

    private let audioEngine = AVAudioEngine()
    private let bufferSink = SessionBufferSink()
    private let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()

    private var activeSession: (any BuddyStreamingTranscriptionSession)?
    private var isRunning = false
    private var isRestarting = false
    private var hasInstalledTap = false
    private var consecutiveFailures = 0
    /// Bumped on intentional teardown so stale session callbacks are ignored.
    private var sessionGeneration = 0
    private var sessionTask: Task<Void, Never>?
    private var errorRestartTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }

        isRunning = true
        consecutiveFailures = 0
        LoreleiDiagLog.log("wakeProbe: started")

        sessionTask?.cancel()
        sessionTask = Task { await self.beginListening() }
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false
        isRestarting = false
        sessionTask?.cancel()
        sessionTask = nil
        errorRestartTask?.cancel()
        errorRestartTask = nil

        invalidateAndTearDownSession()
        tearDownEngine()
        LoreleiDiagLog.log("wakeProbe: stopped")
    }

    private func beginListening() async {
        guard isRunning else { return }

        do {
            try startAudioEngineIfNeeded()
            try await openStreamingSession()
        } catch {
            await handleSessionError(error)
        }
    }

    private func startAudioEngineIfNeeded() throws {
        if audioEngine.isRunning, hasInstalledTap {
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // A device that provides no input (e.g. AirPods in output-only mode)
        // reports a zero-channel format. installTap raises an exception on
        // such a format, so bail out with a clean error instead of crashing.
        guard inputFormat.channelCount > 0 else {
            throw ProbeError.inputDeviceProvidesNoAudio
        }

        inputNode.removeTap(onBus: 0)
        let sink = bufferSink
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            sink.append(buffer)
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func openStreamingSession() async throws {
        guard isRunning else { return }

        let generation = sessionGeneration
        let session = try await transcriptionProvider.startStreamingSession(
            keyterms: ["lorelei"],
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.handleTranscriptUpdate(generation: generation, text: transcriptText)
                }
            },
            onFinalTranscriptReady: { _ in
                // Probe does not consume finals; restart after detection opens
                // a fresh session instead.
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    await self?.handleSessionError(error, generation: generation)
                }
            }
        )

        guard isRunning, generation == sessionGeneration else {
            session.cancel()
            return
        }

        activeSession = session
        bufferSink.setSession(session)
        consecutiveFailures = 0
        isRestarting = false
    }

    private func handleTranscriptUpdate(generation: Int, text: String) {
        guard isRunning, !isRestarting, generation == sessionGeneration else { return }
        guard WakeWordMatcher.containsWakeWord(text) else { return }

        isRestarting = true
        // Privacy: lengths only - never log transcript content.
        LoreleiDiagLog.log("wakeProbe: DETECTED transcriptChars=\(text.count)")

        activeSession?.requestFinalTranscript()
        invalidateAndTearDownSession()

        sessionTask?.cancel()
        sessionTask = Task { await self.restartListeningAfterDetection() }
    }

    private func restartListeningAfterDetection() async {
        guard isRunning else { return }

        do {
            try await openStreamingSession()
        } catch {
            await handleSessionError(error, generation: sessionGeneration)
        }
    }

    private func handleSessionError(_ error: Error, generation: Int? = nil) async {
        guard isRunning else { return }
        if let generation, generation != sessionGeneration {
            return
        }

        LoreleiDiagLog.log("wakeProbe: session error \(error.localizedDescription)")
        invalidateAndTearDownSession()
        isRestarting = false

        consecutiveFailures += 1
        if consecutiveFailures >= 5 {
            LoreleiDiagLog.log("wakeProbe: gave up")
            stop()
            return
        }

        errorRestartTask?.cancel()
        errorRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            await self.beginListening()
        }
    }

    private func invalidateAndTearDownSession() {
        sessionGeneration += 1
        bufferSink.setSession(nil)
        activeSession?.cancel()
        activeSession = nil
    }

    private func tearDownEngine() {
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
}
#endif
