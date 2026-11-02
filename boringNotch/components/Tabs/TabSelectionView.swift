//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Translator", icon: "character.bubble.fill", view: .translator),
    TabModel(label: "Ask AI", icon: "sparkles", view: .aiChat),
    TabModel(label: "Notes", icon: "note.text", view: .notes)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var tvm = ShelfStateViewModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.shelfClipboardHistory) var shelfClipboardHistory
    @Default(.showTranslatorTab) var showTranslatorTab
    @Default(.showAIChatTab) var showAIChatTab
    @Default(.showNotesTab) var showNotesTab
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        TabColumnAvailability.visibleTabs(
            boringShelf: boringShelf, translator: showTranslatorTab,
            aiChat: showAIChatTab, notes: showNotesTab)
    }

    private var isAvailable: Bool {
        TabColumnAvailability.isAvailable(
            tabsNonEmpty: !tvm.isEmpty, alwaysShowTabs: coordinator.alwaysShowTabs,
            boringShelf: boringShelf, clipboardHistory: shelfClipboardHistory,
            translator: showTranslatorTab, aiChat: showAIChatTab, notes: showNotesTab)
    }

    static let buttonHeight: CGFloat = 22
    static let minGap: CGFloat = 2
    static let columnWidth: CGFloat = 32
    private let minSpreadCount = 4

    private func gap(count n: Int, height h: CGFloat) -> CGFloat {
        let b = Self.buttonHeight
        let m = max(n, minSpreadCount)
        return max(Self.minGap, (h - CGFloat(m) * b) / CGFloat(m - 1))
    }

    private func button(_ tab: TabModel) -> some View {
        TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
            coordinator.keyHandoffWindow = nil
            withAnimation(.smooth) {
                coordinator.currentView = tab.view
            }
        }
        .frame(width: Self.columnWidth, height: Self.buttonHeight)
        .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
        .background {
            if tab.view == coordinator.currentView {
                Capsule()
                    .fill(Color(nsColor: .secondarySystemFill))
                    .matchedGeometryEffect(id: "capsule", in: animation)
            } else {
                Capsule()
                    .fill(Color.clear)
                    .matchedGeometryEffect(id: "capsule", in: animation)
                    .hidden()
            }
        }
    }

    var body: some View {
        if isAvailable {
            GeometryReader { geo in
                let list = visibleTabs
                let n = list.count
                let needed = CGFloat(n) * Self.buttonHeight + CGFloat(max(0, n - 1)) * Self.minGap
                if needed > geo.size.height {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: Self.minGap) {
                            ForEach(list) { button($0) }
                        }
                    }
                } else {
                    VStack(spacing: gap(count: n, height: geo.size.height)) {
                        ForEach(list) { button($0) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: Self.columnWidth)
        }
    }
}

enum TabColumnAvailability {
    static func isAvailable(
        tabsNonEmpty: Bool, alwaysShowTabs: Bool, boringShelf: Bool, clipboardHistory: Bool,
        translator: Bool, aiChat: Bool, notes: Bool
    ) -> Bool {
        ((tabsNonEmpty || alwaysShowTabs) && boringShelf)
            || (boringShelf && clipboardHistory)
            || translator || aiChat || notes
    }

    static func visibleTabs(boringShelf: Bool, translator: Bool, aiChat: Bool, notes: Bool) -> [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home: return true
            case .shelf: return boringShelf
            case .translator: return translator
            case .aiChat: return aiChat
            case .notes: return notes
            }
        }
    }

    static func currentVisibleTabs() -> [TabModel] {
        visibleTabs(
            boringShelf: Defaults[.boringShelf], translator: Defaults[.showTranslatorTab],
            aiChat: Defaults[.showAIChatTab], notes: Defaults[.showNotesTab])
    }

    @MainActor
    static func isCurrentlyAvailable() -> Bool {
        isAvailable(
            tabsNonEmpty: !ShelfStateViewModel.shared.isEmpty,
            alwaysShowTabs: BoringViewCoordinator.shared.alwaysShowTabs,
            boringShelf: Defaults[.boringShelf], clipboardHistory: Defaults[.shelfClipboardHistory],
            translator: Defaults[.showTranslatorTab], aiChat: Defaults[.showAIChatTab],
            notes: Defaults[.showNotesTab])
    }
}

/// Reserves the column's width (+ gap) in the content row while the overlay column is visible.
struct TabColumnSpacer: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var tvm = ShelfStateViewModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.shelfClipboardHistory) var shelfClipboardHistory
    @Default(.showTranslatorTab) var showTranslatorTab
    @Default(.showAIChatTab) var showAIChatTab
    @Default(.showNotesTab) var showNotesTab

    var body: some View {
        let on = TabColumnAvailability.isAvailable(
            tabsNonEmpty: !tvm.isEmpty, alwaysShowTabs: coordinator.alwaysShowTabs,
            boringShelf: boringShelf, clipboardHistory: shelfClipboardHistory,
            translator: showTranslatorTab, aiChat: showAIChatTab, notes: showNotesTab)
        Color.clear.frame(width: on ? TabSelectionView.columnWidth + 8 : 0, height: 0)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
