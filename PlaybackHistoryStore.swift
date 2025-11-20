import Foundation

struct PlaylistHistoryEntry: Codable {
    let bookmark: Data
    let title: String
    let path: String
}

struct PlaybackHistorySnapshot: Codable {
    var entries: [PlaylistHistoryEntry]
    var lastPlayedPath: String?
    var lastPlaybackSeconds: Double?
    
    static var empty: PlaybackHistorySnapshot {
        PlaybackHistorySnapshot(entries: [], lastPlayedPath: nil, lastPlaybackSeconds: nil)
    }
}

final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()
    
    private let queue = DispatchQueue(label: "io.vplayer.playbackHistory", qos: .utility)
    private let fileURL: URL
    private var snapshot: PlaybackHistorySnapshot
    
    private init() {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("vPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        snapshot = (try? PlaybackHistoryStore.loadSnapshot(from: fileURL)) ?? .empty
    }
    
    func loadPlaylistEntries() -> PlaybackHistorySnapshot {
        queue.sync { snapshot }
    }
    
    func savePlaylist(items: [VideoItem], selectedURL: URL?) {
        queue.async { [weak self] in
            guard let self else { return }
            var entries: [PlaylistHistoryEntry] = []
            for item in items {
                guard let bookmark = try? item.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                    continue
                }
                entries.append(PlaylistHistoryEntry(bookmark: bookmark, title: item.title, path: item.url.standardizedFileURL.path))
            }
            self.snapshot.entries = entries
            self.snapshot.lastPlayedPath = selectedURL?.standardizedFileURL.path
            self.persistSnapshot()
        }
    }
    
    func updatePlaybackPosition(url: URL, time: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.snapshot.lastPlayedPath = url.standardizedFileURL.path
            self.snapshot.lastPlaybackSeconds = time
            self.persistSnapshot()
        }
    }
    
    func resumeTimeIfAvailable(for url: URL) -> Double? {
        queue.sync {
            guard snapshot.lastPlayedPath == url.standardizedFileURL.path else { return nil }
            return snapshot.lastPlaybackSeconds
        }
    }
    
    private func persistSnapshot() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to persist playback history: \(error.localizedDescription)")
        }
    }
    
    private static func loadSnapshot(from url: URL) throws -> PlaybackHistorySnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PlaybackHistorySnapshot.self, from: data)
    }
}

