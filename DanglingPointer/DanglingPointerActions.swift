//
//  DanglingPointerActions.swift
//  DanglingPointer
//
//  Lets the buddy act, not just point: click a spot, press shortcuts, open apps
//  and web pages, and type text. Driven by the [CLICK:x,y:label], [KEY:cmd+w],
//  [OPEN_APP:Safari], [OPEN_URL:https://...] and [TYPE:text] tags in the
//  model's response.
//  Posting CGEvents requires the Accessibility permission the app already has.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum DanglingPointerActions {

    // MARK: - Tag Parsing

    /// One step the buddy can take, in the order the model listed them.
    enum Action {
        case pressShortcut(String)
        case openApp(String)
        case openURL(URL)
        case typeText(String)
    }

    struct ParsedActions {
        /// Response text with action tags removed and [CLICK:...] rewritten
        /// as [POINT:...] so the existing point parser handles it.
        let textForPointParsing: String
        /// True when the model asked to click the element it's pointing at.
        let shouldClickPointedElement: Bool
        /// Steps to run in order (capped at a few per reply).
        let actions: [Action]
    }

    private static let maxActionsPerReply = 4

    static func parseActions(from responseText: String) -> ParsedActions {
        var text = responseText
        var actions: [Action] = []

        let actionTagPattern = #"\[(KEY|OPEN_APP|OPEN_URL|TYPE):([^\]]*)\]"#
        if let regex = try? NSRegularExpression(pattern: actionTagPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard actions.count < maxActionsPerReply,
                      let kindRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text) else { continue }
                let value = String(text[valueRange]).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }

                switch text[kindRange] {
                case "KEY":
                    actions.append(.pressShortcut(value))
                case "OPEN_APP":
                    actions.append(.openApp(value))
                case "OPEN_URL":
                    // Only web links — never file://, custom schemes, etc.
                    if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        actions.append(.openURL(url))
                    } else {
                        print("⚠️ DP: ignoring non-web URL \"\(value)\"")
                    }
                case "TYPE":
                    actions.append(.typeText(value))
                default:
                    break
                }
            }
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }

        let shouldClick = text.contains("[CLICK:")
        if shouldClick {
            // The model sometimes adds [POINT:none] after a click; the click wins.
            text = text.replacingOccurrences(of: #"\[POINT:[^\]]*\]"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "[CLICK:", with: "[POINT:")
        }

        return ParsedActions(
            textForPointParsing: text.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldClickPointedElement: shouldClick,
            actions: actions
        )
    }

    // MARK: - Running Actions

    /// Runs the steps in order, pausing after each so apps and pages can load.
    @MainActor
    static func perform(_ actions: [Action]) async {
        // "open chrome and go to github" → open the page in that app, not the default browser.
        var lastOpenedAppName: String?
        for action in actions {
            guard !Task.isCancelled else { return }
            let pauseAfterSeconds: Double
            switch action {
            case .pressShortcut(let shortcut):
                pressShortcut(shortcut)
                pauseAfterSeconds = 0.5
            case .openApp(let appName):
                openApp(named: appName)
                lastOpenedAppName = appName
                pauseAfterSeconds = 1.8
            case .openURL(let url):
                if let lastOpenedAppName {
                    openApp(named: lastOpenedAppName, withURL: url)
                } else {
                    NSWorkspace.shared.open(url)
                }
                print("🌐 DP opened \(url.absoluteString)")
                pauseAfterSeconds = 1.5
            case .typeText(let text):
                typeText(text)
                pauseAfterSeconds = 0.3
            }
            try? await Task.sleep(nanoseconds: UInt64(pauseAfterSeconds * 1_000_000_000))
        }
    }

    // MARK: - Apps

    /// Opens (or brings to front) an app by name, e.g. "Safari" or "Google Chrome".
    /// With `url`, opens that page in the app (e.g. a site in Google Chrome).
    static func openApp(named appName: String, withURL url: URL? = nil) {
        // `open -a` resolves app names the same way Spotlight does. Arguments are
        // passed directly (no shell), so the name can't inject commands.
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", appName] + (url.map { [$0.absoluteString] } ?? [])
        do {
            try openProcess.run()
            print("🚀 DP opened app \(appName)")
        } catch {
            print("⚠️ DP: couldn't open app \"\(appName)\": \(error)")
        }
    }

    // MARK: - Typing

    /// Types text into whatever field currently has focus.
    static func typeText(_ text: String) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let utf16Characters = Array(text.utf16)
        // CGEvent carries at most ~20 UTF-16 units per event.
        var chunkStart = 0
        while chunkStart < utf16Characters.count {
            let chunk = Array(utf16Characters[chunkStart..<min(chunkStart + 20, utf16Characters.count)])
            for isKeyDown in [true, false] {
                let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: isKeyDown)
                keyEvent?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyEvent?.post(tap: .cghidEventTap)
            }
            usleep(15_000)
            chunkStart += 20
        }
        print("⌨️ DP typed \(text.count) characters")
    }

    // MARK: - Mouse

    /// Clicks once at a point in AppKit global coordinates (bottom-left origin).
    static func click(atAppKitGlobalPoint appKitPoint: CGPoint) {
        // CGEvents use Quartz coordinates: top-left origin of the primary display.
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else { return }
        let quartzPoint = CGPoint(x: appKitPoint.x, y: primaryScreenHeight - appKitPoint.y)
        let eventSource = CGEventSource(stateID: .hidSystemState)

        let mouseEvents: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
        for mouseEventType in mouseEvents {
            CGEvent(
                mouseEventSource: eventSource,
                mouseType: mouseEventType,
                mouseCursorPosition: quartzPoint,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        print("🖱️ DP clicked at \(Int(quartzPoint.x)), \(Int(quartzPoint.y))")
    }

    // MARK: - Keyboard

    /// Presses a shortcut like "cmd+w", "cmd+shift+t" or "escape".
    /// Returns false if the shortcut couldn't be understood.
    @discardableResult
    static func pressShortcut(_ shortcut: String) -> Bool {
        let parts = shortcut.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let keyCode = keyCodesByName[keyName] else {
            print("⚠️ DP: unknown shortcut \"\(shortcut)\"")
            return false
        }

        var flags: CGEventFlags = []
        for modifierName in parts.dropLast() {
            switch modifierName {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "opt", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                print("⚠️ DP: unknown modifier \"\(modifierName)\" in \"\(shortcut)\"")
                return false
            }
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        for isKeyDown in [true, false] {
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isKeyDown)
            keyEvent?.flags = flags
            keyEvent?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        print("⌨️ DP pressed \(shortcut)")
        return true
    }

    private static let keyCodesByName: [String: CGKeyCode] = {
        var keyCodes: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9),
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
            "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
            "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
            "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
            "comma": CGKeyCode(kVK_ANSI_Comma), "period": CGKeyCode(kVK_ANSI_Period),
            "leftbracket": CGKeyCode(kVK_ANSI_LeftBracket), "rightbracket": CGKeyCode(kVK_ANSI_RightBracket),
        ]
        keyCodes[","] = keyCodes["comma"]
        keyCodes["."] = keyCodes["period"]
        return keyCodes
    }()
}
