//
//  GeminiLiveMicrophoneStreamer.swift
//  DanglingPointer
//
//  Captures the microphone while the push-to-talk key is held and hands out
//  16 kHz mono PCM16 chunks ready for the Gemini Live socket, plus a
//  loudness level for the waveform. Bypasses BuddyDictationManager on
//  purpose: there is no transcript to wait for, so there is no finalize delay.
//

import AVFoundation
import Foundation

@MainActor
final class GeminiLiveMicrophoneStreamer {
    private let audioEngine = AVAudioEngine()
    private(set) var isCapturing = false

    /// Called on the main actor with each PCM16 chunk and its loudness (0...1).
    var onAudioChunk: ((Data, CGFloat) -> Void)?

    func start() throws {
        guard !isCapturing else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Owned by the tap closure so it never crosses actor boundaries.
        let pcm16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(GeminiLiveClient.inputSampleRate))

        inputNode.removeTap(onBus: 0)
        // ~43 ms per chunk at 48 kHz: responsive without flooding the socket.
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] audioBuffer, _ in
            let loudness = Self.loudness(of: audioBuffer)
            guard let pcm16Audio = pcm16Converter.convertToPCM16Data(from: audioBuffer), !pcm16Audio.isEmpty else {
                return
            }
            Task { @MainActor [weak self] in
                self?.onAudioChunk?(pcm16Audio, loudness)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
    }

    /// Same boost/clamp as BuddyDictationManager so the waveform looks identical.
    private nonisolated static func loudness(of audioBuffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelSamples = audioBuffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }
        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        return CGFloat(min(max(rootMeanSquare * 10.2, 0), 1))
    }
}
