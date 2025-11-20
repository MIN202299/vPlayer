#if canImport(VLCKit)
import SwiftUI
import VLCKit

struct VLCKitPlayerView: NSViewRepresentable {
    let mediaPlayer: VLCMediaPlayer
    
    func makeNSView(context: Context) -> VLCVideoView {
        let view = VLCVideoView()
        view.translatesAutoresizingMaskIntoConstraints = false
        mediaPlayer.drawable = view
        return view
    }
    
    func updateNSView(_ nsView: VLCVideoView, context: Context) {
        mediaPlayer.drawable = nsView
    }
}
#endif

