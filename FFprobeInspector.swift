import Foundation

/// Represents a parsed media stream produced by ffprobe.
struct MediaStreamInfo {
    let codecType: String
    let codecName: String
    let profile: String?
    let width: Int?
    let height: Int?
    let channels: Int?
    let sampleRate: Int?
    let bitrate: Int?
    let index: Int?
}

/// Basic media profile built from ffprobe output.
struct MediaProfile {
    let url: URL
    let containerFormat: String?
    let videoStream: MediaStreamInfo?
    let audioStreams: [MediaStreamInfo]
}

/// Invokes ffprobe to inspect media metadata for planning playback strategy.
final class FFprobeInspector {
    private let configuration = FFmpegConfiguration.shared
    
    func profile(for url: URL) throws -> MediaProfile {
        let binaries = try configuration.binaries()
        let process = Process()
        process.executableURL = binaries.ffprobeURL
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            url.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "io.vplayer.ffprobe", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffprobe 无法解析该媒体。"
            ])
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(FFprobeResult.self, from: data)
        let streams = result.streams.map { $0.toMediaStreamInfo() }.compactMap { $0 }
        let video = streams.first(where: { $0.codecType == "video" })
        let audio = streams.filter { $0.codecType == "audio" }
        
        return MediaProfile(
            url: url,
            containerFormat: result.format?.formatName,
            videoStream: video,
            audioStreams: audio
        )
    }
}

// MARK: - ffprobe DTOs

private struct FFprobeResult: Decodable {
    let streams: [FFprobeStream]
    let format: FFprobeFormat?
}

private struct FFprobeStream: Decodable {
    let index: Int?
    let codecType: String?
    let codecName: String?
    let profile: String?
    let width: Int?
    let height: Int?
    let channels: Int?
    let sampleRate: String?
    let bitRate: String?
}

private struct FFprobeFormat: Decodable {
    let formatName: String?
}

private extension FFprobeStream {
    func toMediaStreamInfo() -> MediaStreamInfo? {
        guard let codecType, let codecName else { return nil }
        return MediaStreamInfo(
            codecType: codecType,
            codecName: codecName,
            profile: profile,
            width: width,
            height: height,
            channels: channels,
            sampleRate: sampleRate.flatMap { Int($0) },
            bitrate: bitRate.flatMap { Int($0) },
            index: index
        )
    }
}


