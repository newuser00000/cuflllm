import Darwin
import Foundation

public struct ParsedHTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data
}

public enum HTTPParseResult: Sendable, Equatable {
    case needMoreData
    case invalid(String)
    case complete(ParsedHTTPRequest)
}

public enum HTTPRequestParser {
    public static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 65_536 {
                return .invalid("HTTP headers too large")
            }
            return .needMoreData
        }

        let headerData = buffer[..<headerEndRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid("Invalid UTF-8 in HTTP headers")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("Missing request line")
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .invalid("Malformed request line")
        }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = val
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength < 0 || contentLength > 4 * 1024 * 1024 {
            return .invalid("Invalid Content-Length")
        }

        let bodyStart = headerEndRange.upperBound
        let availableBody = buffer.count - bodyStart
        if availableBody < contentLength {
            return .needMoreData
        }

        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        let (path, query) = splitTarget(rawTarget)

        return .complete(ParsedHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        ))
    }

    public static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let qIdx = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<qIdx])
        let queryStr = String(target[target.index(after: qIdx)...])
        var query: [String: String] = [:]
        for pair in queryStr.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if let kRaw = kv.first {
                let key = String(kRaw).removingPercentEncoding ?? String(kRaw)
                let val = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = val
            }
        }
        return (path, query)
    }
}

public final class HTTPServer: @unchecked Sendable {
    private let service: CuflService
    private let host: String
    private let port: UInt16
    private let actionQueue = DispatchQueue(label: "cuflllm.http.actions")
    private let ioQueue = DispatchQueue(label: "cuflllm.http.connections", attributes: .concurrent)

    public init(service: CuflService, host: String = "127.0.0.1", port: UInt16 = 8787) {
        self.service = service
        self.host = host
        self.port = port
    }

    public func runForever() throws {
        signal(SIGPIPE, SIG_IGN)

        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw NSError(domain: "cuflllm.http", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            close(serverFD)
            throw NSError(domain: "cuflllm.http", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid bind host '\(host)'"])
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let errCode = Int(errno)
            close(serverFD)
            throw NSError(domain: "cuflllm.http", code: errCode, userInfo: [NSLocalizedDescriptionKey: "Failed to bind \(host):\(port) (errno \(errCode))"])
        }

        guard listen(serverFD, 64) == 0 else {
            let errCode = Int(errno)
            close(serverFD)
            throw NSError(domain: "cuflllm.http", code: errCode, userInfo: [NSLocalizedDescriptionKey: "Failed to listen on \(host):\(port)"])
        }

        let stderrMsg = "cuflllm HTTP server listening on http://\(host):\(port)\n"
        FileHandle.standardError.write(Data(stderrMsg.utf8))

        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            ioQueue.async { [self] in
                self.handleConnection(clientFD)
            }
        }
        close(serverFD)
    }

    public func handleRequest(_ req: ParsedHTTPRequest) -> (status: Int, contentType: String, body: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        switch (req.method, req.path) {
        case ("GET", "/health"):
            let doc = service.doctor()
            let payload: [String: Any] = [
                "status": "ok",
                "accessibility_trusted": doc.accessibilityTrusted,
                "screen_recording_trusted": doc.screenRecordingTrusted,
                "frontmost_app": doc.frontmostApp ?? ""
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"status\":\"ok\"}".utf8)
            return (200, "application/json", data)

        case ("GET", "/doctor"):
            let doc = service.doctor()
            return jsonResponse(200, doc, encoder: encoder)

        case ("GET", "/windows"):
            let windows = service.listWindows()
            if req.query["format"] == "text" {
                return (200, "text/plain; charset=utf-8", Data(TreeFormatter.formatWindows(windows).utf8))
            }
            return jsonResponse(200, windows, encoder: encoder)

        case ("GET", "/state"):
            let maxEls = Int(req.query["max_elements"] ?? "100") ?? 100
            let ocr = OCRMode(rawValue: req.query["ocr"] ?? "auto") ?? .auto
            let windowId = req.query["window_id"]
            let snap = service.captureSnapshot(targetWindowId: windowId, maxElements: maxEls, ocr: ocr)
            let compact = TreeFormatter.formatSnapshot(snap, maxElements: maxEls)

            if req.query["format"] == "text" {
                return (200, "text/plain; charset=utf-8", Data(compact.utf8))
            }
            struct StateEnvelope: Codable {
                let snapshot: ScreenSnapshot
                let compactText: String
                enum CodingKeys: String, CodingKey {
                    case snapshot
                    case compactText = "compact_text"
                }
            }
            return jsonResponse(200, StateEnvelope(snapshot: snap, compactText: compact), encoder: encoder)

        case ("GET", "/menu"):
            let items = service.getMenuBar()
            if req.query["format"] == "text" {
                return (200, "text/plain; charset=utf-8", Data(TreeFormatter.formatMenu(items).utf8))
            }
            return jsonResponse(200, items, encoder: encoder)

        case ("POST", "/act"):
            do {
                let actionReq = try JSONDecoder().decode(ActionRequest.self, from: req.body)
                let result = service.performAction(actionReq)
                return jsonResponse(result.ok ? 200 : 400, result, encoder: encoder)
            } catch {
                return errorJSON(400, "Invalid JSON ActionRequest: \(error.localizedDescription)")
            }

        case ("POST", "/batch"):
            do {
                let batchReq = try JSONDecoder().decode(BatchActionRequest.self, from: req.body)
                let result = service.performBatch(batchReq)
                return jsonResponse(result.ok ? 200 : 400, result, encoder: encoder)
            } catch {
                return errorJSON(400, "Invalid JSON BatchActionRequest: \(error.localizedDescription)")
            }

        case ("POST", "/open_app"):
            struct OpenAppBody: Codable {
                let appName: String?
                let name: String?
                enum CodingKeys: String, CodingKey {
                    case appName = "app_name"
                    case name
                }
            }
            do {
                let parsed = try JSONDecoder().decode(OpenAppBody.self, from: req.body)
                let target = parsed.appName ?? parsed.name ?? ""
                let result = service.performAction(ActionRequest(action: .openApp, appName: target))
                return jsonResponse(result.ok ? 200 : 400, result, encoder: encoder)
            } catch {
                return errorJSON(400, "Invalid JSON body: \(error.localizedDescription)")
            }

        case ("POST", "/focus_window"):
            struct FocusWindowBody: Codable {
                let windowId: String
                enum CodingKeys: String, CodingKey {
                    case windowId = "window_id"
                }
            }
            do {
                let parsed = try JSONDecoder().decode(FocusWindowBody.self, from: req.body)
                let result = service.performAction(ActionRequest(action: .focusWindow, windowId: parsed.windowId))
                return jsonResponse(result.ok ? 200 : 400, result, encoder: encoder)
            } catch {
                return errorJSON(400, "Invalid JSON body: \(error.localizedDescription)")
            }

        default:
            return errorJSON(404, "Route not found: \(req.method) \(req.path)")
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { close(clientFD) }

        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var parsedRequest: ParsedHTTPRequest?

        while true {
            let n = recv(clientFD, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(chunk, count: n)

            switch HTTPRequestParser.parse(buffer) {
            case .needMoreData:
                continue
            case .invalid(let reason):
                let resp = errorJSON(400, reason)
                sendHTTP(fd: clientFD, status: resp.status, contentType: resp.contentType, body: resp.body)
                return
            case .complete(let req):
                parsedRequest = req
            }
            if parsedRequest != nil { break }
        }

        guard let req = parsedRequest else { return }

        let response = actionQueue.sync {
            self.handleRequest(req)
        }
        sendHTTP(fd: clientFD, status: response.status, contentType: response.contentType, body: response.body)
    }

    private func sendHTTP(fd: Int32, status: Int, contentType: String, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)

        packet.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < packet.count {
                let written = Darwin.send(fd, base.advanced(by: sent), packet.count - sent, 0)
                if written <= 0 { break }
                sent += written
            }
        }
    }

    private func jsonResponse<T: Encodable>(_ status: Int, _ value: T, encoder: JSONEncoder) -> (status: Int, contentType: String, body: Data) {
        if let data = try? encoder.encode(value) {
            return (status, "application/json", data)
        }
        return errorJSON(500, "JSON encoding failed")
    }

    private func errorJSON(_ status: Int, _ message: String) -> (status: Int, contentType: String, body: Data) {
        let payload = ["ok": false, "error": message] as [String: Any]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false}".utf8)
        return (status, "application/json", data)
    }
}
