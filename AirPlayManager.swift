import Foundation
import AVKit
import SwiftUI

/// Coordinates AirPlay state for the unified `AVPlayer` instance.
final class AirPlayManager: ObservableObject {
    static let shared = AirPlayManager()
    
    @Published private(set) var isExternalPlaybackActive = false
    
    private var observation: NSKeyValueObservation?
    
    private init() {}
    
    /// Attaches the manager to a player to observe external playback changes.
    func attach(to player: AVPlayer?) {
        observation?.invalidate()
        
        guard let player else {
            isExternalPlaybackActive = false
            return
        }
        
        player.allowsExternalPlayback = true
        observation = player.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
                self?.isExternalPlaybackActive = observedPlayer.isExternalPlaybackActive
            }
        }
    }
}

/// SwiftUI wrapper around `AVRoutePickerView`.
struct AirPlayRoutePickerView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }
    
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}


