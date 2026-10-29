//
//  AIChatView.swift
//  boringNotch
//
//  Ask AI tab shown in the open notch, plus its settings pane.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct AIChatView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var manager = AIChatManager.shared
    @FocusState private var inputFocused: Bool
    @State private var window: NSWindow?
    @State private var didCopy = false
    @State private var menuDepth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            conversation
            inputField
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AIChatWindowAccessor { resolved in
            if window !== resolved { window = resolved }
        })
        .onChange(of: inputFocused) { _, focused in
            manager.isInputFocused = focused
        }
        .onChange(of: manager.focusRequest) { _, _ in
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            inputFocused = false
            manager.isInputFocused = false
            closeIfPointerLeft()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuDepth += 1
            manager.isMenuOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuDepth = max(0, menuDepth - 1)
            guard menuDepth == 0 else { return }
            manager.isMenuOpen = false
            closeIfPointerLeft()
        }
        .onAppear {
            // Opened via hotkey before the view existed: the request already fired.
            if manager.focusRequest > 0 { inputFocused = true }
        }
        .onDisappear {
            manager.isInputFocused = false
            manager.isMenuOpen = false
            menuDepth = 0
            releaseKeyFocus()
        }
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Menu("History") {
                if manager.recentChats.isEmpty {
                    Text("No chats yet")
                } else {
                    ForEach(manager.recentChats) { chat in
                        Button(chat.title) { manager.load(chat) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("New chat") { manager.newChat() }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))

            Button {
                if manager.copyForClaude() {
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        didCopy = false
                    }
                }
            } label: {
                Text(didCopy ? "Copied" : "Copy for Claude")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(manager.messages.isEmpty)

            if manager.isSearching {
                ProgressView().controlSize(.mini)
                Text("searching…")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            Spacer()
            if manager.isStreaming {
                Button {
                    manager.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
        }
        .foregroundStyle(.white)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if manager.messages.isEmpty && manager.streamingText.isEmpty && manager.error == nil {
                        Text("Ask a quick question")
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                    ForEach(manager.messages) { message in
                        bubble(message.text, isUser: message.role == "user")
                            .id(message.id)
                    }
                    if !manager.streamingText.isEmpty {
                        bubble(manager.streamingText, isUser: false)
                            .id("streaming")
                    }
                    if let error = manager.error {
                        errorView(error).id("error")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: manager.streamingText) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: manager.messages.count) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: manager.error) { _, _ in proxy.scrollTo("bottom") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 30) }
            Text(text)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(isUser ? 0.14 : 0.07))
                )
            if !isUser { Spacer(minLength: 30) }
        }
    }

    private var inputField: some View {
        TextField("Ask anything…", text: $manager.input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .lineLimit(1...3)
            .focused($inputFocused)
            .onSubmit { manager.send() }
            .onExitCommand {
                inputFocused = false
                vm.close()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(inputFocused ? 0.12 : 0.07))
            )
            .contentShape(Rectangle())
            .onTapGesture { inputFocused = true }
    }

    @ViewBuilder
    private func errorView(_ error: AIChatError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            switch error {
            case .missingKey, .unauthorized:
                Button("Open Settings") {
                    SettingsWindowController.shared.showWindow()
                }
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    private func closeIfPointerLeft() {
        guard let window, !manager.keepsNotchOpen,
              !window.frame.contains(NSEvent.mouseLocation) else { return }
        vm.close()
    }

    /// The notch panel only becomes key for typing here. Hand keyboard focus back to the
    /// previously active app when the tab goes away.
    private func releaseKeyFocus() {
        guard let window, window.isKeyWindow else { return }
        window.orderOut(nil)
        window.orderFrontRegardless()
    }
}

private struct AIChatWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Settings

struct AIChatSettings: View {
    @Default(.anthropicAPIKey) private var apiKey

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showAIChatTab) {
                    Text("Show Ask AI tab")
                }
            }

            Section {
                SecureField("API key", text: $apiKey)
                Defaults.Toggle(key: .aiChatWebSearch) {
                    Text("Allow web search")
                }
            } header: {
                Text("Anthropic")
            } footer: {
                Link("Get an API key at console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/")!)
                    .font(.caption)
            }

            Section {
                KeyboardShortcuts.Recorder("Open Ask AI:", name: .openAIChat)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Chats are saved as text under Application Support/AIChat and deleted after 30 days.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Ask AI")
    }
}
