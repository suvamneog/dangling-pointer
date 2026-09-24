//
//  GeminiLiveSession.swift
//  DanglingPointer
//
//  Owns the Live socket, mic, playback, and tools. Push-to-talk is the
//  only time audio is sent (25 tokens/s), so silence never burns quota.
//  The socket stays up between turns and is dropped after a short idle
//  so a stale context isn't re-read on the next request.
//

import Foundation

@MainActor
final class GeminiLiveSession: GeminiLiveClientDelegate {
    private static let idleDisconnectNanoseconds: UInt64 = 90_000_000_000
    /// Resume a dropped socket only when the last context was still small.
    private static let maxTokensToResume = 6_000

    private static let shortSystemInstruction = """
    you're dangling pointer, a macOS menu-bar buddy. speak 1-2 short sentences, casual lowercase, no lists or markdown. never guess news, weather, or live facts — use tools. call look_at_screen only when the question needs the screen, then point_at or click_at if that helps. don't name tools or narrate calling them.
    """

    private static let actionsAddendum = """
    you can open_app, open_url, press_shortcut, and type_text when the user clearly asks. don't delete, send, buy, or submit unless they asked for exactly that.
    """

    private let client: GeminiLiveClient
    private let microphone = GeminiLiveMicrophoneStreamer()
    private let player = GeminiLiveAudioPlayer()
    private let tools: GeminiLiveTools

    var includeActions = true
    var onVoiceStateChange: ((CompanionVoiceState) -> Void)?
    var onAudioPower: ((CGFloat) -> Void)?
    var onInputTranscript: ((String) -> Void)?
    var onOutputTranscript: ((String) -> Void)?
    var onTurnFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var isTalking = false
    private var startedTalkingBeforeReady = false
    private var endTalkingWhenReady = false
    private var audioChunksWhileConnecting: [Data] = []
    private var sentAnyAudioThisTurn = false
    private var inputTranscriptThisTurn = ""
    private var outputTranscriptThisTurn = ""
    private var lastUsageTotalTokens = 0
    private var idleDisconnectTask: Task<Void, Never>?

    var isPlayingAudio: Bool {
        player.isPlaying
    }

    init(
        apiKey: String,
        onPoint: @escaping (_ globalLocation: CGPoint, _ displayFrame: CGRect, _ label: String, _ shouldClick: Bool) -> Void
    ) {
        self.client = GeminiLiveClient(apiKey: apiKey)
        self.tools = GeminiLiveTools(onPoint: onPoint)
        client.delegate = self
        microphone.onAudioChunk = { [weak self] pcm16Audio, loudness in
            self?.handleMicrophoneChunk(pcm16Audio, loudness: loudness)
        }
    }

    // MARK: - Push-to-talk

    func beginTalking() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil
        player.stop()
        inputTranscriptThisTurn = ""
        outputTranscriptThisTurn = ""
        sentAnyAudioThisTurn = false
        endTalkingWhenReady = false
        audioChunksWhileConnecting.removeAll(keepingCapacity: true)
        isTalking = true
        tools.prefetchScreenshot()
        onVoiceStateChange?(.listening)

        if client.connectionState == .disconnected {
            startedTalkingBeforeReady = true
            client.connect(configuration: sessionConfiguration(), resumingPreviousSession: shouldResumePreviousSession)
        } else if client.connectionState == .connecting {
            startedTalkingBeforeReady = true
        } else {
            client.sendActivityStart()
        }

        do {
            try microphone.start()
        } catch {
            print("⚠️ Gemini Live: mic failed: \(error.localizedDescription)")
            isTalking = false
            onFailure?("Couldn't open the microphone.")
        }
    }

    func endTalking() {
        guard isTalking else { return }
        isTalking = false
        microphone.stop()
        onAudioPower?(0)

        if client.connectionState != .ready {
            // Key came up before the socket finished — finish the turn once it does.
            endTalkingWhenReady = true
            onVoiceStateChange?(.processing)
            return
        }

        finishTurnIfNeeded()
    }

    func stopEverything() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil
        isTalking = false
        startedTalkingBeforeReady = false
        endTalkingWhenReady = false
        audioChunksWhileConnecting.removeAll()
        microphone.stop()
        player.stop()
        client.disconnect()
        onAudioPower?(0)
    }

    private var shouldResumePreviousSession: Bool {
        client.sessionResumptionHandle != nil && lastUsageTotalTokens < Self.maxTokensToResume
    }

    private func sessionConfiguration() -> GeminiLiveSessionConfiguration {
        var configuration = GeminiLiveSessionConfiguration(
            systemInstruction: includeActions
                ? Self.shortSystemInstruction + "\n" + Self.actionsAddendum
                : Self.shortSystemInstruction,
            functionDeclarations: tools.functionDeclarations(includeActions: includeActions)
        )
        // Tight window: the model re-reads context every turn.
        configuration.compressionTriggerTokens = 8_000
        configuration.compressionTargetTokens = 2_500
        return configuration
    }

    private func handleMicrophoneChunk(_ pcm16Audio: Data, loudness: CGFloat) {
        onAudioPower?(loudness)
        guard isTalking else { return }

        if client.connectionState == .ready {
            client.sendAudioChunk(pcm16Audio)
            sentAnyAudioThisTurn = true
        } else if audioChunksWhileConnecting.count < 40 {
            // ~1.7s at 43ms/chunk — enough to cover connect without a long backlog.
            audioChunksWhileConnecting.append(pcm16Audio)
        }
    }

    private func flushBufferedAudio() {
        guard client.connectionState == .ready else { return }
        for chunk in audioChunksWhileConnecting {
            client.sendAudioChunk(chunk)
            sentAnyAudioThisTurn = true
        }
        audioChunksWhileConnecting.removeAll(keepingCapacity: true)
    }

    private func finishTurnIfNeeded() {
        guard sentAnyAudioThisTurn || !audioChunksWhileConnecting.isEmpty else {
            print("🔮 Gemini Live: ignored empty press")
            onVoiceStateChange?(.idle)
            scheduleIdleDisconnect()
            return
        }
        flushBufferedAudio()
        client.sendActivityEnd()
        onVoiceStateChange?(.processing)
    }

    private func scheduleIdleDisconnect() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleDisconnectNanoseconds)
            guard let self, !Task.isCancelled, !self.isTalking, !self.player.isPlaying else { return }
            print("🔮 Gemini Live: idle disconnect to drop context")
            self.client.disconnect()
            self.lastUsageTotalTokens = 0
        }
    }

    // MARK: - GeminiLiveClientDelegate

    func geminiLiveClientDidBecomeReady(_ client: GeminiLiveClient) {
        if startedTalkingBeforeReady {
            startedTalkingBeforeReady = false
            client.sendActivityStart()
            flushBufferedAudio()
            if endTalkingWhenReady {
                endTalkingWhenReady = false
                finishTurnIfNeeded()
            }
        }
    }

    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveAudioChunk pcm16Audio: Data) {
        if !player.isPlaying {
            onVoiceStateChange?(.responding)
        }
        player.enqueue(pcm16Audio: pcm16Audio)
    }

    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveInputTranscription text: String) {
        inputTranscriptThisTurn += text
        onInputTranscript?(inputTranscriptThisTurn)
    }

    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveOutputTranscription text: String) {
        outputTranscriptThisTurn += text
        onOutputTranscript?(outputTranscriptThisTurn)
    }

    func geminiLiveClient(_ client: GeminiLiveClient, didRequestFunctionCalls functionCalls: [GeminiLiveFunctionCall]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var functionResponses: [GeminiLiveFunctionResponse] = []
            for functionCall in functionCalls {
                let outcome = await self.tools.handle(functionCall)
                if let imageToAttach = outcome.imageToAttach {
                    // Image first so it's in context when the tool result lands.
                    self.client.sendImage(jpegData: imageToAttach)
                }
                functionResponses.append(outcome.functionResponse)
            }
            self.client.sendFunctionResponses(functionResponses)
        }
    }

    func geminiLiveClientWasInterrupted(_ client: GeminiLiveClient) {
        player.stop()
    }

    func geminiLiveClientDidCompleteTurn(_ client: GeminiLiveClient) {
        if !inputTranscriptThisTurn.isEmpty {
            DanglingPointerAnalytics.trackUserMessageSent(transcript: inputTranscriptThisTurn)
        }
        if !outputTranscriptThisTurn.isEmpty {
            DanglingPointerAnalytics.trackAIResponseReceived(response: outputTranscriptThisTurn)
        }
        onVoiceStateChange?(.idle)
        onTurnFinished?()
        scheduleIdleDisconnect()
    }

    func geminiLiveClient(_ client: GeminiLiveClient, didReportUsage usage: GeminiLiveClient.TokenUsage) {
        lastUsageTotalTokens = usage.totalTokens
        print("💰 Gemini Live tokens  prompt=\(usage.promptTokens)  response=\(usage.responseTokens)  total=\(usage.totalTokens)")
    }

    func geminiLiveClient(_ client: GeminiLiveClient, didCloseWithError error: Error?) {
        microphone.stop()
        isTalking = false
        startedTalkingBeforeReady = false
        endTalkingWhenReady = false
        audioChunksWhileConnecting.removeAll()
        if let error {
            onFailure?(error.localizedDescription)
        }
    }
}
