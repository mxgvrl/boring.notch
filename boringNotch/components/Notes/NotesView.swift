//
//  NotesView.swift
//  boringNotch
//
//  Notes tab: a single plain-text quick note, plus its settings pane.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
final class NotesManager: ObservableObject {
    static let shared = NotesManager()

    @Published var text = "" {
        didSet {
            guard text != oldValue, !isLoading else { return }
            if !text.isEmpty { clearedText = nil }
            scheduleSave()
        }
    }
    @Published var isEditorFocused = false
    /// Text removed by Clear, kept in memory only so Undo can bring it back.
    @Published private(set) var clearedText: String?

    var keepsNotchOpen: Bool { isEditorFocused }

    private var isLoading = false
    private var saveTask: Task<Void, Never>?

    private init() {
        isLoading = true
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
        isLoading = false
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NotesManager.shared.flush() }
        }
    }

    private static var fileURL: URL {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (support ?? fm.temporaryDirectory).appendingPathComponent("Notes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("note.txt")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the note now, cancelling any pending debounced save.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        guard !text.isEmpty else { return }
        let previous = text
        text = ""
        clearedText = previous
        flush()
    }

    func undoClear() {
        guard let previous = clearedText, text.isEmpty else { return }
        text = previous
        clearedText = nil
        flush()
    }

    @discardableResult
    func copyAll() -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardWatcher.shared.markOwnWrite()
        return true
    }
}

struct NotesView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var manager = NotesManager.shared
    @FocusState private var editorFocused: Bool
    @State private var window: NSWindow?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            editor
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotesWindowAccessor { resolved in
            if window !== resolved { window = resolved }
        })
        .onChange(of: editorFocused) { _, focused in
            manager.isEditorFocused = focused
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            editorFocused = false
            manager.isEditorFocused = false
            closeIfPointerLeft()
        }
        .onDisappear {
            editorFocused = false
            manager.isEditorFocused = false
            manager.flush()
            releaseKeyFocus()
        }
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.gray)
            Spacer()
            Button {
                if manager.copyAll() {
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        didCopy = false
                    }
                }
            } label: {
                Text(didCopy ? "Copied" : "Copy")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(manager.text.isEmpty)

            if manager.text.isEmpty, manager.clearedText != nil {
                Button {
                    manager.undoClear()
                } label: {
                    Text("Undo")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    manager.clear()
                } label: {
                    Text("Clear")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(manager.text.isEmpty)
            }
        }
        .foregroundStyle(.white)
    }

    private var editor: some View {
        TextEditor(text: $manager.text)
            .scrollContentBackground(.hidden)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .focused($editorFocused)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
            .overlay(alignment: .topLeading) {
                if manager.text.isEmpty {
                    Text("Quick note…")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray.opacity(0.6))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
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

private struct NotesWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Settings

struct NotesSettings: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showNotesTab) {
                    Text("Show Notes tab")
                }
            } footer: {
                Text("The note is saved to Application Support/Notes/note.txt as you type.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notes")
    }
}
