//
//  BuddyTranscriptionProvider.swift
//  Lorelei
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession

    /// Optional warm-up performed once at app launch so the first real
    /// session does not pay model-loading latency.
    func prewarm() async
}

extension BuddyTranscriptionProvider {
    func prewarm() async {}
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case apple = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")
        let provider = makeProvider(preferredProviderRawValue: preferredProviderRawValue)
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    static func makeProvider(preferredProviderRawValue: String?) -> any BuddyTranscriptionProvider {
        let normalizedPreferredProviderRawValue = preferredProviderRawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let preferredProvider = normalizedPreferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        switch preferredProvider {
        case .apple, nil:
            return SpeechAnalyzerTranscriptionProvider()
        }
    }
}
