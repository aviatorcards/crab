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
        #expect(throws: CrabError.self) { try validateSetting("ssh_user", "-oProxyCommand=id", arch: "amd64") }
        #expect(throws: CrabError.self) { try validateSetting("ssh_user", "root\n-oBatchMode=yes", arch: "amd64") }
        #expect(throws: CrabError.self) { try validateSetting("ssh_user", "root\u{7f}", arch: "amd64") }
        #expect(try validateSetting("ssh_user", "alice", arch: "amd64") == "alice")
        #expect(try validateSetting("ssh_user", "user.name", arch: "amd64") == "user.name")
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
        #expect(try sshCommand(paths, "bsd") == [
            "ssh", "-p", "2201", "-o", "HostKeyAlias=crab-bsd", "-l", "root", "--", "localhost",
        ])
        #expect(try sshCommand(paths, "me@bsd") == [
            "ssh", "-p", "2201", "-o", "HostKeyAlias=crab-bsd", "-l", "me", "--", "localhost",
        ])
        #expect { try sshCommand(paths, "nossh") } throws: { ($0 as? CrabError)?.message.contains("no SSH port") == true }
        #expect(throws: CrabError.self) { try sshCommand(paths, "missing") }
        #expect(throws: CrabError.self) { try sshCommand(paths, "-oProxyCommand=id@bsd") }
        #expect(throws: CrabError.self) { try sshCommand(paths, "root\n-oBatchMode=yes@bsd") }

        let poisoned = testDir("ssh-poison")
        let poisonedPaths = Paths(root: poisoned)
        makeVM(poisoned, "bsd", conf: "arch=amd64\nssh_port=2201\nssh_user=-oProxyCommand=id\n")
        #expect(throws: CrabError.self) { try sshCommand(poisonedPaths, "bsd") }
        makeVM(poisoned, "plain", conf: "arch=amd64\nssh_port=2222\n")
        #expect(try sshCommand(poisonedPaths, "plain") == [
            "ssh", "-p", "2222", "-o", "HostKeyAlias=crab-plain", "--", "localhost",
        ])
    }

    @Test func vmNamesRejectSlashesColonsAndBackslashes() throws {
        try checkName("debian-amd64")
        #expect(throws: CrabError.self) { try checkName("") }
        #expect(throws: CrabError.self) { try checkName(".hidden") }
        #expect(throws: CrabError.self) { try checkName("a/b") }
        #expect(throws: CrabError.self) { try checkName("a\\b") }
        #expect(throws: CrabError.self) { try checkName("win:disk") }
    }

    @Test func stoppedVMs() throws {
        let dir = makeVM(testDir("stopped"), "a", conf: "arch=amd64\n")
        // A stale pid file pointing at a process that isn't QEMU.
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: dir.appending(path: "qemu.pid"), atomically: true, encoding: .utf8)
        #expect(vmState(dir) == nil)
        #expect { try requestShutdown(dir) } throws: { ($0 as? CrabError)?.message.contains("isn't running") == true }
        #expect(throws: CrabError.self) { try forceOff(dir) }
    }

    /// The app finds its own throwaway VMs after a relaunch, but not the CLI's.
    @Test func appThrowawaysSurviveARelaunch() throws {
        let paths = Paths(root: testDir("throwaways"))
        let fm = FileManager.default
        let gui = paths.scratchRoot.appending(path: "AAAAAA", directoryHint: .isDirectory)
        let live = paths.scratchRoot.appending(path: "BBBBBB", directoryHint: .isDirectory)
        let cli = paths.scratchRoot.appending(path: "CCCCCC", directoryHint: .isDirectory)
        for d in [gui, live, cli] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let image = URL(filePath: "/isos/Mac OS 9.2.iso")
        try saveThrowawayInfo(ThrowawayInfo(dir: gui, imagePath: image, defaultName: "macos9-ppc", live: false))
        try saveThrowawayInfo(ThrowawayInfo(dir: live, imagePath: nil, defaultName: "alpine", live: true))

        let found = listAppThrowaways(paths).sorted { $0.dir.path < $1.dir.path }
        #expect(found.map(\.dir.lastPathComponent) == ["AAAAAA", "BBBBBB"])
        #expect(found[0].imagePath == image)
        #expect(found[0].defaultName == "macos9-ppc")
        #expect(!found[0].live)
        #expect(found[1].imagePath == nil)
        #expect(found[1].live)
        #expect(readConfigKey(throwawayInfoFile(gui), "state") == guiSessionRunning)
    }

    /// Cleanup may remove a crashed CLI scratch dir. It must leave app sessions
    /// that are still running, waiting on Keep/Discard, or named in `preserving`.
    @Test func cleanKeepsRecoverableGUISessions() throws {
        let fm = FileManager.default
        let paths = Paths(root: testDir("clean-scratch"))
        let cli = paths.scratchRoot.appending(path: "cli-crash", directoryHint: .isDirectory)
        let stalePID = paths.scratchRoot.appending(path: "stale-pid", directoryHint: .isDirectory)
        let pending = paths.scratchRoot.appending(path: "pending", directoryHint: .isDirectory)
        let running = paths.scratchRoot.appending(path: "running", directoryHint: .isDirectory)
        let held = paths.scratchRoot.appending(path: "held", directoryHint: .isDirectory)
        for dir in [cli, stalePID, pending, running, held] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("disk").write(to: dir.appending(path: "disk.qcow2"))
        }
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: stalePID.appending(path: "qemu.pid"), atomically: true, encoding: .utf8
        )
        try saveThrowawayInfo(ThrowawayInfo(dir: pending, imagePath: nil, defaultName: "pending", live: false))
        markThrowawayPending(pending)
        try saveThrowawayInfo(ThrowawayInfo(dir: running, imagePath: nil, defaultName: "running", live: false))

        let (n, _) = cleanLeftoverScratch(paths, preserving: [held])
        #expect(n == 2)
        #expect(!fm.fileExists(atPath: cli.path))
        #expect(!fm.fileExists(atPath: stalePID.path))
        #expect(read(pending.appending(path: "disk.qcow2")) == "disk")
        #expect(readConfigKey(throwawayInfoFile(pending), "state") == guiSessionPending)
        #expect(read(running.appending(path: "disk.qcow2")) == "disk")
        #expect(readConfigKey(throwawayInfoFile(running), "state") == guiSessionRunning)
        #expect(read(held.appending(path: "disk.qcow2")) == "disk")
    }
}
