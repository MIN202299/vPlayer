import Foundation
import UniformTypeIdentifiers

enum VideoFormatSupport {
    private static let avFoundationExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mpg", "mpeg", "mp2", "m2v", "3gp", "3g2"
    ]
    
    private static let extendedExtensions: Set<String> = [
        "mkv", "avi", "flv", "wmv", "webm", "ts", "m2ts", "ogv"
    ]
    
    private static var allExtensions: Set<String> {
        avFoundationExtensions.union(extendedExtensions)
    }
    
    static var supportedContentTypes: [UTType] {
        allExtensions.compactMap { type(forExtension: $0) }
    }
    
    static func isRecognizedVideo(url: URL) -> Bool {
        guard let ext = url.pathExtension.lowercased().nilIfEmpty else { return false }
        return allExtensions.contains(ext)
    }
    
    static func prefersAVFoundation(for url: URL) -> Bool {
        guard let ext = url.pathExtension.lowercased().nilIfEmpty else { return false }
        return avFoundationExtensions.contains(ext)
    }
    
    private static func type(forExtension ext: String) -> UTType? {
        if let type = UTType(filenameExtension: ext) {
            return type
        }
        return UTType(importedAs: "io.vplayer.video.\(ext)")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

