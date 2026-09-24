//
//  DanglingPointerMemoryStore.swift
//  DanglingPointer
//
//  Tiny flat memory under ~/.dangling-pointer/memory.json.
//  Kept small on purpose: only a short snippet is injected into the Live
//  system prompt so context tokens stay cheap.
//

import Foundation

@MainActor
final class DanglingPointerMemoryStore {
    static let shared = DanglingPointerMemoryStore()

    /// Hard caps — memory must never bloat the Live context.
    private static let maxStoredItems = 40
    private static let maxFactCharacters = 120
    private static let maxPromptItems = 12
    private static let maxPromptCharacters = 600

    private struct MemoryItem: Codable, Equatable {
        var id: String
        var text: String
        var tags: [String]
        var updatedAt: Date
    }

    private struct MemoryFile: Codable {
        var items: [MemoryItem]
    }

    private let fileURL: URL
    private var items: [MemoryItem] = []

    private init() {
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dangling-pointer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("memory.json", isDirectory: false)
        loadFromDisk()
    }

    // MARK: - Prompt (token-tight)

    /// Compact block for the Live system instruction. Empty when nothing stored.
    func promptSnippet() -> String {
        let recentItems = Array(items.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxPromptItems))
        guard !recentItems.isEmpty else { return "" }

        var lines: [String] = []
        var usedCharacters = 0
        for item in recentItems {
            let line = "- \(item.text)"
            if usedCharacters + line.count + 1 > Self.maxPromptCharacters { break }
            lines.append(line)
            usedCharacters += line.count + 1
        }
        guard !lines.isEmpty else { return "" }
        return "memory (short):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Mutations

    @discardableResult
    func remember(fact rawFact: String, tags: [String] = []) -> String {
        let fact = Self.clamp(rawFact.trimmingCharacters(in: .whitespacesAndNewlines), max: Self.maxFactCharacters)
        guard !fact.isEmpty else { return "empty fact" }

        // Upsert by case-insensitive text match so repeats don't duplicate.
        if let existingIndex = items.firstIndex(where: { $0.text.compare(fact, options: .caseInsensitive) == .orderedSame }) {
            items[existingIndex].updatedAt = Date()
            items[existingIndex].tags = Self.normalizedTags(tags.isEmpty ? items[existingIndex].tags : tags)
            persist()
            return "updated"
        }

        items.insert(
            MemoryItem(
                id: UUID().uuidString,
                text: fact,
                tags: Self.normalizedTags(tags),
                updatedAt: Date()
            ),
            at: 0
        )
        if items.count > Self.maxStoredItems {
            items = Array(items.prefix(Self.maxStoredItems))
        }
        persist()
        return "remembered"
    }

    @discardableResult
    func forget(matching rawQuery: String) -> String {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "nothing to forget" }

        let beforeCount = items.count
        items.removeAll { item in
            item.text.localizedCaseInsensitiveContains(query)
                || item.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
        let removedCount = beforeCount - items.count
        guard removedCount > 0 else { return "no match" }
        persist()
        return "forgot \(removedCount)"
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(MemoryFile.self, from: data) else {
            items = []
            return
        }
        items = Array(file.items.prefix(Self.maxStoredItems))
    }

    private func persist() {
        let file = MemoryFile(items: items)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func clamp(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: max)
        return String(text[..<endIndex])
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        Array(
            Set(
                tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                    .map { clamp($0, max: 24) }
            )
        ).prefix(4).map { $0 }
    }
}
