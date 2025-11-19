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
    @Published var currentSelection: VideoItem.ID?
    
    func addFiles(at urls: [URL]) {
        for url in urls {
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
}
