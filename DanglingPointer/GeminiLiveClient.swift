//
//  GeminiLiveClient.swift
//  DanglingPointer
//
//  Raw WebSocket client for the Gemini Live API (BidiGenerateContent).
//  Speech in, speech out and tool calls over one socket — no separate
//  STT or TTS round trips. Server-side voice detection is disabled: the
//  push-to-talk key sends explicit activityStart/activityEnd, so no
//  silence is ever streamed and the reply starts the moment the key lifts.
//

import Foundation

struct GeminiLiveFunctionCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

struct GeminiLiveFunctionResponse {
    let id: String
    let name: String
    /// JSON object handed back to the model, e.g. ["result": "..."].
    let response: [String: Any]
}

struct GeminiLiveSessionConfiguration {
    var model = "gemini-3.8-live"
    var voiceName = "Aoede"
    var systemInstruction: String
    /// Gemini `functionDeclarations`; empty means no tools.
    var functionDeclarations: [[String: Any]]
    /// Context size that triggers server-side trimming, and what it trims down to.
    /// Kept small on purpose: every model turn re-reads the whole context.
    var compressionTriggerTokens = 12_000
    var compressionTargetTokens = 4_000
}

@MainActor
protocol GeminiLiveClientDelegate: AnyObject {
    func geminiLiveClientDidBecomeReady(_ client: GeminiLiveClient)
    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveAudioChunk pcm16Audio: Data)
    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveInputTranscription text: String)
    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveOutputTranscription text: String)
    func geminiLiveClient(_ client: GeminiLiveClient, didRequestFunctionCalls functionCalls: [GeminiLiveFunctionCall])
    func geminiLiveClientWasInterrupted(_ client: GeminiLiveClient)
    func geminiLiveClientDidCompleteTurn(_ client: GeminiLiveClient)
    func geminiLiveClient(_ client: GeminiLiveClient, didReportUsage usage: GeminiLiveClient.TokenUsage)
    func geminiLiveClient(_ client: GeminiLiveClient, didCloseWithError error: Error?)
}

@MainActor
final class GeminiLiveClient {
    enum ConnectionState {
        case disconnected
        case connecting
        case ready
    }

    struct TokenUsage {
        let promptTokens: Int
        let responseTokens: Int
        let totalTokens: Int
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let inputSampleRate = 16_000
    static let outputSampleRate = 24_000

    private static let endpointURLString =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    weak var delegate: GeminiLiveClientDelegate?
    private(set) var connectionState: ConnectionState = .disconnected
    /// Lets a new socket continue the same conversation after the server closes this one.
    private(set) var sessionResumptionHandle: String?
    /// The server sends goAway shortly before it drops the connection (~10 min lifetime).
    private(set) var isServerGoingAway = false

    private let apiKey: String
    // One long-lived URLSession for every connection. Creating and invalidating a
    // session per connection corrupts the connection pool (see the AssemblyAI note).
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    /// Bumped on every connect/disconnect so callbacks from a stale socket are ignored.
    private var connectionGeneration = 0

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Connection

    func connect(configuration: GeminiLiveSessionConfiguration, resumingPreviousSession: Bool) {
        guard connectionState == .disconnected else { return }

        guard var urlComponents = URLComponents(string: Self.endpointURLString) else { return }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let websocketURL = urlComponents.url else { return }

        connectionGeneration += 1
        let generation = connectionGeneration
        connectionState = .connecting
        isServerGoingAway = false

        let webSocketTask = urlSession.webSocketTask(with: websocketURL)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
        receiveNextMessage(generation: generation)

        let resumeHandle = resumingPreviousSession ? sessionResumptionHandle : nil
        if !resumingPreviousSession {
            sessionResumptionHandle = nil
        }
        send(["setup": Self.setupMessage(for: configuration, resumeHandle: resumeHandle)])
        print("🔮 Gemini Live: connecting (\(configuration.model), resume: \(resumeHandle != nil))")
    }

    func disconnect() {
        guard connectionState != .disconnected else { return }
        connectionGeneration += 1
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
        isServerGoingAway = false
        print("🔮 Gemini Live: disconnected")
    }

    // MARK: - Sending

    /// Marks the start of the user's speech. Only valid because automatic
    /// activity detection is disabled in the setup message.
    func sendActivityStart() {
        send(["realtimeInput": ["activityStart": [String: Any]()]])
    }

    /// Marks the end of the user's speech; the model starts replying right away.
    func sendActivityEnd() {
        send(["realtimeInput": ["activityEnd": [String: Any]()]])
    }

    /// Streams one chunk of 16 kHz mono PCM16 microphone audio.
    func sendAudioChunk(_ pcm16Audio: Data) {
        send([
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(Self.inputSampleRate)",
                    "data": pcm16Audio.base64EncodedString()
                ]
            ]
        ])
    }

    /// Puts a screenshot into the conversation as a user message without
    /// ending the turn. Used while a blocking tool call is pending, so the
    /// image is guaranteed to be in context before the tool result arrives.
    /// (A realtime video frame would be attributed to the *next* user turn.)
    func sendImage(jpegData: Data) {
        send([
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]]]
                ]],
                "turnComplete": false
            ]
        ])
    }

    func sendFunctionResponses(_ functionResponses: [GeminiLiveFunctionResponse]) {
        guard !functionResponses.isEmpty else { return }
        send([
            "toolResponse": [
                "functionResponses": functionResponses.map { functionResponse in
                    ["id": functionResponse.id, "name": functionResponse.name, "response": functionResponse.response]
                }
            ]
        ])
    }

    private func send(_ message: [String: Any]) {
        guard let webSocketTask, connectionState != .disconnected else { return }
        guard let messageData = try? JSONSerialization.data(withJSONObject: message),
              let messageText = String(data: messageData, encoding: .utf8) else {
            print("⚠️ Gemini Live: couldn't encode message")
            return
        }
        let generation = connectionGeneration
        webSocketTask.send(.string(messageText)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.handleSocketFailure(error, generation: generation)
            }
        }
    }

    // MARK: - Setup Message

    private static func setupMessage(for configuration: GeminiLiveSessionConfiguration, resumeHandle: String?) -> [String: Any] {
        var setup: [String: Any] = [
            "model": "models/\(configuration.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                // MEDIUM is enough to read UI text and costs far fewer tokens than HIGH.
                "mediaResolution": "MEDIA_RESOLUTION_MEDIUM",
                "speechConfig": [
                    "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": configuration.voiceName]]
                ]
            ] as [String: Any],
            "systemInstruction": ["parts": [["text": configuration.systemInstruction]]],
            // Push-to-talk owns the turn boundaries.
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            // Transcripts are text tokens — negligible next to audio, and they
            // give us the user's words for history/analytics without a second STT.
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            "contextWindowCompression": [
                "triggerTokens": configuration.compressionTriggerTokens,
                "slidingWindow": ["targetTokens": configuration.compressionTargetTokens]
            ] as [String: Any],
            "sessionResumption": resumeHandle.map { ["handle": $0] } ?? [String: Any]()
        ]
        if !configuration.functionDeclarations.isEmpty {
            setup["tools"] = [["functionDeclarations": configuration.functionDeclarations]]
        }
        return setup
    }

    // MARK: - Receiving

    private func receiveNextMessage(generation: Int) {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                let messageData: Data?
                switch message {
                case .data(let data):
                    messageData = data
                case .string(let text):
                    messageData = text.data(using: .utf8)
                @unknown default:
                    messageData = nil
                }
                // Parse off the main actor; audio chunks arrive many times a second.
                let events = messageData.map(Self.parseServerMessage) ?? []
                Task { @MainActor [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    events.forEach(self.handle)
                    self.receiveNextMessage(generation: generation)
                }
            case .failure(let error):
                Task { @MainActor [weak self] in
                    self?.handleSocketFailure(error, generation: generation)
                }
            }
        }
    }

    private enum ServerEvent {
        case setupComplete
        case audioChunk(Data)
        case inputTranscription(String)
        case outputTranscription(String)
        case toolCall([GeminiLiveFunctionCall])
        case interrupted
        case turnComplete
        case goAway
        case sessionResumptionHandle(String)
        case usage(TokenUsage)
    }

    private nonisolated static func parseServerMessage(_ messageData: Data) -> [ServerEvent] {
        guard let message = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any] else {
            return []
        }
        var events: [ServerEvent] = []

        if message["setupComplete"] != nil {
            events.append(.setupComplete)
        }

        if let serverContent = message["serverContent"] as? [String: Any] {
            if let parts = (serverContent["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let base64Audio = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: base64Audio) {
                        events.append(.audioChunk(audioData))
                    }
                }
            }
            if let text = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String {
                events.append(.inputTranscription(text))
            }
            if let text = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String {
                events.append(.outputTranscription(text))
            }
            if serverContent["interrupted"] as? Bool == true {
                events.append(.interrupted)
            }
            if serverContent["turnComplete"] as? Bool == true {
                events.append(.turnComplete)
            }
        }

        if let functionCalls = (message["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            let parsedCalls = functionCalls.compactMap { functionCall -> GeminiLiveFunctionCall? in
                guard let name = functionCall["name"] as? String else { return nil }
                return GeminiLiveFunctionCall(
                    id: functionCall["id"] as? String ?? UUID().uuidString,
                    name: name,
                    arguments: functionCall["args"] as? [String: Any] ?? [:]
                )
            }
            if !parsedCalls.isEmpty {
                events.append(.toolCall(parsedCalls))
            }
        }

        if message["goAway"] != nil {
            events.append(.goAway)
        }

        if let resumptionUpdate = message["sessionResumptionUpdate"] as? [String: Any],
           resumptionUpdate["resumable"] as? Bool == true,
           let handle = resumptionUpdate["newHandle"] as? String, !handle.isEmpty {
            events.append(.sessionResumptionHandle(handle))
        }

        if let usage = message["usageMetadata"] as? [String: Any] {
            events.append(.usage(TokenUsage(
                promptTokens: usage["promptTokenCount"] as? Int ?? 0,
                responseTokens: usage["responseTokenCount"] as? Int ?? 0,
                totalTokens: usage["totalTokenCount"] as? Int ?? 0
            )))
        }

        return events
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .setupComplete:
            connectionState = .ready
            print("🔮 Gemini Live: ready")
            delegate?.geminiLiveClientDidBecomeReady(self)
        case .audioChunk(let audioData):
            delegate?.geminiLiveClient(self, didReceiveAudioChunk: audioData)
        case .inputTranscription(let text):
            delegate?.geminiLiveClient(self, didReceiveInputTranscription: text)
        case .outputTranscription(let text):
            delegate?.geminiLiveClient(self, didReceiveOutputTranscription: text)
        case .toolCall(let functionCalls):
            delegate?.geminiLiveClient(self, didRequestFunctionCalls: functionCalls)
        case .interrupted:
            delegate?.geminiLiveClientWasInterrupted(self)
        case .turnComplete:
            delegate?.geminiLiveClientDidCompleteTurn(self)
        case .goAway:
            isServerGoingAway = true
            print("🔮 Gemini Live: server is closing the connection soon")
        case .sessionResumptionHandle(let handle):
            sessionResumptionHandle = handle
        case .usage(let usage):
            delegate?.geminiLiveClient(self, didReportUsage: usage)
        }
    }

    private func handleSocketFailure(_ error: Error, generation: Int) {
        guard connectionGeneration == generation, connectionState != .disconnected else { return }
        connectionGeneration += 1
        // The server explains rejected setups (bad key, unknown model…) in the close reason.
        let closeReason = webSocketTask?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        webSocketTask = nil
        connectionState = .disconnected
        // A goAway followed by the server hanging up is expected, not a failure.
        let closedByServerAsAnnounced = isServerGoingAway
        isServerGoingAway = false
        if closedByServerAsAnnounced {
            print("🔮 Gemini Live: server closed the connection as announced")
            delegate?.geminiLiveClient(self, didCloseWithError: nil)
        } else {
            print("❌ Gemini Live: socket failed: \(error.localizedDescription) \(closeReason ?? "")")
            let reportedError: Error = closeReason.map { ClientError(message: $0) } ?? error
            delegate?.geminiLiveClient(self, didCloseWithError: reportedError)
        }
    }
}
