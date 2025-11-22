import Foundation
import AVFoundation

/// Represents the next action required to make a media URL playable by `AVPlayer`.
enum PlaybackPlan: Equatable {
    case direct(URL)
    case remux(RemuxRequest)
    case needsTranscode(URL)
    
    /// Returns `true` when the plan expects an intermediate remux step.
    var requiresRemux: Bool {
        if case .remux = self {
            return true
        }
        return false
    }
}

/// Describes the information needed to remux a media file into an `AVPlayer` friendly container.
struct RemuxRequest: Equatable {
    let sourceURL: URL
    let targetFileType: AVFileType
}

/// Inspects incoming media and decides whether it can be played directly, remuxed, or needs full transcode.
final class PlaybackPlanner {
    private let inspector = MediaInspector()
    
    /// Builds a playback plan for the provided file URL.
    func plan(for url: URL) -> PlaybackPlan {
        let profile = inspector.profile(for: url)
        
        guard profile.isRecognized else {
            return .needsTranscode(url)
        }
        
        if profile.prefersDirectPlayback {
            return .direct(url)
        }
        
        return .remux(RemuxRequest(sourceURL: url, targetFileType: .mp4))
    }
}

/// Provides lightweight media metadata used by the planner.
struct MediaProfile {
    let url: URL
    let fileExtension: String?
    
    /// Indicates whether the file extension is part of the known video list.
    var isRecognized: Bool {
        VideoFormatSupport.isRecognizedVideo(url: url)
    }
    
    /// Indicates whether AVFoundation is the preferred backend for this file.
    var prefersDirectPlayback: Bool {
        VideoFormatSupport.prefersAVFoundation(for: url)
    }
}

/// Creates `MediaProfile` instances from URLs for future extensibility.
final class MediaInspector {
    /// Builds a profile by capturing metadata such as file extension.
    func profile(for url: URL) -> MediaProfile {
        MediaProfile(
            url: url,
            fileExtension: url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
        )
    }
}


