import Foundation
import Testing
@testable import CrabKit

struct ConfigTests {
    @Test func memSizes() {
        #expect(validMem("2G") && validMem("512M") && validMem("4096") && validMem("1g"))
        #expect(!validMem("") && !validMem("G") && !validMem("2T") && !validMem("2.5G"))
    }

    @Test func cpusAndPorts() {
        #expect(validCPUs("4") && !validCPUs("0") && !validCPUs("04") && !validCPUs("x"))
        #expect(validPort("0") && validPort("65535") && !validPort("65536") && !validPort("-1"))
    }

    @Test func diskSizes() {
        #expect(validDiskSize("20G", relative: false) && validDiskSize("1T", relative: false))
        #expect(!validDiskSize("+10G", relative: false) && validDiskSize("+10G", relative: true))
        #expect(!validDiskSize("20", relative: false) && !validDiskSize("0G", relative: false))
    }

    @Test func forwards() throws {
        #expect(Forward.parse("8080:80") == Forward(udp: false, host: 8080, guest: 80))
        #expect(Forward.parse("udp:5353:53") == Forward(udp: true, host: 5353, guest: 53))
        #expect(Forward.parse("tcp:1:2")?.description == "1:2")
        #expect(Forward.parse("80") == nil && Forward.parse("0:80") == nil)
        #expect(Forward.parse("sctp:1:2") == nil && Forward.parse("1:99999") == nil)

        let list = try Forward.parseList("8080:80, udp:5353:53")
        #expect(Forward.listToConf(list) == "8080:80,udp:5353:53")
        #expect(list[1].hostfwd == "udp:127.0.0.1:5353-:53")
        #expect(try Forward.parseList("0").isEmpty)
        #expect(throws: CrabError.self) { try Forward.parseList("8080") }
        #expect(Forward.listToConf([]) == "0")
    }

    @Test func searchDirSettings() throws {
        let root = testDir("search-dir")
        var paths = Paths(root: root)
        try "# comment\nsearch_dir=/old\nother=1\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        #expect(Paths(environment: ["VM_ROOT": root.path]).searchDir.path == "/old")
        try paths.saveSearchDir(URL(filePath: "/new"))
        #expect(read(paths.configFile) == "# comment\nsearch_dir=/new\nother=1\n")
        #expect(Paths(environment: ["VM_ROOT": root.path, "CRAB_SEARCH_DIR": "/env"]).searchDir.path == "/env")
    }

    @Test func isoVolumeLabels() throws {
        let dir = testDir("iso-label")
        var data = Data(count: 0x8000 + 2048)
        data.replaceSubrange(0x8000..<0x8006, with: [1] + Array("CD001".utf8))
        data.replaceSubrange((0x8000 + 40)..<(0x8000 + 72), with: Array("OpenBSD/amd64   7.6".utf8) + Array(repeating: 32, count: 13))
        let iso = dir.appending(path: "x.iso")
        try data.write(to: iso)
        #expect(fileBrief(iso) == "ISO 9660 CD-ROM filesystem data 'OpenBSD/amd64 7.6'")
        #expect(extractQuotedLabel(fileBrief(iso)) == "OpenBSD/amd64 7.6")
        #expect(isCDImage(iso) && isBSDImage(iso))
        #expect(detectArch(iso) == ["amd64"])
    }
}
