# Dangling Pointer

**Made by [Suvam Neog](https://github.com/suvamneog)**

A macOS menu bar AI companion. It lives in your status bar, talks with your voice, can see your screen, and points at UI with a Patrick Star buddy cursor.

Hold **ctrl + option** to talk. Release to let it answer out loud.

---

## What it is

Dangling Pointer is a menu-bar-only Mac app (no dock icon, no main window). You click the status item for controls, or use the global push-to-talk shortcut to speak.

Under the hood it uses **Gemini Live** over a WebSocket: speech in, speech out, and tool calls on one connection. It can:

- Answer questions by voice
- Look at your screen when needed (`look_at_screen`)
- Point at UI elements (`point_at`)
- Click things (`click_at`)
- Call local tools for web / news / weather-style lookups (via the app tool layer)

The on-screen buddy is a **Patrick Star Lip Bite** cursor/pointer overlay that follows your mouse and flies to elements the model names.

Your Gemini API key stays on disk at `~/.dangling-pointer/gemini_api_key` — nothing sensitive ships in the app bundle.

---

## How it was made

Built as a native **SwiftUI + AppKit** macOS app:

| Piece | What it does |
|-------|----------------|
| Menu bar panel | `NSStatusItem` + borderless `NSPanel` for controls |
| Cursor overlay | Full-screen transparent panel for the buddy, waveform, Dynamic Island transcript |
| Push-to-talk | Global `CGEvent` tap for ctrl+option; mic streams 16 kHz PCM16 only while held |
| Gemini Live | Raw `BidiGenerateContent` WebSocket — no separate STT/TTS pipeline for the live path |
| Screen capture | ScreenCaptureKit; screenshots only when the model asks |
| Pointing | Model returns 0–1000 coords over the last screenshot; overlay maps and animates along a bezier arc |
| Worker (optional legacy) | Cloudflare Worker can still proxy Claude / ElevenLabs / AssemblyAI for older paths |

Token-conscious Live session: audio only during the held key, short system prompt, idle socket drop, compressed screenshots.

Project layout:

```
DanglingPointer/           # Swift sources + assets
DanglingPointer.xcodeproj  # Xcode project (scheme: DanglingPointer)
DanglingPointerTests/
DanglingPointerUITests/
worker/                    # Optional Cloudflare proxy
AGENTS.md                  # Architecture notes for coding agents
```

---

## Setup

### Prerequisites

- macOS 14.2+
- Xcode 15+
- A Gemini API key

### 1. API key

```bash
mkdir -p ~/.dangling-pointer
echo 'YOUR_GEMINI_API_KEY' > ~/.dangling-pointer/gemini_api_key
chmod 600 ~/.dangling-pointer/gemini_api_key
```

### 2. Open and run

```bash
open DanglingPointer.xcodeproj
```

In Xcode: select the **DanglingPointer** scheme, set your signing team, then **Cmd+R**.

### 3. Permissions

Grant when asked:

- Microphone — push-to-talk
- Accessibility — global shortcut
- Screen Recording / Screen Content — look at screen + pointing

---

## Usage

1. Click the menu bar icon → toggle “Show buddy” / check status
2. Hold **ctrl + option** and speak
3. Release — Gemini Live replies by voice
4. Ask it to look at something on screen or point/click when useful

---

## License

MIT — Copyright (c) 2026 Suvam Neog. See `LICENSE`.

Inspired by [Farza](https://x.com/farzatv) / [Clicky](https://github.com/farzaa/clicky).
