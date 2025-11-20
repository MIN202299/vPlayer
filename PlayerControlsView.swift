import SwiftUI
import AVKit

struct PlayerControlsView: View {
    @ObservedObject var playerVM: VideoPlayerViewModel
    var onToggleSidebar: () -> Void
    
    @State private var showControls = false
    @State private var lastHoverDate = Date()
    @State private var isInteracting = false
    
    // Timer to check for inactivity
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    // Panel width constant
    private let panelWidth: CGFloat = 600
    
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
                    playerVM.togglePlayPause()
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
                            .tint(.white)
                            .accentColor(.white)
                            
                            Text(playerVM.durationString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        // Controls Row
                        HStack(spacing: 40) {
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
                                .accentColor(.white)
                            }
                            
                            Spacer()
                            
                            // Playback Controls (Center)
                            HStack(spacing: 24) {
                                Button(action: { playerVM.seek(by: -10) }) {
                                    Image(systemName: "gobackward.10")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playerVM.togglePlayPause() }) {
                                    Image(systemName: playerVM.isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 32))
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
                            }
                            
                            Spacer()
                            
                            // Right Side Controls (Playlist)
                            HStack {
                                Spacer()
                                Button(action: onToggleSidebar) {
                                    Image(systemName: "sidebar.right")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white.opacity(0.8))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(width: 110)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(width: panelWidth)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 40)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
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
