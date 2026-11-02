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
        tabs.filter { tab in
            switch tab.view {
            case .home: return true
            case .shelf: return boringShelf
            case .translator: return showTranslatorTab
            case .aiChat: return showAIChatTab
            case .notes: return showNotesTab
            }
        }
    }

    private var isAvailable: Bool {
        ((!tvm.isEmpty || coordinator.alwaysShowTabs) && boringShelf)
            || (boringShelf && shelfClipboardHistory)
            || showTranslatorTab || showAIChatTab || showNotesTab
    }

    var body: some View {
        if isAvailable {
        VStack(spacing: 2) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(width: 32, height: 24)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
