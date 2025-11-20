import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var playlistVM = PlaylistViewModel()
    @StateObject private var playerVM = VideoPlayerViewModel()
    @State private var isImporterPresented = false
    @State private var showSidebar = false
    
    var body: some View {
        ZStack(alignment: .trailing) { // Align content to trailing for sidebar
            // Main Content Area
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let player = playerVM.player {
                    CustomVideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    Text("Drop videos here or click + to add")
                        .foregroundColor(.gray)
                }
                
                // Floating Controls
                PlayerControlsView(playerVM: playerVM, onToggleSidebar: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar.toggle()
                    }
                })
            }
            .frame(minWidth: 650, minHeight: 400) // Minimum window size larger than control panel
            
            // Sidebar Overlay
            if showSidebar {
                SidebarView(
                    playlistVM: playlistVM,
                    isImporterPresented: $isImporterPresented,
                    onClose: {
                        withAnimation {
                            showSidebar = false
                        }
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(1) // Ensure sidebar is on top
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .onChange(of: playlistVM.currentSelection) { _, newSelection in
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

extension Array where Element == NSItemProvider {
    func loadObjects<T>(ofType type: T.Type, completion: @escaping (T) -> Void) -> Bool where T : _ObjectiveCBridgeable, T._ObjectiveCType : NSItemProviderReading {
        var found = false
        for provider in self {
            if provider.canLoadObject(ofClass: T.self) {
                _ = provider.loadObject(ofClass: T.self) { object, _ in
                    if let value = object {
                        completion(value)
                    }
                }
                found = true
            }
        }
        return found
    }
}
