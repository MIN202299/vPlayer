import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var playlistVM = PlaylistViewModel()
    @StateObject private var playerVM = VideoPlayerViewModel()
    @State private var isImporterPresented = false
    
    var body: some View {
        NavigationSplitView {
            List(playlistVM.items, selection: $playlistVM.currentSelection) { item in
                Text(item.title)
                    .tag(item.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isImporterPresented = true }) {
                        Label("Add Video", systemImage: "plus")
                    }
                }
            }
        } detail: {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let player = playerVM.player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    Text("Drop videos here or click + to add")
                        .foregroundColor(.gray)
                }
                
                PlayerControlsView(playerVM: playerVM)
            }
        }
        .onChange(of: playlistVM.currentSelection) { newSelection in
            if let id = newSelection, let item = playlistVM.item(for: id) {
                playerVM.loadVideo(from: item.url)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                playlistVM.addFiles(at: urls)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.loadObjects(ofType: URL.self) { url in
                DispatchQueue.main.async {
                    playlistVM.addFiles(at: [url])
                }
            }
            return true
        }
    }
}

// Helper for Drag & Drop
extension NSItemProvider {
    func loadObjects<T>(ofType type: T.Type, completion: @escaping (T) -> Void) -> Bool where T : _ObjectiveCBridgeable, T._ObjectiveCType : NSItemProviderReading {
        if canLoadObject(ofClass: T.self) {
            loadObject(ofClass: T.self) { object, _ in
                if let value = object as? T {
                    completion(value)
                }
            }
            return true
        }
        return false
    }
}
