import Foundation
import AVKit
import Combine
#if canImport(VLCKit)
import VLCKit
#endif

enum PlaybackBackendType: Equatable {
    case idle
    case avFoundation
    case vlc
}

final class VideoPlayerViewModel: NSObject, ObservableObject {
    @Published var player: AVPlayer?
#if canImport(VLCKit)
    @Published var vlcMediaPlayer: VLCMediaPlayer?
#endif
    @Published var activeBackend: PlaybackBackendType = .idle
    @Published var isPaused: Bool = true
    @Published var progress: Double = 0.0
    @Published var timeString: String = "00:00"
    @Published var duration: Double = 0.0
    @Published var durationString: String = "00:00"
    @Published var completionCountdown: Int?
    @Published var volume: Float = 0.5 {
        didSet {
            applyVolume()
        }
    }
    
    var isSeeking = false
    
    private let historyStore = PlaybackHistoryStore.shared
    private var currentUrl: URL?
    private var timeObserver: Any?
    private var playerItemStatusObserver: NSKeyValueObservation?
    private var playerFailedObserver: NSObjectProtocol?
    private var playerDidPlayToEndObserver: NSObjectProtocol?
    private var seekRequestCancellable: AnyCancellable?
    private var triedVLCKit = false
    private var pendingResumeTime: Double?
    private var lastPersistedPlaybackTime: Double = 0
    private var completionTimer: Timer?
    private var shouldRestartFromBeginning = false
    
    override init() {
        super.init()
        observeSeekRequests()
    }
    
    deinit {
        cleanUp()
    }
    
    func loadVideo(from url: URL) {
        cleanUp()
        resetTracking()
        
        guard url.startAccessingSecurityScopedResource() else {
            print("Permission denied to access security scoped resource.")
            return
        }
        
        currentUrl = url
        triedVLCKit = false
        pendingResumeTime = historyStore.resumeTimeIfAvailable(for: url)
        lastPersistedPlaybackTime = pendingResumeTime ?? 0
        
#if canImport(VLCKit)
        if VideoFormatSupport.prefersAVFoundation(for: url) {
            activateAVFoundation(with: url)
        } else {
            activateVLCKitIfAvailable(with: url, reason: "Preferred backend")
        }
#else
        activateAVFoundation(with: url)
#endif
    }
    
    func togglePlayPause() {
        cancelCompletionCountdown()
        if shouldRestartFromBeginning {
            restartCurrentVideoFromBeginning()
            return
        }
        
        switch activeBackend {
        case .avFoundation:
            guard let player = player else { return }
            if player.timeControlStatus == .playing {
                player.pause()
                isPaused = true
            } else {
                player.play()
                isPaused = false
            }
        case .vlc:
#if canImport(VLCKit)
            guard let vlc = vlcMediaPlayer else { return }
            if vlc.isPlaying {
                vlc.pause()
                isPaused = true
            } else {
                vlc.play()
                isPaused = false
            }
#endif
        case .idle:
            break
        }
    }
    
    /// Stops any current playback session and resets the player state.
    func stopPlayback() {
        cleanUp()
    }
    
    func seek(by seconds: Double) {
        switch activeBackend {
        case .avFoundation:
            guard let player = player, let item = player.currentItem else { return }
            let currentTime = player.currentTime().seconds
            let duration = item.duration.seconds
            
            var newTime = currentTime + seconds
            let maxDuration = duration.isFinite && duration > 0 ? duration : currentTime
            newTime = max(0, min(newTime, maxDuration))
            
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        case .vlc:
#if canImport(VLCKit)
            guard let vlc = vlcMediaPlayer else { return }
            let currentSeconds = (vlc.time as VLCTime?)?.seconds ?? 0
            let newSeconds = max(0, currentSeconds + seconds)
            vlc.time = VLCTime.fromSeconds(newSeconds)
#endif
        case .idle:
            break
        }
    }
    
    private func observeSeekRequests() {
        seekRequestCancellable = $progress
            .dropFirst()
            .sink { [weak self] value in
                self?.handleSeekRequest(for: value)
            }
    }
    
    private func handleSeekRequest(for value: Double) {
        guard isSeeking, duration > 0 else { return }
        switch activeBackend {
        case .avFoundation:
            guard let player = player else { return }
            let targetTime = value * duration
            player.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600))
            timeString = formatTime(seconds: targetTime)
        case .vlc:
#if canImport(VLCKit)
            guard let vlc = vlcMediaPlayer else { return }
            let targetSeconds = value * duration
            vlc.time = VLCTime.fromSeconds(targetSeconds)
            timeString = formatTime(seconds: targetSeconds)
#endif
        case .idle:
            break
        }
    }
    
    private func activateAVFoundation(with url: URL) {
        let item = AVPlayerItem(url: url)
        if let player = player {
            player.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            self.player = player
        }
        
        activeBackend = .avFoundation
        setupPlayerObservers(with: item)
        
        player?.volume = volume
        player?.play()
        isPaused = false
    }
    
    private func setupPlayerObservers(with item: AVPlayerItem) {
        guard let player = player else { return }
        removeAVPlayerObservers()
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            let duration = item.duration.seconds
            guard duration.isFinite && duration > 0 else { return }
            
            self.duration = duration
            self.durationString = self.formatTime(seconds: duration)
            self.progress = time.seconds / duration
            self.timeString = self.formatTime(seconds: time.seconds)
            self.persistPlaybackTimeIfNeeded(time.seconds)
        }
        
        playerItemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            switch item.status {
            case .failed:
                self.handleAVFailure(error: item.error)
            case .readyToPlay:
                self.applyPendingResumeForAVPlayer()
            default:
                break
            }
        }
        
        playerFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.handleAVFailure(error: error)
        }
        
        playerDidPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackCompletion()
        }
    }
    
    private func handleAVFailure(error: Error?) {
        guard activeBackend == .avFoundation else { return }
        if let error = error {
            print("AVPlayer failed: \(error.localizedDescription)")
        }
        activateVLCKitIfAvailable(reason: "AVFoundation failure")
    }
    
    private func resetTracking() {
        duration = 0
        durationString = formatTime(seconds: 0)
        timeString = formatTime(seconds: 0)
        progress = 0
        pendingResumeTime = nil
        shouldRestartFromBeginning = false
        completionCountdown = nil
    }
    
    private func applyVolume() {
        player?.volume = volume
#if canImport(VLCKit)
        if let vlc = vlcMediaPlayer {
            let clamped = max(0, min(1, volume))
            let scaled = Int32(round(clamped * 100))
            vlc.audio?.volume = scaled
        }
#endif
    }
    
    private func removeAVPlayerObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        if let failedObserver = playerFailedObserver {
            NotificationCenter.default.removeObserver(failedObserver)
            playerFailedObserver = nil
        }
        if let endObserver = playerDidPlayToEndObserver {
            NotificationCenter.default.removeObserver(endObserver)
            playerDidPlayToEndObserver = nil
        }
    }
    
    private func cleanUp() {
        removeAVPlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
#if canImport(VLCKit)
        vlcMediaPlayer?.stop()
        vlcMediaPlayer?.delegate = nil
        vlcMediaPlayer = nil
#endif
        if let url = currentUrl {
            url.stopAccessingSecurityScopedResource()
            currentUrl = nil
        }
        cancelCompletionCountdown()
        activeBackend = .idle
        isPaused = true
        resetTracking()
    }
    
    private func formatTime(seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
#if canImport(VLCKit)
    private func activateVLCKitIfAvailable(with url: URL? = nil, reason: String) {
        guard let playbackUrl = url ?? currentUrl else { return }
        if triedVLCKit {
            print("VLCKit already attempted. Reason: \(reason)")
            return
        }
        triedVLCKit = true
        
        removeAVPlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        
        let mediaPlayer = VLCMediaPlayer()
        mediaPlayer.delegate = self
        mediaPlayer.media = VLCMedia(url: playbackUrl)
        
        vlcMediaPlayer = mediaPlayer
        activeBackend = .vlc
        mediaPlayer.play()
        applyVolume()
        isPaused = false
    }
#else
    private func activateVLCKitIfAvailable(with url: URL? = nil, reason: String) {
        print("VLCKit is not available. Reason: \(reason)")
    }
#endif
}

#if canImport(VLCKit)
extension VideoPlayerViewModel: VLCMediaPlayerDelegate {
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard activeBackend == .vlc, let vlc = vlcMediaPlayer, !isSeeking else { return }
        let currentSeconds = (vlc.time as VLCTime?)?.seconds ?? 0
        timeString = formatTime(seconds: currentSeconds)
        
        let mediaDuration = vlc.media.flatMap { media -> Double? in
            let length: VLCTime? = media.length
            return length?.seconds
        } ?? 0
        if mediaDuration > 0 {
            duration = mediaDuration
            durationString = formatTime(seconds: mediaDuration)
            progress = currentSeconds / mediaDuration
            persistPlaybackTimeIfNeeded(currentSeconds)
        }
    }
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard activeBackend == .vlc, let vlc = vlcMediaPlayer else { return }
        switch vlc.state {
        case .paused, .stopped:
            isPaused = true
        case .playing:
            isPaused = false
            applyPendingResumeForVLCKit()
        case .ended:
            handlePlaybackCompletion()
        default:
            break
        }
    }
}

private extension VLCTime {
    var seconds: Double {
        Double(intValue) / 1000.0
    }
    
    static func fromSeconds(_ seconds: Double) -> VLCTime {
        VLCTime(number: NSNumber(value: seconds * 1000.0))
    }
}
#endif

extension VideoPlayerViewModel {
    func persistPlaybackTimeIfNeeded(_ time: Double) {
        guard let url = currentUrl else { return }
        guard abs(time - lastPersistedPlaybackTime) >= 1 else { return }
        lastPersistedPlaybackTime = time
        historyStore.updatePlaybackPosition(url: url, time: time)
    }
    
    /// Responds to backend completion events and starts the replay countdown.
    private func handlePlaybackCompletion() {
        guard currentUrl != nil else { return }
        shouldRestartFromBeginning = true
        isPaused = true
        progress = 1
        timeString = durationString
        startCompletionCountdown()
    }
    
    /// Starts the countdown timer that informs the user before replaying the video.
    private func startCompletionCountdown() {
        cancelCompletionCountdown()
        completionCountdown = 3
        
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            
            guard let remaining = self.completionCountdown else {
                timer.invalidate()
                return
            }
            
            if remaining <= 1 {
                timer.invalidate()
                self.completionCountdown = nil
                self.restartCurrentVideoFromBeginning()
            } else {
                self.completionCountdown = remaining - 1
            }
        }
        
        completionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    /// Stops the countdown timer and hides the countdown overlay.
    func cancelCompletionCountdown() {
        completionTimer?.invalidate()
        completionTimer = nil
        completionCountdown = nil
    }
    
    /// Seeks to the start of the current media and resumes playback.
    func restartCurrentVideoFromBeginning() {
        guard let url = currentUrl else { return }
        shouldRestartFromBeginning = false
        completionCountdown = nil
        lastPersistedPlaybackTime = 0
        historyStore.updatePlaybackPosition(url: url, time: 0)
        
        switch activeBackend {
        case .avFoundation:
            guard let player = player else { return }
            player.seek(to: .zero) { [weak self] _ in
                guard let self else { return }
                player.play()
                self.progress = 0
                self.timeString = self.formatTime(seconds: 0)
                self.isPaused = false
            }
        case .vlc:
#if canImport(VLCKit)
            guard let vlc = vlcMediaPlayer else { return }
            vlc.time = VLCTime.fromSeconds(0)
            vlc.play()
            progress = 0
            timeString = formatTime(seconds: 0)
            isPaused = false
#else
            break
#endif
        case .idle:
            break
        }
    }
    
    func applyPendingResumeForAVPlayer() {
        guard let pending = pendingResumeTime, let player = player else { return }
        pendingResumeTime = nil
        player.seek(to: CMTime(seconds: pending, preferredTimescale: 600))
    }
    
#if canImport(VLCKit)
    func applyPendingResumeForVLCKit() {
        guard let pending = pendingResumeTime, let vlc = vlcMediaPlayer else { return }
        pendingResumeTime = nil
        vlc.time = VLCTime.fromSeconds(pending)
    }
#else
    func applyPendingResumeForVLCKit() {}
#endif
}
