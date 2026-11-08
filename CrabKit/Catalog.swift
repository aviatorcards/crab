import CryptoKit
import Foundation

public struct CatalogEntry: Sendable, Hashable, Identifiable {
    public var distro: String
    public var variant: String
    public var version: String
    public var arch: String
    public var url: String
    public var sha256: String
    public var display: String
    /// SHA-1, for releases that publish that instead of SHA-256 (Apple's IPSWs).
    public var sha1: String
    public var id: String { "\(distro)/\(variant)/\(arch)/\(version)" }

    public init(distro: String, variant: String, version: String, arch: String, url: String, sha256: String, display: String, sha1: String = "") {
        self.distro = distro
        self.variant = variant
        self.version = version
        self.arch = arch
        self.url = url
        self.sha256 = sha256
        self.display = display
        self.sha1 = sha1
    }

    public var tsvLine: String {
        [distro, variant, version, arch, url, sha256, display, sha1].joined(separator: "\t")
    }

    public init?(tsvLine line: String) {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { return nil }
        self.init(
            distro: parts[0], variant: parts[1], version: parts[2], arch: parts[3], url: parts[4],
            sha256: parts[5], display: parts.count > 6 ? parts[6] : "",
            sha1: parts.count > 7 ? parts[7] : ""
        )
    }
}

let userAgent = "crab/0.1"

/// A session for small index fetches (15s connect / 60s total timeout).
let indexSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 60
    config.httpAdditionalHeaders = ["User-Agent": userAgent]
    return URLSession(configuration: config)
}()

func statusLine(_ code: Int) -> String {
    "HTTP \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))"
}

/// Fetches `url` as text, failing on non-2xx responses.
func fetchText(_ url: String, method: String = "GET") async throws(CrabError) -> String {
    guard let u = URL(string: url) else { throw CrabError("bad URL: \(url)") }
    var request = URLRequest(url: u)
    request.httpMethod = method
    do {
        let (data, response) = try await indexSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CrabError("\(statusLine(code)) for \(url)")
        }
        return String(decoding: data, as: UTF8.self)
    } catch let error as CrabError {
        throw error
    } catch {
        throw CrabError(error.localizedDescription)
    }
}

// MARK: - Release index parsers

private struct FedoraRelease: Decodable {
    var version: String?
    var arch: String?
    var link: String?
    var sha256: String?
}

func syncFedora() async throws(CrabError) -> [CatalogEntry] {
    let json = try await fetchText("https://getfedora.org/releases.json")
    guard let releases = try? JSONDecoder().decode([FedoraRelease].self, from: Data(json.utf8)) else {
        throw CrabError("couldn't parse Fedora's releases.json")
    }
    guard let maxVer = releases.compactMap({ r -> Int? in
        guard let v = r.version, !v.isEmpty, v.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(v)
    }).max() else {
        throw CrabError("no numeric fedora version found")
    }

    var items: [(Int, CatalogEntry)] = []
    for r in releases {
        guard let version = r.version, let archRaw = r.arch, let link = r.link, let sha256 = r.sha256 else { continue }
        guard version == String(maxVer), archRaw == "aarch64" || archRaw == "x86_64" else { continue }
        let (order, variant, display): (Int, String, String)
        if link.contains("Workstation-Live") {
            (order, variant, display) = (0, "workstation", "window")
        } else if link.contains("KDE-Desktop-Live") {
            (order, variant, display) = (1, "kde", "window")
        } else if link.contains("Server-dvd") {
            (order, variant, display) = (2, "server", "")
        } else if link.contains("Everything-netinst") {
            (order, variant, display) = (3, "netinst", "")
        } else {
            continue
        }
        items.append((order, CatalogEntry(
            distro: "fedora", variant: variant, version: version, arch: archRaw == "aarch64" ? "arm64" : "amd64",
            url: link, sha256: sha256, display: display
        )))
    }
    // A stable sort, so each variant keeps the index's arch order.
    return items.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
}

func syncAlpine() async throws(CrabError) -> [CatalogEntry] {
    var all: [CatalogEntry] = []
    for (a, arch) in [("aarch64", "arm64"), ("x86_64", "amd64")] {
        let yaml = try await fetchText("https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/\(a)/latest-releases.yaml")
        all += parseAlpineReleases(yaml, alpineArch: a, arch: arch)
    }
    return all
}

/// Parses the flat list of maps in Alpine's latest-releases.yaml, standard ISO first.
func parseAlpineReleases(_ yaml: String, alpineArch a: String, arch: String) -> [CatalogEntry] {
    var current: [String: String] = [:]
    var standard: [CatalogEntry] = []
    var rest: [CatalogEntry] = []

    func flush() {
        defer { current.removeAll() }
        guard let file = current["file"], let flavor = current["flavor"], let version = current["version"],
              let branch = current["branch"], let sha256 = current["sha256"] else { return }
        guard file.hasSuffix(".iso"), ["alpine-standard", "alpine-virt", "alpine-extended"].contains(flavor) else { return }
        let v = String(flavor.dropFirst("alpine-".count))
        let entry = CatalogEntry(
            distro: "alpine", variant: v, version: version, arch: arch,
            url: "https://dl-cdn.alpinelinux.org/alpine/\(branch)/releases/\(a)/\(file)",
            sha256: sha256, display: ""
        )
        if v == "standard" {
            standard.append(entry)
        } else {
            rest.append(entry)
        }
    }

    for line in yaml.lines {
        if line.hasPrefix("-") {
            flush()
        } else if line.hasPrefix("  "), let sep = line.range(of: ": ") {
            let k = line[line.index(line.startIndex, offsetBy: 2)..<sep.lowerBound]
            if !k.isEmpty && k.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) {
                current[String(k)] = line[sep.upperBound...].trimmed
            }
        }
    }
    flush()
    return standard + rest
}

func versionKey(_ s: String) -> [Int] {
    s.split(whereSeparator: { !$0.isASCIIDigit }).compactMap { Int($0) }
}

func syncUbuntu() async throws(CrabError) -> [CatalogEntry] {
    let meta = try await fetchText("https://changelogs.ubuntu.com/meta-release-lts")
    var curV = ""
    var supportedV = ""
    for line in meta.lines {
        if line.hasPrefix("Version:") {
            if let tok = line.dropFirst("Version:".count).split(whereSeparator: \.isWhitespace).first {
                curV = String(tok)
            }
        } else if line.trimmed == "Supported: 1" {
            supportedV = curV
        }
    }
    if supportedV.isEmpty {
        throw CrabError("no supported Ubuntu LTS found")
    }
    let dir = supportedV.split(separator: ".", omittingEmptySubsequences: false).prefix(2).joined(separator: ".")

    var entries: [CatalogEntry] = []
    for arch in ["amd64", "arm64"] {
        let base = arch == "amd64"
            ? "https://releases.ubuntu.com/\(dir)"
            : "https://cdimage.ubuntu.com/releases/\(dir)/release"
        let sums = try await fetchText("\(base)/SHA256SUMS")
        entries += parseUbuntuSums(sums, base: base, dir: dir, arch: arch)
    }
    return entries
}

/// The newest desktop and live-server ISOs listed in an Ubuntu SHA256SUMS file.
func parseUbuntuSums(_ sums: String, base: String, dir: String, arch: String) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    for kind in ["desktop", "live-server"] {
        let suffix = "-\(kind)-\(arch).iso"
        var best: (key: [Int], sum: String, file: String)?
        for line in sums.lines {
            guard let sep = line.range(of: " *") else { continue }
            let sum = line[..<sep.lowerBound].trimmed
            let file = String(line[sep.upperBound...])
            guard file.hasPrefix("ubuntu-"), file.hasSuffix(suffix),
                  file.count > "ubuntu-".count + suffix.count else { continue }
            let mid = file.dropFirst("ubuntu-".count).dropLast(suffix.count)
            guard mid.allSatisfy({ $0.isASCIIDigit || $0 == "." }) else { continue }
            let k = versionKey(file)
            if best == nil || !k.lexicographicallyPrecedes(best!.key) {
                best = (k, sum, file)
            }
        }
        if let best {
            let ver = String(best.file.dropFirst("ubuntu-".count).dropLast(suffix.count))
            entries.append(CatalogEntry(
                distro: "ubuntu", variant: kind == "desktop" ? "desktop" : "server", version: ver.isEmpty ? dir : ver,
                arch: arch, url: "\(base)/\(best.file)", sha256: best.sum, display: kind == "desktop" ? "window" : ""
            ))
        }
    }
    return entries
}

/// Every `href` value in an HTML page, quoted or not (minified pages drop the quotes).
func hrefs(_ html: String) -> [String] {
    var out: [String] = []
    var rest = html[...]
    while let start = rest.range(of: "href=") {
        rest = rest[start.upperBound...]
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { break }
            out.append(String(rest[..<end]))
            rest = rest[rest.index(after: end)...]
        } else {
            let value = rest.prefix { !$0.isWhitespace && $0 != ">" }
            if !value.isEmpty {
                out.append(String(value))
            }
            rest = rest[value.endIndex...]
        }
    }
    return out
}

/// Version directories (`15.1/`, `10/`) in an HTML directory index that have
/// exactly `components` dot-separated numbers, newest first.
func versionDirs(_ html: String, components: Int) -> [String] {
    var seen = Set<String>()
    let versions = hrefs(html).compactMap { href -> String? in
        let h = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
        guard h.hasSuffix("/") else { return nil }
        let ver = String(h.dropLast())
        let parts = ver.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == components, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              seen.insert(ver).inserted else { return nil }
        return ver
    }
    return versions.sorted { versionKey($1).lexicographicallyPrecedes(versionKey($0)) }
}

struct Checksum: Equatable {
    var file: String
    var sum: String
}

/// The SHA-256 sums in a checksum file, in either the GNU (`<sum>  <file>`,
/// `<sum> *<file>`) or the BSD (`SHA256 (<file>) = <sum>`) format. Other
/// lines, such as a PGP signature wrapper, are skipped.
func parseChecksums(_ text: String) -> [Checksum] {
    text.lines.compactMap { line in
        let l = line.trimmed
        if l.hasPrefix("SHA256 ("), let close = l.range(of: ") = ") {
            let file = l[l.index(l.startIndex, offsetBy: "SHA256 (".count)..<close.lowerBound]
            let sum = l[close.upperBound...].trimmed
            return sum.count == 64 ? Checksum(file: String(file), sum: sum) : nil
        }
        let parts = l.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { return nil }
        var file = parts[1].trimmed
        if file.hasPrefix("*") {
            file.removeFirst()
        }
        return Checksum(file: file, sum: String(parts[0]))
    }
}

func isDottedNumber<S: StringProtocol>(_ s: S) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isASCIIDigit || $0 == "." }
}

func syncOpenBSD() async throws(CrabError) -> [CatalogEntry] {
    let index = try await fetchText("https://cdn.openbsd.org/pub/OpenBSD/")
    let versions = versionDirs(index, components: 2).prefix(3)

    var entries: [CatalogEntry] = []
    for arch in ["arm64", "amd64"] {
        // The newest release that has an installer up for this arch.
        for v in versions {
            let shortV = v.replacingOccurrences(of: ".", with: "")
            let file = arch == "arm64" ? "install\(shortV).img" : "install\(shortV).iso"
            guard let sums = try? await fetchText("https://cdn.openbsd.org/pub/OpenBSD/\(v)/\(arch)/SHA256") else {
                continue
            }
            if let c = parseChecksums(sums).first(where: { $0.file == file }) {
                entries.append(CatalogEntry(
                    distro: "openbsd", variant: "install", version: v, arch: arch,
                    url: "https://cdn.openbsd.org/pub/OpenBSD/\(v)/\(arch)/\(file)", sha256: c.sum, display: ""
                ))
                break
            }
        }
    }
    return entries
}

func syncDebian() async throws(CrabError) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    for arch in ["arm64", "amd64"] {
        let sums = try await fetchText("https://cdimage.debian.org/debian-cd/current/\(arch)/iso-cd/SHA256SUMS")
        entries += parseDebianSums(sums, arch: arch)
    }
    return entries
}

/// The netinst ISO in a Debian SHA256SUMS file. It's linked through its
/// version's directory rather than `current/`, which moves on each point release.
func parseDebianSums(_ sums: String, arch: String) -> [CatalogEntry] {
    let suffix = "-\(arch)-netinst.iso"
    return parseChecksums(sums).compactMap { c in
        guard c.file.hasPrefix("debian-"), c.file.hasSuffix(suffix) else { return nil }
        let ver = c.file.dropFirst("debian-".count).dropLast(suffix.count)
        guard isDottedNumber(ver) else { return nil }
        return CatalogEntry(
            distro: "debian", variant: "netinst", version: String(ver), arch: arch,
            url: "https://cdimage.debian.org/debian-cd/\(ver)/\(arch)/iso-cd/\(c.file)", sha256: c.sum, display: ""
        )
    }
}

func syncFreeBSD() async throws(CrabError) -> [CatalogEntry] {
    let root = "https://download.freebsd.org/releases/ISO-IMAGES"
    let versions = versionDirs(try await fetchText("\(root)/"), components: 2).prefix(3)

    var entries: [CatalogEntry] = []
    for arch in ["arm64", "amd64"] {
        let platform = arch == "arm64" ? "arm64-aarch64" : "amd64"
        // The newest release with ISOs up for this arch: a release's directory
        // can appear before its images do.
        for v in versions {
            guard let sums = try? await fetchText("\(root)/\(v)/CHECKSUM.SHA256-FreeBSD-\(v)-RELEASE-\(platform)") else {
                continue
            }
            let found = parseFreeBSDSums(sums, root: root, version: v, platform: platform, arch: arch)
            if !found.isEmpty {
                entries += found
                break
            }
        }
    }
    return entries
}

/// The disc1 and bootonly ISOs in a FreeBSD `CHECKSUM.SHA256-*` file.
func parseFreeBSDSums(_ sums: String, root: String, version: String, platform: String, arch: String) -> [CatalogEntry] {
    let all = parseChecksums(sums)
    return ["disc1", "bootonly"].compactMap { kind in
        let file = "FreeBSD-\(version)-RELEASE-\(platform)-\(kind).iso"
        guard let c = all.first(where: { $0.file == file }) else { return nil }
        return CatalogEntry(
            distro: "freebsd", variant: kind, version: version, arch: arch,
            url: "\(root)/\(version)/\(file)", sha256: c.sum, display: ""
        )
    }
}

/// Rocky Linux and AlmaLinux lay out their ISOs the same way, under
/// `<root>/<major>/isos/<arch>/CHECKSUM`.
func syncEnterpriseLinux(distro: String, root: String, prefix: String) async throws(CrabError) -> [CatalogEntry] {
    let majors = versionDirs(try await fetchText("\(root)/"), components: 1).prefix(2)

    var entries: [CatalogEntry] = []
    for (a, arch) in [("aarch64", "arm64"), ("x86_64", "amd64")] {
        for major in majors {
            guard let sums = try? await fetchText("\(root)/\(major)/isos/\(a)/CHECKSUM") else { continue }
            let found = parseEnterpriseSums(sums, distro: distro, root: root, prefix: prefix, linuxArch: a, arch: arch)
            if !found.isEmpty {
                entries += found
                break
            }
        }
    }
    return entries
}

/// The minimal, boot and DVD ISOs in a Rocky or AlmaLinux CHECKSUM file. It
/// takes the versioned names (`Rocky-10.2-aarch64-minimal.iso`) and links
/// them through their point release's directory, skipping the `-latest-`
/// aliases, which change with each point release.
func parseEnterpriseSums(
    _ sums: String, distro: String, root: String, prefix: String, linuxArch a: String, arch: String
) -> [CatalogEntry] {
    let all = parseChecksums(sums)
    return ["minimal", "boot", "dvd"].compactMap { variant in
        for c in all where c.file.hasPrefix("\(prefix)-") && c.file.hasSuffix(".iso") {
            let parts = c.file.dropFirst(prefix.count + 1).dropLast(".iso".count).split(separator: "-")
            guard parts.count == 3, parts[0].contains("."), isDottedNumber(parts[0]), parts[1] == a,
                  parts[2] == variant || parts[2] == "\(variant)1" else { continue }
            return CatalogEntry(
                distro: distro, variant: variant, version: String(parts[0]), arch: arch,
                url: "\(root)/\(parts[0])/isos/\(a)/\(c.file)", sha256: c.sum, display: ""
            )
        }
        return nil
    }
}

func syncArch() async throws(CrabError) -> [CatalogEntry] {
    let root = "https://geo.mirror.pkgbuild.com/iso"
    return parseArchSums(try await fetchText("\(root)/latest/sha256sums.txt"), root: root)
}

/// The dated live ISO in Arch's sha256sums.txt, linked through its date's
/// directory. Arch only builds for x86_64.
func parseArchSums(_ sums: String, root: String) -> [CatalogEntry] {
    let suffix = "-x86_64.iso"
    for c in parseChecksums(sums) where c.file.hasPrefix("archlinux-") && c.file.hasSuffix(suffix) {
        let date = c.file.dropFirst("archlinux-".count).dropLast(suffix.count)
        guard isDottedNumber(date) else { continue }
        return [CatalogEntry(
            distro: "arch", variant: "live", version: String(date), arch: "amd64",
            url: "\(root)/\(date)/\(c.file)", sha256: c.sum, display: ""
        )]
    }
    return []
}

func syncOpenSUSE() async throws(CrabError) -> [CatalogEntry] {
    let bases = [
        ("aarch64", "arm64", "https://download.opensuse.org/ports/aarch64/tumbleweed/iso"),
        ("x86_64", "amd64", "https://download.opensuse.org/tumbleweed/iso"),
    ]
    var entries: [CatalogEntry] = []
    for (a, arch, base) in bases {
        for (kind, variant) in [("NET", "net"), ("DVD", "dvd")] {
            let sums = try await fetchText("\(base)/openSUSE-Tumbleweed-\(kind)-\(a)-Current.iso.sha256")
            if let entry = parseOpenSUSESum(sums, base: base, variant: variant, arch: arch) {
                entries.append(entry)
            }
        }
    }
    return entries
}

/// A Tumbleweed `-Current.iso.sha256` file names the snapshot ISO that
/// `Current` points at, and that's the one linked to. Tumbleweed only keeps
/// recent snapshots, so an old catalog's link stops working; syncing fixes it.
func parseOpenSUSESum(_ sums: String, base: String, variant: String, arch: String) -> CatalogEntry? {
    guard let c = parseChecksums(sums).first(where: { $0.file.hasSuffix(".iso") }),
          let snap = c.file.range(of: "-Snapshot") else { return nil }
    let version = c.file[snap.upperBound...].prefix(while: \.isASCIIDigit)
    guard !version.isEmpty else { return nil }
    return CatalogEntry(
        distro: "opensuse", variant: variant, version: String(version), arch: arch,
        url: "\(base)/\(c.file)", sha256: c.sum, display: ""
    )
}

func syncRedox() async throws(CrabError) -> [CatalogEntry] {
    var entries: [CatalogEntry] = []
    for (a, arch) in [("aarch64", "arm64"), ("x86_64", "amd64")] {
        let base = "https://static.redox-os.org/img/\(a)"
        entries += parseRedoxSums(try await fetchText("\(base)/SHA256SUM"), base: base, redoxArch: a, arch: arch)
    }
    return entries
}

/// The zstd-packed live disks in a Redox SHA256SUM file. These are Redox's
/// daily builds: its last numbered release (0.9.0) predates its aarch64
/// images, and old dailies are removed, so an old catalog's links stop working.
func parseRedoxSums(_ sums: String, base: String, redoxArch a: String, arch: String) -> [CatalogEntry] {
    let all = parseChecksums(sums)
    return ["desktop", "server", "demo"].compactMap { variant in
        let prefix = "redox_\(variant)_\(a)_"
        guard let c = all.first(where: { $0.file.hasPrefix(prefix) && $0.file.hasSuffix("_livedisk.iso.zst") }) else {
            return nil
        }
        // redox_desktop_aarch64_2026-11-01_571_livedisk.iso.zst
        let date = c.file.dropFirst(prefix.count).prefix { $0.isASCIIDigit || $0 == "-" }
        return CatalogEntry(
            distro: "redox", variant: variant, version: String(date), arch: arch,
            url: "\(base)/\(c.file)", sha256: c.sum, display: variant == "server" ? "" : "window"
        )
    }
}

func syncHaiku() async throws(CrabError) -> [CatalogEntry] {
    guard let release = haikuRelease(try await fetchText("https://www.haiku-os.org/get-haiku/")) else {
        throw CrabError("no Haiku release found on its download page")
    }
    let base = "https://haiku-release.cdn.haiku-os.org/\(release)"
    let file = "haiku-\(release)-x86_64-anyboot.iso"
    guard let c = parseChecksums(try await fetchText("\(base)/\(file).sha256")).first(where: { $0.file == file }) else {
        return []
    }
    return [CatalogEntry(
        distro: "haiku", variant: "anyboot", version: release, arch: "amd64",
        url: "\(base)/\(file)", sha256: c.sum, display: "window"
    )]
}

/// The current release on Haiku's download page, from its links to the
/// release CDN (which has no directory index of its own).
func haikuRelease(_ html: String) -> String? {
    let prefix = "https://haiku-release.cdn.haiku-os.org/"
    for href in hrefs(html) where href.hasPrefix(prefix) {
        let release = href.dropFirst(prefix.count).prefix { $0 != "/" }
        if !release.isEmpty && release.count < href.count - prefix.count {
            return String(release)
        }
    }
    return nil
}

func sync9front() async throws(CrabError) -> [CatalogEntry] {
    parse9frontIndex(try await fetchText("https://9front.org/iso/"))
}

/// The newest gzipped amd64 ISO in 9front's download directory. 9front
/// publishes no checksums, so the entry has none and the download is unverified.
func parse9frontIndex(_ html: String) -> [CatalogEntry] {
    let suffix = ".amd64.iso.gz"
    var best: (rev: Int, file: String)?
    for href in hrefs(html) where href.hasPrefix("9front-") && href.hasSuffix(suffix) {
        guard let rev = Int(href.dropFirst("9front-".count).dropLast(suffix.count)) else { continue }
        if best == nil || rev > best!.rev {
            best = (rev, href)
        }
    }
    guard let best else { return [] }
    return [CatalogEntry(
        distro: "9front", variant: "live", version: String(best.rev), arch: "amd64",
        url: "https://9front.org/iso/\(best.file)", sha256: "", display: "window"
    )]
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var browser_download_url: String
        var digest: String?
    }
    var assets: [Asset]
}

func syncZealOS() async throws(CrabError) -> [CatalogEntry] {
    try parseZealOSRelease(try await fetchText("https://api.github.com/repos/Zeal-Operating-System/ZealOS/releases/latest"))
}

/// The UEFI and BIOS ISOs in ZealOS's latest GitHub release, checked
/// against the SHA-256 digests GitHub gives for release assets.
func parseZealOSRelease(_ json: String) throws(CrabError) -> [CatalogEntry] {
    guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8)) else {
        throw CrabError("couldn't parse ZealOS's release list")
    }
    let kinds: [(variant: String, marker: String)] = [("uefi", "-UEFI-"), ("bios", "-BIOS-")]
    return kinds.compactMap { kind in
        guard let asset = release.assets.first(where: {
                  $0.name.hasPrefix("ZealOS-") && $0.name.contains(kind.marker) && $0.name.hasSuffix(".iso")
              }),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              let built = asset.name.range(of: kind.marker) else { return nil }
        // Named for when it was built: ZealOS-BSD2-UEFI-2025-11-10-02_56_42.iso
        let date = asset.name[built.upperBound...].prefix(10)
        return CatalogEntry(
            distro: "zealos", variant: kind.variant, version: String(date), arch: "amd64",
            url: asset.browser_download_url, sha256: String(digest.dropFirst("sha256:".count)), display: "window"
        )
    }
}

// MARK: - Distros

/// A distro `crab get` knows about, and how to find its current releases.
public struct DistroSource: Sendable {
    public let name: String
    public let displayName: String
    public let defaultVariant: String
    let sync: @Sendable () async throws(CrabError) -> [CatalogEntry]
}

/// The distros in the catalog, in the order they're listed.
func syncMacOS() async throws(CrabError) -> [CatalogEntry] {
    // Apple's feed has the current image; the history list has the older
    // ones. Either is enough on its own.
    async let appleText = try? await fetchText(macosIPSWCatalogURL)
    async let historyText = try? await fetchText(macosIPSWHistoryURL)
    let apple = await appleText.map { parseMacOSIPSWCatalog(Data($0.utf8)) } ?? []
    let history = await historyText.map { parseIPSWHistory(Data($0.utf8)) } ?? []
    let assets = mergeMacOSAssets(apple: apple, history: history)
    if assets.isEmpty {
        throw CrabError("couldn't find any restore image for \(macosVirtualMachineModel)")
    }
    return macOSCatalogEntries(assets)
}

public let distroSources: [DistroSource] = [
    DistroSource(name: macosDistro, displayName: "macOS", defaultVariant: macosVariant, sync: syncMacOS),
    DistroSource(name: "fedora", displayName: "Fedora", defaultVariant: "workstation", sync: syncFedora),
    DistroSource(name: "ubuntu", displayName: "Ubuntu", defaultVariant: "desktop", sync: syncUbuntu),
    DistroSource(name: "debian", displayName: "Debian", defaultVariant: "netinst", sync: syncDebian),
    DistroSource(name: "alpine", displayName: "Alpine", defaultVariant: "standard", sync: syncAlpine),
    DistroSource(name: "arch", displayName: "Arch Linux", defaultVariant: "live", sync: syncArch),
    DistroSource(name: "opensuse", displayName: "openSUSE Tumbleweed", defaultVariant: "net", sync: syncOpenSUSE),
    DistroSource(name: "rocky", displayName: "Rocky Linux", defaultVariant: "minimal") { () async throws(CrabError) in
        try await syncEnterpriseLinux(distro: "rocky", root: "https://download.rockylinux.org/pub/rocky", prefix: "Rocky")
    },
    DistroSource(name: "almalinux", displayName: "AlmaLinux", defaultVariant: "minimal") { () async throws(CrabError) in
        try await syncEnterpriseLinux(distro: "almalinux", root: "https://repo.almalinux.org/almalinux", prefix: "AlmaLinux")
    },
    DistroSource(name: "freebsd", displayName: "FreeBSD", defaultVariant: "disc1", sync: syncFreeBSD),
    DistroSource(name: "openbsd", displayName: "OpenBSD", defaultVariant: "install", sync: syncOpenBSD),
    DistroSource(name: "haiku", displayName: "Haiku", defaultVariant: "anyboot", sync: syncHaiku),
    DistroSource(name: "redox", displayName: "Redox", defaultVariant: "desktop", sync: syncRedox),
    DistroSource(name: "9front", displayName: "9front", defaultVariant: "live", sync: sync9front),
    DistroSource(name: "zealos", displayName: "ZealOS", defaultVariant: "uefi", sync: syncZealOS),
]

public let distros = distroSources.map(\.name)

public func distroDisplayName(_ distro: String) -> String {
    distroSources.first { $0.name == distro }?.displayName ?? distro.capitalized
}

public func defaultVariant(_ distro: String) -> String {
    distroSources.first { $0.name == distro }?.defaultVariant ?? ""
}

// MARK: - Catalog file

public func loadCatalog(_ paths: Paths) -> [CatalogEntry] {
    guard let content = try? String(contentsOf: paths.catalog, encoding: .utf8) else { return [] }
    return content.lines.compactMap(CatalogEntry.init(tsvLine:))
}

/// Refreshes `~/VMs/.catalog` from each distro's official index, keeping the
/// old entries for any distro that can't be reached. Prints progress.
public func cmdSync(_ paths: Paths) async throws(CrabError) {
    do {
        try FileManager.default.createDirectory(at: paths.vmRoot, withIntermediateDirectories: true)
    } catch {
        throw CrabError("failed to create \(paths.vmRoot.path): \(error.localizedDescription)")
    }
    let existing = loadCatalog(paths)
    var newEntries: [CatalogEntry] = []

    print("Checking current releases...")
    // Check every distro at once, then report them in order.
    let found = await withTaskGroup(of: (String, [CatalogEntry]?).self) { group in
        for d in distroSources {
            group.addTask { (d.name, try? await d.sync()) }
        }
        var found: [String: [CatalogEntry]] = [:]
        for await (name, list) in group {
            found[name] = list
        }
        return found
    }

    for d in distros {
        print("  \(d.padded(10)) ", terminator: "")
        if let list = found[d], !list.isEmpty {
            if d == macosDistro {
                // Every build Apple has published; name the newest of each major.
                let shown = newestMacOSPerMajor(list).map(\.version)
                print(shown.joined(separator: " ") + " (\(list.count) builds) ")
            } else {
                print(Set(list.map(\.version)).sorted().joined(separator: " ") + " ")
            }
            newEntries += list
        } else {
            print("couldn't check; keeping what the catalog had")
            newEntries += existing.filter { $0.distro == d }
        }
    }

    let out = newEntries.map { $0.tsvLine + "\n" }.joined()
    do {
        try out.write(to: paths.catalog, atomically: true, encoding: .utf8)
    } catch {
        throw CrabError("failed to write catalog \(paths.catalog.path): \(error.localizedDescription)")
    }
}

public func ensureCatalog(_ paths: Paths) async throws(CrabError) {
    if !paths.catalog.isFile {
        try await cmdSync(paths)
    } else if fileMtime(paths.catalog) < nowSecs() - catalogMaxAgeDays * 86400 {
        print("The release list is over \(catalogMaxAgeDays) days old; refreshing it.")
        if (try? await cmdSync(paths)) == nil {
            print("Couldn't refresh it; using the old one.")
        }
    }
    print()
}

/// How a release's file is packed, from its URL: `gz`, `zst`, or nil for a
/// plain image.
func packing(_ url: String) -> String? {
    ["gz", "zst"].first { url.lowercased().hasSuffix(".\($0)") }
}

/// The local file name for a download: the URL's, without any `.gz`/`.zst`
/// (it's unpacked), and with the distro and arch added if they aren't in it already.
public func getFilename(distro: String, arch: String, url: String) -> String {
    // Keep Apple's own name (UniversalMac_15.2_24C101_Restore.ipsw). The file
    // is an installer, not a disk image, and the name already says what it is.
    if distro == macosDistro {
        return url.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "macOS.ipsw"
    }
    var file = url.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "image.iso"
    if let ext = packing(file) {
        file = String(file.dropLast(ext.count + 1))
    }
    if !file.lowercased().contains(distro) {
        file = "\(distro)-\(file)"
    }
    if archFromName(file) == nil {
        if let dot = file.lastIndex(of: ".") {
            file = "\(file[..<dot])-\(arch)\(file[dot...])"
        } else {
            file = "\(file)-\(arch)"
        }
    }
    return file
}

// MARK: - Mirrors

public struct MirrorRule: Sendable, Hashable {
    public var official: String
    public var mirror: String

    public init(_ official: String, _ mirror: String) {
        self.official = official
        self.mirror = mirror
    }
}

public let defaultMirrorRules: [MirrorRule] = [
    MirrorRule("https://download.fedoraproject.org/pub/fedora/", "https://mirrors.rit.edu/fedora/fedora/"),
    MirrorRule("https://download.fedoraproject.org/pub/fedora/", "https://plug-mirror.rcac.purdue.edu/fedora/fedora/"),
    MirrorRule("https://dl-cdn.alpinelinux.org/alpine/", "https://plug-mirror.rcac.purdue.edu/alpine/"),
    MirrorRule("https://releases.ubuntu.com/", "https://mirrors.rit.edu/ubuntu-releases/"),
    MirrorRule("https://releases.ubuntu.com/", "https://plug-mirror.rcac.purdue.edu/ubuntu-releases/"),
    MirrorRule("https://cdimage.ubuntu.com/", "https://mirrors.rit.edu/ubuntu-cdimage/"),
    MirrorRule("https://cdn.openbsd.org/pub/OpenBSD/", "https://mirrors.rit.edu/OpenBSD/"),
    MirrorRule("https://cdn.openbsd.org/pub/OpenBSD/", "https://plug-mirror.rcac.purdue.edu/openbsd/"),
    MirrorRule("https://cdimage.debian.org/debian-cd/", "https://plug-mirror.rcac.purdue.edu/debian-cd/"),
    MirrorRule("https://download.freebsd.org/", "https://mirrors.rit.edu/FreeBSD/"),
    MirrorRule("https://download.rockylinux.org/pub/rocky/", "https://mirrors.rit.edu/rocky/"),
    MirrorRule("https://download.rockylinux.org/pub/rocky/", "https://plug-mirror.rcac.purdue.edu/rocky/"),
    MirrorRule("https://repo.almalinux.org/almalinux/", "https://mirrors.rit.edu/almalinux/"),
    MirrorRule("https://repo.almalinux.org/almalinux/", "https://plug-mirror.rcac.purdue.edu/almalinux/"),
    MirrorRule("https://geo.mirror.pkgbuild.com/", "https://mirrors.rit.edu/archlinux/"),
    MirrorRule("https://geo.mirror.pkgbuild.com/", "https://plug-mirror.rcac.purdue.edu/archlinux/"),
    MirrorRule("https://download.opensuse.org/tumbleweed/", "https://plug-mirror.rcac.purdue.edu/opensuse/tumbleweed/"),
]

public func mirrorRules(_ paths: Paths) -> [MirrorRule] {
    guard paths.mirrorsFile.isFile, let content = try? String(contentsOf: paths.mirrorsFile, encoding: .utf8) else {
        return defaultMirrorRules
    }
    return content.lines.compactMap { line in
        let trimmed = line.trimmed
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return nil
        }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        return parts.count >= 2 ? MirrorRule(String(parts[0]), String(parts[1])) : nil
    }
}

public func normalizeMirrorBase(_ input: String) -> String {
    var trimmed = input.trimmed
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
}

/// Probes a mirror root (e.g. `https://mirrors.rit.edu` or `mirrors.example.edu`) by parsing its
/// top-level HTML directory index (and checking well-known paths) to discover which official distro
/// prefixes it mirrors.
public func probeMirrorSite(_ siteInput: String) async throws(CrabError) -> [MirrorRule] {
    let base = normalizeMirrorBase(siteInput)
    let indexHTML = (try? await fetchText("\(base)/")) ?? ""

    var dirs = Set<String>()
    for href in hrefs(indexHTML) where href.hasSuffix("/") {
        let name = String(href.dropLast())
        if !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") {
            dirs.insert(name)
        }
    }

    func exists(_ url: String) async -> Bool {
        if (try? await fetchText(url, method: "HEAD")) != nil {
            return true
        }
        return (try? await fetchText(url)) != nil
    }

    /// Whether the mirror has a top-level `dir`, from its index or by asking.
    func has(_ dir: String) async -> Bool {
        if dirs.contains(dir) {
            return true
        }
        return await exists("\(base)/\(dir)/")
    }

    var discovered: [MirrorRule] = []

    if await has("fedora") {
        if await exists("\(base)/fedora/fedora/linux/") {
            discovered.append(MirrorRule("https://download.fedoraproject.org/pub/fedora/", "\(base)/fedora/fedora/"))
        } else if await exists("\(base)/fedora/linux/") {
            discovered.append(MirrorRule("https://download.fedoraproject.org/pub/fedora/", "\(base)/fedora/"))
        }
    }

    // Official prefixes, and the directory names mirrors tend to keep them under.
    let trees: [(official: String, dirs: [String])] = [
        ("https://dl-cdn.alpinelinux.org/alpine/", ["alpine"]),
        ("https://releases.ubuntu.com/", ["ubuntu-releases", "ubuntu"]),
        ("https://cdimage.ubuntu.com/", ["ubuntu-cdimage"]),
        ("https://cdn.openbsd.org/pub/OpenBSD/", ["OpenBSD", "openbsd"]),
        ("https://cdimage.debian.org/debian-cd/", ["debian-cd"]),
        ("https://download.freebsd.org/", ["FreeBSD", "freebsd"]),
        ("https://download.rockylinux.org/pub/rocky/", ["rocky"]),
        ("https://repo.almalinux.org/almalinux/", ["almalinux"]),
        ("https://geo.mirror.pkgbuild.com/", ["archlinux"]),
        ("https://download.opensuse.org/", ["opensuse"]),
    ]
    for tree in trees {
        for cand in tree.dirs {
            if await has(cand) {
                discovered.append(MirrorRule(tree.official, "\(base)/\(cand)/"))
                break
            }
        }
    }

    if discovered.isEmpty {
        throw CrabError("couldn't auto-detect any known distro trees on \(base) (you can pass an explicit 'OFFICIAL_PREFIX MIRROR_PREFIX' pair)")
    }
    return discovered
}

public func saveMirrorRules(_ paths: Paths, _ rules: [MirrorRule]) throws {
    try FileManager.default.createDirectory(at: paths.vmRoot, withIntermediateDirectories: true)
    var out = "# crab mirror mappings (official_prefix mirror_prefix)\n"
    for r in rules {
        out += "\(r.official.padded(48)) \(r.mirror)\n"
    }
    try out.write(to: paths.mirrorsFile, atomically: true, encoding: .utf8)
}

/// Adds an explicit `official mirror` pair, or probes `arg1` as a mirror site
/// when `arg2` is nil. Returns the rules added.
public func addMirrorEntry(_ paths: Paths, _ arg1: String, _ arg2: String?) async throws(CrabError) -> [MirrorRule] {
    var rules = mirrorRules(paths)
    let added: [MirrorRule]
    if let mir = arg2 {
        let off = arg1.hasSuffix("/") ? arg1 : "\(arg1)/"
        let m = mir.hasSuffix("/") ? mir : "\(mir)/"
        added = [MirrorRule(off, m)]
    } else {
        print("Probing mirror \(arg1)...")
        added = try await probeMirrorSite(arg1)
    }
    for rule in added where !rules.contains(rule) {
        rules.append(rule)
    }
    do {
        try saveMirrorRules(paths, rules)
    } catch {
        throw CrabError("failed to save mirrors: \(error.localizedDescription)")
    }
    return added
}

/// Removes every rule whose official or mirror prefix contains `pattern`.
public func removeMirrorMatching(_ paths: Paths, _ pattern: String) throws(CrabError) -> Int {
    let rules = mirrorRules(paths)
    let kept = rules.filter { !$0.official.contains(pattern) && !$0.mirror.contains(pattern) }
    do {
        try saveMirrorRules(paths, kept)
    } catch {
        throw CrabError("failed to save mirrors: \(error.localizedDescription)")
    }
    return rules.count - kept.count
}

public func resetMirrors(_ paths: Paths) throws(CrabError) {
    guard paths.mirrorsFile.isFile else { return }
    do {
        try FileManager.default.removeItem(at: paths.mirrorsFile)
    } catch {
        throw CrabError(error.localizedDescription)
    }
}

// MARK: - RSS

public struct RSSReleaseItem: Sendable, Hashable {
    public var title: String
    public var link: String
    public var pubDate: String
}

public let defaultRSSFeed = "https://distrowatch.com/news/dwd.xml"

/// Fetches and parses an RSS feed (e.g. DistroWatch's ISO feed or a mirror's).
public func fetchRSSFeed(_ feedURL: String) async throws(CrabError) -> [RSSReleaseItem] {
    parseRSS(try await fetchText(feedURL))
}

func parseRSS(_ xml: String) -> [RSSReleaseItem] {
    xml.components(separatedBy: "<item").dropFirst().compactMap { chunk in
        let body = chunk.range(of: "</item>").map { String(chunk[..<$0.lowerBound]) } ?? chunk
        let title = extractXMLTag(body, "title") ?? ""
        guard !title.isEmpty else { return nil }
        return RSSReleaseItem(
            title: title,
            link: extractXMLTag(body, "link") ?? "",
            pubDate: extractXMLTag(body, "pubDate") ?? extractXMLTag(body, "dc:date") ?? ""
        )
    }
}

func extractXMLTag(_ xml: String, _ tag: String) -> String? {
    guard let open = xml.range(of: "<\(tag)>"),
          let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
        return nil
    }
    var raw = xml[open.upperBound..<close.lowerBound].trimmed
    if raw.hasPrefix("<![CDATA[") && raw.hasSuffix("]]>") {
        raw = String(raw.dropFirst("<![CDATA[".count).dropLast("]]>".count))
    }
    return raw.trimmed
}

public func cmdMirrors(_ paths: Paths, _ args: [String]) async throws(CrabError) {
    guard let action = args.first else {
        let source = paths.mirrorsFile.isFile
            ? "from \(paths.mirrorsFile.path)"
            : "built-in defaults (run 'crab mirrors add <host>' to customize)"
        print("Configured mirrors (\(source)):")
        for r in mirrorRules(paths) {
            print("  \(r.official.padded(46)) -> \(r.mirror)")
        }
        return
    }

    switch action {
    case "add":
        guard (2...3).contains(args.count) else {
            throw CrabError("usage: crab mirrors add <MIRROR_HOST_OR_URL>  OR  crab mirrors add <OFFICIAL_PREFIX> <MIRROR_PREFIX>")
        }
        for r in try await addMirrorEntry(paths, args[1], args.count > 2 ? args[2] : nil) {
            print("Added mirror rule: \(r.official) -> \(r.mirror)")
        }
    case "remove", "rm":
        guard args.count == 2 else {
            throw CrabError("usage: crab mirrors remove <HOST_OR_SUBSTRING>")
        }
        print("Removed \(try removeMirrorMatching(paths, args[1])) matching mirror rule(s).")
    case "reset":
        try resetMirrors(paths)
        print("Reset mirrors to built-in defaults.")
    case "rss":
        let url = args.count > 1 ? args[1] : defaultRSSFeed
        print("Fetching release RSS feed from \(url)...")
        for item in try await fetchRSSFeed(url).prefix(15) {
            if item.pubDate.isEmpty {
                print("  • \(item.title)  (\(item.link))")
            } else {
                print("  • [\(item.pubDate)] \(item.title)  (\(item.link))")
            }
        }
    default:
        throw CrabError("unknown mirrors action '\(action)' (try: crab mirrors [add|remove|reset|rss])")
    }
}

// MARK: - Downloads

/// The mirror URLs for `url`, in order, then `url` itself.
public func sourcesFor(_ paths: Paths, _ url: String) -> [String] {
    mirrorRules(paths).compactMap { r in
        url.hasPrefix(r.official) ? r.mirror + url.dropFirst(r.official.count) : nil
    } + [url]
}

public func sha256OfFile(_ url: URL) throws -> String {
    try hashFile(url, SHA256())
}

func hashFile<H: HashFunction>(_ url: URL, _ hasher: H) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = hasher
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func hostFromURL(_ url: String) -> String {
    guard let r = url.range(of: "://") else { return url }
    return String(url[r.upperBound...].prefix { $0 != "/" })
}

/// What `downloadImage` reports as it goes.
public enum DownloadEvent: Sendable {
    /// A status line: which source is being tried, why one was given up on, and so on.
    case note(String)
    /// Bytes of the file on disk so far, and its full size if the server said.
    case progress(done: Int64, total: Int64?)
}

/// When a source counts as stalled, so the download moves on to the next one.
public struct StallLimits: Sendable {
    /// No data at all for this long.
    public var silence: TimeInterval
    /// Or fewer than `minBytes` arriving in a `window`.
    public var window: TimeInterval
    public var minBytes: Int64

    public init(silence: TimeInterval, window: TimeInterval, minBytes: Int64) {
        self.silence = silence
        self.window = window
        self.minBytes = minBytes
    }

    public static let standard = StallLimits(silence: 30, window: 60, minBytes: 64 * 1024)
}

/// A flag the GUI sets to stop a download between chunks.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { value }
    }

    public func cancel() {
        lock.withLock { value = true }
    }
}

public typealias DownloadReport = @Sendable (DownloadEvent) -> Void

/// Downloads `file` into the search folder from the first source (mirrors,
/// then `url`) that gives a file matching `sum`. A partial download is kept
/// as `file.part` and resumed by the next source or the next attempt.
/// Setting `cancel` stops it between chunks. A `.gz` or `.zst` release is
/// checked as downloaded, then unpacked into `file`. An empty `sum` and
/// `sha1` means the release has no published checksum, so the download isn't
/// verified. macOS restore images pass Apple's SHA-1 in `sha1`.
public func downloadImage(
    _ paths: Paths,
    url: String,
    sha256 sum: String,
    file: String,
    dryRun: Bool,
    cancel: CancelFlag,
    report: DownloadReport,
    sha1: String = ""
) async throws(CrabError) -> URL {
    let dest = paths.searchDir.appending(path: file)
    let packed = packing(url)

    if dest.isFile {
        if sum.isEmpty && sha1.isEmpty {
            report(.note("Already downloaded: \(dest.path) (there's no published checksum to check it against)"))
            return dest
        }
        if packed != nil {
            // Only the packed file has a published checksum, and it's checked before unpacking.
            report(.note("Already downloaded: \(dest.path) (unpacked from a download that matched the checksum)"))
            return dest
        }
        let matches: Bool
        do {
            matches = try fileMatchesChecksum(dest, sha256: sum, sha1: sha1)
        } catch {
            throw CrabError(error.localizedDescription)
        }
        if matches {
            report(.note("Already downloaded: \(dest.path)"))
            return dest
        }
        throw CrabError("\(dest.path) is there but doesn't match the release checksum; move it aside first")
    }

    let sources = sourcesFor(paths, url)
    if dryRun {
        report(.note("Would download \(file), trying in order:"))
        for s in sources {
            report(.note("  \(s)"))
        }
        if let packed {
            report(.note("then unpack it with \(unpacker(packed))"))
        }
        return dest
    }

    do {
        try FileManager.default.createDirectory(at: paths.searchDir, withIntermediateDirectories: true)
    } catch {
        throw CrabError(error.localizedDescription)
    }
    guard let packed else {
        return try await downloadFrom(sources, sha256: sum, sha1: sha1, dest: dest, limits: .standard, cancel: cancel, report: report)
    }

    let archive = paths.searchDir.appending(path: "\(file).\(packed)")
    // An archive left by an earlier attempt whose unpacking failed.
    let haveArchive = archive.isFile && !sum.isEmpty
        && (try? sha256OfFile(archive))?.caseInsensitiveCompare(sum) == .orderedSame
    if !haveArchive {
        try? FileManager.default.removeItem(at: archive)
        _ = try await downloadFrom(sources, sha256: sum, sha1: sha1, dest: archive, limits: .standard, cancel: cancel, report: report)
    }
    try unpack(archive, packed, to: dest, report: report)
    return dest
}

/// The command that unpacks a `gz` or `zst` file.
func unpacker(_ packing: String) -> String {
    packing == "gz" ? "gzip" : "zstd"
}

/// Unpacks `archive` into `dest` (through a temporary file, so `dest` only
/// appears once it's whole), then deletes the archive.
func unpack(_ archive: URL, _ packing: String, to dest: URL, report: DownloadReport) throws(CrabError) {
    let tool = unpacker(packing)
    guard let exe = findExecutable(tool) else {
        throw CrabError("unpacking \(archive.lastPathComponent) needs \(tool) (brew install \(tool)); the download is kept as \(archive.path)")
    }
    report(.note("Unpacking \(archive.lastPathComponent)"))
    let tmp = dest.deletingLastPathComponent().appending(path: "\(dest.lastPathComponent).unpacking")
    do {
        let status = try runWritingTo(tmp, exe, ["-d", "-c", archive.path])
        guard status == 0 else {
            throw CrabError("couldn't unpack \(archive.path) (\(tool) exited with status \(status))")
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw (error as? CrabError) ?? CrabError(error.localizedDescription)
    }
    try? FileManager.default.removeItem(at: archive)
    report(.note("Unpacked: \(dest.path)"))
}

func fileMatchesChecksum(_ url: URL, sha256: String, sha1: String) throws -> Bool {
    if !sha256.isEmpty {
        return try sha256OfFile(url).caseInsensitiveCompare(sha256) == .orderedSame
    }
    if !sha1.isEmpty {
        return try sha1OfFile(url).caseInsensitiveCompare(sha1) == .orderedSame
    }
    return true
}

func downloadFrom(
    _ sources: [String],
    sha256 sum: String,
    sha1: String = "",
    dest: URL,
    limits: StallLimits,
    cancel: CancelFlag,
    report: DownloadReport
) async throws(CrabError) -> URL {
    let file = dest.lastPathComponent
    let part = dest.deletingLastPathComponent().appending(path: "\(file).part")
    let cancelled = CrabError("download cancelled (the partial download is kept as \(part.path) and resumes next time)")

    for src in sources {
        if cancel.isCancelled {
            throw cancelled
        }
        let host = hostFromURL(src)
        report(.note("Downloading \(file) from \(host)"))

        var complete = false
        do {
            try await fetchInto(src, part: part, limits: limits, cancel: cancel, report: report)
            complete = true
        } catch {
            switch error {
            case .cancelled: throw cancelled
            case .failed(let why): report(.note("  couldn't get it from \(host): \(why)"))
            }
        }

        guard part.isFile else { continue }
        if sum.isEmpty && sha1.isEmpty {
            // Nothing to check it against, so take any complete download.
            guard complete else { continue }
            do {
                try FileManager.default.moveItem(at: part, to: dest)
            } catch {
                throw CrabError(error.localizedDescription)
            }
            report(.note("Downloaded \(dest.path) (there's no published checksum, so it isn't verified)"))
            return dest
        }
        if (try? fileMatchesChecksum(part, sha256: sum, sha1: sha1)) == true {
            do {
                try FileManager.default.moveItem(at: part, to: dest)
            } catch {
                throw CrabError(error.localizedDescription)
            }
            report(.note("Checksum OK: \(dest.path)"))
            return dest
        }
        if complete {
            report(.note("  the file from \(host) doesn't match the checksum; discarding it"))
            try? FileManager.default.removeItem(at: part)
        }
    }

    throw CrabError("couldn't download \(file) from any source (a partial download is kept as \(part.path))")
}

enum FetchError: Error {
    case cancelled
    case failed(String)
}

/// Fetches `src` into `part`, resuming from what's already there if the
/// server supports ranges. Returning normally means the server sent the whole file.
func fetchInto(
    _ src: String,
    part: URL,
    limits: StallLimits,
    cancel: CancelFlag,
    report: DownloadReport
) async throws(FetchError) {
    guard let url = URL(string: src) else { throw .failed("bad URL") }
    let existingLen = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64) ?? 0
    var request = URLRequest(url: url)
    if existingLen > 0 {
        request.setValue("bytes=\(existingLen)-", forHTTPHeaderField: "Range")
    }

    let stream = ChunkStream(request: request, silence: limits.silence)
    defer { stream.cancel() }

    var out: FileHandle?
    defer { try? out?.close() }
    var done: Int64 = 0
    var total: Int64?
    var windowStart = Date()
    var windowBytes: Int64 = 0

    do {
        for try await chunk in stream.chunks {
            if cancel.isCancelled {
                throw FetchError.cancelled
            }
            switch chunk {
            case .response(let response):
                let status = response.statusCode
                guard (200..<300).contains(status) else {
                    throw FetchError.failed(statusLine(status))
                }
                let append = status == 206 && existingLen > 0
                done = append ? existingLen : 0
                total = response.expectedContentLength >= 0 ? done + response.expectedContentLength : nil
                if !append {
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: part)
                if append {
                    try handle.seekToEnd()
                }
                out = handle
                report(.progress(done: done, total: total))
            case .data(let data):
                try out?.write(contentsOf: data)
                done += Int64(data.count)
                windowBytes += Int64(data.count)
                report(.progress(done: done, total: total))
                if Date().timeIntervalSince(windowStart) >= limits.window {
                    if windowBytes < limits.minBytes {
                        throw FetchError.failed("stalled (only \(windowBytes) bytes in \(formatSeconds(limits.window)))")
                    }
                    windowStart = Date()
                    windowBytes = 0
                }
            }
        }
    } catch let error as FetchError {
        throw error
    } catch let error as URLError where error.code == .timedOut {
        throw .failed("stalled (no data for \(formatSeconds(limits.silence)))")
    } catch {
        throw .failed(error.localizedDescription)
    }
    if cancel.isCancelled {
        throw .cancelled
    }
}

func formatSeconds(_ t: TimeInterval) -> String {
    t >= 1 ? "\(Int(t))s" : String(format: "%.1fs", t)
}

/// Streams a request's response and body chunks as they arrive, timing out
/// after `silence` seconds without data.
final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Chunk {
        case response(HTTPURLResponse)
        case data(Data)
    }

    let chunks: AsyncThrowingStream<Chunk, Error>
    private let continuation: AsyncThrowingStream<Chunk, Error>.Continuation
    private var session: URLSession!

    init(request: URLRequest, silence: TimeInterval) {
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Chunk.self)
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = silence
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
    }

    func cancel() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: URLError(.badServerResponse))
            return .cancel
        }
        continuation.yield(.response(http))
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Shows `downloadImage`'s progress on the terminal as a bar.
public func terminalReport() -> DownloadReport {
    let state = TerminalProgress()
    return { event in state.handle(event) }
}

private final class TerminalProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var showing = false
    private var lastDraw = Date.distantPast
    private var start = Date()

    func handle(_ event: DownloadEvent) {
        lock.withLock {
            switch event {
            case .note(let msg):
                if showing {
                    print()
                    showing = false
                }
                print(msg)
                start = Date()
            case .progress(let done, let total):
                guard Date().timeIntervalSince(lastDraw) >= 0.1 || done == total else { return }
                lastDraw = Date()
                showing = true
                print("\r\(Self.bar(done: done, total: total, elapsed: Date().timeIntervalSince(start)))", terminator: "")
                fflush(stdout)
            }
        }
    }

    static func bar(done: Int64, total: Int64?, elapsed: TimeInterval) -> String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .binary) }
        guard let total, total > 0 else {
            return "\(fmt(done)) downloaded"
        }
        let width = 50
        let filled = Int(Double(width) * Double(done) / Double(total))
        var eta = ""
        if done > 0 && elapsed > 1 {
            let remaining = Double(total - done) / (Double(done) / elapsed)
            eta = " (\(Int(remaining))s)"
        }
        let bar = String(repeating: "#", count: min(filled, width)) + String(repeating: "-", count: max(0, width - filled))
        return "\(bar) \(fmt(done))/\(fmt(total))\(eta)   "
    }
}

// MARK: - crab get

public func cmdGetList(_ paths: Paths, arch: String) {
    print("Available for \(arch), last checked \(fmtAge(fileMtime(paths.catalog))) (crab sync to refresh, -a for other architectures):")
    let catalog = loadCatalog(paths).filter { $0.arch == arch }
    let macos = newestMacOSPerMajor(catalog)
    for entry in catalog where entry.distro != macosDistro || macos.contains(entry) {
        let file = getFilename(distro: entry.distro, arch: entry.arch, url: entry.url)
        var marks: [String] = []
        if paths.searchDir.appending(path: file).isFile {
            marks.append("downloaded")
        }
        if entry.variant == defaultVariant(entry.distro) && (entry.distro != macosDistro || entry == macos.first) {
            marks.append("default")
        }
        if entry.sha256.isEmpty && entry.sha1.isEmpty {
            marks.append("unverified")
        }
        let markStr = marks.isEmpty ? "" : "(\(marks.joined(separator: ", ")))"
        print("  \("\(entry.distro)/\(entry.variant)".padded(22)) \(entry.version.padded(9)) \(file.padded(46)) \(markStr)")
    }
    let older = catalog.filter { $0.distro == macosDistro }.count - macos.count
    if older > 0 {
        print("  (\(older) more macOS builds: crab get macos/list, then crab get macos/VERSION)")
    }
}

public func cmdGet(_ paths: Paths, _ opts: BootOptions, spec: String?) async throws(CrabError) {
    let arch = opts.arch.flatMap { $0.isEmpty ? nil : $0 } ?? hostArch()
    // Refuse before refreshing the whole catalog: an Intel Mac can't install it.
    if spec?.split(separator: "/").first?.lowercased() == macosDistro,
       let reason = macosGuestRefusal(hostArchitecture: hostArch()) {
        throw CrabError(reason)
    }
    try await ensureCatalog(paths)

    guard let spec, !spec.isEmpty else {
        cmdGetList(paths, arch: arch)
        return
    }

    let distroRaw: Substring
    var variantOpt: String?
    if let slash = spec.firstIndex(of: "/") {
        distroRaw = spec[..<slash]
        let v = spec[spec.index(after: slash)...]
        variantOpt = v.isEmpty ? nil : String(v)
    } else {
        distroRaw = spec[...]
    }
    let distro = distroRaw.lowercased()
    guard distros.contains(distro) else {
        throw CrabError("don't know how to get '\(distro)' (I know: \(distros.joined(separator: " ")))")
    }
    let variant = variantOpt ?? defaultVariant(distro)
    if distro == macosDistro {
        try await cmdGetMacOS(paths, opts, variant: variant)
        return
    }

    let catalog = loadCatalog(paths)
    guard let entry = catalog.first(where: { $0.distro == distro && $0.variant == variant && $0.arch == arch }) else {
        var msg = "no \(distro)/\(variant) for \(arch) in the release list. What there is for \(distro):"
        for e in catalog where e.distro == distro {
            msg += "\n  \(e.distro)/\(e.variant) (\(e.arch))"
        }
        throw CrabError(msg)
    }

    let file = getFilename(distro: distro, arch: arch, url: entry.url)
    print("\(distro)/\(variant) \(entry.version) for \(arch)")

    let imagePath = try await downloadImage(
        paths, url: entry.url, sha256: entry.sha256, file: file, dryRun: opts.dryRun,
        cancel: CancelFlag(), report: terminalReport(), sha1: entry.sha1
    )
    if opts.downloadOnly {
        return
    }
    print()

    var bootOpts = opts
    bootOpts.knownArch = arch
    if bootOpts.display == nil && !entry.display.isEmpty {
        bootOpts.display = entry.display
    }
    try cmdBoot(paths, bootOpts, vmName: nil, image: imagePath)
}
