//
//  SystemTTSClient.swift
//  DanglingPointer
//
//  Speaks responses with the built-in macOS voices (AVSpeechSynthesizer).
//  Same interface as ElevenLabsTTSClient, but needs no API key or network.
//  Tip: download a nicer "Premium"/"Enhanced" voice in System Settings →
//  Accessibility → Spoken Content → System Voice → Manage Voices.
//

import AVFoundation
import Foundation

@MainActor
final class SystemTTSClient {
    private let synthesizer = AVSpeechSynthesizer()

    /// Picks the highest-quality installed English voice.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let languageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let languagePrefix = String(languageCode.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) }
        let bestVoice = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
        return bestVoice ?? AVSpeechSynthesisVoice(language: languageCode)
    }()

    /// Starts speaking `text` and returns immediately, like ElevenLabsTTSClient
    /// returning after `player.play()`.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        print("🔊 System TTS: speaking \(text.count) chars with \(voice?.name ?? "default voice")")
    }

    /// Queues `text` after whatever is already being spoken.
    func enqueueText(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Whether speech is currently playing back.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Feeds a streaming response to the TTS client one complete sentence at a
/// time, so speech starts before the full response has arrived. Tags like
/// [POINT:...], [CLICK:...], [KEY:...], [OPEN_APP:...] etc. are never spoken, wherever they appear.
@MainActor
final class StreamingSentenceSpeaker {
    private let ttsClient: SystemTTSClient
    /// Speakable text that has already been handed to the TTS client.
    private var spokenPrefix = ""

    init(ttsClient: SystemTTSClient) {
        self.ttsClient = ttsClient
    }

    /// Removes complete tags and cuts at a tag that's still streaming in.
    nonisolated static func speakableText(from streamedText: String) -> String {
        let withoutCompleteTags = streamedText.replacingOccurrences(
            of: #"\[[A-Z_]+:[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )
        return withoutCompleteTags.components(separatedBy: "[").first ?? ""
    }

    /// Speaks any newly completed sentences in `accumulatedText`.
    /// Returns true if something new was queued.
    @discardableResult
    func speakCompletedSentences(in accumulatedText: String) -> Bool {
        let speakableText = Self.speakableText(from: accumulatedText)
        guard speakableText.count > spokenPrefix.count,
              speakableText.hasPrefix(spokenPrefix) else { return false }

        let unspokenText = speakableText.dropFirst(spokenPrefix.count)
        // A sentence ends at . ! or ? followed by whitespace (so "3.5" isn't split).
        var lastSentenceEnd: String.Index?
        var index = unspokenText.startIndex
        while index < unspokenText.endIndex {
            let nextIndex = unspokenText.index(after: index)
            if ".!?".contains(unspokenText[index]),
               nextIndex < unspokenText.endIndex,
               unspokenText[nextIndex].isWhitespace {
                lastSentenceEnd = nextIndex
            }
            index = nextIndex
        }
        guard let lastSentenceEnd else { return false }

        let completedSentences = String(unspokenText[..<lastSentenceEnd])
        spokenPrefix += completedSentences
        return enqueueIfNotBlank(completedSentences)
    }

    /// Speaks whatever part of the finished response wasn't spoken while streaming.
    func speakRemainder(ofStreamedText fullResponseText: String) {
        let speakableText = Self.speakableText(from: fullResponseText)
        guard speakableText.hasPrefix(spokenPrefix) else { return }
        enqueueIfNotBlank(String(speakableText.dropFirst(spokenPrefix.count)))
        spokenPrefix = speakableText
    }

    @discardableResult
    private func enqueueIfNotBlank(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }
        ttsClient.enqueueText(trimmedText)
        return true
    }
}
