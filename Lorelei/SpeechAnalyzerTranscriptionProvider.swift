//
//  SpeechAnalyzerTranscriptionProvider.swift
//  Lorelei
//
//  On-device transcription provider backed by Apple's SpeechAnalyzer APIs.
//

import AVFoundation
import Foundation
import Speech

struct SpeechAnalyzerTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct SpeechAnalyzerTranscriptReducer: Equatable, Sendable {
    private(set) var finalizedText: String = ""
    private(set) var volatileText: String = ""

    var currentTranscript: String {
        Self.joinTranscriptSegments(finalizedText, volatileText)
    }

    mutating func applyVolatile(_ text: String) {
        volatileText = Self.normalizedTranscriptText(text)
    }

    mutating func applyFinalized(_ text: String) {
        let normalizedText = Self.normalizedTranscriptText(text)
        guard !normalizedText.isEmpty else {
            volatileText = ""
            return
        }

        finalizedText = Self.joinTranscriptSegments(finalizedText, normalizedText)
        volatileText = ""
    }

    private static func joinTranscriptSegments(_ firstSegment: String, _ secondSegment: String) -> String {
        let firstSegment = normalizedTranscriptText(firstSegment)
        let secondSegment = normalizedTranscriptText(secondSegment)

        guard !firstSegment.isEmpty else { return secondSegment }
        guard !secondSegment.isEmpty else { return firstSegment }

        return "\(firstSegment) \(secondSegment)"
    }

    private static func normalizedTranscriptText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple SpeechAnalyzer"
    let requiresSpeechRecognitionPermission = false

    private(set) var assetStatus: AssetInventory.Status?

    var isConfigured: Bool {
        assetStatus == .installed
    }

    var unavailableExplanation: String? {
        switch assetStatus {
        case .unsupported:
            return "Apple SpeechAnalyzer dictation is not supported for the selected locale."
        case .supported, .downloading, nil:
            return "Apple SpeechAnalyzer dictation model is downloading."
        case .installed:
            return nil
        @unknown default:
            return "Apple SpeechAnalyzer dictation model is unavailable."
        }
    }

    /// Loads the dictation model ahead of the first push-to-talk press so
    /// the first real session starts fast. Combined with the
    /// processLifetime retention policy the model then stays resident.
    func prewarm() async {
        let locale = await Self.bestAvailableLocale()
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )

        do {
            try await ensureAssetsAvailable(for: transcriber)
        } catch {
            print("SpeechAnalyzer: prewarm asset check failed: \(error)")
            return
        }

        let modules: [any SpeechModule] = [transcriber]
        let targetAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .processLifetime)
        )

        do {
            try await analyzer.prepareToAnalyze(in: targetAudioFormat)
        } catch {
            print("SpeechAnalyzer: prewarm failed: \(error)")
        }

        await analyzer.cancelAndFinishNow()
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let locale = await Self.bestAvailableLocale()
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )

        if !keyterms.isEmpty {
            print("SpeechAnalyzer: keyterms are not supported by DictationTranscriber; ignoring.")
        }

        try await ensureAssetsAvailable(for: transcriber)

        return try await SpeechAnalyzerTranscriptionSession(
            transcriber: transcriber,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    private func ensureAssetsAvailable(for transcriber: DictationTranscriber) async throws {
        let modules: [any SpeechModule] = [transcriber]
        assetStatus = await AssetInventory.status(forModules: modules)

        switch assetStatus {
        case .installed:
            return
        case .supported, .downloading:
            guard let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                assetStatus = await AssetInventory.status(forModules: modules)
                if assetStatus == .installed {
                    return
                }

                throw SpeechAnalyzerTranscriptionProviderError(
                    message: "speechanalyzer dictation model is not installed."
                )
            }

            assetStatus = .downloading
            try await installationRequest.downloadAndInstall()
            assetStatus = await AssetInventory.status(forModules: modules)

            guard assetStatus == .installed else {
                throw SpeechAnalyzerTranscriptionProviderError(
                    message: "speechanalyzer dictation model is still unavailable."
                )
            }
        case .unsupported:
            throw SpeechAnalyzerTranscriptionProviderError(
                message: "speechanalyzer dictation is not supported for this locale."
            )
        case nil:
            throw SpeechAnalyzerTranscriptionProviderError(
                message: "speechanalyzer dictation model availability is unknown."
            )
        @unknown default:
            throw SpeechAnalyzerTranscriptionProviderError(
                message: "speechanalyzer dictation model is unavailable."
            )
        }
    }

    private static func bestAvailableLocale() async -> Locale {
        let preferredLocales = [
            Locale.autoupdatingCurrent,
            Locale(identifier: "en-US")
        ]

        for preferredLocale in preferredLocales {
            if let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: preferredLocale) {
                return supportedLocale
            }
        }

        if let installedLocale = await DictationTranscriber.installedLocales.first {
            return installedLocale
        }

        if let supportedLocale = await DictationTranscriber.supportedLocales.first {
            return supportedLocale
        }

        return Locale(identifier: "en-US")
    }
}

private final class SpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    private let audioConverter: BuddyAudioBufferConverter?
    private var reducer = SpeechAnalyzerTranscriptReducer()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false

    init(
        transcriber: DictationTranscriber,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        let modules: [any SpeechModule] = [transcriber]
        let targetAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            streamContinuation = continuation
        }

        self.analyzer = SpeechAnalyzer(
            modules: modules,
            // processLifetime keeps the dictation model resident between
            // push-to-talk sessions; whileInUse reloaded it on every press,
            // adding over a second of startup before audio was accepted.
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        self.inputContinuation = streamContinuation!
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.audioConverter = targetAudioFormat.map(BuddyAudioBufferConverter.init(targetAudioFormat:))

        try await analyzer.prepareToAnalyze(in: targetAudioFormat)

        analysisTask = Task { [analyzer, onError] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                await MainActor.run {
                    onError(error)
                }
            }
        }

        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    self?.handleTranscriptionResult(result)
                }
            } catch {
                self?.handleTranscriptionError(error)
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript, !isCancelled else { return }

        let buffer = audioConverter?.convertIfNeeded(audioBuffer) ?? audioBuffer
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript, !isCancelled else { return }

        hasRequestedFinalTranscript = true
        inputContinuation.finish()

        fallbackTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(finalTranscriptFallbackDelaySeconds))
            deliverFinalTranscriptIfNeeded()
        }

        Task { [weak self, analyzer] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                self?.deliverFinalTranscriptIfNeeded()
            } catch {
                self?.handleTranscriptionError(error)
            }
        }
    }

    func cancel() {
        guard !isCancelled else { return }

        isCancelled = true
        fallbackTask?.cancel()
        resultTask?.cancel()
        analysisTask?.cancel()
        inputContinuation.finish()

        Task { [analyzer] in
            await analyzer.cancelAndFinishNow()
        }
    }

    private func handleTranscriptionResult(_ result: DictationTranscriber.Result) {
        guard !isCancelled else { return }

        let text = String(result.text.characters)
        if result.isFinal {
            reducer.applyFinalized(text)
            onTranscriptUpdate(reducer.currentTranscript)

            if hasRequestedFinalTranscript {
                deliverFinalTranscriptIfNeeded()
            }
        } else {
            reducer.applyVolatile(text)
            onTranscriptUpdate(reducer.currentTranscript)
        }
    }

    private func handleTranscriptionError(_ error: Error) {
        guard !isCancelled else { return }

        if hasRequestedFinalTranscript && !reducer.currentTranscript.isEmpty {
            deliverFinalTranscriptIfNeeded()
        } else {
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded() {
        guard !isCancelled, !hasDeliveredFinalTranscript else { return }

        hasDeliveredFinalTranscript = true
        fallbackTask?.cancel()
        onFinalTranscriptReady(reducer.currentTranscript)
    }

    deinit {
        cancel()
    }
}
