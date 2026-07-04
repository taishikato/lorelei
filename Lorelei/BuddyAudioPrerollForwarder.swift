//
//  BuddyAudioPrerollForwarder.swift
//  Lorelei
//
//  Buffers microphone audio captured before the transcription session is
//  ready, then replays it into the session so no speech is lost.
//

import AVFoundation
import Foundation

/// Forwards microphone buffers to a transcription session, holding on to
/// everything captured before the session exists.
///
/// Transcription providers can take over a second to come up (model load,
/// asset checks), and push-to-talk users start speaking the instant they
/// press the shortcut. The audio tap therefore starts before the provider
/// and feeds this forwarder; once the session is ready, `attach` replays the
/// buffered audio in order and live buffers pass straight through.
///
/// `forward` is called from the audio render thread while `attach`/`discard`
/// run on the main actor, so all state is guarded by a lock. Replaying under
/// the lock keeps buffered and live audio strictly ordered; a session append
/// only converts and enqueues the buffer, so the critical section stays
/// short enough for the audio thread.
final class BuddyAudioPrerollForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrameCount = 0
    private var session: (any BuddyStreamingTranscriptionSession)?
    private var isDiscarded = false
    private let maxPendingFrames: Int

    /// 90 seconds at 48kHz - far beyond any real push-to-talk hold, purely
    /// a memory backstop if the provider never comes up.
    init(maxPendingFrames: Int = 48_000 * 90) {
        self.maxPendingFrames = maxPendingFrames
    }

    var bufferedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingFrameCount
    }

    func forward(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDiscarded else { return }

        if let session {
            session.appendAudioBuffer(audioBuffer)
            return
        }

        pendingBuffers.append(audioBuffer)
        pendingFrameCount += Int(audioBuffer.frameLength)
        while pendingFrameCount > maxPendingFrames, !pendingBuffers.isEmpty {
            pendingFrameCount -= Int(pendingBuffers.removeFirst().frameLength)
        }
    }

    func attach(_ session: any BuddyStreamingTranscriptionSession) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDiscarded, self.session == nil else { return }

        for audioBuffer in pendingBuffers {
            session.appendAudioBuffer(audioBuffer)
        }
        pendingBuffers = []
        pendingFrameCount = 0
        self.session = session
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        isDiscarded = true
        pendingBuffers = []
        pendingFrameCount = 0
        session = nil
    }
}
