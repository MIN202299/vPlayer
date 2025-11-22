import Foundation
import AVKit
import Combine

enum PlaybackBackendType: Equatable {
    case idle
    case preparing
    case avFoundation
}

final class VideoPlayerViewModel: NSObject, ObservableObject {
    @Published var player: AVPlayer?
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
    @Published var statusMessage: String?
    
    var isSeeking = false
    
    private let historyStore = PlaybackHistoryStore.shared
    private let playbackPlanner = PlaybackPlanner()
    private let processingCoordinator = ProcessingCoordinator()
    private var currentUrl: URL?
    private var timeObserver: Any?
    private var playerItemStatusObserver: NSKeyValueObservation?
    private var playerFailedObserver: NSObjectProtocol?
    private var playerDidPlayToEndObserver: NSObjectProtocol?
    private var seekRequestCancellable: AnyCancellable?
    private var processingTask: ProcessingTask?
    private var activeStreamHandle: LocalHTTPStreamHandle?
    private var activeArtifactCleanup: (() -> Void)?
    private var currentPlan: PlaybackPlan?
    private var hasAttemptedProcessingFallback = false
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
    
    /// Loads the provided media URL using the best available plan.
    func loadVideo(from url: URL) {
        cleanUp()
        resetTracking()
        
        guard url.startAccessingSecurityScopedResource() else {
            print("Permission denied to access security scoped resource.")
            return
        }
        
        currentUrl = url
        pendingResumeTime = historyStore.resumeTimeIfAvailable(for: url)
        lastPersistedPlaybackTime = pendingResumeTime ?? 0
        hasAttemptedProcessingFallback = false
        statusMessage = nil
        
        let plan = playbackPlanner.plan(for: url)
        execute(plan: plan)
    }
    
    private func execute(plan: PlaybackPlan) {
        currentPlan = plan
        switch plan {
        case .direct(let directURL):
            activateAVFoundation(with: directURL)
        case .remux(let request):
            prepareRemux(for: request)
        case .transcode(let request):
            prepareTranscode(for: request)
        }
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
        case .preparing, .idle:
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
        case .preparing, .idle:
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
        case .preparing, .idle:
            break
        }
    }
    
    private func activateAVFoundation(with url: URL) {
        let item = AVPlayerItem(url: url)
        if let player = player {
            player.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            self.player = player
        }
        
        activeBackend = .avFoundation
        setupPlayerObservers(with: item)
        AirPlayManager.shared.attach(to: player)
        
        player?.volume = volume
        player?.play()
        isPaused = false
        statusMessage = nil
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
        guard let url = currentUrl else { return }
        if let error {
            print("AVPlayer failed: \(error.localizedDescription)")
        }
        
        if hasAttemptedProcessingFallback {
            statusMessage = error?.localizedDescription ?? "无法播放该视频。"
            activeBackend = .idle
            isPaused = true
            return
        }
        
        hasAttemptedProcessingFallback = true
        let fallbackPlan = playbackPlanner.forcedTranscodePlan(for: url)
        execute(plan: fallbackPlan)
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
    
    /// Starts a remux pipeline and swaps in the resulting local HTTP stream.
    private func prepareRemux(for request: RemuxRequest) {
        startProcessing(
            for: request.sourceURL,
            status: "正在重封装以适配 AirPlay...",
            launcher: { completion in
                self.processingCoordinator.prepareStream(for: request, completion: completion)
            }
        )
    }
    
    private func prepareTranscode(for request: TranscodeRequest) {
        startProcessing(
            for: request.sourceURL,
            status: "正在转码以适配 AirPlay...",
            launcher: { completion in
                self.processingCoordinator.prepareStream(for: request, completion: completion)
            }
        )
    }
    
    private func startProcessing(
        for sourceURL: URL,
        status message: String,
        launcher: (@escaping (Result<ProcessingArtifact, Error>) -> Void) -> ProcessingTask
    ) {
        processingTask?.cancel()
        statusMessage = message
        activeBackend = .preparing
        processingTask = launcher { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.currentUrl == sourceURL else {
                    if case .success(let artifact) = result {
                        artifact.cleanup()
                    }
                    return
                }
                self.processingTask = nil
                switch result {
                case .success(let artifact):
                    do {
                        let handle = try self.registerHTTPHandle(for: artifact)
                        self.installStreamHandle(handle, artifactCleanup: artifact.cleanup)
                    } catch {
                        artifact.cleanup()
                        self.statusMessage = error.localizedDescription
                        self.activeBackend = .idle
                        self.isPaused = true
                    }
                case .failure(let error):
                    self.statusMessage = error.localizedDescription
                    self.activeBackend = .idle
                    self.isPaused = true
                }
            }
        }
    }
    
    /// Tracks the currently active HTTP stream so it can be torn down when no longer needed.
    private func installStreamHandle(_ handle: LocalHTTPStreamHandle, artifactCleanup: @escaping () -> Void) {
        activeStreamHandle?.cleanup()
        activeArtifactCleanup?()
        activeStreamHandle = handle
        activeArtifactCleanup = artifactCleanup
        activateAVFoundation(with: handle.url)
    }
    
    private func registerHTTPHandle(for artifact: ProcessingArtifact) throws -> LocalHTTPStreamHandle {
        switch artifact.kind {
        case .file(let url):
            return try LocalHTTPServer.shared.registerFile(at: url)
        case .hls(let directory, let playlist):
            return try LocalHTTPServer.shared.registerHLSDirectory(at: directory, playlistFilename: playlist)
        }
    }
    
    private func applyVolume() {
        player?.volume = volume
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
        processingTask?.cancel()
        processingTask = nil
        activeStreamHandle?.cleanup()
        activeStreamHandle = nil
        activeArtifactCleanup?()
        activeArtifactCleanup = nil
        if let url = currentUrl {
            url.stopAccessingSecurityScopedResource()
            currentUrl = nil
        }
        cancelCompletionCountdown()
        activeBackend = .idle
        isPaused = true
        statusMessage = nil
        resetTracking()
    }
    
    private func formatTime(seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
}

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
        case .preparing, .idle:
            break
        }
    }
    
    func applyPendingResumeForAVPlayer() {
        guard let pending = pendingResumeTime, let player = player else { return }
        pendingResumeTime = nil
        player.seek(to: CMTime(seconds: pending, preferredTimescale: 600))
    }
}
