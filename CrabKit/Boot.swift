import Foundation

public struct BootOptions: Sendable, Equatable {
    public var searchDir: URL?
    public var arch: String?
    public var knownArch: String?
    /// The app's architecture setting: used only when an image's architecture
    /// can't be detected.
    public var fallbackArch: String?
    public var downloadOnly = false
    public var keep = false
    public var live = false
    public var mem: String?
    public var cpus: String?
    public var diskSize: String?
    public var sshPort: String?
    /// An empty array clears the saved forwards (-P 0).
    public var forwards: [Forward]?
    public var firmware: String?
    public var display: String?
    public var fullscreen: String?
    public var gpu: String?
    /// "standard", "virtio" or "legacy" (-H).
    public var hw: String?
    public var dryRun = false
    public var extraQemuArgs: [String] = []

    public init() {}

    /// These options minus the settings a VM saves in vm.conf, so booting an
    /// existing VM from the app keeps what it has instead of taking the app's
    /// launch settings (which are for new VMs).
    public func withoutSavedSettings() -> BootOptions {
        var o = self
        o.mem = nil
        o.cpus = nil
        o.sshPort = nil
        o.forwards = nil
        o.firmware = nil
        o.display = nil
        o.fullscreen = nil
        o.gpu = nil
        o.hw = nil
        return o
    }
}

/// Splits a raw string of command-line flags into individual arguments,
/// respecting single and double quotes.
public func parseExtraQemuFlags(_ raw: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inQuote: Character? = nil
    var escaping = false

    for char in raw {
        if escaping {
            current.append(char)
            escaping = false
            continue
        }
        if char == "\\" {
            escaping = true
            continue
        }
        if let quote = inQuote {
            if char == quote {
                inQuote = nil
            } else {
                current.append(char)
            }
        } else if char == "\"" || char == "'" {
            inQuote = char
        } else if char.isWhitespace {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }
    if !current.isEmpty {
        args.append(current)
    }
    return args
}

// MARK: - Architecture detection

public func archFromName(_ name: String) -> String? {
    let lower = URL(filePath: name).lastPathComponent.lowercased()
    if lower.contains("aarch64") || lower.contains("arm64") || lower.contains("evbarm") {
        return "arm64"
    } else if lower.contains("amd64") || lower.contains("x86_64") || lower.contains("x86-64") || lower.contains("x64") {
        return "amd64"
    } else if lower.contains("i386") || lower.contains("i686") || lower.contains("x86") {
        return "i386"
    } else if lower.contains("sparc64") || lower.contains("sun4u") {
        return "sparc64"
    }
    // Whole words only: "ppc" turns up inside other words, and ppc64 is
    // 64-bit POWER, which crab doesn't boot.
    let words = Set(URL(filePath: lower).deletingPathExtension().lastPathComponent.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    if !words.isDisjoint(with: ["ppc", "powerpc", "macppc"]) {
        return "ppc"
    }
    return nil
}

/// Scans the whole image for `BOOTAA64.EFI`, `BOOTX64.EFI` and `BOOTIA32.EFI`
/// (allowing for ISO 9660's `BOOTX64 EFI` and `BOOTX64EFI` spellings).
func scanEFILoaders(_ url: URL) -> (aa64: Bool, x64: Bool, ia32: Bool) {
    var aa64 = false, x64 = false, ia32 = false
    guard let handle = try? FileHandle(forReadingFrom: url) else { return (false, false, false) }
    defer { try? handle.close() }

    let chunk = 1024 * 1024
    let overlap = 32
    var carry: [UInt8] = []
    while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
        let buf = carry + data
        buf.withUnsafeBufferPointer { slice in
            if !aa64 && matchesEFI(slice, "BOOTAA64") { aa64 = true }
            if !x64 && matchesEFI(slice, "BOOTX64") { x64 = true }
            if !ia32 && matchesEFI(slice, "BOOTIA32") { ia32 = true }
        }
        if aa64 && x64 && ia32 {
            break
        }
        carry = Array(buf.suffix(overlap))
    }
    return (aa64, x64, ia32)
}

/// Whether `haystack` contains `prefix`, an optional space, an optional dot, then "EFI".
/// Finds candidates with memmem, since this runs over every byte of an image.
func matchesEFI<C: Collection>(_ haystack: C, _ prefix: String) -> Bool where C.Element == UInt8 {
    let p = Array(prefix.utf8)
    let efi = Array("EFI".utf8)
    func search(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = buf.baseAddress else { return false }
        let n = buf.count
        var start = 0
        while start < n, let hit = memmem(base + start, n - start, p, p.count) {
            let at = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            var j = at + p.count
            if j < n && buf[j] == UInt8(ascii: " ") { j += 1 }
            if j < n && buf[j] == UInt8(ascii: ".") { j += 1 }
            if j + 3 <= n && buf[j..<j + 3].elementsEqual(efi) {
                return true
            }
            start = at + 1
        }
        return false
    }
    return haystack.withContiguousStorageIfAvailable(search) ?? Array(haystack).withUnsafeBufferPointer(search)
}

/// El Torito platform IDs, as found in an ISO's boot catalog.
enum BootPlatform: UInt8, CaseIterable {
    case x86BIOS = 0
    case powerPC = 1
    case mac = 2
    case uefi = 0xEF
}

/// The platforms an ISO's El Torito boot catalog has bootable entries for.
/// The boot record volume descriptor (among sectors 16-31) points at the
/// catalog: a validation entry, the default entry, then section headers
/// (0x90, or 0x91 for the last) each followed by their entries.
func elToritoPlatforms(_ url: URL) -> Set<UInt8> {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    func sector(_ n: UInt64) -> [UInt8]? {
        guard (try? handle.seek(toOffset: n * 2048)) != nil,
              let data = try? handle.read(upToCount: 2048), data.count == 2048 else { return nil }
        return [UInt8](data)
    }
    for n in UInt64(16)..<32 {
        guard let vd = sector(n), vd[1..<6].elementsEqual("CD001".utf8), vd[0] != 255 else { return [] }
        guard vd[0] == 0, vd[7..<30].elementsEqual("EL TORITO SPECIFICATION".utf8) else { continue }
        let lba = vd[0x47..<0x4B].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let cat = sector(lba), cat[0] == 1 else { return [] }
        var found: Set<UInt8> = []
        if cat[32] == 0x88 {
            found.insert(cat[1])
        }
        var i = 64
        while i + 32 <= cat.count, cat[i] == 0x90 || cat[i] == 0x91 {
            let last = cat[i] == 0x91
            let platform = cat[i + 1]
            let count = Int(cat[i + 2]) | Int(cat[i + 3]) << 8
            i += 32
            for _ in 0..<count where i + 32 <= cat.count {
                if cat[i] == 0x88 {
                    found.insert(platform)
                }
                i += 32
            }
            if last { break }
        }
        return found
    }
    return []
}

/// Reads up to `count` bytes at `offset`, or nil if the file is shorter.
private func readBytes(_ url: URL, at offset: UInt64, count: Int) -> [UInt8]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: offset)) != nil,
          let data = try? handle.read(upToCount: count), data.count == count else { return nil }
    return [UInt8](data)
}

/// A PC floppy image: one of the standard floppy sizes, with a boot sector.
func isFloppyImage(_ url: URL) -> Bool {
    let sizes: Set<Int> = [368_640, 737_280, 1_228_800, 1_474_560, 1_720_320, 2_949_120]
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    guard sizes.contains(size), let boot = readBytes(url, at: 0, count: 512) else { return false }
    return boot[510] == 0x55 && boot[511] == 0xAA
}

/// Whether `url` starts with an Apple Driver Map ("ER") followed by an
/// Apple Partition Map ("PM"), as Mac CDs and disks do.
func hasApplePartitionMap(_ url: URL) -> Bool {
    guard let head = readBytes(url, at: 0, count: 514) else { return false }
    return head[0..<2].elementsEqual("ER".utf8) && head[512..<514].elementsEqual("PM".utf8)
}

/// The architectures `url` could be: from its name, its ISO volume label,
/// the UEFI boot loaders inside it and its El Torito boot catalog, or, for
/// a PC floppy image, x86. A Mac disc with no x86 or UEFI way in is PowerPC.
public func detectArch(_ url: URL) -> [String] {
    if let a = archFromName(url.path) {
        return [a]
    }
    let label = fileBrief(url).lowercased()
    if label.contains("aarch64") || label.contains("arm64") || label.contains("evbarm") {
        return ["arm64"]
    }
    if label.contains("amd64") || label.contains("x86_64") {
        return ["amd64"]
    }
    if label.contains("i386") {
        return ["i386"]
    }
    if label.contains("sparc64") || label.contains("sun4u") {
        return ["sparc64"]
    }
    let platforms = elToritoPlatforms(url)
    let pcBootable = platforms.contains(BootPlatform.x86BIOS.rawValue) || platforms.contains(BootPlatform.uefi.rawValue)
    let macBootable = platforms.contains(BootPlatform.powerPC.rawValue) || platforms.contains(BootPlatform.mac.rawValue)
    if !pcBootable && (macBootable || hasApplePartitionMap(url)) {
        return ["ppc"]
    }

    let found = scanEFILoaders(url)
    var archs = [(found.aa64, "arm64"), (found.x64, "amd64"), (found.ia32, "i386")].filter(\.0).map(\.1)
    // 64-bit x86 discs often carry a 32-bit loader too, for 32-bit UEFI tablets.
    if found.x64 {
        archs.removeAll { $0 == "i386" }
    }
    // A disc that boots x86 BIOS is an x86 disc, even if its boot loader
    // ships an arm64 build too (ZealOS's Limine has all three). Some arm64
    // discs mislabel their EFI image as x86, so this only counts when there
    // are x86 loaders, or none at all.
    if platforms.contains(BootPlatform.x86BIOS.rawValue) {
        if archs.contains(where: { $0 != "arm64" }) {
            archs.removeAll { $0 == "arm64" }
        } else if archs.isEmpty {
            archs = ["amd64"]
        }
    }
    if archs.isEmpty && isFloppyImage(url) {
        archs = ["amd64"]
    }
    return archs
}

/// Why crab can't boot `url`, for images that are plainly for some other
/// kind of machine. Cheap: it reads only the name and the first sectors.
public func unsupportedImageReason(_ url: URL) -> String? {
    let base = url.lastPathComponent
    let notSupported = "crab only boots arm64, x86, PowerPC Mac and SPARC64 guests"
    let cpus = [
        "ppc64": "64-bit POWER", "ppc64le": "64-bit POWER", "ppc64el": "64-bit POWER",
        "sparc": "32-bit SPARC", "mips": "MIPS",
        "riscv64": "RISC-V", "m68k": "68k", "arm": "32-bit ARM", "armv7": "32-bit ARM", "armhf": "32-bit ARM",
    ]
    let words = url.fileStem.lowercased().split { !$0.isLetter && !$0.isNumber }
    if let cpu = words.lazy.compactMap({ cpus[String($0)] }).first {
        return "\(base) looks like a \(cpu) image; \(notSupported)"
    }
    if url.pathExtension.lowercased() == "dmg" {
        return "\(base) is a macOS disk image (.dmg), not an OS to boot"
    }
    return nil
}

/// `detectArch`, but an image that's plainly for another kind of machine
/// is an error rather than an empty list. That's checked first, since
/// `detectArch` may read the whole image; a name naming an arch crab boots wins.
func detectBootableArch(_ url: URL) throws(CrabError) -> [String] {
    if isIPSW(url) {
        throw CrabError("\(url.lastPathComponent) is a macOS restore image. crab installs those with Apple's Virtualization framework (crab get macos), not QEMU.")
    }
    if archFromName(url.path) == nil, let why = unsupportedImageReason(url) {
        throw CrabError(why)
    }
    return detectArch(url)
}

public func hasEFILoader(_ url: URL) -> Bool {
    let found = scanEFILoaders(url)
    return found.aa64 || found.x64 || found.ia32
}

public func isCDImage(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    guard url.isFile else { return ext == "iso" }
    if fileBrief(url).contains("ISO 9660") {
        return true
    }
    // Mac CDs are often plain HFS with an Apple partition map, no ISO 9660.
    return ["iso", "cdr", "toast"].contains(ext) && hasApplePartitionMap(url)
}

public func isBSDImage(_ url: URL) -> Bool {
    let fb = url.isFile ? fileBrief(url) : ""
    let text = "\(url.lastPathComponent) \(fb)".lowercased()
    return text.contains("openbsd") || text.contains("freebsd") || text.contains("netbsd")
}

// MARK: - Menus

public enum MenuPick {
    case image(URL)
    case vm(URL)
}

public func selectNumbered(_ labels: [String], header: String? = nil) -> Int? {
    if let header {
        print(header)
    }
    for (i, label) in labels.enumerated() {
        print("\(i + 1)) \(label)")
    }
    while true {
        guard let reply = promptLine("> ") else { return nil }
        if let n = Int(reply.trimmed), n >= 1, n <= labels.count {
            return n - 1
        }
        print("Pick a number from 1 to \(labels.count).")
    }
}

public func pickFromMenu(_ paths: Paths) throws(CrabError) -> MenuPick {
    var choices: [MenuPick] = []
    var labels: [String] = []

    for img in listImageEntries(paths) {
        var extra = img.sizeHuman
        if !img.fileInfo.isEmpty {
            extra += ", \(img.fileInfo)"
        }
        if let b = img.lastBootedSecs {
            extra += ", booted \(fmtAge(b))"
        }
        choices.append(.image(img.path))
        labels.append("\(img.name)  (\(extra))")
    }

    for v in listVMEntries(paths) {
        var details = "\(v.arch.isEmpty ? "?" : v.arch), \(v.mem), \(v.cpus) CPUs"
        if !v.sshPort.isEmpty && v.sshPort != "0" {
            details += ", ssh :\(v.sshPort)"
        }
        if v.runningPID != nil {
            details += ", running"
        }
        choices.append(.vm(v.dir))
        labels.append("[VM] \(v.name)  (\(details))")
    }

    if choices.isEmpty {
        throw CrabError("no .iso/.img/.ipsw files in \(paths.searchDir.path) and no VMs in \(paths.vmRoot.path)")
    }
    guard let idx = selectNumbered(labels, header: "Choose something to boot:") else {
        throw CrabError("nothing chosen")
    }
    return choices[idx]
}

// MARK: - Host helpers

func createScratchDir(_ scratchRoot: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    let pid = ProcessInfo.processInfo.processIdentifier
    for i in 0..<1000 {
        let candidate = scratchRoot.appending(path: "crab-\(pid)-\(i)", directoryHint: .isDirectory)
        if !candidate.exists {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
            return candidate
        }
    }
    throw CrabError("could not allocate scratch dir")
}

/// Whether something on this Mac is already listening on TCP `port` on localhost.
public func portInUse(_ portStr: String) -> Bool {
    guard let port = UInt16(portStr), port > 0 else { return false }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    // Allow binding over connections in TIME_WAIT.
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return rc != 0
}

/// QEMU's share directory, where its UEFI firmware lives.
func qemuShareDir() -> URL {
    if let brew = findExecutable("brew"),
       let out = try? runCapturing(brew, ["--prefix", "qemu"]), out.success {
        let prefix = out.stdout.trimmed
        if !prefix.isEmpty {
            return URL(filePath: prefix).appending(path: "share/qemu")
        }
    }
    for binName in ["qemu-system-aarch64", "qemu-system-x86_64"] {
        if let bin = findExecutable(binName)?.resolvingSymlinksInPath() {
            let share = bin.deletingLastPathComponent().deletingLastPathComponent().appending(path: "share/qemu")
            if share.isDirectory {
                return share
            }
        }
    }
    let opt = URL(filePath: "/opt/homebrew/share/qemu")
    return opt.isDirectory ? opt : URL(filePath: "/usr/local/share/qemu")
}

/// The (code, vars template) file names QEMU ships in its share directory.
func qemuUEFINames(_ arch: String) -> (code: String, vars: String) {
    switch arch {
    case "arm64": return ("edk2-aarch64-code.fd", "edk2-arm-vars.fd")
    case "amd64": return ("edk2-x86_64-code.fd", "edk2-i386-vars.fd")
    default: return ("edk2-i386-code.fd", "edk2-i386-vars.fd")
    }
}

func baseName(_ url: URL) -> String {
    url.lastPathComponent
}

/// Names a new VM after its image, adding the arch unless it's already in there.
public func defaultVMName(_ image: URL, arch: String) -> String {
    var name = image.fileStem
    if name.isEmpty {
        name = "vm"
    }
    if archFromName(name) != arch {
        name += "-\(arch)"
    }
    return name
}

/// Picks a host port for a new VM's SSH forward that no saved VM uses and
/// nothing on this Mac is listening on.
public func pickFreePort(_ paths: Paths, ownDir: URL) -> UInt16? {
    var taken: Set<UInt16> = []
    for dir in listVMDirs(paths) where dir.standardizedFileURL != ownDir.standardizedFileURL {
        if let p = UInt16(confGet(dir, "ssh_port")) {
            taken.insert(p)
        }
        if let fwds = try? Forward.parseList(confGet(dir, "fwd")) {
            taken.formUnion(fwds.map(\.host))
        }
    }
    return (2222..<2300).first { !taken.contains($0) && !portInUse(String($0)) }
}

func afterThrowaway(_ paths: Paths, scratch: URL, image: URL?, defaultName: String, live: Bool) throws(CrabError) {
    let fm = FileManager.default
    let disk = scratch.appending(path: "disk.qcow2")
    if !live {
        if diskKB(disk) < 1024 {
            print("Nothing was written to the disk, so there's nothing to keep.")
        } else if askYes("Keep this VM (\(humanSize(disk)))?") {
            while true {
                guard let input = promptLine("Name [\(defaultName)]: ") else {
                    try? fm.removeItem(at: scratch)
                    throw CrabError("no name given; discarding the VM")
                }
                let name = input.trimmed.isEmpty ? defaultName : input.trimmed
                if name.isEmpty || name.hasPrefix(".") || name.contains("/") {
                    print("Names can't start with a dot or contain '/'.")
                    continue
                }
                let dest = paths.vmRoot.appending(path: name, directoryHint: .isDirectory)
                if dest.exists {
                    print("There's already a VM called '\(name)'.")
                    continue
                }
                try? fm.removeItem(at: scratch.appending(path: "qemu.pid"))
                try? fm.removeItem(at: QMP.socketPath(scratch))
                do {
                    try fm.moveItem(at: scratch, to: dest)
                } catch {
                    throw CrabError("failed to move scratch VM to \(dest.path): \(error.localizedDescription)")
                }
                print("Kept as '\(name)'. Boot it again with: crab boot \(name)")
                return
            }
        }
    }

    try? fm.removeItem(at: scratch)
    print("Throwaway VM deleted.")
    if let image, image.isFile {
        let base = baseName(image)
        if askYes("Delete the image \(base) (\(humanSize(image))) too?") {
            try? fm.removeItem(at: image)
            print("Deleted \(base).")
        }
    }
}

// MARK: - Boot requests and settings

public enum BootMode: Sendable, Equatable {
    /// A saved VM, by name.
    case vm
    /// `-k`: creates or reuses `~/VMs/<name>` with the image attached.
    case named
    /// The default for images: runs in `~/VMs/.scratch/...`.
    case throwaway
    /// `-l`: no disk at all.
    case live
}

/// What we know about the image being booted, worked out once up front.
public struct ImageInfo: Sendable, Equatable {
    public var path: URL
    public var isCD: Bool
    public var isBSD: Bool

    public init(path: URL, isCD: Bool, isBSD: Bool) {
        self.path = path
        self.isCD = isCD
        self.isBSD = isBSD
    }

    public static func probe(_ url: URL) -> ImageInfo {
        ImageInfo(path: url, isCD: isCDImage(url), isBSD: isBSDImage(url))
    }
}

/// Everything needed to boot, once the CLI or GUI has decided which VM
/// directory to use and (for images) which architecture it is.
public struct BootRequest: Sendable {
    public var mode: BootMode
    public var vmDir: URL
    public var image: ImageInfo?
    /// Empty means "use the VM's saved architecture".
    public var arch: String
    public var defaultName: String
    public var newVM: Bool

    /// The name QEMU shows in its window title.
    var displayName: String {
        switch mode {
        case .vm, .named: vmDir.lastPathComponent
        case .throwaway, .live: defaultName
        }
    }
}

/// A VM's settings after combining flags, its vm.conf and the defaults.
public struct VMSettings: Sendable, Equatable {
    public var arch: String
    public var firmware: String
    public var mem: String
    public var cpus: String
    public var display: String
    /// Empty when SSH isn't forwarded.
    public var sshPort: String
    public var forwards: [Forward]
    public var hw: String
    public var gpu: String
    public var fullscreen: String

    var confEntries: [(String, String)] {
        [
            ("arch", arch),
            ("firmware", firmware),
            ("mem", mem),
            ("cpus", cpus),
            ("display", display),
            ("ssh_port", sshPort.isEmpty ? "0" : sshPort),
            ("fwd", Forward.listToConf(forwards)),
            ("hw", hw),
            ("gpu", gpu),
            ("fullscreen", fullscreen),
        ]
    }
}

/// A flag if one was given, else the saved value if there is one.
private func flagOrSaved(_ flag: String?, _ saved: String) -> String? {
    if let flag, !flag.isEmpty {
        return flag
    }
    return saved.isEmpty ? nil : saved
}

/// Settings come from flags first, then the VM's saved values, then defaults.
/// `hasEFI` is only called when the firmware has to be guessed, since it
/// reads the whole image. Returns the settings plus notes for the user.
func resolveSettings(
    _ opts: BootOptions,
    conf: (String) -> String,
    arch: String,
    image: ImageInfo?,
    newVM: Bool,
    hasEFI: () -> Bool,
    pickPort: () -> UInt16?
) throws(CrabError) -> (VMSettings, [String]) {
    var notes: [String] = []

    let ppc = arch == "ppc"
    let sparc64 = arch == "sparc64"
    // Mac OS 9 can't use more than 1.5G, and QEMU's mac99 has a single CPU.
    var mem = flagOrSaved(opts.mem, conf("mem")) ?? (ppc ? defaultPPCMem : defaultMem)
    if ppc, let mb = memMB(mem), mb > maxPPCMemMB {
        notes.append("PowerPC Macs get at most \(maxPPCMemMB)M (Mac OS 9 won't boot with more); using \(maxPPCMemMB)M.")
        mem = "\(maxPPCMemMB)M"
    }
    var cpus = flagOrSaved(opts.cpus, conf("cpus")) ?? ((ppc || sparc64) ? "1" : String(defaultCPUs))
    if (ppc || sparc64) && cpus != "1" {
        if opts.cpus != nil {
            let desc = ppc ? "PowerPC Macs (mac99)" : "SPARC64 (sun4u)"
            notes.append("\(desc) have one CPU; using 1.")
        }
        cpus = "1"
    }

    // New VMs get a free SSH port unless one was asked for; -p 0 turns it off.
    var sshPort: String
    if let p = opts.sshPort, !p.isEmpty {
        sshPort = p
    } else if newVM {
        sshPort = pickPort().map(String.init) ?? ""
    } else {
        sshPort = conf("ssh_port")
    }
    if sshPort == "0" {
        sshPort = ""
    }

    let forwards: [Forward]
    if let f = opts.forwards {
        forwards = f
    } else {
        do {
            forwards = try Forward.parseList(conf("fwd"))
        } catch {
            throw CrabError("vm.conf: \(error.message)")
        }
    }

    let display = flagOrSaved(opts.display, conf("display")) ?? {
        // VMs from older versions of vmboot: arm64 used the serial console.
        let terminal = image.map(\.isBSD) ?? (arch == "arm64")
        return terminal ? "terminal" : "window"
    }()

    let firmware: String
    if ppc {
        if opts.firmware.map({ !$0.isEmpty }) == true {
            throw CrabError("PowerPC Macs boot with Open Firmware; -f is for x86 guests")
        }
        firmware = "openbios"
    } else if sparc64 {
        if opts.firmware.map({ !$0.isEmpty }) == true {
            throw CrabError("SPARC64 guests boot with OpenBIOS; -f is for x86 guests")
        }
        firmware = "openbios"
    } else if let f = flagOrSaved(opts.firmware, conf("firmware")) {
        firmware = f
    } else if let image, arch != "arm64", !hasEFI() {
        notes.append("No UEFI boot loader in \(baseName(image.path)); using legacy BIOS.")
        firmware = "bios"
    } else {
        firmware = "uefi"
    }
    if arch == "arm64" && firmware == "bios" {
        throw CrabError("arm64 guests always boot with UEFI")
    }

    let gpu = flagOrSaved(opts.gpu, conf("gpu")) ?? "virtio"
    let fullscreen = flagOrSaved(opts.fullscreen, conf("fullscreen")) ?? "off"

    // New x86 VMs get an AHCI disk and an e1000 network card, which x86 OSes
    // since the mid-2000s have drivers for. Ones that can only boot with BIOS
    // are older, so they get the legacy PC: i440fx, IDE and a PCnet card,
    // which DOS-era CD drivers, Windows 9x and XP understand. arm64 OSes all
    // speak virtio, and so did VMs from older versions of vmboot.
    // PowerPC VMs are always QEMU's mac99 (a G4 Power Mac).
    // SPARC64 VMs are always QEMU's sun4u (a Sun Ultra 5).
    if ppc && opts.hw.map({ !$0.isEmpty }) == true {
        throw CrabError("PowerPC Macs always use mac99 hardware; -H is for x86 guests")
    }
    if sparc64 && opts.hw.map({ !$0.isEmpty }) == true {
        throw CrabError("SPARC64 guests always use sun4u hardware; -H is for x86 guests")
    }
    let hw = ppc ? "mac99" : (sparc64 ? "sun4u" : flagOrSaved(opts.hw, conf("hw")) ?? {
        guard newVM && arch != "arm64" else { return "virtio" }
        return firmware == "bios" ? "legacy" : "standard"
    }())
    if arch == "arm64" && hw != "virtio" {
        throw CrabError("arm64 guests always use virtio hardware")
    }

    let settings = VMSettings(
        arch: arch, firmware: firmware, mem: mem, cpus: cpus, display: display, sshPort: sshPort,
        forwards: forwards, hw: hw, gpu: gpu, fullscreen: fullscreen
    )
    return (settings, notes)
}

/// The QEMU binary and arguments for a boot, with no side effects.
struct QemuCommand {
    var qemu: String
    var args: [String]
    var fwCode: URL?
    var fwVarsTemplate: URL?
    var notes: [String]
}

/// The `-accel` and `-cpu` arguments for a guest (`"arm64"` or `"x86"`) on
/// a Mac with `hostArch`, plus a note if it will run under emulation.
func accelArgs(guest: String, hostArch: String) -> ([String], String?) {
    let sameArch = guest == "arm64" ? hostArch == "arm64" : hostArch == "x86_64"
    if !sameArch {
        let note = guest == "arm64"
            ? "Note: arm64 guest on an x86_64 host runs under emulation (slow)."
            : "Note: x86 guest on an arm64 host runs under emulation (works, but slow)."
        return (["-accel", "tcg", "-cpu", "max"], note)
    }
    return (["-accel", "hvf", "-cpu", "host"], nil)
}

/// Builds the QEMU command line, with no filesystem access: `uefi` finds the
/// (code, vars template) firmware pair for an arch. `forceWindow` opens a
/// window even for VMs set to use the serial console, since the GUI has no terminal.
func buildQemuCommand(
    _ s: VMSettings,
    _ req: BootRequest,
    hostArch: String,
    uefi: (String) -> (URL, URL),
    forceWindow: Bool
) throws(CrabError) -> QemuCommand {
    var args: [String] = []
    var notes: [String] = []
    let qemu: String
    var fwCode: URL?
    var fwVarsTemplate: URL?
    let arch = s.arch

    switch arch {
    case "arm64":
        qemu = "qemu-system-aarch64"
        args += ["-M", "virt"]
        (fwCode, fwVarsTemplate) = uefi("arm64")
        let (accel, note) = accelArgs(guest: "arm64", hostArch: hostArch)
        args += accel
        if let note { notes.append(note) }
    case "amd64", "i386":
        qemu = arch == "amd64" ? "qemu-system-x86_64" : "qemu-system-i386"
        if s.firmware != "bios" {
            (fwCode, fwVarsTemplate) = uefi(arch)
        }
        args += ["-M", s.hw == "legacy" ? "pc" : "q35"]
        let (accel, note) = accelArgs(guest: "x86", hostArch: hostArch)
        args += accel
        if let note { notes.append(note) }
    case "ppc":
        // A G4 Power Mac with a PMU (which brings USB keyboard and mouse),
        // booting QEMU's built-in OpenBIOS. vga-ndrv lets Mac OS change the
        // screen resolution.
        qemu = "qemu-system-ppc"
        args += ["-M", "mac99,via=pmu", "-accel", "tcg"]
        args += ["-prom-env", "auto-boot?=true", "-prom-env", "vga-ndrv?=true"]
        notes.append("Note: PowerPC guests run under emulation (works, but slow).")
    case "sparc64":
        // Sun Ultra 5 workstation, booting QEMU's built-in OpenBIOS.
        qemu = "qemu-system-sparc64"
        args += ["-M", "sun4u", "-accel", "tcg"]
        notes.append("Note: SPARC64 guests run under emulation (works, but slow).")
    default:
        throw CrabError("unsupported architecture: \(arch)")
    }

    let vmDir = req.vmDir
    let disk = vmDir.appending(path: "disk.qcow2")
    let vars = vmDir.appending(path: "efivars.fd")

    if let fwCode {
        args += [
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(fwCode.path)",
            "-drive", "if=pflash,format=raw,unit=1,file=\(vars.path)",
        ]
    }

    let (diskIf, nic) = switch s.hw {
    case "standard": ("ide", "e1000")
    case "legacy": ("ide", "pcnet")
    case "mac99": ("ide", "sungem")
    case "sun4u": ("ide", "sunhme")
    default: ("virtio", "virtio-net-pci")
    }

    args += ["-name", req.displayName, "-m", s.mem, "-smp", s.cpus]

    if req.mode != .live {
        // An explicit boot order overrides whatever efivars.fd has saved, which
        // can leave the firmware ignoring a CD. Disk first, so an empty disk
        // falls through to the CD but a finished install doesn't reboot into it.
        let cdAttached = req.image?.isCD ?? false
        if arch == "arm64" && diskIf == "virtio" && cdAttached {
            args += [
                "-drive", "file=\(disk.path),if=none,id=disk,format=qcow2",
                "-device", "virtio-blk-pci,drive=disk,bootindex=0",
            ]
        } else {
            args += ["-drive", "file=\(disk.path),if=\(diskIf),format=qcow2"]
        }
    }

    var nicArg = "user,model=\(nic)"
    if !s.sshPort.isEmpty {
        nicArg += ",hostfwd=tcp:127.0.0.1:\(s.sshPort)-:22"
    }
    for f in s.forwards {
        nicArg += ",hostfwd=\(f.hostfwd)"
    }
    args += ["-nic", nicArg]
    args += ["-pidfile", vmDir.appending(path: "qemu.pid").path]
    if let sock = QMP.usableSocketPath(vmDir) {
        args += ["-qmp", "unix:\(sock.path),server=on,wait=off"]
    } else {
        notes.append("Note: \(vmDir.path) is too long a path for a control socket, so crab stop won't work for this VM.")
    }

    if let img = req.image {
        let path = img.path.path
        if !img.isCD {
            args += ["-drive", "file=\(path),if=\(diskIf),format=raw,snapshot=on"]
        } else if arch == "arm64" {
            args += [
                "-device", "virtio-scsi-pci",
                "-drive", "if=none,id=cd,media=cdrom,readonly=on,file=\(path)",
                "-device", "scsi-cd,drive=cd,bootindex=1",
            ]
        } else {
            // Index 2 (secondary master) is where QEMU puts its default CD
            // drive, so taking it leaves one drive instead of ours plus an empty one.
            args += ["-drive", "file=\(path),media=cdrom,readonly=on,index=2"]
        }
    }
    // OpenBIOS boots one device and doesn't fall back to the next, so boot
    // the CD while one is attached.
    if arch == "ppc" || arch == "sparc64" {
        args += ["-boot", req.image?.isCD == true ? "d" : "c"]
    }

    if s.display == "terminal" && !forceWindow {
        args.append("-nographic")
    } else {
        args += ["-display", "cocoa,zoom-to-fit=on,full-screen=\(s.fullscreen)"]
        if arch == "arm64" {
            args += ["-device", s.gpu == "ramfb" ? "ramfb" : "virtio-gpu-pci"]
            args += ["-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet"]
        }
    }

    return QemuCommand(qemu: qemu, args: args, fwCode: fwCode, fwVarsTemplate: fwVarsTemplate, notes: notes)
}

/// A boot that's ready to go: the VM directory is set up (unless this is a
/// dry run) and all that's left is to run QEMU.
public struct BootPlan: Sendable {
    public var qemu: String
    public var args: [String]
    public var settings: VMSettings
    public var notes: [String]

    public var commandLine: String {
        "\(qemu) \(args.joined(separator: " "))"
    }
}

/// Shared by the CLI and the GUI: resolves settings, checks that QEMU, its
/// firmware and the host ports are available, then creates the disk, UEFI
/// variable store and vm.conf.
public func prepareBoot(_ paths: Paths, _ opts: BootOptions, _ req: BootRequest, forceWindow: Bool) throws(CrabError) -> BootPlan {
    let vmDir = req.vmDir
    try requireStopped(vmDir)

    var arch = req.arch
    if arch.isEmpty {
        arch = confGet(vmDir, "arch")
        if arch.isEmpty {
            throw CrabError("\(vmDir.path) has no saved architecture; can't tell which QEMU to use")
        }
    }

    let resolved = try resolveSettings(
        opts,
        conf: { confGet(vmDir, $0) },
        arch: arch,
        image: req.image,
        newVM: req.newVM,
        hasEFI: {
            guard let img = req.image else { return true }
            return !img.path.isFile || hasEFILoader(img.path)
        },
        pickPort: { pickFreePort(paths, ownDir: vmDir) }
    )
    let settings = resolved.0
    var notes = resolved.1

    if !settings.sshPort.isEmpty && portInUse(settings.sshPort) {
        throw CrabError("port \(settings.sshPort) is already in use on this Mac; pick another with -p")
    }
    for f in settings.forwards {
        if String(f.host) == settings.sshPort {
            throw CrabError("port \(f.host) is forwarded twice")
        }
        if !f.udp && portInUse(String(f.host)) {
            throw CrabError("port \(f.host) is already in use on this Mac; change it with -P")
        }
    }

    let share = qemuShareDir()
    let cmd = try buildQemuCommand(settings, req, hostArch: hostUnameM(), uefi: { arch in
        let names = qemuUEFINames(arch)
        return (share.appending(path: names.code), share.appending(path: names.vars))
    }, forceWindow: forceWindow)
    notes += cmd.notes

    if !commandExists(cmd.qemu) {
        throw CrabError("\(cmd.qemu) not found (\(installQemuHint))")
    }
    try needQemuImg()
    if let code = cmd.fwCode, !code.isFile {
        throw CrabError("UEFI firmware not found at \(code.path) (\(installQemuHint))")
    }
    if let tmpl = cmd.fwVarsTemplate, !tmpl.isFile {
        throw CrabError("UEFI variable store template not found at \(tmpl.path)")
    }

    let disk = vmDir.appending(path: "disk.qcow2")
    let diskSize = opts.diskSize.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDiskSize
    if req.mode == .named && req.newVM {
        notes.append("New \(diskSize) disk at \(disk.path)")
    }

    if !opts.dryRun {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: vmDir, withIntermediateDirectories: true)
        } catch {
            throw CrabError("failed to create \(vmDir.path): \(error.localizedDescription)")
        }
        if req.mode != .live && !disk.isFile {
            if !(try qemuImg(["create", "-q", "-f", "qcow2", disk.path, diskSize])).success {
                throw CrabError("qemu-img create failed")
            }
        }
        let vars = vmDir.appending(path: "efivars.fd")
        if let tmpl = cmd.fwVarsTemplate, !vars.isFile {
            do {
                try fm.copyItem(at: tmpl, to: vars)
            } catch {
                throw CrabError("failed to copy efivars.fd: \(error.localizedDescription)")
            }
        }
        do {
            try confSet(vmDir, settings.confEntries)
        } catch {
            throw CrabError("failed to write vm.conf: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: QMP.socketPath(vmDir))
    }

    if let img = req.image {
        logImageBoot(paths, img.path, dryRun: opts.dryRun)
    }

    let finalArgs = cmd.args + opts.extraQemuArgs
    return BootPlan(qemu: cmd.qemu, args: finalArgs, settings: settings, notes: notes)
}

// MARK: - CLI boot

public func cmdBoot(_ paths: Paths, _ opts: BootOptions, vmName: String?, image imageArg: URL?) throws(CrabError) {
    var image: URL?
    var vmDir: URL?

    if let vn = vmName, !vn.isEmpty {
        vmDir = try vmPath(paths, vn)
    } else if let imageArg {
        image = absPath(imageArg)
    } else {
        switch try pickFromMenu(paths) {
        case .image(let p): image = p
        case .vm(let d): vmDir = d
        }
    }

    if let vmDir, isMacOSVM(vmDir) {
        try launchSavedMacOSVM(paths, opts, dir: vmDir)
        return
    }
    if let image, isIPSW(image) {
        try launchMacOSInstaller(paths, opts, image: image)
        return
    }

    let mode: BootMode
    if image == nil {
        if opts.live || opts.keep {
            throw CrabError("-k and -l are for booting images, not saved VMs\nRun 'crab -h' for usage.")
        }
        mode = .vm
    } else if opts.keep {
        mode = .named
    } else if opts.live {
        mode = .live
    } else {
        mode = .throwaway
    }

    var arch = ""
    var defaultName = ""

    if let img = image {
        let detected: String
        if let ka = opts.knownArch {
            detected = ka
        } else if let oa = opts.arch {
            detected = oa
        } else {
            let candidates = try detectBootableArch(img)
            if candidates.count == 1 {
                detected = candidates[0]
                print("Detected architecture: \(detected)")
            } else {
                let base = baseName(img)
                let list: [String]
                if candidates.isEmpty {
                    print("Couldn't detect the architecture of \(base).")
                    list = ["arm64", "amd64", "i386", "ppc", "sparc64"]
                } else {
                    print("\(base) has boot loaders for more than one architecture. Which is it?")
                    list = candidates
                }
                guard let idx = selectNumbered(list) else {
                    throw CrabError("no architecture chosen")
                }
                detected = list[idx]
            }
        }
        defaultName = defaultVMName(img, arch: detected)
        arch = detected
    }

    var newVM = false
    var scratchDir: URL?
    let targetDir: URL

    switch mode {
    case .vm:
        targetDir = vmDir!
    case .named:
        let input = promptLine("VM name [\(defaultName)]: ") ?? ""
        let chosen = input.trimmed.isEmpty ? defaultName : input.trimmed
        try checkName(chosen)
        let d = paths.vmRoot.appending(path: chosen, directoryHint: .isDirectory)
        if d.appending(path: "disk.qcow2").isFile {
            print("Using the existing VM '\(chosen)', with the installer attached.")
            let saved = confGet(d, "arch")
            if !saved.isEmpty && saved != arch {
                print("Note: this VM is \(saved), but the image looks like \(arch). Keeping \(saved).")
            }
            arch = ""
        } else {
            newVM = true
        }
        targetDir = d
    case .throwaway, .live:
        newVM = true
        if opts.dryRun {
            targetDir = paths.scratchRoot.appending(path: "DRY-RUN")
        } else {
            do {
                let s = try createScratchDir(paths.scratchRoot)
                scratchDir = s
                targetDir = s
            } catch {
                throw CrabError("failed to create scratch dir: \(error.localizedDescription)")
            }
        }
    }

    let req = BootRequest(
        mode: mode, vmDir: targetDir, image: image.map(ImageInfo.probe), arch: arch,
        defaultName: defaultName, newVM: newVM
    )
    do {
        try runCLIBoot(paths, opts, req)
    } catch {
        if let scratchDir {
            try? FileManager.default.removeItem(at: scratchDir)
        }
        throw error
    }
}

func runCLIBoot(_ paths: Paths, _ opts: BootOptions, _ req: BootRequest) throws(CrabError) {
    let plan = try prepareBoot(paths, opts, req, forceWindow: false)
    let s = plan.settings
    for note in plan.notes {
        print(note)
    }

    switch req.mode {
    case .throwaway: print("Throwaway VM: you'll be asked whether to keep it when QEMU exits.")
    case .live: print("Live boot: no disk attached, nothing is kept.")
    case .vm, .named: break
    }

    if s.display == "terminal" {
        print("Serial console in this terminal. Quit QEMU with Ctrl-A then X.")
        if s.arch == "amd64" || s.arch == "i386" {
            print("Tip: if output stops after the boot loader, type 'set tty com0' at the boot> prompt.")
        }
    } else {
        if s.fullscreen != "on" {
            print("Window: drag it bigger to scale the screen up, or boot with -F for full screen.")
        }
        if s.arch == "arm64" && s.gpu == "virtio" {
            print("Tip: if the window stays blank once the OS is up, try again with -r, or -t for the serial console.")
        }
    }
    if !s.sshPort.isEmpty {
        switch req.mode {
        case .vm, .named:
            print("SSH: once the guest runs sshd, connect with: crab ssh \(req.displayName)  (or ssh -p \(s.sshPort) <user>@localhost)")
        case .throwaway, .live:
            print("SSH: once the guest runs sshd, connect with: ssh -p \(s.sshPort) <user>@localhost")
        }
    }
    for f in s.forwards {
        print("Forwarding localhost:\(f.host) to guest port \(f.guest)\(f.udp ? " (udp)" : "").")
    }

    print()
    print(plan.commandLine)
    print()

    if opts.dryRun {
        return
    }

    let qemuBin = findExecutable(plan.qemu) ?? URL(filePath: plan.qemu)

    switch req.mode {
    case .vm, .named:
        do {
            try execReplacing(qemuBin, plan.args)
        } catch {
            throw CrabError("failed to exec \(plan.qemu): \(error.localizedDescription)")
        }
    case .throwaway, .live:
        // Ignore SIGINT while QEMU runs so we survive to ask what to keep.
        signal(SIGINT, SIG_IGN)
        let status: Int32
        do {
            status = try runInheriting(qemuBin, plan.args)
        } catch {
            signal(SIGINT, SIG_DFL)
            try? FileManager.default.removeItem(at: req.vmDir)
            throw CrabError("failed to run \(plan.qemu): \(error.localizedDescription)")
        }
        signal(SIGINT, SIG_DFL)
        print()
        if status != 0 {
            print("QEMU exited with status \(status).")
        }
        try afterThrowaway(paths, scratch: req.vmDir, image: req.image?.path, defaultName: req.defaultName, live: req.mode == .live)
    }
}

// MARK: - GUI boot

/// A QEMU started by the GUI, plus what it needs to offer keep/discard when QEMU exits.
public final class SpawnedVM: @unchecked Sendable {
    public let process: Process
    public let scratchDir: URL?
    public let imagePath: URL?
    public let defaultName: String
    public let live: Bool
    public let qemuCommandLine: String

    init(process: Process, scratchDir: URL?, imagePath: URL?, defaultName: String, live: Bool, qemuCommandLine: String) {
        self.process = process
        self.scratchDir = scratchDir
        self.imagePath = imagePath
        self.defaultName = defaultName
        self.live = live
        self.qemuCommandLine = qemuCommandLine
    }

    /// The throwaway VM this is, or nil for saved VMs.
    public var throwaway: ThrowawayInfo? {
        scratchDir.map { ThrowawayInfo(dir: $0, imagePath: imagePath, defaultName: defaultName, live: live) }
    }
}

/// A throwaway or live VM started by the app. It's also saved in the scratch
/// dir, so the app can pick it back up after quitting while QEMU runs on.
public struct ThrowawayInfo: Sendable, Identifiable, Hashable {
    public let dir: URL
    public let imagePath: URL?
    public let defaultName: String
    public let live: Bool
    public var id: URL { dir }
}

/// The file in a scratch dir that marks it as the app's (crab-only; CLI
/// throwaways don't have one, since the CLI asks about them itself).
public func throwawayInfoFile(_ dir: URL) -> URL {
    dir.appending(path: "gui-session")
}

func saveThrowawayInfo(_ info: ThrowawayInfo) throws {
    var lines = ["name=\(info.defaultName)", "live=\(info.live ? "on" : "off")"]
    if let image = info.imagePath {
        lines.append("image=\(image.path)")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: throwawayInfoFile(info.dir), atomically: true, encoding: .utf8)
}

/// Throwaway VMs the app started, running or not, found in the scratch folder.
public func listAppThrowaways(_ paths: Paths) -> [ThrowawayInfo] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: paths.scratchRoot, includingPropertiesForKeys: nil)) ?? []
    return entries.compactMap { dir in
        let file = throwawayInfoFile(dir)
        guard dir.isDirectory, file.isFile else { return nil }
        return ThrowawayInfo(
            dir: dir,
            imagePath: readConfigKey(file, "image").map { URL(filePath: $0) },
            defaultName: readConfigKey(file, "name") ?? dir.lastPathComponent,
            live: readConfigKey(file, "live") == "on"
        )
    }
}

/// The architecture the app boots an image as: one given outright, else the
/// first detected, else the app's fallback setting, else this Mac's.
func guiImageArch(_ opts: BootOptions, detect: () throws(CrabError) -> [String]) throws(CrabError) -> String {
    func given(_ a: String?) -> String? { a.flatMap { $0.isEmpty ? nil : $0 } }
    if let a = given(opts.knownArch) ?? given(opts.arch) {
        return a
    }
    return try detect().first ?? given(opts.fallbackArch) ?? hostArch()
}

/// Prepares and starts a VM or image in a QEMU window without prompting:
/// images use `guiImageArch`. Existing VMs keep their saved settings. Blocks while it
/// scans the image, so call it off the main thread. `onExit` runs (on a
/// background thread) when QEMU exits.
public func spawnFromGUI(
    _ paths: Paths,
    _ opts: BootOptions,
    vmName: String?,
    image imagePath: URL?,
    namedTarget: String?,
    onExit: @escaping @Sendable (SpawnedVM) -> Void
) throws(CrabError) -> SpawnedVM {
    var arch = ""
    var defaultName = ""
    let image = imagePath.map(absPath)

    if let image, isIPSW(image) {
        throw CrabError("\(image.lastPathComponent) is a macOS restore image. Install it from Get Distros or Local Images; it uses Virtualization.framework, not QEMU.")
    }
    if let vmName, let dir = try? vmPath(paths, vmName), isMacOSVM(dir) {
        throw CrabError("\(vmName) is a macOS VM. Boot it from the Saved VMs list; it doesn't run under QEMU.")
    }

    let mode: BootMode
    if image == nil {
        mode = .vm
    } else if opts.keep {
        mode = .named
    } else if opts.live {
        mode = .live
    } else {
        mode = .throwaway
    }

    if let img = image {
        let detected = try guiImageArch(opts) { () throws(CrabError) in try detectBootableArch(img) }
        defaultName = defaultVMName(img, arch: detected)
        arch = detected
    }

    var newVM = false
    var scratchDir: URL?
    let vmDir: URL

    switch mode {
    case .vm:
        guard let vmName else { throw CrabError("no VM selected") }
        vmDir = try vmPath(paths, vmName)
        defaultName = vmName
    case .named:
        let chosen = namedTarget.flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed } ?? defaultName
        try checkName(chosen)
        let d = paths.vmRoot.appending(path: chosen, directoryHint: .isDirectory)
        if d.appending(path: "disk.qcow2").isFile {
            arch = ""
        } else {
            newVM = true
        }
        vmDir = d
    case .throwaway, .live:
        newVM = true
        do {
            let s = try createScratchDir(paths.scratchRoot)
            scratchDir = s
            vmDir = s
        } catch {
            throw CrabError("failed to create scratch dir: \(error.localizedDescription)")
        }
    }

    let req = BootRequest(
        mode: mode, vmDir: vmDir, image: image.map(ImageInfo.probe), arch: arch,
        defaultName: defaultName, newVM: newVM
    )
    let bootOpts = newVM ? opts : opts.withoutSavedSettings()
    do throws(CrabError) {
        let plan = try prepareBoot(paths, bootOpts, req, forceWindow: true)
        let process = Process()
        process.executableURL = findExecutable(plan.qemu) ?? URL(filePath: plan.qemu)
        process.arguments = plan.args
        process.standardInput = FileHandle.nullDevice
        let spawned = SpawnedVM(
            process: process, scratchDir: scratchDir, imagePath: image, defaultName: defaultName,
            live: mode == .live, qemuCommandLine: plan.commandLine
        )
        process.terminationHandler = { _ in onExit(spawned) }
        if let info = spawned.throwaway {
            do {
                try saveThrowawayInfo(info)
            } catch {
                throw CrabError("failed to write \(throwawayInfoFile(info.dir).path): \(error.localizedDescription)")
            }
        }
        do {
            try process.run()
        } catch {
            throw CrabError("failed to spawn \(plan.qemu): \(error.localizedDescription)")
        }
        return spawned
    } catch {
        if let scratchDir {
            try? FileManager.default.removeItem(at: scratchDir)
        }
        throw error
    }
}
