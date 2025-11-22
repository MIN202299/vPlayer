import Foundation

/// Represents the local media output produced by the processing pipeline.
struct ProcessingArtifact {
    enum Kind {
        case file(url: URL)
        case hls(directory: URL, playlistFilename: String)
    }
    
    let kind: Kind
    let cleanup: () -> Void
}


