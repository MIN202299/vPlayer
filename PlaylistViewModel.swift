import Foundation
import Combine

struct VideoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var title: String {
        url.lastPathComponent
    }
}

class PlaylistViewModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var currentSelection: VideoItem.ID? {
        didSet {
            persistHistory()
        }
    }
    
    private let historyStore = PlaybackHistoryStore.shared
    private var isRestoringHistory = false
    
    init() {
        restoreHistory()
    }
    
    func addFiles(at urls: [URL]) {
        for url in urls {
            guard VideoFormatSupport.isRecognizedVideo(url: url) else {
                print("Skipped unsupported file: \(url.lastPathComponent)")
                continue
            }
            // Security scope is handled by the player when loading, 
            // but we need to ensure we have access to read the file to add it?
            // Actually, for a playlist, we might just store the URL. 
            // The player VM will handle the security scope when it plays.
            // However, to be safe with Drag & Drop, we usually get security scoped URLs.
            let item = VideoItem(url: url)
            if !items.contains(where: { $0.url == url }) {
                items.append(item)
            }
        }
        
        // Auto-select first if empty
        if currentSelection == nil, let first = items.first {
            currentSelection = first.id
        }
        
        persistHistory()
    }
    
    func item(for id: VideoItem.ID) -> VideoItem? {
        items.first { $0.id == id }
    }
    
    func nextVideo() -> VideoItem? {
        guard let currentId = currentSelection,
              let index = items.firstIndex(where: { $0.id == currentId }),
              index + 1 < items.count else {
            return nil
        }
        return items[index + 1]
    }
    
    func previousVideo() -> VideoItem? {
        guard let currentId = currentSelection,
              let index = items.firstIndex(where: { $0.id == currentId }),
              index > 0 else {
            return nil
        }
        return items[index - 1]
    }
    
    func selectNext() {
        if let next = nextVideo() {
            currentSelection = next.id
        }
    }
    
    func selectPrevious() {
        if let prev = previousVideo() {
            currentSelection = prev.id
        }
    }
    
    func clearPlaylist() {
        items.removeAll()
        currentSelection = nil
        persistHistory()
    }
    
    var hasNext: Bool { nextVideo() != nil }
    var hasPrevious: Bool { previousVideo() != nil }
    
    private func restoreHistory() {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        
        let snapshot = historyStore.loadPlaylistEntries()
        var restoredItems: [VideoItem] = []
        
        for entry in snapshot.entries {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
                restoredItems.append(VideoItem(url: url))
            } catch {
                print("Failed to restore bookmark for \(entry.title): \(error.localizedDescription)")
            }
        }
        
        items = restoredItems
        
        if let savedPath = snapshot.lastPlayedPath,
           let match = items.first(where: { $0.url.standardizedFileURL.path == savedPath }) {
            currentSelection = match.id
        } else {
            currentSelection = items.first?.id
        }
    }
    
    private func persistHistory() {
        guard !isRestoringHistory else { return }
        let selectedURL = currentSelection.flatMap { item(for: $0)?.url }
        historyStore.savePlaylist(items: items, selectedURL: selectedURL)
    }
}
