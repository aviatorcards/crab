import Foundation
@testable import CrabKit

/// A fresh, empty directory for a test, unique per test name and process.
func testDir(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "crab-test-\(ProcessInfo.processInfo.processIdentifier)-\(name)", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fake saved VM with a placeholder disk and the given vm.conf.
@discardableResult
func makeVM(_ root: URL, _ name: String, conf: String) -> URL {
    let dir = root.appending(path: name, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! Data("fake disk".utf8).write(to: dir.appending(path: "disk.qcow2"))
    if !conf.isEmpty {
        try! conf.write(to: dir.appending(path: "vm.conf"), atomically: true, encoding: .utf8)
    }
    return dir
}

func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// Collects values from @Sendable callbacks.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.withLock { items.append(item) }
    }

    var all: [T] {
        lock.withLock { items }
    }
}

/// A connected socket for the fake servers, read a line at a time.
final class TestConn {
    let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close(fd)
    }

    func readLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[...nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                return line
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 {
                return nil
            }
            buffer += chunk[0..<n]
        }
    }

    @discardableResult
    func write(_ bytes: some Collection<UInt8>) -> Bool {
        let arr = Array(bytes)
        var offset = 0
        while offset < arr.count {
            let n = arr.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, arr.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    @discardableResult
    func write(_ s: String) -> Bool {
        write(Array(s.utf8))
    }
}

/// Listens on a Unix socket at `path` and serves one connection on a background thread.
func serveUnixSocket(at path: String, handler: @escaping @Sendable (TestConn) -> Void) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    precondition(rc == 0, "bind \(path) failed")
    listen(fd, 1)
    Thread.detachNewThread {
        let client = accept(fd, nil, nil)
        close(fd)
        handler(TestConn(fd: client))
    }
}

/// Listens on a free localhost TCP port, handling each connection on its own
/// thread. Returns the port.
func serveTCP(handler: @escaping @Sendable (TestConn) -> Void) -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            precondition(bind(fd, $0, len) == 0)
            getsockname(fd, $0, &len)
        }
    }
    listen(fd, 8)
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            Thread.detachNewThread { handler(TestConn(fd: client)) }
        }
    }
    return UInt16(bigEndian: addr.sin_port)
}

extension Data {
    init(_ string: String) {
        self.init(string.utf8)
    }
}
