//
//  GeminiLiveTools.swift
//  DanglingPointer
//
//  Tool declarations and dispatch for the Gemini Live session. Wraps the
//  keyless DanglingPointerTools (web, weather, news, battery) and DanglingPointerActions
//  (open, type, shortcuts) in Gemini's function-calling format and adds the
//  screen tools: look_at_screen, point_at, click_at.
//
//  The screen is never sent up front. The model asks for it with
//  look_at_screen only when the question needs it, which is where most of
//  the per-turn token savings come from.
//

import AppKit
import Foundation

@MainActor
final class GeminiLiveTools {
    struct Outcome {
        let functionResponse: GeminiLiveFunctionResponse
        /// Screenshot to place in context before the response (look_at_screen only).
        let imageToAttach: Data?
    }

    /// point_at / click_at coordinates live in this grid over the screenshot.
    static let normalizedCoordinateSpaceSize: CGFloat = 1000

    /// MEDIUM media resolution downsamples further server-side; 960px JPEG is enough for UI text.
    private static let screenshotMaxDimension = 960
    private static let screenshotCompressionFactor: CGFloat = 0.5

    /// Blocking tools pause the model until the result is back — right for
    /// facts it must not guess. Non-blocking ones run while it keeps talking;
    /// their results are returned with `scheduling: SILENT` so the model
    /// doesn't spend output tokens acknowledging them.
    private static let nonBlockingToolNames: Set<String> = [
        "point_at", "click_at", "open_app", "open_url", "press_shortcut", "type_text"
    ]

    private let danglingPointerTools: DanglingPointerTools
    private let onPoint: (_ globalLocation: CGPoint, _ displayFrame: CGRect, _ label: String, _ shouldClick: Bool) -> Void

    /// The screenshot the model saw last; point_at / click_at refer to it.
    private var lastScreenCapture: CompanionScreenCapture?
    /// Started when the key goes down so look_at_screen usually has an answer ready.
    private var prefetchedScreenshotTask: Task<CompanionScreenCapture?, Never>?

    init(onPoint: @escaping (_ globalLocation: CGPoint, _ displayFrame: CGRect, _ label: String, _ shouldClick: Bool) -> Void) {
        self.onPoint = onPoint
        self.danglingPointerTools = DanglingPointerTools(captureScreen: {
            let screenCapture = try await Self.captureCursorScreen()
            return (data: screenCapture.imageData, label: screenCapture.label)
        })
    }

    // MARK: - Declarations

    func functionDeclarations(includeActions: Bool) -> [[String: Any]] {
        var declarations = DanglingPointerTools.definitions(includeLookAtScreen: false)
            .compactMap { Self.declaration(fromOpenAIToolDefinition: $0) }

        declarations.append(Self.declaration(
            name: "look_at_screen",
            description: "Screenshot the user's screen. Call before answering about what they see, or before pointing or clicking.",
            parameters: [:],
            required: []
        ))
        declarations.append(Self.declaration(
            name: "point_at",
            description: "Fly the cursor to an element in the latest screenshot to show the user where it is.",
            parameters: [
                "x": ("integer", "0-1000 across the screenshot, 0 is the left edge"),
                "y": ("integer", "0-1000 down the screenshot, 0 is the top edge"),
                "label": ("string", "1-3 word name of the element")
            ],
            required: ["x", "y", "label"]
        ))

        guard includeActions else { return declarations }

        declarations.append(Self.declaration(
            name: "click_at",
            description: "Click an element visible in the latest screenshot. Same coordinates as point_at.",
            parameters: [
                "x": ("integer", "0-1000 across the screenshot"),
                "y": ("integer", "0-1000 down the screenshot"),
                "label": ("string", "1-3 word name of the element")
            ],
            required: ["x", "y", "label"]
        ))
        declarations.append(Self.declaration(
            name: "open_app",
            description: "Open or switch to a Mac app by its exact name, e.g. Safari, Spotify, Notes.",
            parameters: ["name": ("string", "app name")],
            required: ["name"]
        ))
        declarations.append(Self.declaration(
            name: "open_url",
            description: "Open a web page in the browser. Use full https urls, including for google or youtube searches.",
            parameters: ["url": ("string", "full https url")],
            required: ["url"]
        ))
        declarations.append(Self.declaration(
            name: "press_shortcut",
            description: "Press a keyboard shortcut in the front app, e.g. cmd+w, cmd+shift+t, escape, return.",
            parameters: ["shortcut": ("string", "modifiers cmd/shift/option/ctrl joined with + and one key")],
            required: ["shortcut"]
        ))
        declarations.append(Self.declaration(
            name: "type_text",
            description: "Type text into the focused field.",
            parameters: ["text": ("string", "text to type")],
            required: ["text"]
        ))
        return declarations
    }

    private static func declaration(
        name: String,
        description: String,
        parameters: [String: (type: String, description: String)],
        required: [String]
    ) -> [String: Any] {
        var declaration: [String: Any] = [
            "name": name,
            "description": description,
            "behavior": nonBlockingToolNames.contains(name) ? "NON_BLOCKING" : "BLOCKING"
        ]
        // Gemini rejects an OBJECT schema with no properties; leave parameters out instead.
        if !parameters.isEmpty {
            declaration["parameters"] = [
                "type": "object",
                "properties": parameters.mapValues { ["type": $0.type, "description": $0.description] },
                "required": required
            ] as [String: Any]
        }
        return declaration
    }

    /// DanglingPointerTools describes itself in OpenAI's `{"type":"function","function":{...}}`
    /// shape; Gemini wants the inner object plus a `behavior`.
    private static func declaration(fromOpenAIToolDefinition definition: [String: Any]) -> [String: Any]? {
        guard let function = definition["function"] as? [String: Any],
              let name = function["name"] as? String else { return nil }

        var declaration: [String: Any] = [
            "name": name,
            "behavior": nonBlockingToolNames.contains(name) ? "NON_BLOCKING" : "BLOCKING"
        ]
        if let description = function["description"] as? String {
            declaration["description"] = description
        }
        if let parameters = function["parameters"] as? [String: Any],
           let properties = parameters["properties"] as? [String: Any], !properties.isEmpty {
            declaration["parameters"] = parameters
        }
        return declaration
    }

    // MARK: - Screenshot Prefetch

    /// Called when the push-to-talk key goes down. Capturing is local and
    /// costs nothing in tokens, so the screenshot is ready if the model asks.
    func prefetchScreenshot() {
        prefetchedScreenshotTask?.cancel()
        prefetchedScreenshotTask = Task {
            try? await Self.captureCursorScreen()
        }
    }

    private static func captureCursorScreen() async throws -> CompanionScreenCapture {
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
            onlyCursorScreen: true,
            maxDimension: screenshotMaxDimension,
            compressionFactor: screenshotCompressionFactor
        )
        guard let cursorScreenCapture = screenCaptures.first else {
            throw NSError(domain: "GeminiLiveTools", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't capture the cursor screen"])
        }
        return cursorScreenCapture
    }

    // MARK: - Dispatch

    func handle(_ functionCall: GeminiLiveFunctionCall) async -> Outcome {
        let arguments = functionCall.arguments
        let stringArgument = { (key: String) in
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var imageToAttach: Data?
        let resultText: String

        switch functionCall.name {
        case "look_at_screen":
            do {
                // Use the key-down prefetch if it finished; otherwise capture now.
                let prefetchedCapture: CompanionScreenCapture? = await prefetchedScreenshotTask?.value ?? nil
                prefetchedScreenshotTask = nil
                let screenCapture: CompanionScreenCapture
                if let prefetchedCapture {
                    screenCapture = prefetchedCapture
                } else {
                    screenCapture = try await Self.captureCursorScreen()
                }
                lastScreenCapture = screenCapture
                imageToAttach = screenCapture.imageData
                resultText = "screenshot attached as the image above. coordinates for point_at/click_at are 0-1000 over it."
            } catch {
                resultText = "couldn't capture the screen: \(error.localizedDescription)"
            }

        case "point_at":
            resultText = pointAtElement(arguments: arguments, shouldClick: false)

        case "click_at":
            resultText = pointAtElement(arguments: arguments, shouldClick: true)

        case "open_app":
            let appName = stringArgument("name")
            if appName.isEmpty {
                resultText = "no app name given"
            } else {
                DanglingPointerActions.openApp(named: appName)
                resultText = "opening \(appName)"
            }

        case "open_url":
            // Only web links — never file://, custom schemes, etc.
            if let url = URL(string: stringArgument("url")),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                print("🌐 DP opened \(url.absoluteString)")
                resultText = "opened"
            } else {
                resultText = "only http(s) urls can be opened"
            }

        case "press_shortcut":
            let shortcut = stringArgument("shortcut")
            resultText = DanglingPointerActions.pressShortcut(shortcut) ? "pressed \(shortcut)" : "unknown shortcut \(shortcut)"

        case "type_text":
            let text = stringArgument("text")
            if text.isEmpty {
                resultText = "nothing to type"
            } else {
                DanglingPointerActions.typeText(text)
                resultText = "typed"
            }

        default:
            // Web search, weather, news, read_webpage, battery.
            let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let toolResult = await danglingPointerTools.run(
                XkiroToolCall(id: functionCall.id, name: functionCall.name, argumentsJSON: argumentsJSON)
            )
            resultText = toolResult.text
        }

        var response: [String: Any] = ["result": resultText]
        if Self.nonBlockingToolNames.contains(functionCall.name) {
            response["scheduling"] = "SILENT"
        }
        print("🔧 Gemini Live tool \(functionCall.name) → \(resultText.prefix(80))")

        return Outcome(
            functionResponse: GeminiLiveFunctionResponse(id: functionCall.id, name: functionCall.name, response: response),
            imageToAttach: imageToAttach
        )
    }

    private func pointAtElement(arguments: [String: Any], shouldClick: Bool) -> String {
        guard let screenCapture = lastScreenCapture else {
            return "no screenshot yet — call look_at_screen first"
        }
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue,
              let y = (arguments["y"] as? NSNumber)?.doubleValue else {
            return "x and y are required"
        }
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "element"

        let globalLocation = screenCapture.globalScreenLocation(
            forNormalizedPoint: CGPoint(x: x, y: y),
            normalizedSpaceSize: Self.normalizedCoordinateSpaceSize
        )
        onPoint(globalLocation, screenCapture.displayFrame, label, shouldClick)
        return shouldClick ? "clicking \(label)" : "pointing at \(label)"
    }
}
