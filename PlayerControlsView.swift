import SwiftUI
import AVKit

struct PlayerControlsView: View {
    @ObservedObject var playerVM: VideoPlayerViewModel
    @State private var isHovering = false
    
    var body: some View {
        VStack {
            Spacer()
            
            if isHovering || playerVM.isPaused {
                HStack(spacing: 20) {
                    Button(action: {
                        playerVM.togglePlayPause()
                    }) {
                        Image(systemName: playerVM.isPaused ? "play.fill" : "pause.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    
                    Slider(value: $playerVM.progress, in: 0...1, onEditingChanged: { editing in
                        playerVM.isSeeking = editing
                    })
                    .accentColor(.white)
                    
                    Text(playerVM.timeString)
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation {
                isHovering = hovering
            }
        }
    }
}
