import SwiftUI
import AVKit
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var playlistVM = PlaylistViewModel()
    @StateObject private var playerVM = VideoPlayerViewModel()
    @State private var isImporterPresented = false
    @State private var showSidebar = false
    @State private var keyboardMonitor: Any?
    
    var body: some View {
        ZStack(alignment: .trailing) { // Align content to trailing for sidebar
            // Main Content Area
            ZStack {
                Color.black.ignoresSafeArea()
                
                playerSurface()
                
                // Floating Controls
                PlayerControlsView(
                    playerVM: playerVM,
                    playlistVM: playlistVM,
                    onToggleSidebar: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar.toggle()
                    }
                },
                    onTogglePlayPause: {
                        handlePlayPauseRequest()
                    }
                )
                
                if let countdown = playerVM.completionCountdown {
                    ReplayOverlayView(
                        countdown: countdown,
                        onReplay: {
                            playerVM.restartCurrentVideoFromBeginning()
                        },
                        onCancel: {
                            playerVM.cancelCompletionCountdown()
                        }
                    )
                }
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
                    },
                    onClearPlaylist: {
                        playlistVM.clearPlaylist()
                        playerVM.stopPlayback()
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
            allowedContentTypes: VideoFormatSupport.supportedContentTypes,
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
        .onAppear {
            registerKeyboardShortcuts()
        }
        .onDisappear {
            removeKeyboardShortcuts()
        }
    }
    
    @ViewBuilder
    private func playerSurface() -> some View {
        switch playerVM.activeBackend {
        case .avFoundation:
            if let player = playerVM.player {
                CustomVideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                placeholderView
            }
        case .preparing:
            statusView(message: playerVM.statusMessage ?? "正在准备播放...")
        case .idle:
            placeholderView
        }
    }
    
    private var placeholderView: some View {
        VStack(spacing: 12) {
            if let message = playerVM.statusMessage {
                Text(message)
                    .foregroundColor(.gray)
            } else {
                Text("Drop videos here or click + to add")
                    .foregroundColor(.gray)
            }
        }
    }
    
    private func statusView(message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text(message)
                .foregroundColor(.white.opacity(0.8))
        }
    }

    /// Registers a local keyDown monitor to translate key presses into playback actions.
    private func registerKeyboardShortcuts() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
    }

    /// Handles the incoming key event and maps supported keys to player actions.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        if modifiers.intersection(disallowedModifiers).isEmpty == false {
            return event
        }
        
        switch event.keyCode {
        case KeyboardKeyCode.space:
            handlePlayPauseRequest()
            return nil
        case KeyboardKeyCode.leftArrow:
            playerVM.seek(by: -10)
            return nil
        case KeyboardKeyCode.rightArrow:
            playerVM.seek(by: 10)
            return nil
        default:
            return event
        }
    }

    /// Responds to play or pause requests, ensuring a video is ready or prompting file import.
    private func handlePlayPauseRequest() {
        if playerVM.activeBackend == .idle {
            if loadSelectedVideoIfAvailable() {
                return
            }
            if let firstItem = playlistVM.items.first {
                playlistVM.currentSelection = firstItem.id
                return
            }
            isImporterPresented = true
            return
        }
        playerVM.togglePlayPause()
    }
    
    /// Loads the currently selected playlist item when available.
    private func loadSelectedVideoIfAvailable() -> Bool {
        guard
            let selection = playlistVM.currentSelection,
            let item = playlistVM.item(for: selection)
        else {
            return false
        }
        playerVM.loadVideo(from: item.url)
        return true
    }
    
    /// Removes the previously registered keyboard monitor to avoid leaks.
    private func removeKeyboardShortcuts() {
        guard let monitor = keyboardMonitor else { return }
        NSEvent.removeMonitor(monitor)
        keyboardMonitor = nil
    }
}

private enum KeyboardKeyCode {
    static let space: UInt16 = 49
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
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
