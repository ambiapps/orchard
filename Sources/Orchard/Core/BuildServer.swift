import Foundation
import Network

struct HTTPRequest: Equatable, Sendable {
    var method: String
    /// Without the query.
    var path: String
    /// Names in lower case.
    var headers: [String: String] = [:]

    /// Parses a request head (the lines before the blank one); nil if it isn't one.
    static func parse(_ head: Data) -> HTTPRequest? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return HTTPRequest(method: String(parts[0]), path: String(path), headers: headers)
    }
}

struct HTTPResponse: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case data(Data)
        case file(URL)
    }
    var status: Int
    var contentType = "text/plain; charset=utf-8"
    var body: Body

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, body: .data(Data((text + "\n").utf8)))
    }

    var reason: String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }
}

/// What a builder serves, decided from the files `SharedBuilds` keeps. Every request needs the token.
struct BuildService: Sendable {
    var name: String
    var token: String
    var root: URL = Paths.pipelines
    /// The package with `devicectl` from this Mac's Xcode, for clients that have no Xcode.
    var deviceSupport: URL?

    func response(to request: HTTPRequest) -> HTTPResponse {
        guard request.headers["authorization"] == "Bearer \(token)" else { return .text(401, "Unauthorized") }
        guard request.method == "GET" else { return .text(405, "Method not allowed") }
        let parts = request.path.split(separator: "/").map(String.init)
        switch parts.count {
        case 2 where parts == ["v1", "builds"]:
            let catalog = BuildCatalog(builder: name, hasDeviceSupport: deviceSupport != nil,
                                       pipelines: SharedBuilds.catalog(root: root))
            guard let data = try? JSONEncoder().encode(catalog) else { return .text(404, "Not found") }
            return HTTPResponse(status: 200, contentType: "application/json", body: .data(data))
        case 2 where parts == ["v1", "device-support.pkg"]:
            guard let deviceSupport else { return .text(404, "Not found") }
            return HTTPResponse(status: 200, contentType: "application/octet-stream", body: .file(deviceSupport))
        case 4 where parts[0] == "v1" && parts[1] == "builds" && parts[3].hasSuffix(".zip"):
            // Both are parsed as UUIDs, so a request can't name any other file.
            guard let pipeline = UUID(uuidString: parts[2]),
                  let build = UUID(uuidString: String(parts[3].dropLast(4))),
                  let archive = SharedBuilds.archive(pipeline: pipeline, build: build, root: root)
            else { return .text(404, "Not found") }
            return HTTPResponse(status: 200, contentType: "application/zip", body: .file(archive))
        default:
            return .text(404, "Not found")
        }
    }
}

/// A small HTTP/1.1 server for `BuildService`: one request per connection, files streamed in chunks.
final class BuildServer: @unchecked Sendable {
    private let service: BuildService
    private let listener: NWListener
    private let queue = DispatchQueue(label: "se.ambi.Orchard.BuildServer")

    /// `port` 0 picks a free one.
    init(service: BuildService, port: Int) throws {
        self.service = service
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any)
    }

    /// Starts listening and returns the port. Throws when the port is taken.
    @discardableResult
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                // Called on `queue`, one state at a time; only the first outcome is reported.
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [service, queue] connection in
                Session(connection: connection, service: service).start(on: queue)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

/// One connection. Everything runs on the server's queue.
private final class Session: @unchecked Sendable {
    private let connection: NWConnection
    private let service: BuildService
    private var buffer = Data()
    private var file: FileHandle?
    private var answered = false

    init(connection: NWConnection, service: BuildService) {
        self.connection = connection
        self.service = service
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        // A connection that never sends a request doesn't stay around.
        queue.asyncAfter(deadline: .now() + 30) { [self] in
            if !answered { connection.cancel() }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            buffer.append(data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                answered = true
                let request = HTTPRequest.parse(buffer[..<end.lowerBound])
                send(request.map(service.response) ?? .text(400, "Bad request"))
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        var response = response
        var content = Data()
        var length = 0
        switch response.body {
        case .data(let data):
            content = data
            length = data.count
        case .file(let url):
            if let handle = try? FileHandle(forReadingFrom: url),
               let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
                file = handle
                length = size
            } else {
                response = .text(404, "Not found")
                if case .data(let data) = response.body { content = data; length = data.count }
            }
        }
        let head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(length)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + content, completion: .contentProcessed { [self] error in
            error == nil ? sendFile() : close()
        })
    }

    private func sendFile() {
        guard let file, let chunk = try? file.read(upToCount: 1 << 20), !chunk.isEmpty else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [self] _ in close() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            error == nil ? sendFile() : close()
        })
    }

    private func close() {
        try? file?.close()
        file = nil
        connection.cancel()
    }
}
