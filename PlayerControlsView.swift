import SwiftUI
import AVKit

struct PlayerControlsView: View {
    @ObservedObject var playerVM: VideoPlayerViewModel
    @ObservedObject var playlistVM: PlaylistViewModel
    var onToggleSidebar: () -> Void
    var onTogglePlayPause: () -> Void
    
    @State private var showControls = false
    @State private var lastHoverDate = Date()
    @State private var isInteracting = false
    
    // Timer to check for inactivity
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    // Panel width constant
    private let panelWidth: CGFloat = 640
    
    var body: some View {
        ZStack {
            // Invisible view to catch hover and clicks
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(_):
                        lastHoverDate = Date()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls = true
                        }
                        NSCursor.unhide()
                    case .ended:
                        break
                    }
                }
                .onTapGesture {
                    onTogglePlayPause()
                }
            
            VStack {
                Spacer()
                
                if showControls || playerVM.isPaused || isInteracting {
                    VStack(spacing: 16) {
                        // Progress Bar
                        HStack(spacing: 12) {
                            Text(playerVM.timeString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                            
                            Slider(value: $playerVM.progress, in: 0...1, onEditingChanged: { editing in
                                playerVM.isSeeking = editing
                                isInteracting = editing
                                if editing {
                                    lastHoverDate = Date()
                                }
                            })
                            .tint(Color(red: 1.0, green: 0.576, blue: 0.0))
                            .accentColor(Color(red: 1.0, green: 0.576, blue: 0.0))
                            
                            Text(playerVM.durationString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        // Controls Row
                        ZStack {
                            // Playback Controls (Center)
                            HStack(spacing: 20) {
                                Button(action: { playlistVM.selectPrevious() }) {
                                    Image(systemName: "backward.end.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(playlistVM.hasPrevious ? .white : .white.opacity(0.3))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!playlistVM.hasPrevious)

                                Button(action: { playerVM.seek(by: -10) }) {
                                    Image(systemName: "gobackward.10")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { onTogglePlayPause() }) {
                                    Image(systemName: playerVM.isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 32))
                                        .frame(width: 44, height: 44)
                                        .foregroundColor(.white)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playerVM.seek(by: 10) }) {
                                    Image(systemName: "goforward.10")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playlistVM.selectNext() }) {
                                    Image(systemName: "forward.end.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(playlistVM.hasNext ? .white : .white.opacity(0.3))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!playlistVM.hasNext)
                            }
                            
                            // Side Controls
                            HStack {
                                // Volume (Left)
                                HStack(spacing: 8) {
                                    Image(systemName: playerVM.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .foregroundColor(.white.opacity(0.8))
                                        .onTapGesture {
                                            playerVM.volume = playerVM.volume > 0 ? 0 : 1.0
                                        }
                                    
                                    Slider(value: $playerVM.volume, in: 0...1, onEditingChanged: { editing in
                                        isInteracting = editing
                                        if editing {
                                            lastHoverDate = Date()
                                        }
                                    })
                                    .frame(width: 80)
                                    .tint(Color(red: 1.0, green: 0.576, blue: 0.0))
                                    .accentColor(Color(red: 1.0, green: 0.576, blue: 0.0))
                                }
                                
                                Spacer()
                                
                                // Right Side Controls (Playlist)
                                Button(action: onToggleSidebar) {
                                    Image(systemName: "sidebar.right")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white.opacity(0.8))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(width: panelWidth)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(.ultraThinMaterial.opacity(0.7))
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color.white.opacity(0.05))
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.5),
                                        Color.white.opacity(0.2),
                                        Color.white.opacity(0.05)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Prevent clicks on the panel from toggling play/pause on the background
                    .onTapGesture { }
                    .onHover { hovering in
                        if hovering {
                            lastHoverDate = Date()
                            isInteracting = true
                        } else {
                            isInteracting = false
                        }
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            if !playerVM.isPaused && !isInteracting && Date().timeIntervalSince(lastHoverDate) > 3.0 {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showControls = false
                }
            }
        }
    }
}
