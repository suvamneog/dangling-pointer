//
//  GeminiLiveAudioPlayer.swift
//  DanglingPointer
//
//  Plays the 24 kHz PCM16 audio Gemini Live streams back, chunk by chunk,
//  so speech starts on the first packet instead of after the whole reply.
//

import AVFoundation
import Foundation

@MainActor
final class GeminiLiveAudioPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(GeminiLiveClient.outputSampleRate),
        channels: 1,
        interleaved: false
    )!

    /// Buffers scheduled but not yet played out.
    private var pendingBufferCount = 0
    /// Bumped on stop() so completion callbacks from discarded buffers are ignored.
    private var playbackGeneration = 0

    init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
    }

    var isPlaying: Bool {
        pendingBufferCount > 0
    }

    func enqueue(pcm16Audio: Data) {
        guard let audioBuffer = makeFloatBuffer(fromPCM16: pcm16Audio) else { return }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("⚠️ Gemini Live player: couldn't start audio engine: \(error)")
                return
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }

        pendingBufferCount += 1
        let generation = playbackGeneration
        playerNode.scheduleBuffer(audioBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingBufferCount = max(0, self.pendingBufferCount - 1)
            }
        }
    }

    /// Drops everything queued. Used when the user starts talking again or
    /// the server reports the model was interrupted.
    func stop() {
        playbackGeneration += 1
        pendingBufferCount = 0
        playerNode.stop()
    }

    private func makeFloatBuffer(fromPCM16 pcm16Audio: Data) -> AVAudioPCMBuffer? {
        let sampleCount = pcm16Audio.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatSamples = audioBuffer.floatChannelData?[0] else {
            return nil
        }

        pcm16Audio.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for sampleIndex in 0..<sampleCount {
                floatSamples[sampleIndex] = Float(Int16(littleEndian: int16Samples[sampleIndex])) / Float(Int16.max)
            }
        }
        audioBuffer.frameLength = AVAudioFrameCount(sampleCount)
        return audioBuffer
    }
}
