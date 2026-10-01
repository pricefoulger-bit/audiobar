import Darwin
import Foundation
import Network

enum PeerAskResult: Equatable {
    case released
    case unreachable
    case refused
}

/// Listens on port 47653 for `POST /disconnect` and asks the peer to do the same.
///
/// Requests must carry `X-AudioBar-Secret`. IPv4 peers must sit in Tailscale's
/// 100.64.0.0/10 range. IPv6 peers must use Tailscale's `fd7a:` prefix.
final class PeerService {
    private let queue = DispatchQueue(label: "com.pricefoulger.audiobar.peer")
    private var listenFD: Int32 = -1
    private var secret = ""
    private var onDisconnect: ((String) -> Void)?

    func start(secret: String, onDisconnect: @escaping (String) -> Void) {
        self.secret = secret
        self.onDisconnect = onDisconnect
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("%@", "AudioBar listener failed to open a socket")
            return
        }
        setOption(fd, level: SOL_SOCKET, name: SO_REUSEADDR, value: Int32(1))
        setOption(fd, level: IPPROTO_IPV6, name: IPV6_V6ONLY, value: Int32(0))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(AppConfig.port).bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            NSLog("%@", "AudioBar listener failed to bind port \(AppConfig.port)")
            close(fd)
            return
        }
        listenFD = fd
        NSLog("%@", "AudioBar listening on port \(AppConfig.port)")
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "AudioBar peer"
        thread.start()
    }

    func askToDisconnect(address: String, peerHost: String, secret: String, completion: @escaping (PeerAskResult) -> Void) {
        let host = peerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = BluetoothAddress.normalize(address)
        guard !host.isEmpty, !secret.isEmpty, !normalized.isEmpty else {
            completion(.unreachable)
            return
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["address": normalized])) ?? Data()
        var hosts = [host]
        if !host.lowercased().hasSuffix(".local") {
            hosts.append("\(host).local")
        }
        attempt(hosts: hosts, index: 0, body: body, secret: secret, completion: completion)
    }

    private func setOption<T>(_ fd: Int32, level: Int32, name: Int32, value: T) {
        var stored = value
        withUnsafePointer(to: &stored) { pointer in
            _ = setsockopt(fd, level, name, pointer, socklen_t(MemoryLayout<T>.size))
        }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    accept(listenFD, socketAddress, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            let timeout = timeval(tv_sec: 2, tv_usec: 0)
            setOption(client, level: SOL_SOCKET, name: SO_RCVTIMEO, value: timeout)
            setOption(client, level: SOL_SOCKET, name: SO_SNDTIMEO, value: timeout)
            handle(client: client, peer: peer)
            close(client)
        }
    }

    private func handle(client: Int32, peer: sockaddr_storage) {
        if !remoteAllowed(peer) {
            NSLog("%@", "AudioBar rejected a peer outside Tailscale")
            writeResponse(client: client, status: 403, message: "forbidden")
            return
        }
        let buffer = readRequest(client: client)
        guard let request = Self.parseRequest(buffer) else {
            writeResponse(client: client, status: 400, message: "bad request")
            return
        }
        guard request.method == "POST", request.path == "/disconnect" else {
            writeResponse(client: client, status: 404, message: "not found")
            return
        }
        guard secretsMatch(request.secret, secret), !secret.isEmpty else {
            writeResponse(client: client, status: 401, message: "unauthorized")
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawAddress = object["address"] as? String else {
            writeResponse(client: client, status: 400, message: "bad request")
            return
        }
        let address = BluetoothAddress.normalize(rawAddress)
        guard !address.isEmpty else {
            writeResponse(client: client, status: 400, message: "bad request")
            return
        }
        let disconnect = onDisconnect
        DispatchQueue.main.sync {
            disconnect?(address)
        }
        writeResponse(client: client, status: 200, message: "ok")
    }

    private func readRequest(client: Int32) -> Data {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while received.count < 16 * 1024 {
            let count = chunk.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(client, base, pointer.count, 0)
            }
            if count <= 0 { break }
            received.append(contentsOf: chunk.prefix(count))
            if Self.parseRequest(received) != nil { break }
        }
        return received
    }

    private func writeResponse(client: Int32, status: Int, message: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let raw = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n\(message)"
        let bytes = Array(raw.utf8)
        bytes.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < pointer.count {
                let count = send(client, base.advanced(by: sent), pointer.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    private func remoteAllowed(_ peer: sockaddr_storage) -> Bool {
        var peer = peer
        if peer.ss_family == sa_family_t(AF_INET) {
            let address = withUnsafePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            return Self.isTailscaleIPv4(address)
        }
        if peer.ss_family == sa_family_t(AF_INET6) {
            let address = withUnsafePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            }
            return Self.isTailscaleIPv6(address)
        }
        return false
    }

    private static func isTailscaleIPv4(_ address: in_addr) -> Bool {
        let host = UInt32(bigEndian: address.s_addr)
        let first = UInt8((host >> 24) & 0xff)
        let second = UInt8((host >> 16) & 0xff)
        return first == 100 && second >= 64 && second <= 127
    }

    private static func isTailscaleIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count >= 16 else { return false }
        let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        if mapped {
            return bytes[12] == 100 && bytes[13] >= 64 && bytes[13] <= 127
        }
        return bytes[0] == 0xfd && bytes[1] == 0x7a
    }

    private func attempt(hosts: [String], index: Int, body: Data, secret: String, completion: @escaping (PeerAskResult) -> Void) {
        guard index < hosts.count else {
            completion(.unreachable)
            return
        }
        post(host: hosts[index], body: body, secret: secret) { [weak self] result in
            switch result {
            case .released, .refused:
                completion(result)
            case .unreachable:
                self?.attempt(hosts: hosts, index: index + 1, body: body, secret: secret, completion: completion)
            }
        }
    }

    private func post(host: String, body: Data, secret: String, completion: @escaping (PeerAskResult) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: AppConfig.port) else {
            completion(.unreachable)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let attempt = PeerAttempt()
        func finish(_ result: PeerAskResult) {
            attempt.finish(on: queue) {
                connection.cancel()
                completion(result)
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let payload = self.requestData(host: host, secret: secret, body: body)
                connection.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                    if error != nil {
                        finish(.unreachable)
                        return
                    }
                    self.receiveResponse(connection: connection, buffer: Data(), finish: finish)
                })
            case .failed:
                finish(.unreachable)
            case .cancelled:
                finish(.unreachable)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1.5) {
            finish(.unreachable)
        }
    }

    private func receiveResponse(connection: NWConnection, buffer: Data, finish: @escaping (PeerAskResult) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let code = Self.statusCode(in: buffer), buffer.range(of: Data([13, 10])) != nil {
                finish(Self.result(forStatus: code))
                return
            }
            if isComplete || error != nil {
                if let code = Self.statusCode(in: buffer) {
                    finish(Self.result(forStatus: code))
                } else {
                    finish(.unreachable)
                }
                return
            }
            self?.receiveResponse(connection: connection, buffer: buffer, finish: finish)
        }
    }

    private func requestData(host: String, secret: String, body: Data) -> Data {
        let header = [
            "POST /disconnect HTTP/1.1",
            "Host: \(host):\(AppConfig.port)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "\(AppConfig.secretHeader): \(secret)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func secretsMatch(_ provided: String, _ expected: String) -> Bool {
        let left = Array(provided.utf8)
        let right = Array(expected.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var diff: UInt8 = 0
        for index in 0..<left.count {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }

    private static func statusCode(in data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func result(forStatus code: Int) -> PeerAskResult {
        if code == 200 { return .released }
        if code == 401 || code == 403 { return .refused }
        return .unreachable
    }

    private static func parseRequest(_ buffer: Data) -> ParsedRequest? {
        guard let marker = buffer.range(of: Data([13, 10, 13, 10])) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<marker.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let length = contentLength(header)
        guard length <= 8192 else { return nil }
        let bodyStart = marker.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2 else { return nil }
        let method = String(pieces[0])
        let path = String(pieces[1].split(separator: "?").first ?? pieces[1])
        return ParsedRequest(method: method, path: path, secret: headerValue(header, name: AppConfig.secretHeader), body: body)
    }

    private static func contentLength(_ header: String) -> Int {
        Int(headerValue(header, name: "Content-Length")) ?? 0
    }

    private static func headerValue(_ header: String, name: String) -> String {
        let wanted = name.lowercased()
        for line in header.components(separatedBy: "\r\n") {
            guard let split = line.firstIndex(of: ":") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces).lowercased()
            if key == wanted {
                return line[line.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }
}

private struct ParsedRequest {
    var method: String
    var path: String
    var secret: String
    var body: Data
}

private final class PeerAttempt {
    private var finished = false
    func finish(on queue: DispatchQueue, _ body: @escaping () -> Void) {
        queue.async {
            if self.finished { return }
            self.finished = true
            body()
        }
    }
}
