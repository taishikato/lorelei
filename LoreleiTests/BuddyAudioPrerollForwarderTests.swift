//
//  BuddyAudioPrerollForwarderTests.swift
//  LoreleiTests
//

import AVFoundation
import Testing
@testable import Lorelei

private final class RecordingTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.0
    private(set) var appendedFrameLengths: [AVAudioFrameCount] = []

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        appendedFrameLengths.append(audioBuffer.frameLength)
    }

    func requestFinalTranscript() {}

    func cancel() {}
}

private func makeAudioBuffer(frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
    buffer.frameLength = frameLength
    return buffer
}

struct BuddyAudioPrerollForwarderTests {
    @Test func replaysBufferedAudioInOrderOnAttachThenForwardsLive() async throws {
        let forwarder = BuddyAudioPrerollForwarder()
        let session = RecordingTranscriptionSession()

        forwarder.forward(makeAudioBuffer(frameLength: 100))
        forwarder.forward(makeAudioBuffer(frameLength: 200))
        #expect(session.appendedFrameLengths.isEmpty)
        #expect(forwarder.bufferedFrameCount == 300)

        forwarder.attach(session)
        #expect(session.appendedFrameLengths == [100, 200])
        #expect(forwarder.bufferedFrameCount == 0)

        forwarder.forward(makeAudioBuffer(frameLength: 300))
        #expect(session.appendedFrameLengths == [100, 200, 300])
        #expect(forwarder.bufferedFrameCount == 0)
    }

    @Test func evictsOldestAudioWhenOverCapacity() async throws {
        let forwarder = BuddyAudioPrerollForwarder(maxPendingFrames: 300)
        let session = RecordingTranscriptionSession()

        forwarder.forward(makeAudioBuffer(frameLength: 100))
        forwarder.forward(makeAudioBuffer(frameLength: 150))
        forwarder.forward(makeAudioBuffer(frameLength: 120))

        forwarder.attach(session)
        #expect(session.appendedFrameLengths == [150, 120])
    }

    @Test func discardDropsBufferedAudioAndIgnoresLaterCalls() async throws {
        let forwarder = BuddyAudioPrerollForwarder()
        let session = RecordingTranscriptionSession()

        forwarder.forward(makeAudioBuffer(frameLength: 100))
        forwarder.discard()
        #expect(forwarder.bufferedFrameCount == 0)

        forwarder.attach(session)
        forwarder.forward(makeAudioBuffer(frameLength: 200))
        #expect(session.appendedFrameLengths.isEmpty)
    }

    @Test func attachTwiceKeepsFirstSession() async throws {
        let forwarder = BuddyAudioPrerollForwarder()
        let firstSession = RecordingTranscriptionSession()
        let secondSession = RecordingTranscriptionSession()

        forwarder.attach(firstSession)
        forwarder.attach(secondSession)
        forwarder.forward(makeAudioBuffer(frameLength: 100))

        #expect(firstSession.appendedFrameLengths == [100])
        #expect(secondSession.appendedFrameLengths.isEmpty)
    }
}
