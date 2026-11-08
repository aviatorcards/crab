import CryptoKit
import Darwin
import Foundation

// MARK: - Host support

public let macosDistro = "macos"
public let macosVariant = "restore"
/// The hardware model Apple's Virtualization framework installs, in the IPSW feed.
public let macosVirtualMachineModel = "VirtualMac2,1"
public let macosIPSWCatalogURL = "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml"

public let vmBackendVZ = "vz"
public let vmBackendQEMU = "qemu"

/// Floor used before the restore image reports its own minimums.
public let minMacOSMemoryMB = 4096
public let minMacOSCPUs = 2
public let defaultMacOSMem = "4G"
public let defaultMacOSCPUs = 4
public let defaultMacOSDisk = "64G"
public let minMacOSDiskBytes: UInt64 = 64 * 1024 * 1024 * 1024

public let crabAppBundleID = "com.tristansmith.Crab"

/// Why this host can't run a modern macOS guest, or nil when it can.
/// `hostArchitecture` is crab's name (`arm64` / `amd64`), not `uname -m`.
public func macosGuestRefusal(hostArchitecture: String) -> String? {
    if hostArchitecture == "arm64" {
        return nil
    }
    let which = hostArchitecture.isEmpty ? "this computer" : hostArchitecture
    return """
    Modern macOS guests need an Apple Silicon Mac. This one is \(which), and Apple's \
    Virtualization framework only installs macOS on Apple Silicon. QEMU can't run current \
    macOS either. An Intel Mac can still boot older PowerPC Mac OS X discs (up to 10.5) as ppc guests.
    """
}

public func isIPSW(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "ipsw"
}

// MARK: - Apple's IPSW feed

public struct MacOSIPSWAsset: Sendable, Equatable {
    public var version: String
    public var build: String
    public var url: String
    public var sha1: String
    public var device: String

    public init(version: String, build: String, url: String, sha1: String, device: String) {
        self.version = version
        self.build = build
        self.url = url
        self.sha1 = sha1
        self.device = device
    }
}

/// Reads Apple's `com_apple_macOSIPSW.xml` property list.
///
/// The feed lists one or more builds per Mac model. Virtual machines install
/// the `VirtualMac2,1` image. That entry often omits `FirmwareSHA1`; the same
/// IPSW URL on another model carries it, and that checksum is copied across.
public func parseMacOSIPSWCatalog(_ data: Data, device: String = macosVirtualMachineModel) -> [MacOSIPSWAsset] {
    guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let byVersion = root["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any] else {
        return []
    }
    var found: [RawRestore] = []
    for node in byVersion.values {
        guard let versionDict = node as? [String: Any],
              let models = versionDict["MobileDeviceSoftwareVersions"] as? [String: Any] else {
            continue
        }
        for (model, buildsAny) in models {
            guard let builds = buildsAny as? [String: Any] else { continue }
            for (buildKey, entryAny) in builds {
                guard let entry = entryAny as? [String: Any] else { continue }
                if buildKey == "Unknown" {
                    appendRestore(entry["Universal"] ?? entry, model: model, fallbackBuild: "", into: &found)
                } else {
                    appendRestore(entry, model: model, fallbackBuild: buildKey, into: &found)
                }
            }
        }
    }

    var sha1ByURL: [String: String] = [:]
    for item in found where !item.sha1.isEmpty {
        sha1ByURL[item.url] = item.sha1
    }

    var best: [String: MacOSIPSWAsset] = [:]
    for item in found where item.device == device && !item.version.isEmpty && item.url.lowercased().hasSuffix(".ipsw") {
        let asset = MacOSIPSWAsset(
            version: item.version,
            build: item.build,
            url: item.url,
            sha1: item.sha1.isEmpty ? (sha1ByURL[item.url] ?? "") : item.sha1,
            device: item.device
        )
        if let existing = best[asset.version] {
            if appleBuildIsNewer(asset.build, than: existing.build) {
                best[asset.version] = asset
            }
        } else {
            best[asset.version] = asset
        }
    }
    return best.values.sorted { lhs, rhs in
        let lv = versionKey(lhs.version)
        let rv = versionKey(rhs.version)
        if lv != rv { return lv > rv }
        return appleBuildIsNewer(lhs.build, than: rhs.build)
    }
}

/// Catalog rows for the macOS restore images. Checksums are SHA-1 (Apple
/// doesn't publish SHA-256 for these). `display` is `window` because the
/// guest always has a graphical console.
public func macOSCatalogEntries(_ assets: [MacOSIPSWAsset]) -> [CatalogEntry] {
    assets.map { asset in
        CatalogEntry(
            distro: macosDistro, variant: macosVariant, version: asset.version, arch: "arm64",
            url: asset.url, sha256: "", display: "window", sha1: asset.sha1
        )
    }
}

private struct RawRestore {
    var version: String
    var build: String
    var url: String
    var sha1: String
    var device: String
}

private func appendRestore(_ node: Any?, model: String, fallbackBuild: String, into found: inout [RawRestore]) {
    guard let entry = node as? [String: Any],
          let restore = entry["Restore"] as? [String: Any],
          let url = restore["FirmwareURL"] as? String else {
        return
    }
    found.append(RawRestore(
        version: (restore["ProductVersion"] as? String) ?? "",
        build: (restore["BuildVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBuild,
        url: url,
        sha1: (restore["FirmwareSHA1"] as? String) ?? "",
        device: model
    ))
}

/// Apple's build strings look like `24C101`: a train, a letter, then a number.
struct AppleBuild: Comparable {
    var train: Int
    var letter: UInt8
    var number: Int

    init?(_ raw: String) {
        var index = raw.startIndex
        var trainDigits = ""
        while index < raw.endIndex, raw[index].isASCIIDigit {
            trainDigits.append(raw[index])
            index = raw.index(after: index)
        }
        guard let train = Int(trainDigits), index < raw.endIndex, let letter = raw[index].asciiValue, raw[index].isLetter else {
            return nil
        }
        index = raw.index(after: index)
        let rest = raw[index...]
        guard !rest.isEmpty, rest.allSatisfy(\.isASCIIDigit), let number = Int(rest) else { return nil }
        self.train = train
        self.letter = letter
        self.number = number
    }

    static func < (lhs: AppleBuild, rhs: AppleBuild) -> Bool {
        if lhs.train != rhs.train { return lhs.train < rhs.train }
        if lhs.letter != rhs.letter { return lhs.letter < rhs.letter }
        return lhs.number < rhs.number
    }
}

func appleBuildIsNewer(_ build: String, than other: String) -> Bool {
    switch (AppleBuild(build), AppleBuild(other)) {
    case let (lhs?, rhs?): return lhs > rhs
    case (_?, nil): return true
    case (nil, _?): return false
    default: return build > other
    }
}

public func macosVersionFromIPSWName(_ name: String) -> String? {
    for token in URL(filePath: name).deletingPathExtension().lastPathComponent.split(separator: "_") {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) {
            return String(token)
        }
    }
    return nil
}

public func macosBuildFromIPSWName(_ name: String) -> String? {
    for token in URL(filePath: name).deletingPathExtension().lastPathComponent.split(separator: "_") {
        let text = String(token)
        if AppleBuild(text) != nil { return text }
    }
    return nil
}

// MARK: - Which image to download

public struct MacOSRestoreChoice: Sendable, Equatable {
    public var version: String
    public var build: String
    public var url: String

    public init(version: String, build: String, url: String) {
        self.version = version
        self.build = build
        self.url = url
    }
}

/// `supported` is what `VZMacOSRestoreImage.latestSupported` reported for this
/// Mac, when it could be asked. That image wins even if the feed lists a newer
/// one, because a newer IPSW may not install on this host. With no host answer,
/// the newest catalog entry is used.
public func selectMacOSRestore(catalog: [CatalogEntry], supported: MacOSRestoreChoice?) -> MacOSRestoreChoice? {
    if let supported, !supported.url.isEmpty {
        return supported
    }
    let entries = catalog.filter { $0.distro == macosDistro && $0.arch == "arm64" && !$0.url.isEmpty }
    guard let best = entries.max(by: { versionKey($0.version) < versionKey($1.version) }) else { return nil }
    return MacOSRestoreChoice(
        version: best.version,
        build: macosBuildFromIPSWName(best.url) ?? "",
        url: best.url
    )
}

public func sha1ForMacOSRestore(_ choice: MacOSRestoreChoice, catalog: [CatalogEntry]) -> String {
    catalog.first { $0.url == choice.url && !$0.sha1.isEmpty }?.sha1 ?? ""
}

// MARK: - On-disk layout

/// Files a macOS VM keeps next to `vm.conf`. QEMU VMs keep `disk.qcow2` instead,
/// so the two kinds share `~/VMs/<name>/` without colliding.
public struct MacOSVMLayout: Sendable, Equatable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var disk: URL { directory.appending(path: Self.diskName) }
    public var hardwareModel: URL { directory.appending(path: Self.hardwareModelName) }
    public var machineIdentifier: URL { directory.appending(path: Self.machineIdentifierName) }
    public var auxiliaryStorage: URL { directory.appending(path: Self.auxiliaryStorageName) }
    public var pidFile: URL { directory.appending(path: Self.pidName) }
    public var socket: URL { directory.appending(path: Self.socketName) }

    public static let diskName = "Disk.img"
    public static let hardwareModelName = "HardwareModel"
    public static let machineIdentifierName = "MachineIdentifier"
    public static let auxiliaryStorageName = "AuxiliaryStorage"
    public static let pidName = "vz.pid"
    public static let socketName = "vz.sock"
    /// Copied when a macOS VM is cloned. The machine identifier is part of the
    /// installation, so the copy keeps it; two copies shouldn't run at once.
    public static let cloneNames = [diskName, hardwareModelName, machineIdentifierName, auxiliaryStorageName, "vm.conf"]
}

/// Settings stored in `vm.conf` for a `backend=vz` VM.
public struct MacOSVMConfig: Sendable, Equatable {
    public var version: String
    public var build: String
    public var mem: String
    public var cpus: String
    public var disk: String
    public var installed: Bool
    public var restoreImage: String
    public var minMemoryMB: Int
    public var minCPUs: Int

    public init(
        version: String = "",
        build: String = "",
        mem: String = defaultMacOSMem,
        cpus: String = String(defaultMacOSCPUs),
        disk: String = defaultMacOSDisk,
        installed: Bool = false,
        restoreImage: String = "",
        minMemoryMB: Int = minMacOSMemoryMB,
        minCPUs: Int = minMacOSCPUs
    ) {
        self.version = version
        self.build = build
        self.mem = mem
        self.cpus = cpus
        self.disk = disk
        self.installed = installed
        self.restoreImage = restoreImage
        self.minMemoryMB = minMemoryMB
        self.minCPUs = minCPUs
    }

    public static func load(_ dir: URL) -> MacOSVMConfig {
        func value(_ key: String) -> String { confGet(dir, key) }
        let minMem = Int(value("min_mem_mb")).flatMap { $0 > 0 ? $0 : nil } ?? minMacOSMemoryMB
        let minCPU = Int(value("min_cpus")).flatMap { $0 > 0 ? $0 : nil } ?? minMacOSCPUs
        return MacOSVMConfig(
            version: value("macos_version"),
            build: value("macos_build"),
            mem: value("mem").isEmpty ? defaultMacOSMem : value("mem"),
            cpus: value("cpus").isEmpty ? String(defaultMacOSCPUs) : value("cpus"),
            disk: value("disk").isEmpty ? defaultMacOSDisk : value("disk"),
            installed: value("installed") == "1",
            restoreImage: value("restore_image"),
            minMemoryMB: minMem,
            minCPUs: minCPU
        )
    }

    public func updates() -> [(String, String)] {
        [
            ("backend", vmBackendVZ),
            ("guest", macosDistro),
            ("arch", "arm64"),
            ("firmware", vmBackendVZ),
            ("display", "window"),
            ("mem", mem),
            ("cpus", cpus),
            ("disk", disk),
            ("macos_version", version),
            ("macos_build", build),
            ("restore_image", restoreImage),
            ("installed", installed ? "1" : "0"),
            ("min_mem_mb", String(minMemoryMB)),
            ("min_cpus", String(minCPUs)),
            ("ssh_port", "0"),
        ]
    }
}

public let macosSettableKeys = ["mem", "cpus"]

public func validateMacOSSetting(_ key: String, _ value: String, config: MacOSVMConfig) throws(CrabError) -> String {
    switch key {
    case "mem":
        guard validMem(value), let mb = memMB(value) else {
            throw CrabError("mem wants a size like 4G or 8192M")
        }
        let floor = max(config.minMemoryMB, minMacOSMemoryMB)
        if mb < floor {
            throw CrabError("mem for this macOS VM must be at least \(formatMemoryMB(floor))")
        }
        return value
    case "cpus":
        guard validCPUs(value), let n = Int(value) else {
            throw CrabError("cpus wants a number of CPUs")
        }
        let floor = max(config.minCPUs, minMacOSCPUs)
        if n < floor {
            throw CrabError("cpus for this macOS VM must be at least \(floor)")
        }
        return value
    case "firmware", "hw", "gpu", "display", "fullscreen", "ssh_port", "ssh_user", "fwd":
        throw CrabError("\(key) doesn't apply to a macOS VM. It always uses Apple's virtualization window and NAT, with no port forwards.")
    default:
        throw CrabError("can't set '\(key)' on a macOS VM; settable keys are: \(macosSettableKeys.joined(separator: " "))")
    }
}

public struct MacOSHardwarePlan: Sendable, Equatable {
    public var memoryMB: Int
    public var cpus: Int
    public var diskBytes: UInt64
    public var memText: String
    public var cpuText: String
    public var diskText: String
    public var notes: [String]
}

/// Raises memory, CPU and disk requests up to the floor a macOS guest needs.
/// The restore image may demand still more; that clamp happens at install time.
public func resolveMacOSHardware(mem: String?, cpus: String?, disk: String?) -> MacOSHardwarePlan {
    var notes: [String] = []
    var memoryMB = minMacOSMemoryMB
    if let mem, validMem(mem), let mb = memMB(mem) {
        if mb < minMacOSMemoryMB {
            notes.append("macOS guests need at least \(defaultMacOSMem) of RAM; using \(defaultMacOSMem) instead of \(mem).")
        } else {
            memoryMB = mb
        }
    }
    var cpuCount = defaultMacOSCPUs
    if let cpus, validCPUs(cpus), let n = Int(cpus) {
        if n < minMacOSCPUs {
            notes.append("macOS guests need at least \(minMacOSCPUs) CPUs; using \(minMacOSCPUs) instead of \(cpus).")
            cpuCount = minMacOSCPUs
        } else {
            cpuCount = n
        }
    }
    var diskBytes = minMacOSDiskBytes
    if let disk, let bytes = diskSpecBytes(disk) {
        if bytes < minMacOSDiskBytes {
            notes.append("macOS guests need a disk of at least \(defaultMacOSDisk); using \(defaultMacOSDisk) instead of \(disk).")
        } else {
            diskBytes = bytes
        }
    }
    return MacOSHardwarePlan(
        memoryMB: memoryMB,
        cpus: cpuCount,
        diskBytes: diskBytes,
        memText: formatMemoryMB(memoryMB),
        cpuText: String(cpuCount),
        diskText: formatDiskBytes(diskBytes),
        notes: notes
    )
}

public func formatMemoryMB(_ mb: Int) -> String {
    if mb > 0, mb % 1024 == 0 { return "\(mb / 1024)G" }
    return "\(mb)M"
}

public func formatDiskBytes(_ bytes: UInt64) -> String {
    let gib: UInt64 = 1024 * 1024 * 1024
    let mib: UInt64 = 1024 * 1024
    if gib > 0, bytes % gib == 0 { return "\(bytes / gib)G" }
    if mib > 0, bytes % mib == 0 { return "\(bytes / mib)M" }
    return "\(bytes)B"
}

public func diskSpecBytes(_ spec: String) -> UInt64? {
    guard validDiskSize(spec, relative: false), let unit = spec.last, let num = UInt64(spec.dropLast()) else {
        return nil
    }
    switch unit {
    case "M", "m": return num * 1024 * 1024
    case "G", "g": return num * 1024 * 1024 * 1024
    case "T", "t": return num * 1024 * 1024 * 1024 * 1024
    default: return nil
    }
}

/// The size `spec` grows `current` to, or nil when it isn't a growth.
/// `spec` is `40G` or `+10G`, the same forms `crab resize` already accepts.
public func grownDiskBytes(current: UInt64, spec: String) -> UInt64? {
    guard validDiskSize(spec, relative: true) else { return nil }
    let relative = spec.hasPrefix("+")
    let absolute = relative ? String(spec.dropFirst()) : spec
    guard let amount = diskSpecBytes(absolute) else { return nil }
    let target = relative ? current + amount : amount
    return target > current ? target : nil
}

public func logicalFileBytes(_ url: URL) -> UInt64 {
    guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] else { return 0 }
    if let n = size as? UInt64 { return n }
    if let n = size as? Int { return UInt64(n) }
    if let n = size as? NSNumber { return n.uint64Value }
    return 0
}

public func createSparseDisk(_ url: URL, bytes: UInt64) throws(CrabError) {
    if url.exists {
        try? FileManager.default.removeItem(at: url)
    }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    try growRawDisk(url, to: bytes)
}

public func growRawDisk(_ url: URL, to bytes: UInt64) throws(CrabError) {
    do {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        if bytes < current {
            throw CrabError("disks can only grow")
        }
        try handle.truncate(atOffset: bytes)
    } catch let error as CrabError {
        throw error
    } catch {
        throw CrabError("couldn't resize \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

// MARK: - Launch request

/// A boot the CLI asks the app to perform. The virtual machine has to live in
/// the app process: that's the process signed with the virtualization entitlement
/// and the one that can show `VZVirtualMachineView`.
public struct MacOSLaunchRequest: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case install
        case boot
    }

    public var kind: Kind
    public var image: String
    public var vm: String
    public var mem: String
    public var cpus: String
    public var disk: String
    public var keep: Bool
    public var name: String

    public init(kind: Kind, image: String = "", vm: String = "", mem: String = "", cpus: String = "", disk: String = "", keep: Bool = false, name: String = "") {
        self.kind = kind
        self.image = image
        self.vm = vm
        self.mem = mem
        self.cpus = cpus
        self.disk = disk
        self.keep = keep
        self.name = name
    }

    public func text() -> String {
        [
            "kind=\(kind.rawValue)",
            "image=\(image)",
            "vm=\(vm)",
            "mem=\(mem)",
            "cpus=\(cpus)",
            "disk=\(disk)",
            "keep=\(keep ? "1" : "0")",
            "name=\(name)",
        ].joined(separator: "\n") + "\n"
    }

    public init?(text: String) {
        var values: [String: String] = [:]
        for line in text.lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let kind = Kind(rawValue: values["kind"] ?? "") else { return nil }
        self.init(
            kind: kind,
            image: values["image"] ?? "",
            vm: values["vm"] ?? "",
            mem: values["mem"] ?? "",
            cpus: values["cpus"] ?? "",
            disk: values["disk"] ?? "",
            keep: values["keep"] == "1",
            name: values["name"] ?? ""
        )
    }
}

public func macosLaunchRequestURL(_ paths: Paths) -> URL {
    paths.vmRoot.appending(path: ".macos-launch")
}

public func saveMacOSLaunchRequest(_ paths: Paths, _ request: MacOSLaunchRequest) throws(CrabError) {
    do {
        try FileManager.default.createDirectory(at: paths.vmRoot, withIntermediateDirectories: true)
        try request.text().write(to: macosLaunchRequestURL(paths), atomically: true, encoding: .utf8)
    } catch {
        throw CrabError("couldn't write the macOS launch request: \(error.localizedDescription)")
    }
}

/// Takes the pending request, if there is one. Moving it aside first means a
/// second reader (the app polls) won't start the same guest twice.
public func takeMacOSLaunchRequest(_ paths: Paths) -> MacOSLaunchRequest? {
    let url = macosLaunchRequestURL(paths)
    guard url.isFile else { return nil }
    let reading = url.appendingPathExtension("reading")
    try? FileManager.default.removeItem(at: reading)
    do {
        try FileManager.default.moveItem(at: url, to: reading)
    } catch {
        return nil
    }
    defer { try? FileManager.default.removeItem(at: reading) }
    guard let text = try? String(contentsOf: reading, encoding: .utf8) else { return nil }
    return MacOSLaunchRequest(text: text)
}

public func macosLaunchSummary(_ request: MacOSLaunchRequest, paths: Paths) -> String {
    switch request.kind {
    case .boot:
        let dir = paths.vmRoot.appending(path: request.vm)
        let config = MacOSVMConfig.load(dir)
        return """
        Would open the macOS VM '\(request.vm)' in Crab.
          \(dir.path)
          disk \(config.disk), \(config.mem) RAM, \(config.cpus) CPUs
          snapshots: not supported
          network: NAT, no host port forwards
        """
    case .install:
        let plan = resolveMacOSHardware(
            mem: request.mem.isEmpty ? nil : request.mem,
            cpus: request.cpus.isEmpty ? nil : request.cpus,
            disk: request.disk.isEmpty ? nil : request.disk
        )
        let whereTo = request.keep
            ? paths.vmRoot.appending(path: request.name.isEmpty ? "NAME" : request.name).path
            : paths.scratchRoot.appending(path: "crab-XXXX").path
        let lines = [
            "Would install macOS from \(request.image)",
            "  into \(whereTo)",
            "  disk \(plan.diskText), \(plan.memText) RAM, \(plan.cpuText) CPUs",
            "  snapshots: not supported",
            "  network: NAT, no host port forwards",
        ] + plan.notes.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }
}

/// Opens Crab.app, passing `VM_ROOT` / `CRAB_SEARCH_DIR` through. Prefers the
/// app this binary is bundled in (`Crab.app/Contents/Helpers/crab`).
public func openCrabApp(arguments: [String] = []) throws(CrabError) {
    var openArgs: [String] = []
    let me = URL(filePath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
    let bundle = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" {
        openArgs += ["-a", bundle.path]
    } else {
        openArgs += ["-b", crabAppBundleID]
    }
    let env = ProcessInfo.processInfo.environment
    for key in ["VM_ROOT", "CRAB_SEARCH_DIR"] {
        if let value = env[key], !value.isEmpty {
            openArgs += ["--env", "\(key)=\(value)"]
        }
    }
    if !arguments.isEmpty {
        openArgs += ["--args"] + arguments
    }
    let status: Int32
    do {
        status = try runInheriting(URL(filePath: "/usr/bin/open"), openArgs)
    } catch {
        throw CrabError("failed to run open: \(error.localizedDescription)")
    }
    if status != 0 {
        throw CrabError("couldn't open the Crab app; build and install it from Crab.xcodeproj")
    }
}

func sha1OfFile(_ url: URL) throws -> String {
    try hashFile(url, Insecure.SHA1())
}

// MARK: - Control socket

/// Listens on `vz.sock` so `crab stop` / `crab kill` can reach a guest running
/// in the app. One line in (`stop` or `quit`), `ok` back.
public final class VZControlServer: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

    public init() {}

    public func start(at path: String, handler: @escaping @Sendable (String) -> Void) throws(CrabError) {
        if path.utf8.count > QMP.maxSocketPath {
            throw CrabError("control socket path is too long: \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CrabError("couldn't open a control socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw CrabError("couldn't listen on \(path)")
        }
        lock.withLock {
            self.fd = fd
            self.stopped = false
        }
        Thread.detachNewThread { [weak self] in
            while let self, !self.isStopped {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                let line = readControlLine(client) ?? ""
                if !line.isEmpty {
                    handler(line)
                }
                _ = [UInt8]("ok\n".utf8).withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
                close(client)
            }
        }
    }

    public func stop() {
        let fd: Int32 = lock.withLock {
            stopped = true
            let current = self.fd
            self.fd = -1
            return current
        }
        if fd >= 0 {
            close(fd)
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }
}

public func sendVZCommand(_ dir: URL, _ command: String) throws(CrabError) {
    let sock = MacOSVMLayout(directory: dir).socket
    guard sock.exists else {
        let name = dir.lastPathComponent
        throw CrabError("\(name) isn't answering on its control socket. Shut it down from its window in Crab.")
    }
    if sock.path.utf8.count > QMP.maxSocketPath {
        throw CrabError("control socket path is too long")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CrabError("couldn't open a socket") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(sock.path.utf8)) }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        throw CrabError("couldn't connect to \(dir.lastPathComponent)'s control socket")
    }
    let line = Data("\(command)\n".utf8)
    let wrote = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard wrote == line.count else {
        throw CrabError("couldn't talk to \(dir.lastPathComponent)")
    }
    var buf = [UInt8](repeating: 0, count: 32)
    let n = Darwin.read(fd, &buf, buf.count)
    guard n > 0, String(bytes: buf.prefix(n), encoding: .utf8)?.hasPrefix("ok") == true else {
        throw CrabError("\(dir.lastPathComponent) didn't accept \(command)")
    }
}

private func readControlLine(_ fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var one: UInt8 = 0
    while bytes.count < 64 {
        let n = Darwin.read(fd, &one, 1)
        if n <= 0 { break }
        if one == 10 { break }
        if one != 13 { bytes.append(one) }
    }
    guard !bytes.isEmpty else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}

func livePIDFile(_ url: URL) -> Int32? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = Int32(text.trimmed), pid > 0 else {
        return nil
    }
    if kill(pid, 0) == 0 { return pid }
    if errno == EPERM { return pid }
    return nil
}

// MARK: - CLI handoff

public func launchMacOSInstaller(_ paths: Paths, _ opts: BootOptions, image: URL) throws(CrabError) {
    if let reason = macosGuestRefusal(hostArchitecture: hostArch()) {
        throw CrabError(reason)
    }
    if opts.live {
        throw CrabError("-l doesn't apply to a macOS restore image: installing macOS needs a disk. Drop -l, or use -k to keep the VM.")
    }
    var name = ""
    if opts.keep {
        let fallback = defaultVMName(image, arch: "arm64")
        let input = promptLine("VM name [\(fallback)]: ") ?? ""
        name = input.trimmed.isEmpty ? fallback : input.trimmed
        try checkName(name)
        let dest = paths.vmRoot.appending(path: name, directoryHint: .isDirectory)
        if dest.exists {
            throw CrabError("there's already something called '\(name)' in \(paths.vmRoot.path)")
        }
    }
    let request = MacOSLaunchRequest(
        kind: .install,
        image: absPath(image).path,
        mem: opts.mem ?? "",
        cpus: opts.cpus ?? "",
        disk: opts.diskSize ?? "",
        keep: opts.keep,
        name: name
    )
    if opts.dryRun {
        print(macosLaunchSummary(request, paths: paths))
        return
    }
    var notes = resolveMacOSHardware(mem: opts.mem, cpus: opts.cpus, disk: opts.diskSize).notes
    if opts.display == "terminal" {
        notes.append("macOS guests always open a window, so -t is ignored.")
    }
    for note in notes {
        print(note)
    }
    print("Opening Crab to install and run it. The guest window is in the app.")
    print("Snapshots and SSH port forwards aren't available for macOS VMs.")
    try saveMacOSLaunchRequest(paths, request)
    try openCrabAppOrDropRequest(paths)
}

public func launchSavedMacOSVM(_ paths: Paths, _ opts: BootOptions, dir: URL) throws(CrabError) {
    if let reason = macosGuestRefusal(hostArchitecture: hostArch()) {
        throw CrabError(reason)
    }
    if opts.live || opts.keep {
        throw CrabError("-k and -l are for booting images, not saved VMs\nRun 'crab -h' for usage.")
    }
    let request = MacOSLaunchRequest(
        kind: .boot,
        vm: dir.lastPathComponent,
        mem: opts.mem ?? "",
        cpus: opts.cpus ?? ""
    )
    if opts.dryRun {
        print(macosLaunchSummary(request, paths: paths))
        return
    }
    print("Opening '\(request.vm)' in Crab.")
    try saveMacOSLaunchRequest(paths, request)
    try openCrabAppOrDropRequest(paths)
}

private func openCrabAppOrDropRequest(_ paths: Paths) throws(CrabError) {
    do {
        try openCrabApp()
    } catch let error as CrabError {
        try? FileManager.default.removeItem(at: macosLaunchRequestURL(paths))
        throw error
    } catch {
        try? FileManager.default.removeItem(at: macosLaunchRequestURL(paths))
        throw CrabError(error.localizedDescription)
    }
}

public func cmdGetMacOS(_ paths: Paths, _ opts: BootOptions, variant: String) async throws(CrabError) {
    if let reason = macosGuestRefusal(hostArchitecture: hostArch()) {
        throw CrabError(reason)
    }
    guard variant == macosVariant else {
        throw CrabError("macOS only has the \(macosVariant) image (crab get macos).")
    }
    let arch = opts.arch.flatMap { $0.isEmpty ? nil : $0 } ?? hostArch()
    if arch != "arm64" {
        throw CrabError("macOS restore images are arm64 only. Drop -a \(arch).")
    }
    let catalog = loadCatalog(paths)
    let supported = await fetchLatestSupportedMacOSRestore()
    guard let choice = selectMacOSRestore(catalog: catalog, supported: supported) else {
        throw CrabError("no macOS restore image in the release list. Run crab sync and try again.")
    }
    let file = getFilename(distro: macosDistro, arch: "arm64", url: choice.url)
    let build = choice.build.isEmpty ? "" : " (\(choice.build))"
    print("macos/\(macosVariant) \(choice.version)\(build) for arm64")
    if supported != nil {
        print("This Mac's Virtualization framework asked for this restore image.")
    }
    let sha1 = sha1ForMacOSRestore(choice, catalog: catalog)
    if sha1.isEmpty {
        print("Apple didn't publish a SHA-1 for this image. The installer rejects a damaged one.")
    }
    let image = try await downloadImage(
        paths, url: choice.url, sha256: "", file: file, dryRun: opts.dryRun,
        cancel: CancelFlag(), report: terminalReport(), sha1: sha1
    )
    if opts.downloadOnly || opts.dryRun {
        if opts.dryRun {
            print()
            print(macosLaunchSummary(
                MacOSLaunchRequest(kind: .install, image: image.path, mem: opts.mem ?? "", cpus: opts.cpus ?? "", disk: opts.diskSize ?? "", keep: opts.keep),
                paths: paths
            ))
        }
        return
    }
    print()
    try launchMacOSInstaller(paths, opts, image: image)
}
