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

    @Test func findsTheCDDrive() throws {
        let dir = testDir("qmp-cd")
        // As QEMU's mac99 reports it: the disk, the CD (holding an image), then a floppy.
        fakeQEMU(dir, reply: #"""
            {"return": [
              {"device": "ide0-hd0", "removable": false, "inserted": {"file": "/vms/x/disk.qcow2"}},
              {"device": "ide1-cd0", "removable": true, "inserted": {"file": "/isos/Disk 1.iso"}},
              {"device": "floppy0", "removable": true}
            ]}
            """#.replacingOccurrences(of: "\n", with: ""), received: Box())
        #expect(try QMP.cdDrive(dir) == QMP.CDDrive(device: "ide1-cd0", image: URL(filePath: "/isos/Disk 1.iso")))

        let none = testDir("qmp-no-cd")
        fakeQEMU(none, reply: #"{"return": [{"device": "floppy0", "removable": true}]}"#, received: Box())
        #expect(throws: CrabError("the VM has no CD drive")) { try QMP.cdDrive(none) }
    }

    @Test func changesAndEjectsDiscs() throws {
        let dir = testDir("qmp-change")
        let received = Box<String>()
        fakeQEMU(dir, reply: #"{"return": {}}"#, received: received)
        try QMP.changeMedium(dir, device: "ide2-cd0", image: URL(filePath: "/isos/Disk 2.iso"))
        let change = try #require(received.all.first)
        #expect(change.contains(#""execute":"blockdev-change-medium""#))
        for part in [#""device":"ide2-cd0""#, #""filename":"\/isos\/Disk 2.iso""#, #""force":true"#, #""read-only-mode":"read-only""#] {
            #expect(change.contains(part), "\(part) in \(change)")
        }

        let ejectDir = testDir("qmp-eject")
        let ejected = Box<String>()
        fakeQEMU(ejectDir, reply: #"{"return": {}}"#, received: ejected)
        try QMP.changeMedium(ejectDir, device: "cd", image: nil)
        #expect(ejected.all.first?.contains(#""execute":"eject""#) == true)
    }

    @Test func discChangesNeedARunningVM() throws {
        let root = testDir("disc-stopped")
        makeVM(root, "panther", conf: "arch=ppc\n")
        #expect(throws: CrabError("panther isn't running")) {
            try cmdDisc(Paths(root: root), "panther", "eject")
        }
    }

    @Test func missingSocket() {
        #expect(QMP.queryStatus(testDir("qmp-missing")) == nil)
    }

    @Test func socketPathLength() {
        #expect(QMP.usableSocketPath(URL(filePath: "/Users/me/VMs/openbsd")) != nil)
        #expect(QMP.usableSocketPath(URL(filePath: "/Users/me/VMs/" + String(repeating: "x", count: 90))) == nil)
    }
}
