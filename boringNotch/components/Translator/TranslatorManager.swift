//
//  TranslatorManager.swift
//  boringNotch
//
//  Translator tab: DeepL client, auto direction (anything ↔ Russian) and selection capture.
//

import AppKit
import Defaults
import NaturalLanguage
import SwiftUI

enum TranslatorError: Error, Equatable {
    case missingKey
    case invalidKey
    case quotaExceeded
    case rateLimited
    case network(String)
    case noSelection
    case noAccessibility

    var message: String {
        switch self {
        case .missingKey: return "Add your DeepL API key in Settings → Translator"
        case .invalidKey: return "DeepL rejected the API key (403)"
        case .quotaExceeded: return "DeepL monthly character quota exceeded"
        case .rateLimited: return "Too many requests, try again in a moment"
        case .network(let details): return "Translation failed: \(details)"
        case .noSelection: return "Nothing was selected"
        case .noAccessibility: return "Grant Accessibility access to translate selected text"
        }
    }
}

@MainActor
final class TranslatorManager: ObservableObject {
    static let shared = TranslatorManager()

    @Published var input: String = "" {
        didSet {
            guard input != oldValue else { return }
            scheduleTranslation()
        }
    }
    @Published private(set) var output: String = ""
    /// Source language DeepL detected (or the one forced by `sourceSelection`).
    @Published private(set) var sourceLanguage: String?
    /// Target language actually used for the last translation (DeepL target code).
    @Published private(set) var targetLanguage: String?
    @Published private(set) var isTranslating = false
    @Published var error: TranslatorError?
    /// True while the input field has keyboard focus; keeps the notch from closing on hover-out.
    @Published var isInputFocused = false
    /// True while a language menu is open: the pointer leaves the notch to reach the menu.
    @Published var isMenuOpen = false

    /// nil = detect automatically.
    @Published private(set) var sourceSelection: String? = Defaults[.translatorSource]
    /// nil = automatic (anything → Russian, Russian → English).
    @Published private(set) var targetSelection: String? = Defaults[.translatorTarget]
    @Published private(set) var sourceLanguages = TranslatorLanguage.fallbackSources
    @Published private(set) var targetLanguages = TranslatorLanguage.fallbackTargets

    var keepsNotchOpen: Bool { isInputFocused || isMenuOpen }

    private var debounceTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var languagesLoaded = false
    private let debounce: Duration = .milliseconds(600)

    private init() {}

    // MARK: - Languages

    func setSource(_ code: String?) {
        guard code != sourceSelection else { return }
        sourceSelection = code
        Defaults[.translatorSource] = code
        translateNow()
    }

    func setTarget(_ code: String?) {
        guard code != targetSelection else { return }
        targetSelection = code
        Defaults[.translatorTarget] = code
        translateNow()
    }

    /// Swap direction: the current target becomes the source and vice versa, and the
    /// translation moves into the input.
    func swapLanguages() {
        guard let source = sourceSelection ?? sourceLanguage,
              let target = targetSelection ?? targetLanguage else { return }
        sourceSelection = TranslatorLanguage.baseCode(target)
        targetSelection = TranslatorLanguage.targetCode(forSource: source)
        Defaults[.translatorSource] = sourceSelection
        Defaults[.translatorTarget] = targetSelection
        if !output.isEmpty {
            input = output
        }
        translateNow()
    }

    func isStarred(_ code: String) -> Bool {
        let starred = Defaults[.translatorStarredLanguages]
        return starred.contains(code) || starred.map(TranslatorLanguage.baseCode).contains(code)
    }

    /// Stars are stored as target codes so one star covers both menus (EN-US ↔ EN).
    func toggleStar(_ code: String) {
        var starred = Defaults[.translatorStarredLanguages]
        if let index = starred.firstIndex(where: { $0 == code || TranslatorLanguage.baseCode($0) == code }) {
            starred.remove(at: index)
        } else {
            starred.append(TranslatorLanguage.targetCode(forSource: code))
        }
        Defaults[.translatorStarredLanguages] = starred
        objectWillChange.send()
    }

    func name(for code: String) -> String {
        (targetLanguages + sourceLanguages).first { $0.code == code }?.name
            ?? TranslatorLanguage.localizedName(code)
    }

    /// Replace the built-in lists with the ones DeepL reports for this key (once per launch).
    func loadLanguagesIfNeeded() {
        let key = Defaults[.deeplAPIKey].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !languagesLoaded, !key.isEmpty else { return }
        languagesLoaded = true
        Task { [weak self] in
            async let sources = DeepLClient.languages(type: "source", key: key)
            async let targets = DeepLClient.languages(type: "target", key: key)
            let (loadedSources, loadedTargets) = await (sources, targets)
            guard let self else { return }
            if let loadedSources, !loadedSources.isEmpty { self.sourceLanguages = loadedSources }
            if let loadedTargets, !loadedTargets.isEmpty { self.targetLanguages = loadedTargets }
            if loadedSources == nil || loadedTargets == nil { self.languagesLoaded = false }
        }
    }

    // MARK: - Translation

    private func scheduleTranslation() {
        debounceTask?.cancel()
        let text = input
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .zero)
            guard !Task.isCancelled else { return }
            self?.translate(text)
        }
    }

    func translateNow() {
        debounceTask?.cancel()
        translate(input)
    }

    private func translate(_ text: String) {
        translationTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            output = ""
            sourceLanguage = nil
            targetLanguage = nil
            isTranslating = false
            if error != .missingKey { error = nil }
            return
        }
        let key = Defaults[.deeplAPIKey].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            error = .missingKey
            return
        }

        isTranslating = true
        let source = sourceSelection
        let fixedTarget = targetSelection
        translationTask = Task { [weak self] in
            var target: String
            if let fixedTarget {
                target = fixedTarget
            } else {
                // Auto: guess the direction locally, then fix it if DeepL detects Russian anyway
                let sourceIsRussian = source.map { $0 == "RU" } ?? Self.isLikelyRussian(trimmed)
                target = sourceIsRussian ? "EN-US" : "RU"
            }
            var result = await DeepLClient.translate(trimmed, source: source, target: target, key: key)
            if fixedTarget == nil, source == nil, target == "RU",
               case .success(let translation) = result, translation.detectedSource == "RU" {
                target = "EN-US"
                result = await DeepLClient.translate(trimmed, source: nil, target: target, key: key)
            }
            guard !Task.isCancelled, let self else { return }
            self.isTranslating = false
            switch result {
            case .success(let translation):
                self.output = translation.text
                self.sourceLanguage = translation.detectedSource
                self.targetLanguage = target
                self.error = nil
            case .failure(let error):
                self.error = error
            }
        }
    }

    private static func isLikelyRussian(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.russian, .english, .ukrainian, .german, .french, .spanish]
        recognizer.processString(text)
        return recognizer.dominantLanguage == .russian
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    // MARK: - Selection capture

    /// Copies the selection of the frontmost app via a synthetic ⌘C, restores the clipboard,
    /// and translates the captured text.
    func translateSelection() async {
        guard await XPCHelperClient.shared.isAccessibilityAuthorized() else {
            error = .noAccessibility
            return
        }

        // Let the user release the hotkey modifiers so the target app sees a clean ⌘C
        for _ in 0..<20 where !NSEvent.modifierFlags.intersection([.control, .option, .shift]).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)
        let changeCount = pasteboard.changeCount

        guard await XPCHelperClient.shared.postCopyShortcut() else {
            error = .noAccessibility
            return
        }

        for _ in 0..<20 where pasteboard.changeCount == changeCount {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard pasteboard.changeCount != changeCount else {
            error = .noSelection
            return
        }

        let text = pasteboard.string(forType: .string)
        Self.restore(saved, to: pasteboard)

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = .noSelection
            return
        }
        input = text
        translateNow()
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

// MARK: - DeepL

enum DeepLClient {
    struct Translation {
        let text: String
        let detectedSource: String
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let detected_source_language: String
            let text: String
        }
        let translations: [Item]
    }

    /// Free-plan keys end with ":fx" and must use the api-free host.
    static func isFreeKey(_ key: String) -> Bool {
        key.hasSuffix(":fx")
    }

    private static func host(for key: String) -> String {
        isFreeKey(key) ? "https://api-free.deepl.com" : "https://api.deepl.com"
    }

    /// `type` is "source" or "target". Returns nil on any failure.
    static func languages(type: String, key: String) async -> [TranslatorLanguage]? {
        struct Item: Decodable {
            let language: String
            let name: String
        }
        var request = URLRequest(url: URL(string: "\(host(for: key))/v2/languages?type=\(type)")!)
        request.timeoutInterval = 10
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return nil
        }
        return items
            .map { TranslatorLanguage(code: $0.language.uppercased(), name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    static func translate(_ text: String, source: String? = nil, target: String, key: String) async -> Result<Translation, TranslatorError> {
        var request = URLRequest(url: URL(string: "\(host(for: key))/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "text": [text],
            "target_lang": target,
        ]
        if let source {
            body["source_lang"] = source
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let item = try JSONDecoder().decode(Response.self, from: data).translations.first else {
                    return .failure(.network("empty response"))
                }
                return .success(Translation(text: item.text, detectedSource: item.detected_source_language))
            case 400:
                // e.g. same source and target language; DeepL explains it in "message"
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                return .failure(.network(message ?? "bad request"))
            case 403:
                return .failure(.invalidKey)
            case 456:
                return .failure(.quotaExceeded)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(.network("HTTP \(status)"))
            }
        } catch is CancellationError {
            return .failure(.network("cancelled"))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

// MARK: - Languages

struct TranslatorLanguage: Identifiable, Hashable {
    /// DeepL code: "DE", "EN" for sources; "EN-US", "PT-BR", "ZH-HANS" for targets.
    let code: String
    let name: String
    var id: String { code }

    /// "EN-US" → "EN"
    static func baseCode(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }

    /// DeepL needs a regional variant for some targets.
    static func targetCode(forSource code: String) -> String {
        switch code {
        case "EN": return "EN-US"
        case "PT": return "PT-BR"
        case "ZH": return "ZH-HANS"
        default: return code
        }
    }

    static func localizedName(_ code: String) -> String {
        let identifier = code.lowercased().replacingOccurrences(of: "zh-hans", with: "zh-Hans")
            .replacingOccurrences(of: "zh-hant", with: "zh-Hant")
        return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? code
    }

    private static func list(_ codes: [String]) -> [TranslatorLanguage] {
        codes.map { TranslatorLanguage(code: $0, name: localizedName($0)) }.sorted { $0.name < $1.name }
    }

    // Used until /v2/languages answers (or without a key)
    static let fallbackSources = list([
        "AR", "BG", "CS", "DA", "DE", "EL", "EN", "ES", "ET", "FI", "FR", "HU", "ID", "IT", "JA",
        "KO", "LT", "LV", "NB", "NL", "PL", "PT", "RO", "RU", "SK", "SL", "SV", "TR", "UK", "ZH",
    ])
    static let fallbackTargets = list([
        "AR", "BG", "CS", "DA", "DE", "EL", "EN-GB", "EN-US", "ES", "ET", "FI", "FR", "HU", "ID",
        "IT", "JA", "KO", "LT", "LV", "NB", "NL", "PL", "PT-BR", "PT-PT", "RO", "RU", "SK", "SL",
        "SV", "TR", "UK", "ZH-HANS", "ZH-HANT",
    ])
}
