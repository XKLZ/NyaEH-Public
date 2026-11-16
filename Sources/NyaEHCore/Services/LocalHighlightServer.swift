// 本文件提供默认关闭的 localhost 只读接口，让 userscript 高亮远端页面中本地已存在的 gallery。

import Foundation
import Observation
import Darwin

enum LocalHighlightServerStatus: Equatable, Sendable {
    case disabled
    case starting(port: Int)
    case running(port: Int)
    case failed(port: Int, message: String)

    var port: Int? {
        switch self {
        case .disabled:
            return nil
        case .starting(let port), .running(let port), .failed(let port, _):
            return port
        }
    }
}

final class LocalHighlightSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot = LocalHighlightGallerySnapshot(gids: [])

    func update(books: [LibraryBook]) {
        // Snapshot 只包含可公开匹配的 gallery gid，不暴露本地路径、标题、hash、tag 或凭据。
        let snapshot = LocalHighlightGallerySnapshot.make(from: books)
        lock.withLock {
            storedSnapshot = snapshot
        }
    }

    func snapshot() -> LocalHighlightGallerySnapshot {
        lock.withLock {
            storedSnapshot
        }
    }
}

final class LocalHighlightServer: @unchecked Sendable {
    typealias SnapshotProvider = @Sendable () -> LocalHighlightGallerySnapshot

    private let queue = DispatchQueue(label: "dev.gazelee.NyaEH.local-highlight-server")
    private var listenerFileDescriptor: Int32 = -1
    private var currentPort: Int?
    private var snapshotProvider: SnapshotProvider?

    func start(
        port: Int,
        snapshotProvider: @escaping SnapshotProvider
    ) throws {
        // 监听仅绑定 loopback，功能默认关闭；开启后 userscript 也只能读取只读快照。
        let normalizedPort = AppPreferences.normalizedLocalHighlightServerPort(port)
        stop()

        guard UInt16(exactly: normalizedPort) != nil else {
            throw LocalHighlightServerError.invalidPort(port)
        }

        self.snapshotProvider = snapshotProvider

        let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw LocalHighlightServerError.socketFailed(code: errno)
        }

        do {
            try configure(fileDescriptor: fileDescriptor)
            try bind(fileDescriptor: fileDescriptor, port: normalizedPort)
            try listen(fileDescriptor: fileDescriptor, port: normalizedPort)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }

        listenerFileDescriptor = fileDescriptor
        currentPort = normalizedPort
        queue.async { [weak self] in
            self?.acceptLoop(fileDescriptor: fileDescriptor)
        }
    }

    func stop() {
        let fileDescriptor = listenerFileDescriptor
        listenerFileDescriptor = -1
        currentPort = nil
        if fileDescriptor >= 0 {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }
    }

    private func configure(fileDescriptor: Int32) throws {
        var value: Int32 = 1
        let result = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )
        if result < 0 {
            throw LocalHighlightServerError.socketOptionFailed(code: errno)
        }
    }

    private func bind(fileDescriptor: Int32, port: Int) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    fileDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        if result < 0 {
            throw LocalHighlightServerError.bindFailed(port: port, code: errno)
        }
    }

    private func listen(fileDescriptor: Int32, port: Int) throws {
        if Darwin.listen(fileDescriptor, SOMAXCONN) < 0 {
            throw LocalHighlightServerError.listenFailed(port: port, code: errno)
        }
    }

    private func acceptLoop(fileDescriptor: Int32) {
        while listenerFileDescriptor == fileDescriptor {
            let clientFileDescriptor = Darwin.accept(fileDescriptor, nil, nil)
            if clientFileDescriptor < 0 {
                if errno == EBADF || errno == EINVAL {
                    break
                }
                continue
            }
            handle(clientFileDescriptor: clientFileDescriptor)
        }
    }

    private func handle(clientFileDescriptor: Int32) {
        defer {
            Darwin.close(clientFileDescriptor)
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(clientFileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        let requestData = count > 0 ? Data(buffer.prefix(Int(count))) : Data()
        let response = response(for: requestData)
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = Darwin.write(
                    clientFileDescriptor,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if result <= 0 {
                    break
                }
                bytesWritten += result
            }
        }
    }

    private func response(for data: Data) -> Data {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return Self.httpResponse(status: 400, reason: "Bad Request", body: #"{"error":"bad_request"}"#)
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return Self.httpResponse(status: 400, reason: "Bad Request", body: #"{"error":"bad_request"}"#)
        }

        let method = parts[0].uppercased()
        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? parts[1]

        guard path == "/api/highlight/v1/galleries" else {
            return Self.httpResponse(status: 404, reason: "Not Found", body: #"{"error":"not_found"}"#)
        }

        if method == "OPTIONS" {
            return Self.httpResponse(status: 204, reason: "No Content", body: "")
        }

        guard method == "GET" else {
            return Self.httpResponse(status: 405, reason: "Method Not Allowed", body: #"{"error":"method_not_allowed"}"#)
        }

        guard let snapshotProvider else {
            return Self.httpResponse(status: 503, reason: "Service Unavailable", body: #"{"error":"service_unavailable"}"#)
        }

        do {
            let bodyData = try JSONEncoder().encode(snapshotProvider())
            let body = String(data: bodyData, encoding: .utf8) ?? #"{"app":"NyaEH","revision":"","gids":[]}"#
            return Self.httpResponse(status: 200, reason: "OK", body: body)
        } catch {
            return Self.httpResponse(status: 500, reason: "Internal Server Error", body: #"{"error":"internal_error"}"#)
        }
    }

    private static func httpResponse(status: Int, reason: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Cache-Control: no-store",
            "Content-Length: \(bodyData.count)",
            "Connection: close"
        ]
        if status == 204 {
            headers[1] = "Content-Type: text/plain; charset=utf-8"
        }
        let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        return headerData + bodyData
    }
}

enum LocalHighlightServerError: LocalizedError {
    case invalidPort(Int)
    case socketFailed(code: Int32)
    case socketOptionFailed(code: Int32)
    case bindFailed(port: Int, code: Int32)
    case listenFailed(port: Int, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid local highlight server port: \(port)"
        case .socketFailed(let code):
            return "Unable to create local highlight server socket: \(Self.message(for: code))"
        case .socketOptionFailed(let code):
            return "Unable to configure local highlight server socket: \(Self.message(for: code))"
        case .bindFailed(let port, let code):
            if code == EADDRINUSE {
                return "Port \(port) is already in use."
            }
            return "Unable to bind local highlight server to port \(port): \(Self.message(for: code))"
        case .listenFailed(let port, let code):
            return "Unable to listen on local highlight server port \(port): \(Self.message(for: code))"
        }
    }

    private static func message(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}

@MainActor
@Observable
final class LocalHighlightServerController {
    private let server = LocalHighlightServer()
    private let snapshotCache = LocalHighlightSnapshotCache()

    private(set) var status: LocalHighlightServerStatus = .disabled

    var snapshot: LocalHighlightGallerySnapshot {
        snapshotCache.snapshot()
    }

    func updateBooks(_ books: [LibraryBook]) {
        snapshotCache.update(books: books)
    }

    func apply(preferences: AppPreferences) {
        if preferences.isLocalHighlightServerEnabled {
            start(port: preferences.localHighlightServerPort)
        } else {
            stop()
        }
    }

    func stop() {
        server.stop()
        status = .disabled
    }

    private func start(port: Int) {
        let normalizedPort = AppPreferences.normalizedLocalHighlightServerPort(port)
        status = .starting(port: normalizedPort)
        do {
            try server.start(
                port: normalizedPort,
                snapshotProvider: { [snapshotCache] in
                    snapshotCache.snapshot()
                }
            )
            status = .running(port: normalizedPort)
        } catch {
            status = .failed(port: normalizedPort, message: error.localizedDescription)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer {
            unlock()
        }
        return try body()
    }
}
