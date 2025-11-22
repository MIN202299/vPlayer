import Foundation
import AVFoundation

/// Handles remuxing sources that AVPlayer cannot load directly.
final class RemuxCoordinator {
    enum RemuxError: LocalizedError {
        case presetUnavailable
        case exportFailed(String)
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .presetUnavailable:
                return "当前视频无法使用系统封装器处理。"
            case .exportFailed(let message):
                return "重封装失败：\(message)"
            case .cancelled:
                return "重封装已取消。"
            }
        }
    }
    
    /// Represents a cancellable remux operation.
    final class Task {
        private let lock = NSLock()
        private var cancelled = false
        private var exportSession: AVAssetExportSession?
        
        /// Indicates whether the task has been cancelled.
        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
        
        /// Attaches the export session so cancelling the task cancels the export as well.
        func attach(_ session: AVAssetExportSession) {
            lock.lock()
            exportSession = session
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel {
                session.cancelExport()
            }
        }
        
        /// Cancels any in-flight export work.
        func cancel() {
            lock.lock()
            cancelled = true
            let session = exportSession
            lock.unlock()
            session?.cancelExport()
        }
    }
    
    private let queue = DispatchQueue(label: "io.vplayer.remux", qos: .userInitiated)
    private let cacheDirectory: URL
    private let fileManager: FileManager
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = fileManager.temporaryDirectory.appendingPathComponent("vplayer-remux-cache", isDirectory: true)
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        cacheDirectory = root
    }
    
    /// Starts a remux task and returns an HTTP stream handle when finished.
    @discardableResult
    func prepareStream(
        for request: RemuxRequest,
        completion: @escaping (Result<LocalHTTPStreamHandle, Error>) -> Void
    ) -> Task {
        let task = Task()
        queue.async { [weak self] in
            guard let self else { return }
            if task.isCancelled {
                completion(.failure(RemuxError.cancelled))
                return
            }
            
            let outputURL = self.cacheDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            do {
                if self.fileManager.fileExists(atPath: outputURL.path) {
                    try self.fileManager.removeItem(at: outputURL)
                }
                
                let asset = AVURLAsset(url: request.sourceURL)
                if #unavailable(macOS 13.0) {
                    let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
                    guard presets.contains(AVAssetExportPresetPassthrough) else {
                        completion(.failure(RemuxError.presetUnavailable))
                        return
                    }
                }
                
                guard let exportSession = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetPassthrough
                ) else {
                    completion(.failure(RemuxError.exportFailed("无法创建导出会话")))
                    return
                }
                
                exportSession.outputURL = outputURL
                exportSession.outputFileType = request.targetFileType
                exportSession.shouldOptimizeForNetworkUse = true
                task.attach(exportSession)
                
                exportSession.exportAsynchronously { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        if task.isCancelled {
                            completion(.failure(RemuxError.cancelled))
                            try? self.fileManager.removeItem(at: outputURL)
                            return
                        }
                        
                        switch exportSession.status {
                        case .completed:
                            do {
                                let handle = try LocalHTTPServer.shared.registerFile(at: outputURL)
                                completion(.success(handle))
                            } catch {
                                completion(.failure(error))
                                try? self.fileManager.removeItem(at: outputURL)
                            }
                        case .failed, .cancelled:
                            let description = exportSession.error?.localizedDescription ?? "未知错误"
                            completion(.failure(RemuxError.exportFailed(description)))
                            try? self.fileManager.removeItem(at: outputURL)
                        default:
                            break
                        }
                    }
                }
            } catch {
                completion(.failure(error))
                try? self.fileManager.removeItem(at: outputURL)
            }
        }
        return task
    }
}


