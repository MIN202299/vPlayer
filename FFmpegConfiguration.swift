import Foundation

/// Paths to the ffmpeg/ffprobe binaries that power the local processing pipeline.
struct FFmpegBinaryPaths {
    let ffmpegURL: URL
    let ffprobeURL: URL
}

enum FFmpegConfigurationError: LocalizedError {
    case binaryNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "\(name) 未找到。请在系统中安装 ffmpeg/ffprobe 或配置 VPLAYER_FFMPEG_PATH、VPLAYER_FFPROBE_PATH 环境变量。"
        }
    }
}

/// Resolves ffmpeg/ffprobe paths once and shares them across the app.
final class FFmpegConfiguration {
    static let shared = FFmpegConfiguration()
    
    private var cachedPaths: FFmpegBinaryPaths?
    private let lock = NSLock()
    private let fileManager = FileManager.default
    
    private init() {}
    
    /// Returns existing binary paths or attempts to locate them.
    func binaries() throws -> FFmpegBinaryPaths {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPaths {
            return cachedPaths
        }
        let resolved = try resolveBinaries()
        cachedPaths = resolved
        return resolved
    }
    
    private func resolveBinaries() throws -> FFmpegBinaryPaths {
        let ffmpeg = try resolveBinary(
            name: "ffmpeg",
            envKeys: ["VPLAYER_FFMPEG_PATH", "FFMPEG_PATH"],
            bundledRelativePath: "ThirdParty/ffmpeg/bin/ffmpeg"
        )
        let ffprobe = try resolveBinary(
            name: "ffprobe",
            envKeys: ["VPLAYER_FFPROBE_PATH", "FFPROBE_PATH"],
            bundledRelativePath: "ThirdParty/ffmpeg/bin/ffprobe"
        )
        return FFmpegBinaryPaths(ffmpegURL: ffmpeg, ffprobeURL: ffprobe)
    }
    
    private func resolveBinary(name: String, envKeys: [String], bundledRelativePath: String) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let path = env[key], fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent(bundledRelativePath).path,
           fileManager.isExecutableFile(atPath: bundlePath) {
            return URL(fileURLWithPath: bundlePath)
        }
        
        let searchPaths = [
            fileManager.currentDirectoryPath + "/\(bundledRelativePath)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        
        for path in searchPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        
        throw FFmpegConfigurationError.binaryNotFound(name)
    }
}


