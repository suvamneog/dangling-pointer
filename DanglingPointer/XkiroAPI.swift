//
//  XkiroAPI.swift
//  DanglingPointer
//
//  OpenAI-compatible chat completions client for xKiro (https://xkiro.com),
//  with streaming and tool calling. The model can call tools (web search,
//  weather, look at the screen, …); results are fed back and the final
//  answer streams to `onTextChunk`.
//

import Foundation

/// A tool call the model asked for.
struct XkiroToolCall {
    let id: String
    let name: String
    /// Raw JSON arguments string from the model.
    let argumentsJSON: String

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// What a tool hands back to the model. `imageData` (e.g. a screenshot) is
/// attached as an image in a follow-up user message, since tool messages are text-only.
struct XkiroToolResult {
    let text: String
    var imageData: Data? = nil
    var imageLabel: String? = nil
}

class XkiroAPI {
    static let defaultBaseURL = "https://api.xkiro.com/v1"
    static let defaultModel = "qwen/qwen3.8-max:free"

    /// Stops a runaway tool loop; each round is a full model call.
    private static let maxToolRounds = 3

    private let apiURL: URL
    private let apiKey: String
    var model: String
    private let session: URLSession

    init(apiKey: String, baseURL: String = XkiroAPI.defaultBaseURL, model: String = XkiroAPI.defaultModel) {
        self.apiURL = URL(string: "\(baseURL)/chat/completions")!
        self.apiKey = apiKey
        self.model = model

        // Cache TLS tickets, never cache responses.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        warmUpTLSConnection()
    }

    /// Sends a no-op HEAD request to pre-establish the TLS session. Failures are ignored.
    private func warmUpTLSConnection() {
        var warmupRequest = URLRequest(url: apiURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in }.resume()
    }

    /// PNG starts with 89 50 4E 47; everything else (screen captures) is JPEG.
    private static func imageDataURL(for imageData: Data) -> String {
        let isPNG = imageData.count >= 4 && [UInt8](imageData.prefix(4)) == [0x89, 0x50, 0x4E, 0x47]
        return "data:\(isPNG ? "image/png" : "image/jpeg");base64,\(imageData.base64EncodedString())"
    }

    private static func imageContentBlocks(for images: [(data: Data, label: String)]) -> [[String: Any]] {
        images.flatMap { image -> [[String: Any]] in
            [
                ["type": "image_url", "image_url": ["url": imageDataURL(for: image.data)]],
                ["type": "text", "text": image.label]
            ]
        }
    }

    // MARK: - Streaming With Tools

    /// Streams a reply, running any tools the model calls along the way.
    /// `onTextChunk` receives all text so far (across tool rounds) on the main actor.
    func respondStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        tools: [[String: Any]] = [],
        maxTokens: Int = 400,
        handleToolCall: @escaping @MainActor (XkiroToolCall) async -> XkiroToolResult = { _ in XkiroToolResult(text: "tool unavailable") },
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }
        if images.isEmpty {
            // Plain string content is the cheapest form for text-only turns.
            messages.append(["role": "user", "content": userPrompt])
        } else {
            messages.append([
                "role": "user",
                "content": Self.imageContentBlocks(for: images) + [["type": "text", "text": userPrompt]]
            ])
        }

        var accumulatedText = ""

        for toolRound in 0...Self.maxToolRounds {
            // On the last round, withhold tools so the model has to answer.
            let toolsForRound = toolRound < Self.maxToolRounds ? tools : []
            let roundStartText = accumulatedText
            let roundResult = try await streamOneRound(
                messages: messages,
                tools: toolsForRound,
                maxTokens: maxTokens,
                onRoundText: { roundText in
                    accumulatedText = roundStartText.isEmpty ? roundText : roundStartText + " " + roundText
                    await onTextChunk(accumulatedText)
                }
            )

            guard !roundResult.toolCalls.isEmpty else { break }
            try Task.checkCancellation()

            messages.append([
                "role": "assistant",
                "content": roundResult.text.isEmpty ? NSNull() : roundResult.text,
                "tool_calls": roundResult.toolCalls.map { toolCall in
                    [
                        "id": toolCall.id,
                        "type": "function",
                        "function": ["name": toolCall.name, "arguments": toolCall.argumentsJSON]
                    ]
                }
            ])

            var attachedImages: [(data: Data, label: String)] = []
            for toolCall in roundResult.toolCalls {
                print("🛠️ Tool call: \(toolCall.name) \(toolCall.argumentsJSON)")
                let toolResult = await handleToolCall(toolCall)
                messages.append(["role": "tool", "tool_call_id": toolCall.id, "content": toolResult.text])
                if let imageData = toolResult.imageData {
                    attachedImages.append((data: imageData, label: toolResult.imageLabel ?? "screenshot"))
                }
            }
            if !attachedImages.isEmpty {
                messages.append([
                    "role": "user",
                    "content": Self.imageContentBlocks(for: attachedImages)
                        + [["type": "text", "text": "(requested screenshot attached)"]]
                ])
            }
        }

        return (text: accumulatedText, duration: Date().timeIntervalSince(startTime))
    }

    /// Kept for the onboarding demo: a single streamed vision request, no tools.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await respondStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxTokens: 200,
            onTextChunk: onTextChunk
        )
    }

    // MARK: - One Streamed Round

    private struct RoundResult {
        let text: String
        let toolCalls: [XkiroToolCall]
    }

    private func streamOneRound(
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int,
        onRoundText: @MainActor (String) async -> Void
    ) async throws -> RoundResult {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        print("🌐 xKiro streaming request (\(model)): \(bodyData.count / 1024)KB, tools: \(tools.count)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "XkiroAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            throw NSError(domain: "XkiroAPI", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBodyLines.joined(separator: "\n"))"])
        }

        // SSE: "data: {chunk}" lines, ending with "data: [DONE]". Text comes in
        // delta.content; tool calls arrive in pieces keyed by delta.tool_calls[].index.
        // Reasoning deltas are ignored so thinking is never spoken.
        var roundText = ""
        var partialToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in byteStream.lines {
            guard line.hasPrefix("data:") else { continue }
            let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = chunk["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }

            if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
                roundText += textChunk
                await onRoundText(roundText)
            }

            for toolCallDelta in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = toolCallDelta["index"] as? Int ?? 0
                var partial = partialToolCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = toolCallDelta["id"] as? String, !id.isEmpty { partial.id = id }
                if let function = toolCallDelta["function"] as? [String: Any] {
                    partial.name += function["name"] as? String ?? ""
                    partial.arguments += function["arguments"] as? String ?? ""
                }
                partialToolCalls[index] = partial
            }
        }

        let toolCalls = partialToolCalls.keys.sorted().compactMap { index -> XkiroToolCall? in
            guard let partial = partialToolCalls[index], !partial.name.isEmpty else { return nil }
            return XkiroToolCall(
                id: partial.id.isEmpty ? "call_\(index)" : partial.id,
                name: partial.name,
                argumentsJSON: partial.arguments.isEmpty ? "{}" : partial.arguments
            )
        }
        return RoundResult(text: roundText, toolCalls: toolCalls)
    }
}
