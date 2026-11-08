import Foundation
import Testing
@testable import CrabKit

struct MacOSVMTests {
    private func catalogData() throws -> Data {
        let plist: [String: Any] = [
            "MobileDeviceSoftwareVersionsByVersion": [
                "1": [
                    "MobileDeviceSoftwareVersions": [
                        "VirtualMac2,1": [
                            "24C101": [
                                "Restore": [
                                    "ProductVersion": "15.2",
                                    "BuildVersion": "24C101",
                                    "FirmwareURL": "https://updates.cdn-apple.com/x/UniversalMac_15.2_24C101_Restore.ipsw",
                                ],
                            ],
                            "24C50": [
                                "Restore": [
                                    "ProductVersion": "15.2",
                                    "BuildVersion": "24C50",
                                    "FirmwareURL": "https://updates.cdn-apple.com/old/UniversalMac_15.2_24C50_Restore.ipsw",
                                ],
                            ],
                            "24B83": [
                                "Restore": [
                                    "ProductVersion": "15.1",
                                    "BuildVersion": "24B83",
                                    "FirmwareURL": "https://updates.cdn-apple.com/y/UniversalMac_15.1_24B83_Restore.ipsw",
                                    "FirmwareSHA1": "bbbb",
                                ],
                            ],
                        ],
                        "Macmini9,1": [
                            "24C101": [
                                "Restore": [
                                    "ProductVersion": "15.2",
                                    "BuildVersion": "24C101",
                                    "FirmwareURL": "https://updates.cdn-apple.com/x/UniversalMac_15.2_24C101_Restore.ipsw",
                                    "FirmwareSHA1": "abc123",
                                ],
                            ],
                            "Unknown": [
                                "Universal": [
                                    "Restore": [
                                        "ProductVersion": "14.0",
                                        "BuildVersion": "23A344",
                                        "FirmwareURL": "https://updates.cdn-apple.com/z/not-a-vm.ipsw",
                                        "FirmwareSHA1": "def",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @Test func ipswCatalogKeepsTheVMModelAndBorrowsSHA1() throws {
        let assets = parseMacOSIPSWCatalog(try catalogData())
        #expect(assets.map(\.version) == ["15.2", "15.1"])
        #expect(assets[0].build == "24C101")
        #expect(assets[0].url.hasSuffix("UniversalMac_15.2_24C101_Restore.ipsw"))
        #expect(assets[0].sha1 == "abc123")
        #expect(assets[1].sha1 == "bbbb")
        #expect(assets.allSatisfy { $0.device == macosVirtualMachineModel })

        let entries = macOSCatalogEntries(assets)
        #expect(entries.map(\.distro) == [macosDistro, macosDistro])
        #expect(entries[0].variant == macosVariant)
        #expect(entries[0].arch == "arm64")
        #expect(entries[0].display == "window")
        #expect(entries[0].sha256.isEmpty)
        #expect(entries[0].sha1 == "abc123")
        #expect(CatalogEntry(tsvLine: entries[0].tsvLine) == entries[0])
        #expect(parseMacOSIPSWCatalog(Data("not a plist".utf8)).isEmpty)
    }

    @Test func restoreChoicePrefersTheHost() throws {
        let catalog = macOSCatalogEntries(parseMacOSIPSWCatalog(try catalogData()))
        let supported = MacOSRestoreChoice(version: "15.1", build: "24B83", url: catalog[1].url)
        #expect(selectMacOSRestore(catalog: catalog, supported: supported) == supported)
        let newest = selectMacOSRestore(catalog: catalog, supported: nil)
        #expect(newest?.version == "15.2")
        #expect(sha1ForMacOSRestore(newest!, catalog: catalog) == "abc123")
        #expect(selectMacOSRestore(catalog: [], supported: nil) == nil)
    }

    @Test func namesAndRefusal() {
        let url = "https://updates.cdn-apple.com/x/UniversalMac_15.2_24C101_Restore.ipsw"
        #expect(getFilename(distro: "macos", arch: "arm64", url: url) == "UniversalMac_15.2_24C101_Restore.ipsw")
        #expect(macosVersionFromIPSWName(url) == "15.2")
        #expect(macosBuildFromIPSWName(url) == "24C101")
        #expect(isIPSW(URL(filePath: "/tmp/UniversalMac_15.2_24C101_Restore.ipsw")))
        #expect(!isIPSW(URL(filePath: "/tmp/fedora.iso")))
        #expect(macosGuestRefusal(hostArchitecture: "arm64") == nil)
        let intel = macosGuestRefusal(hostArchitecture: "amd64")
        #expect(intel?.contains("Apple Silicon") == true)
        #expect(intel?.contains("amd64") == true)
    }

    @Test func hardwareFloorAndLayout() {
        let small = resolveMacOSHardware(mem: "2G", cpus: "1", disk: "20G")
        #expect(small.memoryMB == minMacOSMemoryMB)
        #expect(small.cpus == minMacOSCPUs)
        #expect(small.diskBytes == minMacOSDiskBytes)
        #expect(small.memText == "4G")
        #expect(small.diskText == "64G")
        #expect(small.notes.count == 3)

        let plenty = resolveMacOSHardware(mem: "8G", cpus: "6", disk: "80G")
        #expect(plenty.memoryMB == 8192)
        #expect(plenty.cpus == 6)
        #expect(plenty.diskBytes == 80 * 1024 * 1024 * 1024)
        #expect(plenty.notes.isEmpty)

        let layout = MacOSVMLayout(directory: URL(filePath: "/VMs/sequoia"))
        #expect(layout.disk.lastPathComponent == "Disk.img")
        #expect(layout.hardwareModel.lastPathComponent == "HardwareModel")
        #expect(layout.machineIdentifier.lastPathComponent == "MachineIdentifier")
        #expect(layout.auxiliaryStorage.lastPathComponent == "AuxiliaryStorage")
        #expect(layout.pidFile.lastPathComponent == "vz.pid")
        #expect(layout.socket.lastPathComponent == "vz.sock")
    }

    @Test func configRoundTripAndSettings() throws {
        let root = testDir("macos-conf")
        let dir = makeMacOSVM(root, "sequoia", conf: "")
        let config = MacOSVMConfig(
            version: "15.2", build: "24C101", mem: "8G", cpus: "4", disk: "80G",
            installed: true, restoreImage: "/images/UniversalMac.ipsw", minMemoryMB: 4096, minCPUs: 2
        )
        try confSet(dir, config.updates())
        #expect(MacOSVMConfig.load(dir) == config)
        #expect(confGet(dir, "backend") == vmBackendVZ)
        #expect(confGet(dir, "firmware") == vmBackendVZ)
        #expect(confGet(dir, "arch") == "arm64")
        #expect(confGet(dir, "ssh_port") == "0")

        let paths = Paths(root: root)
        #expect(throws: CrabError.self) { try setSettings(paths, "sequoia", ["mem=2G"]) }
        #expect(confGet(dir, "mem") == "8G")
        try setSettings(paths, "sequoia", ["mem=16G", "cpus=8"])
        #expect(confGet(dir, "mem") == "16G")
        #expect(confGet(dir, "cpus") == "8")
        #expect { try setSettings(paths, "sequoia", ["firmware=uefi"]) } throws: {
            ($0 as? CrabError)?.message.contains("doesn't apply") == true
        }
    }

    @Test func listingCoexistsWithQEMU() throws {
        let root = testDir("macos-list")
        let paths = Paths(root: root)
        makeVM(root, "linux", conf: "arch=amd64\nmem=2G\n")
        makeMacOSVM(root, "sequoia", conf: "backend=vz\narch=arm64\nfirmware=vz\nmem=8G\ncpus=4\ndisk=64G\n")
        try FileManager.default.createDirectory(at: root.appending(path: "notes"), withIntermediateDirectories: true)
        let names = listVMEntries(paths).map(\.name)
        #expect(names == ["linux", "sequoia"])
        let linux = try vmPath(paths, "linux")
        let mac = try vmPath(paths, "sequoia")
        #expect(!isMacOSVM(linux))
        #expect(isMacOSVM(mac))
        let entry = inspectVM(mac)
        #expect(entry.backend == vmBackendVZ)
        #expect(entry.disk.lastPathComponent == "Disk.img")
        #expect(entry.diskVirt == "64G")
        #expect(entry.mem == "8G")
        #expect(entry.snapsCount == 0)
        #expect(entry.runningPID == nil)
        #expect(inspectVM(linux).backend == vmBackendQEMU)
    }

    @Test func runningPidAndSnapshotsAndSSH() throws {
        let root = testDir("macos-ops")
        let paths = Paths(root: root)
        let dir = makeMacOSVM(root, "sequoia", conf: "backend=vz\narch=arm64\nssh_port=2222\n")
        #expect(vmState(dir) == nil)
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: dir.appending(path: "vz.pid"), atomically: true, encoding: .utf8)
        #expect(vmPID(dir) == ProcessInfo.processInfo.processIdentifier)
        #expect(vmState(dir) == "running")
        try? FileManager.default.removeItem(at: dir.appending(path: "vz.pid"))
        try "\(Int32.max)\n".write(to: dir.appending(path: "vz.pid"), atomically: true, encoding: .utf8)
        #expect(vmPID(dir) == nil)

        #expect { try createSnapshot(paths, "sequoia", tag: "fresh") } throws: {
            ($0 as? CrabError)?.message.contains("no disk snapshots") == true
        }
        #expect(throws: CrabError.self) { try restoreSnapshot(paths, "sequoia", "fresh") }
        #expect { try sshCommand(paths, "sequoia") } throws: {
            ($0 as? CrabError)?.message.contains("NAT") == true
        }
        #expect { try changeDisc(dir, to: nil) } throws: {
            ($0 as? CrabError)?.message.contains("macOS") == true
        }
    }

    @Test func resizeAndClone() throws {
        let root = testDir("macos-disk")
        let paths = Paths(root: root)
        let dir = makeMacOSVM(root, "sequoia", conf: "backend=vz\narch=arm64\ndisk=1M\n")
        try createSparseDisk(dir.appending(path: "Disk.img"), bytes: 1024 * 1024)
        #expect(logicalFileBytes(dir.appending(path: "Disk.img")) == 1024 * 1024)
        let grown = try resizeDisk(paths, "sequoia", "+1M")
        #expect(grown == "2M")
        #expect(logicalFileBytes(dir.appending(path: "Disk.img")) == 2 * 1024 * 1024)
        #expect(confGet(dir, "disk") == "2M")
        #expect(throws: CrabError.self) { try resizeDisk(paths, "sequoia", "1M") }
        #expect(grownDiskBytes(current: 100, spec: "+1M") == 100 + 1024 * 1024)
        #expect(grownDiskBytes(current: 100, spec: "1M") == 1024 * 1024)
        #expect(grownDiskBytes(current: 2 * 1024 * 1024, spec: "1M") == nil)

        let aux = dir.appending(path: "AuxiliaryStorage")
        try FileManager.default.createDirectory(at: aux, withIntermediateDirectories: true)
        try Data("nvram").write(to: aux.appending(path: "contents"))
        let copy = try cloneVM(paths, "sequoia", "copy")
        #expect(Data(contentsOf: copy.appending(path: "Disk.img")).count == 2 * 1024 * 1024)
        #expect(Data(contentsOf: copy.appending(path: "HardwareModel")) == Data("hw".utf8))
        #expect(Data(contentsOf: copy.appending(path: "AuxiliaryStorage").appending(path: "contents")) == Data("nvram".utf8))
        #expect(isMacOSVM(copy))
    }

    @Test func launchRequestRoundTrip() throws {
        let paths = Paths(root: testDir("macos-request"))
        let request = MacOSLaunchRequest(
            kind: .install, image: "/tmp/UniversalMac.ipsw", mem: "8G", cpus: "4", disk: "80G", keep: true, name: "work"
        )
        #expect(MacOSLaunchRequest(text: request.text()) == request)
        try saveMacOSLaunchRequest(paths, request)
        #expect(takeMacOSLaunchRequest(paths) == request)
        #expect(takeMacOSLaunchRequest(paths) == nil)
        let summary = macosLaunchSummary(
            MacOSLaunchRequest(kind: .boot, vm: "sequoia"),
            paths: paths
        )
        #expect(summary.contains("not supported"))
        #expect(summary.contains("NAT"))
    }

    @Test func ipswSymlinkIsListedAsTheLink() throws {
        let fm = FileManager.default
        let root = testDir("ipsw-link")
        let paths = Paths(root: root)
        try fm.createDirectory(at: paths.searchDir, withIntermediateDirectories: true)
        let target = root.appending(path: "UniversalMac_15.2_24C101_Restore.ipsw")
        try Data("ipsw-bytes".utf8).write(to: target)
        let link = paths.searchDir.appending(path: "shortcut.ipsw")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let listed = listImagePaths(paths)
        #expect(listed.map(\.lastPathComponent) == ["shortcut.ipsw"])
        #expect(isSymlink(listed[0]))
        #expect(pathOpenedForBoot(listed[0]).lastPathComponent == target.lastPathComponent)
        let entries = listImageEntries(paths)
        #expect(entries[0].fileInfo == "macOS restore image")
        #expect(entries[0].path == listed[0])
        #expect(entries[0].sizeKB == diskKB(target))

        try removeImageEntry(listed[0])
        #expect(!fm.fileExists(atPath: link.path))
        #expect(try Data(contentsOf: target) == Data("ipsw-bytes".utf8))
    }

    /// A macOS throwaway keeps its gui-session marker until Keep or Discard
    /// finishes, so cleanup must not remove it the way it removes a crashed CLI scratch dir.
    @Test func cleanKeepsMacOSGUISessions() throws {
        let fm = FileManager.default
        let paths = Paths(root: testDir("macos-clean"))
        let scratch = paths.scratchRoot.appending(path: "mac", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("disk").write(to: scratch.appending(path: "Disk.img"))
        try "backend=vz\n".write(to: scratch.appending(path: "vm.conf"), atomically: true, encoding: .utf8)
        try saveThrowawayInfo(ThrowawayInfo(dir: scratch, imagePath: URL(filePath: "/tmp/a.ipsw"), defaultName: "mac", live: false))
        markThrowawayPending(scratch)

        let (n, _) = cleanLeftoverScratch(paths)
        #expect(n == 0)
        #expect(fm.fileExists(atPath: scratch.appending(path: "Disk.img").path))
        #expect(read(throwawayInfoFile(scratch)).contains("state=pending"))
    }

    @Test func sha1MatchesAppleDigest() throws {
        let url = testDir("sha1").appending(path: "abc")
        try Data("abc".utf8).write(to: url)
        #expect(try sha1OfFile(url) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(try fileMatchesChecksum(url, sha256: "", sha1: "A9993E364706816ABA3E25717850C26C9CD0D89D"))
        #expect(try !fileMatchesChecksum(url, sha256: "", sha1: "nope"))
    }

    @Test func controlSocketAcceptsStop() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "crab-vz-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let got = Box<String>()
        let server = VZControlServer()
        try server.start(at: dir.appending(path: "vz.sock").path) { got.append($0) }
        defer { server.stop() }
        var sent = false
        for _ in 0..<20 {
            if (try? sendVZCommand(dir, "stop")) != nil {
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(sent)
        #expect(got.all == ["stop"])
    }
}

@discardableResult
private func makeMacOSVM(_ root: URL, _ name: String, conf: String) -> URL {
    let dir = root.appending(path: name, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! Data("hw".utf8).write(to: dir.appending(path: "HardwareModel"))
    try! Data("id".utf8).write(to: dir.appending(path: "MachineIdentifier"))
    try! Data("disk".utf8).write(to: dir.appending(path: "Disk.img"))
    if !conf.isEmpty {
        try! conf.write(to: dir.appending(path: "vm.conf"), atomically: true, encoding: .utf8)
    }
    return dir
}
