import Foundation
import AVFoundation

/// Represents the next action required to make a media URL playable by `AVPlayer`.
enum PlaybackPlan: Equatable {
    case direct(URL)
    case remux(RemuxRequest)
    case transcode(TranscodeRequest)
}

/// Describes the information needed to remux a media file into an `AVPlayer` friendly container.
struct RemuxRequest: Equatable {
    let sourceURL: URL
    let targetFileType: AVFileType
    let videoStreamIndex: Int?
    let audioStreamIndex: Int?
    let videoCodecName: String?
}

/// Describes a hardware accelerated transcode request.
struct TranscodeRequest: Equatable {
    let sourceURL: URL
    let videoCodec: VideoCodecTarget
    let audioCodec: AudioCodecTarget
    let container: TranscodeContainer
    let videoBitrate: String
    let videoBufferSize: String
    let audioBitrate: String
    let videoFilter: String?
    let useHardwareAcceleration: Bool
    let output: TranscodeOutputFormat
}

enum VideoCodecTarget: String {
    case h264
    case hevc
    
    var ffmpegFlag: String {
        switch self {
        case .h264:
            return "h264_videotoolbox"
        case .hevc:
            return "hevc_videotoolbox"
        }
    }
}

enum AudioCodecTarget: String {
    case aac
    case ac3
    
    var ffmpegFlag: String {
        switch self {
        case .aac:
            return "aac"
        case .ac3:
            return "ac3"
        }
    }
}

enum TranscodeContainer {
    case mp4
    
    var fileExtension: String {
        "mp4"
    }
}

enum TranscodeOutputFormat: Equatable {
    case progressiveMP4
    case hls
}

/// Inspects incoming media and decides whether it can be played directly, remuxed, or needs full transcode.
final class PlaybackPlanner {
    private let inspector = FFprobeInspector()
    private let avPlayerVideoCodecs: Set<String> = ["h264", "avc1", "hev1", "hevc"]
    private let avPlayerAudioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3"]
    private let directContainerFormats: Set<String> = [
        "mov", "mp4", "m4a", "m4v", "ismv", "isom", "dash", "quicktime"
    ]
    
    /// Builds a playback plan for the provided file URL.
    func plan(for url: URL) -> PlaybackPlan {
        do {
            let profile = try inspector.profile(for: url)
            if canPlayDirect(profile: profile) {
                return .direct(url)
            }
            if let remuxRequest = remuxRequest(for: profile) {
                return .remux(remuxRequest)
            }
            return .transcode(makeTranscodeRequest(for: profile))
        } catch {
            print("Media inspection failed: \(error.localizedDescription)")
            return heuristicFallbackPlan(for: url)
        }
    }
    
    /// Forces a transcode plan regardless of the preferred path.
    func forcedTranscodePlan(for url: URL) -> PlaybackPlan {
        do {
            let profile = try inspector.profile(for: url)
            return .transcode(makeTranscodeRequest(for: profile))
        } catch {
            return heuristicFallbackPlan(for: url)
        }
    }
}

private extension PlaybackPlanner {
    func canPlayDirect(profile: MediaProfile) -> Bool {
        guard hasSupportedVideo(profile: profile), hasSupportedAudio(profile: profile) else {
            return false
        }
        return formatSet(from: profile.containerFormat).contains(where: directContainerFormats.contains)
    }
    
    func remuxRequest(for profile: MediaProfile) -> RemuxRequest? {
        guard hasSupportedVideo(profile: profile),
              let videoIndex = profile.videoStream?.index,
              let audioStream = profile.audioStreams.first(where: { avPlayerAudioCodecs.contains($0.codecName.lowercased()) })
        else {
            return nil
        }
        
        if formatSet(from: profile.containerFormat).contains(where: directContainerFormats.contains) {
            return nil
        }
        
        return RemuxRequest(
            sourceURL: profile.url,
            targetFileType: .mp4,
            videoStreamIndex: videoIndex,
            audioStreamIndex: audioStream.index,
            videoCodecName: profile.videoStream?.codecName
        )
    }
    
    func hasSupportedVideo(profile: MediaProfile) -> Bool {
        guard let videoCodec = profile.videoStream?.codecName else {
            return false
        }
        return avPlayerVideoCodecs.contains(videoCodec.lowercased())
    }
    
    func hasSupportedAudio(profile: MediaProfile) -> Bool {
        guard profile.audioStreams.isEmpty == false else {
            return false
        }
        return profile.audioStreams.contains { stream in
            avPlayerAudioCodecs.contains(stream.codecName.lowercased())
        }
    }
    
    func makeTranscodeRequest(for profile: MediaProfile) -> TranscodeRequest {
        let resolution = resolutionFor(profile: profile)
        let prefersHEVC = (resolution.width >= 1920 || resolution.height >= 1080)
        let videoCodec: VideoCodecTarget = prefersHEVC ? .hevc : .h264
        let videoBitrateKbps = bitrateFor(resolution: resolution, hevc: prefersHEVC)
        let videoBitrateValue = "\(videoBitrateKbps)k"
        let videoBuffer = "\(videoBitrateKbps * 2)k"
        let filter = scaleFilter(for: resolution, codec: videoCodec)
        
        return TranscodeRequest(
            sourceURL: profile.url,
            videoCodec: videoCodec,
            audioCodec: .aac,
            container: .mp4,
            videoBitrate: videoBitrateValue,
            videoBufferSize: videoBuffer,
            audioBitrate: "192k",
            videoFilter: filter,
            useHardwareAcceleration: true,
            output: .hls
        )
    }
    
    func fallbackTranscodeRequest(for url: URL) -> TranscodeRequest {
        TranscodeRequest(
            sourceURL: url,
            videoCodec: .h264,
            audioCodec: .aac,
            container: .mp4,
            videoBitrate: "10000k",
            videoBufferSize: "20000k",
            audioBitrate: "192k",
            videoFilter: nil,
            useHardwareAcceleration: true,
            output: .hls
        )
    }
    
    func heuristicFallbackPlan(for url: URL) -> PlaybackPlan {
        if VideoFormatSupport.prefersAVFoundation(for: url) {
            return .direct(url)
        }
        if VideoFormatSupport.isRecognizedVideo(url: url) {
            return .remux(
                RemuxRequest(
                    sourceURL: url,
                    targetFileType: .mp4,
                    videoStreamIndex: nil,
                    audioStreamIndex: nil,
                    videoCodecName: nil
                )
            )
        }
        return .transcode(fallbackTranscodeRequest(for: url))
    }
    
    func formatSet(from formatName: String?) -> Set<String> {
        guard let formatName else { return [] }
        let parts = formatName.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Set(parts)
    }
    
    func resolutionFor(profile: MediaProfile) -> (width: Int, height: Int) {
        let width = profile.videoStream?.width ?? 1920
        let height = profile.videoStream?.height ?? 1080
        return (width, height)
    }
    
    func bitrateFor(resolution: (width: Int, height: Int), hevc: Bool) -> Int {
        let maxDimension = max(resolution.width, resolution.height)
        if maxDimension >= 3800 {
            return hevc ? 25000 : 18000
        }
        if maxDimension >= 2500 {
            return hevc ? 18000 : 12000
        }
        if maxDimension >= 1920 {
            return hevc ? 12000 : 10000
        }
        return hevc ? 8000 : 6000
    }
    
    func scaleFilter(for resolution: (width: Int, height: Int), codec: VideoCodecTarget) -> String? {
        let maxWidth = codec == .hevc ? 3840 : 1920
        guard resolution.width > maxWidth else { return nil }
        return "scale=\(maxWidth):-2"
    }
}


