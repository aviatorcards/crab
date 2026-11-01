import CryptoKit
import Foundation
import Testing
@testable import CrabKit

struct CatalogTests {
    @Test func filenames() {
        #expect(getFilename(distro: "openbsd", arch: "amd64", url: "https://x/7.6/amd64/install76.iso") == "openbsd-install76-amd64.iso")
        #expect(getFilename(distro: "fedora", arch: "arm64", url: "https://x/Fedora-Workstation-Live-aarch64-41.iso")
            == "Fedora-Workstation-Live-aarch64-41.iso")
    }

    @Test func catalogLinesRoundTrip() {
        let e = CatalogEntry(distro: "alpine", variant: "virt", version: "3.20.3", arch: "arm64", url: "https://x/a.iso", sha256: "ab", display: "")
        #expect(CatalogEntry(tsvLine: e.tsvLine) == e)
        #expect(CatalogEntry(tsvLine: "too\tfew") == nil)
    }

    @Test func alpineReleases() {
        let yaml = """
            ---
            -
              title: "Virtual"
              flavor: alpine-virt
              file: alpine-virt-3.20.3-aarch64.iso
              version: 3.20.3
              branch: v3.20
              sha256: aaa
            -
              flavor: alpine-standard
              file: alpine-standard-3.20.3-aarch64.iso
              version: 3.20.3
              branch: v3.20
              sha256: bbb
            -
              flavor: alpine-minirootfs
              file: alpine-minirootfs-3.20.3-aarch64.tar.gz
              version: 3.20.3
              branch: v3.20
              sha256: ccc
            """
        let entries = parseAlpineReleases(yaml, alpineArch: "aarch64", arch: "arm64")
        #expect(entries.map(\.variant) == ["standard", "virt"])
        #expect(entries[0].url == "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-standard-3.20.3-aarch64.iso")
    }

    @Test func ubuntuSums() {
        let sums = """
            111 *ubuntu-24.04.1-desktop-amd64.iso
            222 *ubuntu-24.04.2-desktop-amd64.iso
            333 *ubuntu-24.04.2-live-server-amd64.iso
            444 *ubuntu-24.04.2-wubi-amd64.iso
            """
        let entries = parseUbuntuSums(sums, base: "https://releases.ubuntu.com/24.04", dir: "24.04", arch: "amd64")
        #expect(entries.map(\.variant) == ["desktop", "server"])
        #expect(entries[0].sha256 == "222" && entries[0].version == "24.04.2" && entries[0].display == "window")
    }

    static let sumA = String(repeating: "a", count: 64)
    static let sumB = String(repeating: "b", count: 64)

    @Test func checksumFormats() {
        let text = """
            -----BEGIN PGP SIGNED MESSAGE-----
            Hash: SHA256

            SHA256 (Rocky-10.2-aarch64-boot.iso) = \(Self.sumA)
            \(Self.sumB)  debian-13.7.0-arm64-netinst.iso
            \(Self.sumA) *redox_demo_aarch64_2026-11-01_571_livedisk.iso.zst
            SHA256 (short.iso) = abc
            """
        #expect(parseChecksums(text) == [
            Checksum(file: "Rocky-10.2-aarch64-boot.iso", sum: Self.sumA),
            Checksum(file: "debian-13.7.0-arm64-netinst.iso", sum: Self.sumB),
            Checksum(file: "redox_demo_aarch64_2026-11-01_571_livedisk.iso.zst", sum: Self.sumA),
        ])
    }

    @Test func directoryIndexes() {
        let html = """
            <a href="../">../</a><a href="10/">10/</a><a href="9.4/">9.4/</a><a href="10.2/">10.2/</a>
            <a href='./15.0/'>15.0/</a><a href=8/>8/</a><a href="10.3-beta/">beta</a><a href="10/">dup</a>
            """
        #expect(versionDirs(html, components: 1) == ["10", "8"])
        #expect(versionDirs(html, components: 2) == ["15.0", "10.2", "9.4"])
        #expect(hrefs("<link href=https://a/b.css><a href=\"x\">") == ["https://a/b.css", "x"])
    }

    @Test func debianSums() {
        let sums = """
            \(Self.sumA)  debian-13.7.0-amd64-netinst.iso
            \(Self.sumB)  debian-edu-13.7.0-amd64-netinst.iso
            """
        let entries = parseDebianSums(sums, arch: "amd64")
        #expect(entries.map(\.version) == ["13.7.0"])
        #expect(entries[0].url == "https://cdimage.debian.org/debian-cd/13.7.0/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso")
    }

    @Test func freeBSDSums() {
        let sums = """
            SHA256 (FreeBSD-15.1-RELEASE-arm64-aarch64-bootonly.iso) = \(Self.sumA)
            SHA256 (FreeBSD-15.1-RELEASE-arm64-aarch64-bootonly.iso.xz) = \(Self.sumB)
            SHA256 (FreeBSD-15.1-RELEASE-arm64-aarch64-disc1.iso) = \(Self.sumB)
            """
        let entries = parseFreeBSDSums(sums, root: "https://x", version: "15.1", platform: "arm64-aarch64", arch: "arm64")
        #expect(entries.map(\.variant) == ["disc1", "bootonly"])
        #expect(entries[0].sha256 == Self.sumB && entries[0].url == "https://x/15.1/FreeBSD-15.1-RELEASE-arm64-aarch64-disc1.iso")
    }

    @Test func enterpriseLinuxSums() {
        let sums = """
            SHA256 (Rocky-10-latest-aarch64-minimal.iso) = \(Self.sumA)
            SHA256 (Rocky-10.2-aarch64-dvd1.iso) = \(Self.sumB)
            SHA256 (Rocky-10.2-aarch64-minimal.iso) = \(Self.sumA)
            """
        let entries = parseEnterpriseSums(sums, distro: "rocky", root: "https://r", prefix: "Rocky", linuxArch: "aarch64", arch: "arm64")
        #expect(entries.map(\.variant) == ["minimal", "dvd"])
        #expect(entries[0].version == "10.2" && entries[0].url == "https://r/10.2/isos/aarch64/Rocky-10.2-aarch64-minimal.iso")
    }

    @Test func archSums() {
        let sums = """
            \(Self.sumA)  archlinux-2026.11.01-x86_64.iso
            \(Self.sumA)  archlinux-x86_64.iso
            \(Self.sumB)  archlinux-bootstrap-2026.11.01-x86_64.tar.zst
            """
        let entries = parseArchSums(sums, root: "https://a/iso")
        #expect(entries.map(\.url) == ["https://a/iso/2026.11.01/archlinux-2026.11.01-x86_64.iso"])
    }

    @Test func openSUSESum() {
        let sums = "\(Self.sumA)  openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso\n"
        let entry = parseOpenSUSESum(sums, base: "https://o", variant: "net", arch: "arm64")
        #expect(entry?.version == "20261020")
        #expect(entry?.url == "https://o/openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso")
    }

    @Test func nicheOSIndexes() throws {
        let redox = parseRedoxSums("""
            \(Self.sumA) *redox_demo_x86_64_2026-10-14_553_harddrive.img.zst
            \(Self.sumB) *redox_desktop_x86_64_2026-10-14_553_livedisk.iso.zst
            """, base: "https://r", redoxArch: "x86_64", arch: "amd64")
        #expect(redox.map(\.variant) == ["desktop"])
        #expect(redox[0].version == "2026-10-14" && redox[0].display == "window")

        #expect(haikuRelease("<a href=https://haiku-release.cdn.haiku-os.org/r1beta6/haiku-r1beta6-x86_64.torrent>t</a>") == "r1beta6")

        let nine = parse9frontIndex("""
            <a href="9front-11900.amd64.iso.gz">a</a><a href="9front-11952.amd64.iso.gz">b</a>
            <a href="9front-11952.amd64.iso.gz.torrent">c</a><a href="9front-11952.arm64.qcow2.gz">d</a>
            """)
        #expect(nine.map(\.version) == ["11952"])
        #expect(nine[0].sha256.isEmpty)

        let zeal = try parseZealOSRelease("""
            {"assets": [
              {"name": "ZealOS-PublicDomain-BIOS-2025-11-10-02_56_42.iso", "browser_download_url": "https://g/bios.iso", "digest": "sha256:\(Self.sumA)"},
              {"name": "ZealOS-BSD2-UEFI-2025-11-10-02_56_42.iso", "browser_download_url": "https://g/uefi.iso", "digest": "sha256:\(Self.sumB)"}
            ]}
            """)
        #expect(zeal.map(\.variant) == ["uefi", "bios"])
        #expect(zeal[0].version == "2025-11-10" && zeal[0].sha256 == Self.sumB)
    }

    @Test func packedFilenames() {
        #expect(getFilename(distro: "redox", arch: "arm64", url: "https://r/redox_desktop_aarch64_2026-11-01_571_livedisk.iso.zst")
            == "redox_desktop_aarch64_2026-11-01_571_livedisk.iso")
        #expect(getFilename(distro: "9front", arch: "amd64", url: "https://9front.org/iso/9front-11952.amd64.iso.gz")
            == "9front-11952.amd64.iso")
        #expect(packing("https://x/a.iso") == nil)
    }

    @Test func everyDistroHasADefault() {
        #expect(Set(distros).count == distros.count)
        for d in distros {
            #expect(!defaultVariant(d).isEmpty, "\(d)")
        }
        #expect(distroDisplayName("opensuse") == "openSUSE Tumbleweed")
    }

    @Test func rssItems() {
        let xml = """
            <rss><channel><title>Feed</title>
            <item><title><![CDATA[Alpine 3.21]]></title><link>https://a</link><pubDate>Mon</pubDate></item>
            <item><title>No date</title><link>https://b</link></item>
            </channel></rss>
            """
        let items = parseRSS(xml)
        #expect(items == [
            RSSReleaseItem(title: "Alpine 3.21", link: "https://a", pubDate: "Mon"),
            RSSReleaseItem(title: "No date", link: "https://b", pubDate: ""),
        ])
    }

    @Test func mirrorSources() throws {
        let paths = Paths(root: testDir("mirror-sources"))
        let url = "https://cdn.openbsd.org/pub/OpenBSD/7.6/amd64/install76.iso"
        #expect(sourcesFor(paths, url) == [
            "https://mirrors.rit.edu/OpenBSD/7.6/amd64/install76.iso",
            "https://plug-mirror.rcac.purdue.edu/openbsd/7.6/amd64/install76.iso",
            url,
        ])
        _ = try removeMirrorMatching(paths, "purdue")
        #expect(sourcesFor(paths, url).count == 2)
    }
}

/// Downloads from a fake mirror on localhost.
struct DownloadTests {
    /// How the fake mirror answers.
    enum Serve {
        case full
        /// Send this many bytes, then go quiet.
        case stallAfter(Int)
        /// Send this many bytes, then hang up.
        case closeAfter(Int)
        /// A byte every 50ms.
        case trickle
    }

    static let limits = StallLimits(silence: 0.3, window: 0.3, minBytes: 1024)
    static let body: [UInt8] = (0..<300_000).map { UInt8($0 % 251) }

    var bodySHA: String {
        SHA256.hash(data: Data(Self.body)).map { String(format: "%02x", $0) }.joined()
    }

    /// An HTTP server on localhost that serves `body` (honouring Range) as `how` says.
    func serve(_ how: Serve) -> String {
        let body = Self.body
        let port = serveTCP { conn in
            var start = 0
            while let line = conn.readLine(), line != "\r\n" {
                let lower = line.lowercased()
                if lower.hasPrefix("range: bytes=") {
                    start = Int(lower.dropFirst("range: bytes=".count).trimmingCharacters(in: CharacterSet(charactersIn: "-\r\n "))) ?? 0
                }
            }
            let rest = body[start...]
            let status = start > 0 ? "206 Partial Content" : "200 OK"
            conn.write("HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(rest.count)\r\nConnection: close\r\n\r\n")
            switch how {
            case .full:
                conn.write(rest)
            case .stallAfter(let n):
                conn.write(rest.prefix(n))
                Thread.sleep(forTimeInterval: 3)
            case .closeAfter(let n):
                conn.write(rest.prefix(n))
            case .trickle:
                for b in rest {
                    if !conn.write([b]) { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        return "http://127.0.0.1:\(port)/image.iso"
    }

    func download(
        _ name: String,
        _ sources: [String],
        cancel: CancelFlag = CancelFlag(),
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async -> (dest: URL, result: Result<URL, CrabError>, notes: [String]) {
        let dest = testDir(name).appending(path: "image.iso")
        let notes = Box<String>()
        let result: Result<URL, CrabError>
        do {
            result = .success(try await downloadFrom(sources, sha256: bodySHA, dest: dest, limits: Self.limits, cancel: cancel) { event in
                switch event {
                case .note(let n): notes.append(n)
                case .progress(let done, _): onProgress(done)
                }
            })
        } catch {
            result = .failure(error)
        }
        return (dest, result, notes.all)
    }

    @Test func stalledMirrorFallsThroughAndResumes() async throws {
        let (dest, result, notes) = await download("stall", [serve(.stallAfter(100_000)), serve(.full)])
        #expect(try result.get() == dest)
        #expect(try Data(contentsOf: dest) == Data(Self.body))
        #expect(notes.contains { $0.contains("stalled (no data") }, "\(notes)")
    }

    @Test func tricklingMirrorCountsAsStalled() async throws {
        let (dest, result, notes) = await download("trickle", [serve(.trickle), serve(.full)])
        #expect(try Data(contentsOf: try result.get()) == Data(Self.body))
        #expect(notes.contains { $0.contains("stalled (only") }, "\(notes)")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func shortDownloadIsKeptForResuming() async throws {
        let (dest, result, notes) = await download("short", [serve(.closeAfter(70_000))])
        #expect(throws: CrabError.self) { try result.get() }
        #expect(notes.contains { $0.contains("couldn't get it") }, "\(notes)")
        let part = dest.deletingLastPathComponent().appending(path: "image.iso.part")
        #expect(try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int == 70_000)
    }

    @Test func noChecksumTakesACompleteDownload() async throws {
        let dest = testDir("unverified").appending(path: "image.iso")
        let notes = Box<String>()
        let got = try await downloadFrom([serve(.closeAfter(70_000)), serve(.full)], sha256: "", dest: dest,
                                         limits: Self.limits, cancel: CancelFlag()) { event in
            if case .note(let n) = event { notes.append(n) }
        }
        #expect(try Data(contentsOf: got) == Data(Self.body))
        #expect(notes.all.contains { $0.contains("isn't verified") }, "\(notes.all)")
    }

    @Test func unpacksGzip() throws {
        let dir = testDir("unpack")
        let plain = dir.appending(path: "image.iso")
        try Data(Self.body).write(to: plain)
        let gzip = try #require(findExecutable("gzip"))
        #expect(try runInheriting(gzip, ["-q", plain.path]) == 0)
        let archive = dir.appending(path: "image.iso.gz")
        #expect(!plain.isFile && archive.isFile)

        try unpack(archive, "gz", to: plain) { _ in }
        #expect(try Data(contentsOf: plain) == Data(Self.body))
        #expect(!archive.isFile)
        #expect(!dir.appending(path: "image.iso.unpacking").isFile)
    }

    @Test func cancelStopsAndKeepsThePartialFile() async throws {
        let cancel = CancelFlag()
        let (dest, result, notes) = await download("cancel", [serve(.full), serve(.full)], cancel: cancel) { done in
            if done > 0 {
                cancel.cancel()
            }
        }
        #expect { try result.get() } throws: { ($0 as? CrabError)?.message.contains("cancelled") == true }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().appending(path: "image.iso.part").path))
        // It didn't go on to the second source.
        #expect(notes.filter { $0.hasPrefix("Downloading") }.count == 1)
    }
}
