import Foundation
import AVKit
import Combine

class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPaused: Bool = false
    @Published var progress: Double = 0.0
    @Published var timeString: String = "00:00"
    
    var isSeeking = false
    private var currentUrl: URL?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Initialize with a default configuration if needed
    }
    
    deinit {
        cleanUp()
    }
    
    func loadVideo(from url: URL) {
        cleanUp()
        
        // Start accessing the new security-scoped URL
        let gotAccess = url.startAccessingSecurityScopedResource()
        if !gotAccess {
            print("Permission denied to access security scoped resource.")
            return
        }
        
        self.currentUrl = url
        
        let playerItem = AVPlayerItem(url: url)
        if let player = self.player {
            player.replaceCurrentItem(with: playerItem)
        } else {
            self.player = AVPlayer(playerItem: playerItem)
        }
        
        setupPlayerObservers()
        
        // Enable AirPlay
        self.player?.allowsExternalPlayback = true
        // usesExternalPlaybackWhileExternalScreenIsActive is not available on macOS
        // self.player?.usesExternalPlaybackWhileExternalScreenIsActive = true
        
        // Auto play
        self.player?.play()
        self.isPaused = false
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPaused = true
        } else {
            player.play()
            isPaused = false
        }
    }
    
    private func setupPlayerObservers() {
        guard let player = player else { return }
        
        // Observe time for progress slider
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            guard let item = player.currentItem else { return }
            
            let duration = item.duration.seconds
            guard duration.isFinite && duration > 0 else { return }
            
            self.progress = time.seconds / duration
            self.timeString = self.formatTime(seconds: time.seconds)
        }
        
        // Observe seeking
        $progress
            .dropFirst()
            .sink { [weak self] value in
                guard let self = self, self.isSeeking else { return }
                guard let item = self.player?.currentItem else { return }
                let duration = item.duration.seconds
                let targetTime = value * duration
                self.player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600))
                self.timeString = self.formatTime(seconds: targetTime)
            }
            .store(in: &cancellables)
    }
    
    private func cleanUp() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let url = currentUrl {
            url.stopAccessingSecurityScopedResource()
            currentUrl = nil
        }
    }
    
    private func formatTime(seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
