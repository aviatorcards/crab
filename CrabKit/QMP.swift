import Foundation

/// A minimal client for QEMU's machine protocol (QMP), spoken over the
/// `qmp.sock` Unix socket that crab gives every VM it boots.
public enum QMP {
    /// macOS limits Unix socket paths to 104 bytes, including the terminating NUL.
    static let maxSocketPath = 103

    public static func socketPath(_ vmDir: URL) -> URL {
        vmDir.appending(path: "qmp.sock")
    }

    /// The socket path to give QEMU, or nil if it's too long.
    public static func usableSocketPath(_ vmDir: URL) -> URL? {
        let p = socketPath(vmDir)
        return p.path.utf8.count <= maxSocketPath ? p : nil
    }

    /// Runs one QMP command against the VM in `vmDir` and returns its "return" value.
    public static func execute(_ vmDir: URL, _ command: String, arguments: [String: Any]? = nil) throws(CrabError) -> Any {
        let conn = try Connection(path: socketPath(vmDir).path)
        defer { conn.close() }

        let greeting = try conn.readMessage()
        if greeting["QMP"] == nil {
            throw CrabError("QMP: unexpected greeting")
        }
        try conn.send(["execute": "qmp_capabilities"])
        _ = try conn.readReply()

        var msg: [String: Any] = ["execute": command]
        if let arguments {
            msg["arguments"] = arguments
        }
        try conn.send(msg)
        return try conn.readReply()
    }

    /// The guest's run state, e.g. "running", "paused" or "shutdown".
    public static func queryStatus(_ vmDir: URL) -> String? {
        let ret = try? execute(vmDir, "query-status")
        return (ret as? [String: Any])?["status"] as? String
    }

    /// Presses the virtual power button so the guest can shut down cleanly.
    public static func systemPowerdown(_ vmDir: URL) throws(CrabError) {
        _ = try execute(vmDir, "system_powerdown")
    }

    /// A VM's CD drive (QEMU's block device name) and the image in it, if any.
    public struct CDDrive: Sendable, Equatable {
        public var device: String
        public var image: URL?
    }

    /// The VM's CD drive: its first removable drive that isn't a floppy.
    /// x86 and PowerPC VMs always have one; arm64 VMs only when booted with an image.
    public static func cdDrive(_ vmDir: URL) throws(CrabError) -> CDDrive {
        guard let blocks = try execute(vmDir, "query-block") as? [[String: Any]] else {
            throw CrabError("QMP: unexpected query-block reply")
        }
        for block in blocks {
            guard block["removable"] as? Bool == true, let device = block["device"] as? String,
                  !device.isEmpty, !device.hasPrefix("floppy") else { continue }
            let file = (block["inserted"] as? [String: Any])?["file"] as? String
            return CDDrive(device: device, image: file.map { URL(filePath: $0) })
        }
        throw CrabError("the VM has no CD drive")
    }

    /// Puts `image` in `device`, or empties it if `image` is nil. `force`
    /// gets past a tray the guest has locked, as installers often do.
    public static func changeMedium(_ vmDir: URL, device: String, image: URL?) throws(CrabError) {
        if let image {
            _ = try execute(vmDir, "blockdev-change-medium", arguments: [
                "device": device, "filename": image.path, "format": "raw", "read-only-mode": "read-only", "force": true,
            ])
        } else {
            _ = try execute(vmDir, "eject", arguments: ["device": device, "force": true])
        }
    }

    /// Presses `keys` (QEMU qcodes, e.g. ["ctrl", "alt", "delete"]) together,
    /// then releases them, as a real keyboard would.
    public static func sendKeys(_ vmDir: URL, _ keys: [String]) throws(CrabError) {
        _ = try execute(vmDir, "send-key", arguments: ["keys": keys.map { ["type": "qcode", "data": $0] }])
    }

    /// Tells QEMU to exit right away, like pulling the plug.
    public static func quit(_ vmDir: URL) throws(CrabError) {
        do {
            _ = try execute(vmDir, "quit")
        } catch where error.message.contains("connection closed") {
            // QEMU may close the socket before its reply arrives.
        }
    }

    /// A blocking Unix socket connection with 3-second timeouts, read a line at a time.
    final class Connection {
        private let fd: Int32
        private var buffer = Data()

        init(path: String) throws(CrabError) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 {
                throw CrabError("can't reach the VM's control socket: \(lastError())")
            }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count < capacity else {
                Darwin.close(fd)
                throw CrabError("can't reach the VM's control socket: path too long")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: pathBytes)
            }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc != 0 {
                let err = lastError()
                Darwin.close(fd)
                throw CrabError("can't reach the VM's control socket: \(err)")
            }
        }

        func close() {
            Darwin.close(fd)
        }

        func send(_ msg: [String: Any]) throws(CrabError) {
            guard var data = try? JSONSerialization.data(withJSONObject: msg) else {
                throw CrabError("QMP: can't encode command")
            }
            data.append(UInt8(ascii: "\n"))
            let ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            if !ok {
                throw CrabError("QMP: \(lastError())")
            }
        }

        func readMessage() throws(CrabError) -> [String: Any] {
            let line = try readLine()
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CrabError("QMP: bad message")
            }
            return obj
        }

        /// Reads until the reply to the last command, skipping asynchronous events.
        func readReply() throws(CrabError) -> Any {
            while true {
                let msg = try readMessage()
                if let ret = msg["return"] {
                    return ret
                }
                if let err = msg["error"] as? [String: Any] {
                    throw CrabError("QEMU: \(err["desc"] as? String ?? "unknown error")")
                }
            }
        }

        private func readLine() throws(CrabError) -> Data {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return Data(line)
                }
                let n = read(fd, &chunk, chunk.count)
                if n == 0 {
                    throw CrabError("QMP: connection closed")
                }
                if n < 0 {
                    throw CrabError("QMP: \(lastError())")
                }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }

        private func lastError() -> String {
            String(cString: strerror(errno))
        }
    }
}
