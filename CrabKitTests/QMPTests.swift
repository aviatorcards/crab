import Foundation
import Testing
@testable import CrabKit

struct QMPTests {
    /// Serves one QMP session: greeting, capabilities, then replies to the
    /// command with an event first (which the client must skip) and `reply`.
    /// The command the client sent arrives in `received`.
    func fakeQEMU(_ dir: URL, reply: String, received: Box<String>) {
        serveUnixSocket(at: QMP.socketPath(dir).path) { conn in
            conn.write("{\"QMP\": {\"version\": {}, \"capabilities\": []}}\n")
            guard let caps = conn.readLine(), caps.contains("qmp_capabilities") else { return }
            conn.write("{\"return\": {}}\n")
            received.append(conn.readLine() ?? "")
            conn.write("{\"event\": \"RESUME\", \"timestamp\": {}}\n")
            conn.write(reply + "\n")
        }
    }

    @Test func queryStatusSkipsEvents() {
        let dir = testDir("qmp-status")
        let received = Box<String>()
        fakeQEMU(dir, reply: #"{"return": {"status": "paused", "running": false}}"#, received: received)
        #expect(QMP.queryStatus(dir) == "paused")
        #expect(received.all.first?.contains(#""execute":"query-status""#) == true)
    }

    @Test func errorsAreReported() {
        let dir = testDir("qmp-error")
        fakeQEMU(dir, reply: #"{"error": {"class": "GenericError", "desc": "nope"}}"#, received: Box())
        #expect(throws: CrabError("QEMU: nope")) { try QMP.systemPowerdown(dir) }
    }

    @Test func missingSocket() {
        #expect(QMP.queryStatus(testDir("qmp-missing")) == nil)
    }

    @Test func socketPathLength() {
        #expect(QMP.usableSocketPath(URL(filePath: "/Users/me/VMs/openbsd")) != nil)
        #expect(QMP.usableSocketPath(URL(filePath: "/Users/me/VMs/" + String(repeating: "x", count: 90))) == nil)
    }
}
