import Foundation
import Darwin

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong, notRunning, system(String)
    public var description: String {
        switch self {
        case .pathTooLong: return "socket path too long"
        case .notRunning: return "oton is not running"
        case .system(let s): return s
        }
    }
}

func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.pathTooLong }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

/// Reads newline-terminated lines from a file descriptor.
final class LineReader {
    let fd: Int32
    var buffer = Data()
    init(fd: Int32) { self.fd = fd }

    func next() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return buffer.isEmpty ? nil : { defer { buffer = Data() }; return buffer }() }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

public enum SocketClient {
    /// Sends one request and calls `onResponse` for every line until the final one.
    public static func send(_ request: Request, path: String, onResponse: (Response) -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket() failed") }
        defer { close(fd) }
        var addr = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw SocketError.notRunning }
        guard writeAll(fd, Wire.encode(request)) else { throw SocketError.system("write failed") }
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            let r = try Wire.decode(Response.self, line)
            onResponse(r)
            if r.final { return }
        }
        throw SocketError.system("connection closed without an answer")
    }
}

/// Accepts connections on a Unix socket (0600, own user only). One request per connection.
public final class SocketServer {
    public typealias Handler = (Request, _ emit: @escaping (Response) -> Void) -> Void
    let path: String
    let handler: Handler
    var fd: Int32 = -1

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket() failed") }
        var addr = try makeAddress(path)
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { throw SocketError.system("bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw SocketError.system("listen failed") }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "oton.socket"
        t.start()
    }

    func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue } else { return } }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [handler] in
                let reader = LineReader(fd: client)
                guard let line = reader.next(), let req = try? Wire.decode(Request.self, line) else {
                    _ = writeAll(client, Wire.encode(Response.failure("bad request")))
                    close(client)
                    return
                }
                let done = DispatchSemaphore(value: 0)
                handler(req) { resp in
                    _ = writeAll(client, Wire.encode(resp))
                    if resp.final { done.signal() }
                }
                done.wait()
                close(client)
            }
            t.start()
        }
    }

    public func stop() {
        if fd >= 0 { close(fd) }
        unlink(path)
    }
}
