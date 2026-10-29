//
//  AIChatManager.swift
//  boringNotch
//
//  State, streaming and on-disk history for the Ask AI tab.
//

import AppKit
import Foundation

struct AIChatSummary: Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let url: URL
}

@MainActor
final class AIChatManager: ObservableObject {
    static let shared = AIChatManager()

    @Published var input = ""
    @Published private(set) var messages: [AIChatMessage] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var isSearching = false
    @Published private(set) var error: AIChatError?
    @Published var isInputFocused = false
    @Published var isMenuOpen = false
    @Published var pendingFocus = false
    @Published private(set) var recentChats: [AIChatSummary] = []

    var keepsNotchOpen: Bool {
        isInputFocused || isMenuOpen || (isStreaming && BoringViewCoordinator.shared.currentView == .aiChat)
    }

    private let provider: AIChatProvider = AnthropicProvider()
    private var chatID = UUID()
    private var createdAt = Date()
    private var streamTask: Task<Void, Never>?
    private var turnID = 0

    private init() {
        AIChatStore.purgeOld()
        recentChats = AIChatStore.listRecent()
    }

    private var systemPrompt: String {
        let today = Date.now.formatted(date: .complete, time: .omitted)
        return """
        You are a quick-answer assistant inside a macOS notch widget. Today's date is \(today). \
        Answer in 1 to 4 sentences of plain text, no markdown, no preamble. \
        Your training data ends before today's date, so for anything recent or time-sensitive say so or search the web if you can.
        """
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        error = nil
        streamingText = ""
        isSearching = false
        messages.append(AIChatMessage(role: "user", text: text))
        isStreaming = true
        let history = messages
        turnID += 1
        let myTurn = turnID

        streamTask = Task { [weak self] in
            guard let self else { return }
            var stopReason: String?
            do {
                for try await event in self.provider.stream(system: self.systemPrompt, messages: history) {
                    guard self.turnID == myTurn else { return }
                    switch event {
                    case .textDelta(let delta): self.streamingText += delta
                    case .searching(let on): self.isSearching = on
                    case .done(let reason): stopReason = reason
                    }
                }
            } catch let err as AIChatError {
                guard self.turnID == myTurn else { return }
                self.error = err
            } catch {
                guard self.turnID == myTurn else { return }
                self.error = .network(error.localizedDescription)
            }
            guard self.turnID == myTurn else { return }
            self.finishTurn(stopReason: stopReason)
        }
    }

    private func finishTurn(stopReason: String?) {
        var text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if stopReason == "refusal" {
            text = "Claude declined to answer this."
        } else if stopReason == "pause_turn" {
            text += " (stopped early)"
        } else if stopReason == "max_tokens" {
            text += " (cut off)"
        }
        if !text.isEmpty {
            messages.append(AIChatMessage(role: "assistant", text: text))
        }
        streamingText = ""
        isStreaming = false
        isSearching = false
        streamTask = nil
        save()
    }

    func stop() {
        streamTask?.cancel()
    }

    /// Synchronously ends an in-flight turn (keeping the partial answer, saving the old chat)
    /// and invalidates its task so late events can't touch whatever chat is current next.
    private func abandonTurn() {
        guard isStreaming else { return }
        let task = streamTask
        finishTurn(stopReason: nil)
        turnID += 1
        task?.cancel()
    }

    func newChat() {
        abandonTurn()
        messages = []
        streamingText = ""
        error = nil
        input = ""
        chatID = UUID()
        createdAt = Date()
    }

    func load(_ summary: AIChatSummary) {
        guard let chat = AIChatStore.read(summary.url) else { return }
        abandonTurn()
        messages = chat.messages
        chatID = chat.id
        createdAt = chat.createdAt
        streamingText = ""
        error = nil
    }

    @discardableResult
    func copyForClaude() -> Bool {
        guard !messages.isEmpty else { return false }
        let transcript = messages
            .map { ($0.role == "user" ? "User: " : "Assistant: ") + $0.text }
            .joined(separator: "\n\n")
        let text = "Continuing a quick chat from my notch widget:\n\n\(transcript)\n\nLet's continue from here."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    private func save() {
        guard !messages.isEmpty else { return }
        AIChatStore.write(AIChatStore.Chat(id: chatID, createdAt: createdAt, updatedAt: Date(), messages: messages))
        AIChatStore.purgeOld()
        recentChats = AIChatStore.listRecent()
    }
}

enum AIChatStore {
    struct Chat: Codable {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var messages: [AIChatMessage]
    }

    private static var directory: URL {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (support ?? fm.temporaryDirectory).appendingPathComponent("AIChat", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func fileURL(for chat: Chat) -> URL {
        let day = chat.createdAt.formatted(.iso8601.year().month().day())
        return directory.appendingPathComponent("\(day)-\(chat.id.uuidString).json")
    }

    static func write(_ chat: Chat) {
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: fileURL(for: chat), options: .atomic)
    }

    static func read(_ url: URL) -> Chat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Chat.self, from: data)
    }

    private static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
    }

    static func purgeOld() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for url in files() {
            let expired: Bool
            if let chat = read(url) {
                expired = chat.updatedAt < cutoff
            } else {
                // Undecodable file: fall back to its modification date.
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                expired = (modified ?? .distantFuture) < cutoff
            }
            if expired { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func listRecent() -> [AIChatSummary] {
        files().compactMap { url -> AIChatSummary? in
            guard let chat = read(url) else { return nil }
            let first = chat.messages.first { $0.role == "user" }?.text ?? "Chat"
            let title = first.count > 40 ? String(first.prefix(40)) + "…" : first
            let date = chat.updatedAt.formatted(date: .abbreviated, time: .omitted)
            return AIChatSummary(id: chat.id, title: "\(title) · \(date)", updatedAt: chat.updatedAt, url: url)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }
}
