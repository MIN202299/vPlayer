import SwiftUI

struct ReplayOverlayView: View {
    let countdown: Int
    let onReplay: () -> Void
    let onCancel: () -> Void
    
    // Assuming a default total duration for the countdown circle visual
    private let totalDuration: Double = 3.0
    
    var body: some View {
        ZStack {
            // Dark background overlay
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                ZStack {
                    // Background Track
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 4)
                        .frame(width: 80, height: 80)
                    
                    // Progress Circle (Countdown style: Full -> Empty)
                    Circle()
                        .trim(from: 0, to: CGFloat(countdown) / CGFloat(totalDuration))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 80, height: 80)
                        .animation(.linear(duration: 1), value: countdown)
                    
                    // Replay Button (Center)
                    Button(action: onReplay) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                
                VStack(spacing: 8) {
                    Text("即将重新播放")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("\(countdown)")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(24)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

