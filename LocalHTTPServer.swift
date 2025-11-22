import Foundation
import Network

/// Represents a registered local stream served over HTTP.
struct LocalHTTPStreamHandle {
    let id: String
    let url: URL
    let cleanup: () -> Void
}

/// Lightweight single-file HTTP server that exposes remuxed assets to `AVPlayer`.
final class LocalHTTPServer {
    static let shared = LocalHTTPServer()
    
    private enum LocalHTTPServerError: Error {
        case listenerFailed
        case portUnavailable
        case invalidRequest
    }
    
    private struct Session {
        let fileURL: URL
    }
    
    private let queue = DispatchQueue(label: "io.vplayer.httpserver")
    private var listener: NWListener?
    private var port: UInt16?
    private var sessions: [String: Session] = [:]
    
    private init() {}
    
    /// Registers a file path and returns an HTTP URL served from localhost.
    func registerFile(at fileURL: URL) throws -> LocalHTTPStreamHandle {
        try queue.sync {
            try startIfNeededLocked()
            let sessionId = UUID().uuidString
            sessions[sessionId] = Session(fileURL: fileURL)
            guard let port else {
                throw LocalHTTPServerError.portUnavailable
            }
            let streamURL = URL(string: "http://127.0.0.1:\(port)/stream/\(sessionId)")!
            return LocalHTTPStreamHandle(
                id: sessionId,
                url: streamURL,
                cleanup: { [weak self] in
                    self?.queue.async {
                        self?.sessions.removeValue(forKey: sessionId)
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            )
        }
    }
    
    /// Ensures the underlying TCP listener is active.
    private func startIfNeededLocked() throws {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: 39453)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    print("LocalHTTPServer listener failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            self.port = listener.port?.rawValue ?? 39453
        } catch {
            throw LocalHTTPServerError.listenerFailed
        }
    }
    
    /// Accepts a new connection and begins reading its request.
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulatedData: Data())
    }
    
    /// Recursively receives data until a full HTTP request header is available.
    private func receive(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    print("LocalHTTPServer receive error: \(error)")
                    connection.cancel()
                    return
                }
                
                var buffer = accumulatedData
                if let chunk = data {
                    buffer.append(chunk)
                }
                
                if let requestRange = buffer.range(of: Data("\r\n\r\n".utf8)),
                   let headerString = String(data: buffer[..<requestRange.lowerBound], encoding: .utf8) {
                    self.process(request: headerString, connection: connection)
                } else if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, accumulatedData: buffer)
                }
            }
        }
    }
    
    /// Parses and responds to a single HTTP request.
    private func process(request: String, connection: NWConnection) {
        guard let firstLine = request.split(separator: "\r\n").first else {
            send(status: 400, body: "Bad Request", connection: connection)
            return
        }
        
        let components = firstLine.split(separator: " ")
        guard components.count >= 2 else {
            send(status: 400, body: "Bad Request", connection: connection)
            return
        }
        
        let method = components[0]
        let rawPath = components[1]
        
        guard method == "GET" else {
            send(status: 405, body: "Method Not Allowed", connection: connection)
            return
        }
        
        guard let decodedPath = String(rawPath).removingPercentEncoding else {
            send(status: 400, body: "Bad Request", connection: connection)
            return
        }
        
        let headers = parseHeaders(from: request)
        let segments = decodedPath.split(separator: "/")
        guard segments.count == 3, segments[1] == "stream" else {
            send(status: 404, body: "Not Found", connection: connection)
            return
        }
        
        let sessionId = String(segments[2])
        guard let session = sessions[sessionId] else {
            send(status: 404, body: "Not Found", connection: connection)
            return
        }
        
        serve(session: session, headers: headers, connection: connection)
    }
    
    /// Responds with the requested file, honoring HTTP range headers for seeking.
    private func serve(session: Session, headers: [String: String], connection: NWConnection) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: session.fileURL.path)
            let totalBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard totalBytes > 0 else {
                send(status: 410, body: "Gone", connection: connection)
                return
            }
            
            let (statusCode, range) = parseRange(from: headers["range"], totalBytes: totalBytes)
            guard let range else {
                send(status: 416, body: "Requested Range Not Satisfiable", connection: connection)
                return
            }
            
            let length = range.upperBound - range.lowerBound + 1
            let header = buildHeader(
                statusCode: statusCode,
                contentLength: length,
                totalBytes: totalBytes,
                range: range
            )
            
            let handle = try FileHandle(forReadingFrom: session.fileURL)
            try handle.seek(toOffset: UInt64(range.lowerBound))
            
            connection.send(
                content: header,
                completion: .contentProcessed { [weak self] error in
                    guard error == nil, let self else {
                        connection.cancel()
                        try? handle.close()
                        return
                    }
                    self.sendFile(
                        handle: handle,
                        remainingBytes: length,
                        connection: connection
                    )
                }
            )
        } catch {
            send(status: 500, body: "Server Error", connection: connection)
        }
    }
    
    /// Sends file contents in chunks to the client.
    private func sendFile(handle: FileHandle, remainingBytes: Int64, connection: NWConnection, chunkSize: Int = 1_048_576) {
        if remainingBytes <= 0 {
            try? handle.close()
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
            return
        }
        
        let bytesToRead = Int(min(Int64(chunkSize), remainingBytes))
        let data = (try? handle.read(upToCount: bytesToRead)) ?? Data()
        if data.isEmpty {
            try? handle.close()
            connection.cancel()
            return
        }
        
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    print("LocalHTTPServer send error: \(error)")
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self?.sendFile(
                    handle: handle,
                    remainingBytes: remainingBytes - Int64(data.count),
                    connection: connection,
                    chunkSize: chunkSize
                )
            }
        )
    }
    
    /// Sends a plain-text HTTP error response.
    private func send(status: Int, body: String, connection: NWConnection) {
        let bodyData = Data(body.utf8)
        var response = "HTTP/1.1 \(status) \(statusDescription(status))\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Content-Type: text/plain; charset=utf-8\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        connection.send(content: Data(response.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    /// Creates the HTTP header for file responses.
    private func buildHeader(statusCode: Int, contentLength: Int64, totalBytes: Int64, range: ClosedRange<Int64>) -> Data {
        var header = "HTTP/1.1 \(statusCode) \(statusDescription(statusCode))\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        header += "Content-Type: video/mp4\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Connection: close\r\n"
        if statusCode == 206 {
            header += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(totalBytes)\r\n"
        }
        header += "\r\n"
        return Data(header.utf8)
    }
    
    /// Parses headers into a case-insensitive dictionary.
    private func parseHeaders(from request: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = request.components(separatedBy: "\r\n")
        guard lines.count > 1 else { return headers }
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }
    
    /// Determines the requested byte range, defaulting to the full file.
    private func parseRange(from header: String?, totalBytes: Int64) -> (Int, ClosedRange<Int64>?) {
        guard totalBytes > 0 else {
            return (416, nil)
        }
        guard let header else {
            return (200, 0...(totalBytes - 1))
        }
        let normalized = header.lowercased()
        let prefix = "bytes="
        guard normalized.hasPrefix(prefix) else {
            return (416, nil)
        }
        let rangeValue = normalized.dropFirst(prefix.count)
        let parts = rangeValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return (416, nil)
        }
        
        let lowerPart = String(parts[0])
        let upperPart = String(parts[1])
        
        var start: Int64?
        var end: Int64?
        
        if lowerPart.isEmpty, let suffixLength = Int64(upperPart) {
            start = max(0, totalBytes - suffixLength)
            end = totalBytes - 1
        } else {
            start = Int64(lowerPart)
            if upperPart.isEmpty {
                end = totalBytes - 1
            } else {
                end = Int64(upperPart)
            }
        }
        
        guard let lower = start, let upper = end, lower <= upper, lower < totalBytes else {
            return (416, nil)
        }
        
        let clampedUpper = min(upper, totalBytes - 1)
        let status = (lower == 0 && clampedUpper == totalBytes - 1) ? 200 : 206
        return (status, lower...clampedUpper)
    }
    
    /// Converts status codes into human readable descriptions.
    private func statusDescription(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 416: return "Requested Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "HTTP"
        }
    }
}


