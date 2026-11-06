//
//  CurrencyView.swift
//  boringNotch
//
//  Currency tab: EUR / USD / PLN converter, plus its settings pane.
//

import AppKit
import Defaults
import SwiftUI

struct CurrencyView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var manager = CurrencyManager.shared
    @FocusState private var focused: CurrencyCode?
    @State private var window: NSWindow?
    @State private var copied: CurrencyCode?

    private var hasRates: Bool { manager.rates != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            HStack(spacing: 8) {
                ForEach(CurrencyCode.allCases) { code in
                    card(code)
                }
            }
            .opacity(hasRates ? 1 : 0.45)
            .disabled(!hasRates)
            bottomLine
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CurrencyWindowAccessor { resolved in
            if window !== resolved {
                window = resolved
                consumePendingFocus()
            }
        })
        .onChange(of: focused) { _, new in
            manager.focusedField = new
        }
        .onChange(of: manager.pendingFocusWindow) { _, _ in
            consumePendingFocus()
        }
        .onAppear {
            manager.refreshIfStale()
            consumePendingFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            focused = nil
            manager.focusedField = nil
            closeIfPointerLeft()
        }
        .onDisappear {
            focused = nil
            manager.focusedField = nil
            releaseKeyFocus()
        }
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack(spacing: 8) {
            Text("Currency")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.gray)
            Spacer()
            if hasRates {
                Text("ECB · \(manager.rateDateText ?? "—")")
                    .font(.system(size: 11))
                    .foregroundStyle(manager.isRateDateStale ? Color.orange : Color.gray)
                Button {
                    manager.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(manager.isFetching ? 360 : 0))
                        .animation(manager.isFetching
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default, value: manager.isFetching)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
                .disabled(manager.isFetching)
            } else {
                Text("Rates unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button("Retry") { manager.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .disabled(manager.isFetching)
            }
        }
        .frame(height: 16)
    }

    private func card(_ code: CurrencyCode) -> some View {
        let isSource = manager.source == code
        let invalid = isSource && !manager.isValid
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if manager.copyValue(for: code) {
                    copied = code
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        if copied == code { copied = nil }
                    }
                }
            } label: {
                Text(copied == code ? "Copied" : code.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)

            TextField("—", text: Binding(
                get: { manager.texts[code] ?? "" },
                set: { manager.setText($0, for: code) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .medium).monospacedDigit())
            .foregroundStyle(invalid ? Color.red : Color.white)
            .focused($focused, equals: code)
            .onExitCommand {
                focused = nil
                vm.close()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(invalid ? Color.red.opacity(0.15) : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(invalid ? Color.red : (isSource && hasRates ? Color.effectiveAccent : Color.clear), lineWidth: 1)
        )
    }

    private var bottomLine: some View {
        Group {
            if hasRates,
               let usd = manager.rate(from: .eur, to: .usd),
               let pln = manager.rate(from: .eur, to: .pln),
               let usdPln = manager.rate(from: .usd, to: .pln) {
                Text("1 EUR = \(String(format: "%.4f", usd)) USD · 1 EUR = \(String(format: "%.4f", pln)) PLN · 1 USD = \(String(format: "%.4f", usdPln)) PLN")
            } else {
                Text("No connection and no saved rates yet. Fields unlock after the first successful update.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.gray)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: Focus

    private func consumePendingFocus() {
        guard let target = manager.pendingFocusWindow, let window, window.windowNumber == target else { return }
        manager.pendingFocusWindow = nil
        focused = manager.source
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func closeIfPointerLeft() {
        guard !BoringViewCoordinator.shared.keyMovingBetweenNotches else { return }
        guard let window, !manager.keepsNotchOpen,
              !window.frame.contains(NSEvent.mouseLocation) else { return }
        vm.close()
    }

    /// The notch panel only becomes key for typing here. Hand keyboard focus back to the
    /// previously active app when the tab goes away.
    private func releaseKeyFocus() {
        guard let window else { return }
        let coordinator = BoringViewCoordinator.shared
        if coordinator.keyHandoffWindow == window.windowNumber, coordinator.isTypingTabCurrent {
            return
        }
        guard window.isKeyWindow else { return }
        window.orderOut(nil)
        window.orderFrontRegardless()
    }
}

private struct CurrencyWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Settings

struct CurrencySettings: View {
    @ObservedObject var manager = CurrencyManager.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showCurrencyTab) {
                    Text("Show Currency tab")
                }
            } footer: {
                Text("ECB via Frankfurter · updated \(manager.rateDateText ?? "never")")
            }
            Section {
                Button("Refresh now") { manager.refresh() }
                    .disabled(manager.isFetching)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Currency")
    }
}
