import Foundation
import Network

/// Test-only, loopback-bound HTTP server. All state belongs to its serial queue;
/// the only readable resources are the supplied, small synthetic fixture files.
final class HTTPPlaybackFixtureServer: @unchecked Sendable {
    struct Counts { var requests = 0; var ranges = 0; var bytes = 0 }
    private let queue = DispatchQueue(label: "HTTPPlaybackFixtureServer")
    private let listener: NWListener
    private let files: [String: Data]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var counts = Counts()

    init(files: [String: Data]) throws {
        self.files = files
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { reply in
            queue.async {
                self.ready = reply
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port,
                              let url = URL(string: "http://localhost:\(port.rawValue)/") else { return }
                        self.finishStart(.success(url))
                    case .failed(let error): self.finishStart(.failure(error))
                    case .cancelled: self.finishStart(.failure(URLError(.cancelled)))
                    default: break
                    }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 2) {
                    if self.ready != nil {
                        self.finishStart(.failure(URLError(.timedOut)))
                        self.listener.cancel()
                    }
                }
            }
        }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let reply = ready; ready = nil; reply?.resume(with: result)
    }

    func snapshot() -> Counts { queue.sync { counts } }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            finishStart(.failure(URLError(.cancelled)))
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let connection { self?.close(connection) }
        }
        connection.start(queue: queue)
        receive(connection, header: Data())
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func receive(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = header
            if let data { accumulated.append(data) }
            guard accumulated.count <= 16_384 else { self.close(connection); return }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, header: accumulated)
            } else if error != nil || complete { self.close(connection) }
            else { self.receive(connection, header: accumulated) }
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        guard let text = String(data: header, encoding: .utf8) else { close(connection); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD",
              let file = files[String(first[1])] else {
            send(connection, status: "404 Not Found", fields: "Content-Length: 0\r\n", body: Data()); return
        }
        counts.requests += 1
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        var lower = 0, upper = file.count, status = "200 OK", fields = ""
        if let rangeHeader {
            let value = rangeHeader.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes="), !value.contains(",") else {
                send(connection, status: "416 Range Not Satisfiable", fields: "Content-Range: bytes */\(file.count)\r\nContent-Length: 0\r\n", body: Data()); return
            }
            let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2 else { close(connection); return }
            if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 {
                lower = max(0, file.count - suffix)
            } else if let start = Int(bounds[0]), start >= 0, start < file.count {
                lower = start
                if !bounds[1].isEmpty {
                    guard let end = Int(bounds[1]), end >= start else { close(connection); return }
                    upper = min(end, file.count - 1) + 1
                }
            } else {
                send(connection, status: "416 Range Not Satisfiable", fields: "Content-Range: bytes */\(file.count)\r\nContent-Length: 0\r\n", body: Data()); return
            }
            counts.ranges += 1; status = "206 Partial Content"
            fields += "Content-Range: bytes \(lower)-\(upper - 1)/\(file.count)\r\n"
        }
        let body = first[0] == "HEAD" ? Data() : file.subdata(in: lower..<upper)
        counts.bytes += body.count
        fields += "Accept-Ranges: bytes\r\nContent-Type: video/mp4\r\nContent-Length: \(upper - lower)\r\n"
        send(connection, status: status, fields: fields, body: body)
    }

    private func send(_ connection: NWConnection, status: String, fields: String, body: Data) {
        var payload = Data("HTTP/1.1 \(status)\r\n\(fields)Connection: close\r\n\r\n".utf8)
        payload.append(body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }
}

actor HTTPPlaybackCacheGate {
    private var released = false
    private var cancelled = false
    func release() { released = true }
    func cancel() { cancelled = true; released = true }
    func wait() async throws {
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}
