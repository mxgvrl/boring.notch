//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import Defaults

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { ShelfPersistenceService.shared.save(items) }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?

    private init() {
        items = ShelfPersistenceService.shared.load()
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // New items go to the front; an existing duplicate moves to the front (keeping its own flags)
        for it in newItems.reversed() {
            let key = it.identityKey
            if let idx = merged.firstIndex(where: { $0.identityKey == key }) {
                if it.isTemporary && it.id != merged[idx].id { it.cleanupStoredData() }
                var existing = merged.remove(at: idx)
                if !it.fromClipboard { existing.fromClipboard = false }
                merged.insert(existing, at: 0)
            } else {
                merged.insert(it, at: 0)
            }
        }
        items = merged
        enforceClipboardLimit()
    }

    /// Moves an existing item to the front; returns false if it no longer exists.
    @discardableResult
    func moveToFront(id: ShelfItem.ID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        var result = items
        result.insert(result.remove(at: idx), at: 0)
        items = result
        return true
    }

    func enforceClipboardLimit() {
        let limit = Defaults[.clipboardHistoryLimit]
        var result = items
        var count = result.filter { $0.fromClipboard }.count
        guard count > limit else { return }
        while count > limit, let idx = result.lastIndex(where: { $0.fromClipboard }) {
            result[idx].cleanupStoredData()
            result.remove(at: idx)
            count -= 1
        }
        items = result
    }

    func clearClipboardItems() {
        for it in items where it.fromClipboard { it.cleanupStoredData() }
        items.removeAll { $0.fromClipboard }
    }

    func keepOnShelf(_ toKeep: [ShelfItem]) {
        let ids = Set(toKeep.map { $0.id })
        var result = items
        for i in result.indices where ids.contains(result[i].id) { result[i].fromClipboard = false }
        items = result
    }

    var hasNonClipboardItems: Bool { items.contains { !$0.fromClipboard } }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var keep: [ShelfItem] = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if await bookmark.validate() {
                        keep.append(item)
                    } else {
                        item.cleanupStoredData()
                    }
                default:
                    keep.append(item)
                }
            }
            await MainActor.run { self.items = keep }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
