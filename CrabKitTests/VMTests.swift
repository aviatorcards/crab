import Foundation
import Testing
@testable import CrabKit

struct VMTests {
    @Test func confGetTakesLastValue() {
        let dir = makeVM(testDir("conf-get"), "a", conf: "mem=1G\ncpus=2\nmem=4G\n")
        #expect(confGet(dir, "mem") == "4G")
        #expect(confGet(dir, "gpu") == "")
    }

    @Test func legacyArchFile() throws {
        let dir = makeVM(testDir("conf-legacy"), "old", conf: "")
        try "amd64\n".write(to: dir.appending(path: "arch"), atomically: true, encoding: .utf8)
        #expect(confGet(dir, "arch") == "amd64")
        #expect(confGet(dir, "firmware") == "bios")

        // Writing vm.conf for the first time keeps what the arch file said.
        try confSet(dir, [("mem", "3G")])
        #expect(confGet(dir, "arch") == "amd64")
        #expect(confGet(dir, "firmware") == "bios")
        #expect(confGet(dir, "mem") == "3G")
    }

    @Test func confSetReplacesAndKeepsOtherKeys() throws {
        let dir = makeVM(testDir("conf-set"), "a", conf: "arch=arm64\nmem=1G\nssh_user=me\nmem=2G\n")
        try confSet(dir, [("mem", "8G"), ("gpu", "ramfb")])
        #expect(read(dir.appending(path: "vm.conf")) == "arch=arm64\nmem=8G\nssh_user=me\ngpu=ramfb\n")
    }

    @Test func settingsValidation() throws {
        #expect(try validateSetting("fwd", "8080:80, udp:53:53", arch: "amd64") == "8080:80,udp:53:53")
        #expect(try validateSetting("fwd", "", arch: "amd64") == "0")
        #expect(throws: CrabError.self) { try validateSetting("firmware", "bios", arch: "arm64") }
        #expect(try validateSetting("firmware", "bios", arch: "amd64") == "bios")
        #expect(throws: CrabError.self) { try validateSetting("display", "vnc", arch: "amd64") }
        #expect(throws: CrabError.self) { try validateSetting("ssh_user", "a@b", arch: "amd64") }
        #expect(throws: CrabError.self) { try validateSetting("arch", "amd64", arch: "amd64") }
        #expect(throws: CrabError.self) { try validateSetting("mem", "lots", arch: "amd64") }
    }

    @Test func setRejectsUnknownKeysWithoutWriting() throws {
        let root = testDir("set")
        let paths = Paths(root: root)
        let dir = makeVM(root, "a", conf: "arch=amd64\n")
        #expect(throws: CrabError.self) { try setSettings(paths, "a", ["mem=4G", "colour=red"]) }
        #expect(confGet(dir, "mem") == "")
        try setSettings(paths, "a", ["mem=4G", "fwd=8080:80"])
        #expect(confGet(dir, "mem") == "4G")
        #expect(confGet(dir, "fwd") == "8080:80")
    }

    @Test func cloneGetsItsOwnPort() throws {
        let root = testDir("clone")
        let paths = Paths(root: root)
        makeVM(root, "src", conf: "arch=arm64\nssh_port=2222\n")
        let dst = try cloneVM(paths, "src", "dst")
        #expect(read(dst.appending(path: "disk.qcow2")) == "fake disk")
        #expect(confGet(dst, "arch") == "arm64")
        let port = confGet(dst, "ssh_port")
        #expect(!port.isEmpty && port != "2222", "got \(port)")
        #expect(throws: CrabError.self, "won't overwrite") { try cloneVM(paths, "src", "dst") }
        #expect(throws: CrabError.self) { try cloneVM(paths, "src", ".hidden") }
    }

    @Test func rename() throws {
        let root = testDir("rename")
        let paths = Paths(root: root)
        makeVM(root, "a", conf: "arch=arm64\n")
        makeVM(root, "b", conf: "arch=arm64\n")
        #expect(throws: CrabError.self) { try renameVM(paths, "a", "b") }
        try renameVM(paths, "a", "c")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "c/disk.qcow2").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "a").path))
    }

    @Test func sshTargets() throws {
        let root = testDir("ssh")
        let paths = Paths(root: root)
        makeVM(root, "bsd", conf: "arch=amd64\nssh_port=2201\nssh_user=root\n")
        makeVM(root, "nossh", conf: "arch=amd64\nssh_port=0\n")
        #expect(try sshCommand(paths, "bsd").joined(separator: " ") == "ssh -p 2201 -o HostKeyAlias=crab-bsd root@localhost")
        #expect(try sshCommand(paths, "me@bsd").last == "me@localhost")
        #expect { try sshCommand(paths, "nossh") } throws: { ($0 as? CrabError)?.message.contains("no SSH port") == true }
        #expect(throws: CrabError.self) { try sshCommand(paths, "missing") }
    }

    @Test func stoppedVMs() throws {
        let dir = makeVM(testDir("stopped"), "a", conf: "arch=amd64\n")
        // A stale pid file pointing at a process that isn't QEMU.
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: dir.appending(path: "qemu.pid"), atomically: true, encoding: .utf8)
        #expect(vmState(dir) == nil)
        #expect { try requestShutdown(dir) } throws: { ($0 as? CrabError)?.message.contains("isn't running") == true }
        #expect(throws: CrabError.self) { try forceOff(dir) }
    }
}
