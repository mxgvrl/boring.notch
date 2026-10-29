//
//  TranslatorView.swift
//  boringNotch
//
//  Translator tab shown in the open notch, plus its settings pane.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct TranslatorView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var translator = TranslatorManager.shared
    @FocusState private var inputFocused: Bool
    @State private var window: NSWindow?
    @State private var didCopy = false
    @State private var menuDepth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LanguageMenu(kind: .source)
                Button {
                    translator.swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSwap ? .white : .gray.opacity(0.5))
                .disabled(!canSwap)
                .help("Swap languages")
                LanguageMenu(kind: .target)
                if translator.isTranslating {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                if let shortcut = KeyboardShortcuts.getShortcut(for: .translateSelection) {
                    Text("Selection: \(shortcut.description)")
                        .font(.caption2)
                        .foregroundStyle(.gray.opacity(0.7))
                }
            }

            HStack(alignment: .top, spacing: 10) {
                inputColumn
                outputColumn
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { resolved in
            if window !== resolved { window = resolved }
        })
        .onChange(of: inputFocused) { _, focused in
            translator.isInputFocused = focused
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            inputFocused = false
            translator.isInputFocused = false
            closeIfPointerLeft()
        }
        // Language menus pop up outside the notch, which counts as hover-out; hold the notch open
        // while any menu (or submenu) is tracking.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuDepth += 1
            translator.isMenuOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuDepth = max(0, menuDepth - 1)
            guard menuDepth == 0 else { return }
            translator.isMenuOpen = false
            closeIfPointerLeft()
        }
        .onAppear {
            translator.loadLanguagesIfNeeded()
        }
        .onDisappear {
            translator.isInputFocused = false
            translator.isMenuOpen = false
            menuDepth = 0
            releaseKeyFocus()
        }
    }

    private var canSwap: Bool {
        (translator.sourceSelection ?? translator.sourceLanguage) != nil
            && (translator.targetSelection ?? translator.targetLanguage) != nil
    }

    /// Hover-out is ignored while typing or picking a language; close once that ends off-notch.
    private func closeIfPointerLeft() {
        guard let window, !translator.keepsNotchOpen,
              !window.frame.contains(NSEvent.mouseLocation) else { return }
        vm.close()
    }

    private var inputColumn: some View {
        ZStack(alignment: .topTrailing) {
            TextField("Type to translate…", text: $translator.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { translator.translateNow() }
                .onExitCommand {
                    inputFocused = false
                    vm.close()
                }
                .padding(8)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !translator.input.isEmpty {
                Button {
                    translator.input = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(inputFocused ? 0.12 : 0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
    }

    private var outputColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                Group {
                    if let error = translator.error {
                        errorView(error)
                    } else if translator.output.isEmpty {
                        Text("Translation")
                            .foregroundStyle(.gray.opacity(0.6))
                    } else {
                        Text(translator.output)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                .padding(.bottom, 18)
            }

            if !translator.output.isEmpty && translator.error == nil {
                Button {
                    translator.copyOutput()
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func errorView(_ error: TranslatorError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            switch error {
            case .missingKey, .invalidKey:
                Button("Open Settings") {
                    SettingsWindowController.shared.showWindow()
                }
                .controlSize(.small)
            case .noAccessibility:
                Button("Grant Access") {
                    XPCHelperClient.shared.requestAccessibilityAuthorization()
                }
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    /// The notch panel only becomes key for typing here. Hand keyboard focus back to the
    /// previously active app when the tab goes away, otherwise keystrokes go to a hidden field.
    private func releaseKeyFocus() {
        guard let window, window.isKeyWindow else { return }
        window.orderOut(nil)
        window.orderFrontRegardless()
    }
}

private struct LanguageMenu: View {
    enum Kind {
        case source, target
    }

    let kind: Kind
    @ObservedObject var translator = TranslatorManager.shared
    @Default(.translatorStarredLanguages) private var starredCodes

    private var languages: [TranslatorLanguage] {
        kind == .source ? translator.sourceLanguages : translator.targetLanguages
    }

    private var selection: String? {
        kind == .source ? translator.sourceSelection : translator.targetSelection
    }

    private var binding: Binding<String?> {
        Binding(
            get: { selection },
            set: { code in
                kind == .source ? translator.setSource(code) : translator.setTarget(code)
            }
        )
    }

    private var label: String {
        if let selection {
            return translator.name(for: selection)
        }
        let resolved = kind == .source ? translator.sourceLanguage : translator.targetLanguage
        let auto = kind == .source ? "Detect" : "Auto"
        return resolved.map { "\(auto) · \(translator.name(for: $0))" } ?? auto
    }

    var body: some View {
        // Same rule as TranslatorManager.isStarred, read from @Default so stars update live
        let starredBase = Set(starredCodes.map(TranslatorLanguage.baseCode))
        let starred = languages.filter { starredCodes.contains($0.code) || starredBase.contains($0.code) }

        Menu {
            Picker("", selection: binding) {
                Text(kind == .source ? "Detect Language" : "Auto (Russian ↔ English)")
                    .tag(String?.none)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if !starred.isEmpty {
                Section("Starred") {
                    Picker("", selection: binding) {
                        ForEach(starred) { language in
                            Text(language.name).tag(Optional(language.code))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Menu("All Languages") {
                Picker("", selection: binding) {
                    ForEach(languages) { language in
                        Text(language.name).tag(Optional(language.code))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if let selection {
                Divider()
                let name = translator.name(for: selection)
                if translator.isStarred(selection) {
                    Button("Remove \(name) from Starred", systemImage: "star.slash") {
                        translator.toggleStar(selection)
                    }
                } else {
                    Button("Add \(name) to Starred", systemImage: "star") {
                        translator.toggleStar(selection)
                    }
                }
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Settings

struct TranslatorSettings: View {
    @Default(.deeplAPIKey) private var apiKey
    @Default(.translatorStarredLanguages) private var starredCodes
    @ObservedObject private var translator = TranslatorManager.shared
    @State private var accessibilityGranted = false
    @State private var keyCheck: KeyCheck = .idle

    private enum KeyCheck: Equatable {
        case idle
        case checking
        case ok(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showTranslatorTab) {
                    Text("Show Translator tab")
                }
            }

            Section {
                SecureField("API key", text: $apiKey)
                    .onChange(of: apiKey) { keyCheck = .idle }
                HStack {
                    Text(planDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch keyCheck {
                    case .idle:
                        EmptyView()
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .ok(let sample):
                        Label(sample, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    Button("Check Key") { checkKey() }
                        .disabled(apiKey.isEmpty || keyCheck == .checking)
                }
            } header: {
                Text("DeepL")
            } footer: {
                Link("Get a free API key at deepl.com/pro-api",
                     destination: URL(string: "https://www.deepl.com/pro-api")!)
                    .font(.caption)
            }

            Section {
                ForEach(translator.targetLanguages) { language in
                    let isStarred = starredCodes.contains(language.code)
                    Button {
                        if isStarred {
                            starredCodes.removeAll { $0 == language.code }
                        } else {
                            starredCodes.append(language.code)
                        }
                    } label: {
                        HStack {
                            Text(language.name)
                            Spacer()
                            Image(systemName: isStarred ? "star.fill" : "star")
                                .foregroundStyle(isStarred ? .yellow : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Starred languages")
            } footer: {
                Text("Starred languages are listed first in the notch language menus.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                KeyboardShortcuts.Recorder("Translate selection:", name: .translateSelection)
                HStack {
                    Text("Accessibility access")
                    Spacer()
                    if accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            XPCHelperClient.shared.requestAccessibilityAuthorization()
                        }
                    }
                }
            } header: {
                Text("Selected text")
            } footer: {
                Text("The shortcut copies the current selection with ⌘C, restores your clipboard and opens the translation in the notch. Text is translated to Russian, Russian text to English.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Translator")
        .task {
            translator.loadLanguagesIfNeeded()
            accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { note in
            accessibilityGranted = (note.userInfo?["granted"] as? Bool) ?? false
        }
    }

    private var planDescription: String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "No key" }
        return DeepLClient.isFreeKey(key) ? "DeepL API Free" : "DeepL API Pro"
    }

    private func checkKey() {
        keyCheck = .checking
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch await DeepLClient.translate("Hello", target: "RU", key: key) {
            case .success(let translation):
                keyCheck = .ok("Hello → \(translation.text)")
            case .failure(let error):
                keyCheck = .failed(error.message)
            }
        }
    }
}
