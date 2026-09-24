//
//  DynamicIslandView.swift
//  DanglingPointer
//
//  Apple-style Dynamic Island pill at the top of the screen. Expands to
//  show the user's live push-to-talk transcript (already streamed by
//  Gemini Live — no extra tokens), then springs back when idle.
//

import AppKit
import SwiftUI

struct DynamicIslandView: View {
    @ObservedObject var companionManager: CompanionManager

    private enum IslandPhase {
        case collapsed
        case listening
        case processing
        case responding
    }

    private var phase: IslandPhase {
        switch companionManager.voiceState {
        case .listening: return .listening
        case .processing: return .processing
        case .responding: return .responding
        case .idle: return .collapsed
        }
    }

    private var isExpanded: Bool {
        phase != .collapsed
    }

    private var transcriptText: String {
        companionManager.lastTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var displayLine: String {
        switch phase {
        case .listening:
            return transcriptText.isEmpty ? "Listening…" : transcriptText
        case .processing:
            return transcriptText.isEmpty ? "Thinking…" : transcriptText
        case .responding:
            return "Speaking…"
        case .collapsed:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            islandPill
                .animation(.spring(response: 0.38, dampingFraction: 0.78), value: phase)
                .animation(.spring(response: 0.38, dampingFraction: 0.78), value: displayLine)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var islandPill: some View {
        HStack(spacing: isExpanded ? 10 : 0) {
            statusGlyph
                .frame(width: isExpanded ? 18 : 10, height: isExpanded ? 18 : 10)

            if isExpanded {
                Text(displayLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 420, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, isExpanded ? 18 : 14)
        .padding(.vertical, isExpanded ? 12 : 10)
        .frame(minWidth: isExpanded ? 220 : 126, minHeight: isExpanded ? 44 : 36)
        .background(islandBackground)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: isExpanded ? 24 : 14, y: isExpanded ? 10 : 6)
        .shadow(color: Color.purple.opacity(isExpanded ? 0.18 : 0.08), radius: isExpanded ? 18 : 8, y: 0)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch phase {
        case .listening:
            IslandWaveformDots(audioPowerLevel: companionManager.currentAudioPowerLevel)
        case .processing:
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.85))
        case .responding:
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .symbolEffect(.variableColor, options: .repeating, isActive: true)
        case .collapsed:
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.2, green: 0.45, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var islandBackground: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.72))
        }
    }
}

/// Tiny reactive dots — visual only, uses the same loudness already published for the buddy waveform.
private struct IslandWaveformDots: View {
    let audioPowerLevel: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2.5, height: barHeight(for: index, at: timeline.date))
                }
            }
            .frame(width: 14, height: 14)
        }
    }

    private func barHeight(for index: Int, at date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 4.2) + CGFloat(index) * 0.55
        let pulse = (sin(phase) + 1) * 0.5
        let level = max(audioPowerLevel, 0.08)
        return 4 + pulse * 8 * level
    }
}
