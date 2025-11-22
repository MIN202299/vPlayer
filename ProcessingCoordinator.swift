import Foundation

/// Encapsulates a cancellable ffmpeg job.
final class ProcessingTask {
    private let queue = DispatchQueue(label: "io.vplayer.processingtask")
    private var cancelHandler: (() -> Void)?
    private var isCancelled = false
    
    func setCancelHandler(_ handler: @escaping () -> Void) {
        var shouldCancelImmediately = false
        queue.sync {
            cancelHandler = handler
            shouldCancelImmediately = isCancelled
        }
        if shouldCancelImmediately {
            handler()
        }
    }
    
    func cancel() {
        var handler: (() -> Void)?
        queue.sync {
            guard !isCancelled else {
                handler = nil
                return
            }
            isCancelled = true
            handler = cancelHandler
        }
        handler?()
    }
    
    var cancelled: Bool {
        queue.sync {
            isCancelled
        }
    }
}

enum ProcessingCoordinatorError: LocalizedError {
    case ffmpegUnavailable(String)
    case processFailed(code: Int32, message: String)
    case outputMissing
    
    var errorDescription: String? {
        switch self {
        case .ffmpegUnavailable(let message):
            return message
        case .processFailed(_, let message):
            return "ffmpeg 执行失败：\(message)"
        case .outputMissing:
            return "处理完成但输出缺失。"
        }
    }
}

/// Responsible for launching ffmpeg-based remux/transcode jobs and exposing them via the local HTTP server.
final class ProcessingCoordinator {
    private let queue = DispatchQueue(label: "io.vplayer.processingcoordinator", qos: .userInitiated)
    private let fileManager = FileManager.default
    private let configuration = FFmpegConfiguration.shared
    
    private lazy var workingDirectory: URL = {
        let url = fileManager.temporaryDirectory.appendingPathComponent("vplayer-processing", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }()
    
    func prepareStream(
        for request: RemuxRequest,
        completion: @escaping (Result<ProcessingArtifact, Error>) -> Void
    ) -> ProcessingTask {
        var arguments: [String] = [
            "-hide_banner",
            "-loglevel", "warning",
            "-y",
            "-i", request.sourceURL.path
        ]
        
        if let videoIndex = request.videoStreamIndex {
            arguments.append(contentsOf: ["-map", "0:\(videoIndex)"])
        } else {
            arguments.append(contentsOf: ["-map", "0:v:0"])
        }
        
        if let audioIndex = request.audioStreamIndex {
            arguments.append(contentsOf: ["-map", "0:\(audioIndex)"])
        } else {
            arguments.append(contentsOf: ["-map", "0:a:0?"])
        }
        
        arguments.append(contentsOf: [
            "-c:v", "copy",
            "-c:a", "copy",
            "-movflags", "faststart"
        ])
        
        if request.videoCodecName?.lowercased() == "hevc" {
            arguments.append(contentsOf: ["-tag:v", "hvc1"])
        }
        
        return startFFmpegJob(arguments: arguments, mode: .file(extension: "mp4"), completion: completion)
    }
    
    func prepareStream(
        for request: TranscodeRequest,
        completion: @escaping (Result<ProcessingArtifact, Error>) -> Void
    ) -> ProcessingTask {
        var arguments: [String] = [
            "-hide_banner",
            "-loglevel", "info",
            "-y",
            "-i", request.sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?"
        ]
        
        if request.useHardwareAcceleration {
            arguments.insert(contentsOf: ["-hwaccel", "videotoolbox"], at: 4)
        }
        
        arguments.append(contentsOf: [
            "-c:v", request.videoCodec.ffmpegFlag,
            "-b:v", request.videoBitrate,
            "-maxrate", request.videoBitrate,
            "-bufsize", request.videoBufferSize,
            "-pix_fmt", "yuv420p"
        ])
        
        if request.videoCodec == .hevc {
            arguments.append(contentsOf: ["-tag:v", "hvc1"])
        }
        
        if let filter = request.videoFilter {
            arguments.append(contentsOf: ["-vf", filter])
        }
        
        arguments.append(contentsOf: [
            "-c:a", request.audioCodec.ffmpegFlag,
            "-b:a", request.audioBitrate
        ])
        
        switch request.output {
        case .progressiveMP4:
            arguments.append(contentsOf: ["-movflags", "faststart"])
            return startFFmpegJob(
                arguments: arguments,
                mode: .file(extension: request.container.fileExtension),
                completion: completion
            )
        case .hls:
            return startFFmpegJob(
                arguments: arguments,
                mode: .hls(playlistFilename: "master.m3u8", segmentDuration: 4),
                completion: completion
            )
        }
    }
    
    // MARK: - Private
    
    private func startFFmpegJob(
        arguments baseArguments: [String],
        mode: OutputMode,
        completion: @escaping (Result<ProcessingArtifact, Error>) -> Void
    ) -> ProcessingTask {
        let task = ProcessingTask()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let binaries = try self.configuration.binaries()
                let sessionURL = self.makeSessionDirectory()
                let configuration = mode.configuration(for: sessionURL, baseArguments: baseArguments)
                let finalArguments = configuration.arguments
                let artifact = self.makeArtifact(for: configuration.artifactKind, sessionURL: sessionURL)
                
                var didComplete = false
                func finish(_ result: Result<ProcessingArtifact, Error>) {
                    guard !didComplete else { return }
                    didComplete = true
                    completion(result)
                }
                
                let process = Process()
                process.executableURL = binaries.ffmpegURL
                process.arguments = finalArguments
                
                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = Pipe()
                
                var logBuffer = Data()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        logBuffer.append(data)
                        if let text = String(data: data, encoding: .utf8) {
                            print("[ffmpeg] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    }
                }
                
                task.setCancelHandler {
                    process.terminate()
                }
                
                try process.run()
                
                switch configuration.artifactKind {
                case .file:
                    process.waitUntilExit()
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    
                    guard process.terminationStatus == 0 else {
                        let message = String(data: logBuffer, encoding: .utf8) ?? "未知错误"
                        try? self.fileManager.removeItem(at: sessionURL)
                        finish(.failure(ProcessingCoordinatorError.processFailed(code: process.terminationStatus, message: message)))
                        return
                    }
                    
                    guard self.validateOutputs(for: configuration.artifactKind) else {
                        try? self.fileManager.removeItem(at: sessionURL)
                        finish(.failure(ProcessingCoordinatorError.outputMissing))
                        return
                    }
                    
                    finish(.success(artifact))
                    
                case .hls:
                    guard let playlistURL = configuration.readinessURL,
                          self.waitForHLSReadiness(at: playlistURL, task: task) else {
                        process.terminate()
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        try? self.fileManager.removeItem(at: sessionURL)
                        finish(.failure(ProcessingCoordinatorError.outputMissing))
                        return
                    }
                    
                    finish(.success(artifact))
                    
                    process.waitUntilExit()
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    
                    guard process.terminationStatus == 0 else {
                        let message = String(data: logBuffer, encoding: .utf8) ?? "未知错误"
                        if !didComplete {
                            try? self.fileManager.removeItem(at: sessionURL)
                            finish(.failure(ProcessingCoordinatorError.processFailed(code: process.terminationStatus, message: message)))
                        }
                        return
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
        return task
    }
    
    private func validateOutputs(for kind: ProcessingArtifact.Kind) -> Bool {
        switch kind {
        case .file(let url):
            return fileManager.fileExists(atPath: url.path)
        case .hls(let directory, let playlist):
            let playlistURL = directory.appendingPathComponent(playlist)
            return fileManager.fileExists(atPath: playlistURL.path)
        }
    }
    
    private func makeSessionDirectory() -> URL {
        let sessionURL = workingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        return sessionURL
    }
    
    private func makeArtifact(for kind: ProcessingArtifact.Kind, sessionURL: URL) -> ProcessingArtifact {
        var cleaned = false
        return ProcessingArtifact(
            kind: kind,
            cleanup: { [weak self] in
                guard let self else { return }
                if cleaned {
                    return
                }
                cleaned = true
                try? self.fileManager.removeItem(at: sessionURL)
            }
        )
    }
    
    private func waitForHLSReadiness(at playlistURL: URL, task: ProcessingTask, timeout: TimeInterval = 8, pollInterval: TimeInterval = 0.2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if task.cancelled {
                return false
            }
            if let contents = try? String(contentsOf: playlistURL), contents.contains("#EXTINF") {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }
}

private enum OutputMode {
    case file(extension: String)
    case hls(playlistFilename: String, segmentDuration: Int)
    
    func configuration(for sessionURL: URL, baseArguments: [String]) -> OutputConfiguration {
        switch self {
        case .file(let ext):
            let outputURL = sessionURL.appendingPathComponent("output.\(ext)")
            var finalArgs = baseArguments
            finalArgs.append(outputURL.path)
            return OutputConfiguration(
                arguments: finalArgs,
                artifactKind: .file(url: outputURL),
                readinessURL: nil
            )
        case .hls(let playlist, let duration):
            let playlistURL = sessionURL.appendingPathComponent(playlist)
            let segmentTemplate = sessionURL.appendingPathComponent("segment_%05d.ts").path
            var finalArgs = baseArguments
            finalArgs.append(contentsOf: [
                "-f", "hls",
                "-hls_time", "\(duration)",
                "-hls_playlist_type", "event",
                "-hls_flags", "independent_segments+append_list",
                "-hls_segment_filename", segmentTemplate,
                playlistURL.path
            ])
            return OutputConfiguration(
                arguments: finalArgs,
                artifactKind: .hls(directory: sessionURL, playlistFilename: playlist),
                readinessURL: playlistURL
            )
        }
    }
}

private struct OutputConfiguration {
    let arguments: [String]
    let artifactKind: ProcessingArtifact.Kind
    let readinessURL: URL?
}
