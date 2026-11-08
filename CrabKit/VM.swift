import Foundation

public struct VMEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var dir: URL
    public var disk: URL
    public var arch: String
    public var firmware: String
    public var mem: String
    public var cpus: String
    public var sshPort: String
    public var display: String
    public var hw: String
    public var gpu: String
    public var fullscreen: String
    public var sshUser: String
    public var forwards: String
    public var diskUsed: String
    public var diskVirt: String
    public var snapsCount: Int
    public var runningPID: Int32?
    /// "stopped", or QEMU's run state: "running", "paused", "shutdown", ...
    public var state: String
    public var lastUsedSecs: Int
    /// `qemu` for a QEMU VM, `vz` for a macOS guest on Virtualization.framework.
    public var backend: String
    public var id: String { name }
}

/// A macOS guest: `Disk.img` with `backend=vz`, or `Disk.img` plus a hardware
/// model and no QEMU disk. A plain `disk.qcow2` VM is never treated as one.
public func isMacOSVM(_ dir: URL) -> Bool {
    guard dir.appending(path: MacOSVMLayout.diskName).isFile else { return false }
    if confGet(dir, "backend") == vmBackendVZ { return true }
    if dir.appending(path: "disk.qcow2").isFile { return false }
    return dir.appending(path: MacOSVMLayout.hardwareModelName).isFile
}

public func isVMDirectory(_ dir: URL) -> Bool {
    dir.appending(path: "disk.qcow2").isFile || isMacOSVM(dir)
}

public func vmDiskURL(_ dir: URL) -> URL {
    if isMacOSVM(dir) { return dir.appending(path: MacOSVMLayout.diskName) }
    return dir.appending(path: "disk.qcow2")
}

public func confGet(_ dir: URL, _ key: String) -> String {
    let confPath = dir.appending(path: "vm.conf")
    if confPath.isFile {
        guard let content = try? String(contentsOf: confPath, encoding: .utf8) else { return "" }
        let prefix = "\(key)="
        var last = ""
        for line in content.lines where line.hasPrefix(prefix) {
            last = line.dropFirst(prefix.count).trimmed
        }
        return last
    }
    // VMs from old versions of vmboot only have an `arch` file.
    let archPath = dir.appending(path: "arch")
    if archPath.isFile {
        let arch = ((try? String(contentsOf: archPath, encoding: .utf8)) ?? "").trimmed
        switch key {
        case "arch": return arch
        case "firmware": return arch == "arm64" ? "uefi" : "bios"
        default: break
        }
    }
    return ""
}

/// Sets keys in a VM's vm.conf, replacing earlier values and keeping any
/// other keys. VMs from old versions of vmboot only have an `arch` file, so
/// its values are carried over when vm.conf is first created.
public func confSet(_ dir: URL, _ updates: [(String, String)]) throws {
    let confPath = dir.appending(path: "vm.conf")
    var lines: [String]
    if let content = try? String(contentsOf: confPath, encoding: .utf8) {
        lines = content.lines
    } else {
        lines = ["arch", "firmware"].compactMap { k in
            let v = confGet(dir, k)
            return v.isEmpty ? nil : "\(k)=\(v)"
        }
    }
    for (key, value) in updates {
        let prefix = "\(key)="
        let newLine = "\(key)=\(value)"
        var placed = false
        lines = lines.compactMap { line in
            guard line.hasPrefix(prefix) else { return line }
            if placed { return nil }
            placed = true
            return newLine
        }
        if !placed {
            lines.append(newLine)
        }
    }
    try (lines.joined(separator: "\n") + "\n").write(to: confPath, atomically: true, encoding: .utf8)
}

func dirName(_ dir: URL) -> String {
    dir.lastPathComponent
}

public func checkName(_ name: String) throws(CrabError) {
    if name.isEmpty || name.hasPrefix(".") || name.contains("/") || name.contains("\\") || name.contains(":") {
        throw CrabError("invalid VM name '\(name)': names can't be empty, start with a dot, or contain '/', '\\' or ':'")
    }
}

public func vmPath(_ paths: Paths, _ name: String) throws(CrabError) -> URL {
    try checkName(name)
    let dir = paths.vmRoot.appending(path: name, directoryHint: .isDirectory)
    if !isVMDirectory(dir) {
        throw CrabError("no VM named '\(name)' in \(paths.vmRoot.path) (try: crab list)")
    }
    return dir
}

/// The pid of the VM's QEMU process, if it's running.
public func vmPID(_ dir: URL) -> Int32? {
    if isMacOSVM(dir) {
        return livePIDFile(dir.appending(path: MacOSVMLayout.pidName))
    }
    guard let pidStr = try? String(contentsOf: dir.appending(path: "qemu.pid"), encoding: .utf8),
          let pid = Int32(pidStr.trimmed),
          let name = processName(pid), name.lowercased().contains("qemu") else {
        return nil
    }
    return pid
}

public func requireStopped(_ dir: URL) throws(CrabError) {
    if let pid = vmPID(dir) {
        let name = dirName(dir)
        throw CrabError("\(name) is running (pid \(pid)); shut it down first (crab stop \(name))")
    }
}

public func listVMDirs(_ paths: Paths) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: paths.vmRoot, includingPropertiesForKeys: nil)) ?? []
    return entries
        .filter { $0.isDirectory && !$0.lastPathComponent.hasPrefix(".") && isVMDirectory($0) }
        .sorted { $0.path < $1.path }
}

public func qemuImgBin() -> URL {
    findExecutable("qemu-img") ?? URL(filePath: "/opt/homebrew/bin/qemu-img")
}

public func needQemuImg() throws(CrabError) {
    if !commandExists("qemu-img") {
        throw CrabError("qemu-img not found (\(installQemuHint))")
    }
}

/// Runs qemu-img, turning a failure to start it into a CrabError.
func qemuImg(_ args: [String]) throws(CrabError) -> CommandOutput {
    do {
        return try runCapturing(qemuImgBin(), args)
    } catch {
        throw CrabError("failed to run qemu-img: \(error.localizedDescription)")
    }
}

public func qemuImgVirtSize(_ disk: URL) -> String {
    guard let out = try? runCapturing(qemuImgBin(), ["info", "-U", disk.path]) else { return "?" }
    for line in out.stdout.lines where line.hasPrefix("virtual size: ") {
        // e.g. "20 GiB (21474836480 bytes)" -> "20G"
        let parts = line.dropFirst("virtual size: ".count).split(whereSeparator: \.isWhitespace)
        if parts.count >= 2 {
            var unit = Substring(parts[1])
            if unit.hasSuffix("iB") { unit = unit.dropLast(2) }
            if unit.hasSuffix("B") { unit = unit.dropLast() }
            return "\(parts[0])\(unit)"
        }
    }
    return "?"
}

public func qemuImgSnapshots(_ disk: URL) -> [String] {
    guard let out = try? runCapturing(qemuImgBin(), ["snapshot", "-l", "-U", disk.path]) else { return [] }
    return out.stdout.lines.dropFirst(2).compactMap { line in
        let cols = line.split(whereSeparator: \.isWhitespace)
        return cols.count >= 2 ? String(cols[1]) : nil
    }
}

public func inspectVM(_ dir: URL) -> VMEntry {
    let macos = isMacOSVM(dir)
    let disk = vmDiskURL(dir)
    let mem = confGet(dir, "mem")
    let cpus = confGet(dir, "cpus")
    let diskVirt: String
    let snaps: Int
    if macos {
        let saved = confGet(dir, "disk")
        diskVirt = saved.isEmpty ? formatDiskBytes(logicalFileBytes(disk)) : saved
        snaps = 0
    } else {
        diskVirt = qemuImgVirtSize(disk)
        snaps = qemuImgSnapshots(disk).count
    }
    return VMEntry(
        name: dir.lastPathComponent,
        dir: dir,
        disk: disk,
        arch: confGet(dir, "arch"),
        firmware: confGet(dir, "firmware"),
        mem: mem.isEmpty ? (macos ? defaultMacOSMem : defaultMem) : mem,
        cpus: cpus.isEmpty ? String(macos ? defaultMacOSCPUs : defaultCPUs) : cpus,
        sshPort: confGet(dir, "ssh_port"),
        display: confGet(dir, "display"),
        hw: confGet(dir, "hw"),
        gpu: confGet(dir, "gpu"),
        fullscreen: confGet(dir, "fullscreen"),
        sshUser: confGet(dir, "ssh_user"),
        forwards: confGet(dir, "fwd"),
        diskUsed: humanSize(disk),
        diskVirt: diskVirt,
        snapsCount: snaps,
        runningPID: vmPID(dir),
        state: vmState(dir) ?? "stopped",
        lastUsedSecs: fileMtime(disk),
        backend: macos ? vmBackendVZ : vmBackendQEMU
    )
}

public func listVMEntries(_ paths: Paths) -> [VMEntry] {
    listVMDirs(paths).map(inspectVM)
}

public func cmdList(_ paths: Paths) {
    let vms = listVMEntries(paths)
    if vms.isEmpty {
        print("No VMs in \(paths.vmRoot.path)")
        return
    }
    let w = max(4, vms.map(\.name.count).max() ?? 4)
    func row(_ c: [String]) -> String {
        "\(c[0].padded(w))  \(c[1].padded(6)) \(c[2].padded(5)) \(c[3].padded(5)) \(c[4].padded(4)) \(c[5].padded(6)) \(c[6].padded(14)) \(c[7].padded(5)) \(c[8].padded(8)) \(c[9])"
    }
    print(row(["NAME", "ARCH", "FW", "MEM", "CPUS", "SSH", "DISK", "SNAPS", "STATE", "LAST USED"]))
    for v in vms {
        let ssh = !v.sshPort.isEmpty && v.sshPort != "0" ? v.sshPort : "-"
        let snaps = v.backend == vmBackendVZ ? "-" : String(v.snapsCount)
        print(row([v.name, v.arch, v.firmware, v.mem, v.cpus, ssh, "\(v.diskUsed) of \(v.diskVirt)",
                   snaps, v.state, fmtAge(v.lastUsedSecs)]))
    }
}

public func cmdImages(_ paths: Paths) {
    let images = listImageEntries(paths)
    if images.isEmpty {
        print("No .iso/.img/.ipsw files in \(paths.searchDir.path)")
        return
    }
    let w = max(5, images.map(\.name.count).max() ?? 5)
    print("\("IMAGE".padded(w))  \("SIZE".padded(7)) \("DOWNLOADED".padded(14)) LAST BOOTED")
    var totalKB = 0
    for img in images {
        let booted = img.lastBootedSecs.map(fmtAge) ?? "never"
        print("\(img.name.padded(w))  \(img.sizeHuman.padded(7)) \(fmtAge(img.downloadedSecs).padded(14)) \(booted)")
        totalKB += img.sizeKB
    }
    print()
    print("\(fmtKB(totalKB)) in \(paths.searchDir.path)")
}

/// Deletes throwaway VMs left behind (for example by a crash), skipping ones
/// that are running and ones the app can still Keep or Discard.
/// `preserving` is an extra set of scratch dirs (the app's open prompts).
/// Returns how many were removed and the KB freed.
public func cleanLeftoverScratch(_ paths: Paths, preserving protected: Set<URL> = []) -> (count: Int, freedKB: Int) {
    var n = 0
    var freed = 0
    let keep = Set(protected.map { $0.resolvingSymlinksInPath().path } + protected.map { imageEntryPath($0).path })
    let entries = (try? FileManager.default.contentsOfDirectory(at: paths.scratchRoot, includingPropertiesForKeys: nil)) ?? []
    for p in entries where p.isDirectory && vmPID(p) == nil {
        // A gui-session file means the app started this VM and has not
        // finished Keep or Discard, including after a crash or quit.
        // Both state=running and state=pending are kept.
        if scratchIsRecoverable(p) || keep.contains(p.resolvingSymlinksInPath().path) || keep.contains(imageEntryPath(p).path) {
            continue
        }
        let kb = diskKB(p)
        if (try? FileManager.default.removeItem(at: p)) != nil {
            freed += kb
            n += 1
        }
    }
    return (n, freed)
}

public func cmdClean(_ paths: Paths, days: Int) {
    let cutoff = nowSecs() - days * 86400
    var (scratchCount, freed) = cleanLeftoverScratch(paths)
    if scratchCount > 0 {
        print("Removed \(scratchCount) leftover throwaway VM(s).")
    }

    print("Looking for images and VMs not used in \(days) days. Answer y to delete, q to stop.")
    var n = 0
    var quit = false

    for f in listImagePaths(paths) where imageLastUsed(paths, f) < cutoff {
        n += 1
        let booted = imageLastBoot(paths, f).map(fmtAge) ?? "never"
        let kind = isSymlink(f) ? "link " : ""
        let prompt = "  image \(kind)\(f.lastPathComponent) (\(humanSize(pathOpenedForBoot(f))), downloaded \(fmtAge(fileBirthtime(f))), last booted \(booted))? [y/N/q] "
        let ans = promptLine(prompt) ?? "q"
        switch ans.trimmed {
        case "y", "Y":
            let kb = diskKB(f)
            if (try? removeImageEntry(f)) != nil {
                freed += kb
            }
        case "q", "Q":
            quit = true
        default:
            break
        }
        if quit { break }
    }

    if !quit {
        for d in listVMDirs(paths) {
            let mtime = fileMtime(vmDiskURL(d))
            if mtime >= cutoff || vmPID(d) != nil {
                continue
            }
            n += 1
            let ans = promptLine("  VM \(d.lastPathComponent) (\(humanSize(d)), last used \(fmtAge(mtime)))? [y/N/q] ") ?? "q"
            let choice = ans.trimmed
            if choice == "y" || choice == "Y" {
                let kb = diskKB(d)
                if (try? FileManager.default.removeItem(at: d)) != nil {
                    freed += kb
                }
            } else if choice == "q" || choice == "Q" {
                break
            }
        }
    }

    if n == 0 {
        print("  Nothing that old.")
    }
    print("Freed \(fmtKB(freed)).")
}

/// Deletes a VM's folder, or moves it to the Trash if `toTrash`.
public func deleteVMDir(_ paths: Paths, _ name: String, toTrash: Bool = false) throws(CrabError) {
    let dir = try vmPath(paths, name)
    try requireStopped(dir)
    do {
        if toTrash {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: dir)
        }
    } catch {
        throw CrabError("failed to delete \(dir.path): \(error.localizedDescription)")
    }
}

public func cmdDelete(_ paths: Paths, _ name: String) throws(CrabError) {
    let dir = try vmPath(paths, name)
    try requireStopped(dir)
    if isMacOSVM(dir) {
        print("This deletes \(dir.path) (\(humanSize(dir))), including its disk. macOS VMs don't have snapshots.")
    } else {
        print("This deletes \(dir.path) (\(humanSize(dir))), including its disk and snapshots.")
    }
    let answer = promptLine("Type the VM name to confirm: ") ?? ""
    if answer.trimmed != name {
        throw CrabError("names don't match; nothing deleted")
    }
    try deleteVMDir(paths, name)
    print("Deleted \(name).")
}

private let snapshotTagFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f
}()

public func createSnapshot(_ paths: Paths, _ name: String, tag tagOpt: String?) throws(CrabError) -> String {
    let dir = try vmPath(paths, name)
    if isMacOSVM(dir) {
        throw CrabError("\(name) is a macOS VM. Apple's Virtualization framework has no disk snapshots, so crab snapshot doesn't apply. QEMU VMs still snapshot as before.")
    }
    try needQemuImg()
    try requireStopped(dir)
    let tag = tagOpt.flatMap { $0.isEmpty ? nil : $0 } ?? snapshotTagFormatter.string(from: Date())
    let disk = dir.appending(path: "disk.qcow2")
    if qemuImgSnapshots(disk).contains(tag) {
        throw CrabError("\(name) already has a snapshot called '\(tag)'")
    }
    if !(try qemuImg(["snapshot", "-c", tag, disk.path])).success {
        throw CrabError("qemu-img snapshot -c '\(tag)' failed")
    }
    return tag
}

public func cmdSnapshot(_ paths: Paths, _ name: String, tag: String?) throws(CrabError) {
    let tag = try createSnapshot(paths, name, tag: tag)
    print("Created snapshot '\(tag)' of \(name).")
}

public func listSnapshotsRaw(_ paths: Paths, _ name: String) throws(CrabError) -> String {
    let dir = try vmPath(paths, name)
    if isMacOSVM(dir) {
        throw CrabError("\(name) is a macOS VM. Apple's Virtualization framework has no disk snapshots.")
    }
    try needQemuImg()
    let out = try qemuImg(["snapshot", "-l", "-U", dir.appending(path: "disk.qcow2").path])
    return String(out.stdout.reversed().drop(while: \.isWhitespace).reversed())
}

public func cmdSnapshots(_ paths: Paths, _ name: String) throws(CrabError) {
    let out = try listSnapshotsRaw(paths, name)
    print(out.isEmpty ? "\(name) has no snapshots." : out)
}

public func restoreSnapshot(_ paths: Paths, _ name: String, _ tag: String) throws(CrabError) {
    let dir = try vmPath(paths, name)
    if isMacOSVM(dir) {
        throw CrabError("\(name) is a macOS VM. Apple's Virtualization framework has no disk snapshots, so there's nothing to restore.")
    }
    try needQemuImg()
    try requireStopped(dir)
    if !(try qemuImg(["snapshot", "-a", tag, dir.appending(path: "disk.qcow2").path])).success {
        throw CrabError("failed to restore \(name) to '\(tag)'")
    }
}

public func cmdRestore(_ paths: Paths, _ name: String, _ tag: String) throws(CrabError) {
    let dir = try vmPath(paths, name)
    try needQemuImg()
    try requireStopped(dir)
    if !askYes("Roll \(name) back to '\(tag)'? Changes since then are lost.") {
        throw CrabError("nothing changed")
    }
    try restoreSnapshot(paths, name, tag)
    print("Restored \(name) to '\(tag)'.")
}

public func deleteSnapshot(_ paths: Paths, _ name: String, _ tag: String) throws(CrabError) {
    let dir = try vmPath(paths, name)
    if isMacOSVM(dir) {
        throw CrabError("\(name) is a macOS VM. Apple's Virtualization framework has no disk snapshots.")
    }
    try needQemuImg()
    try requireStopped(dir)
    if !(try qemuImg(["snapshot", "-d", tag, dir.appending(path: "disk.qcow2").path])).success {
        throw CrabError("failed to delete snapshot '\(tag)' of \(name)")
    }
}

public func cmdDelsnap(_ paths: Paths, _ name: String, _ tag: String) throws(CrabError) {
    try deleteSnapshot(paths, name, tag)
    print("Deleted snapshot '\(tag)' of \(name).")
}

/// nil if the VM isn't running, else QEMU's run state (falling back to
/// "running" for VMs booted without a control socket).
public func vmState(_ dir: URL) -> String? {
    guard vmPID(dir) != nil else { return nil }
    if isMacOSVM(dir) { return "running" }
    return QMP.queryStatus(dir) ?? "running"
}

public func waitStopped(_ dir: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while vmPID(dir) != nil {
        if Date() >= deadline {
            return false
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return true
}

/// Presses the VM's power button; the guest decides when to actually stop.
public func requestShutdown(_ dir: URL) throws(CrabError) {
    let name = dirName(dir)
    if vmPID(dir) == nil {
        throw CrabError("\(name) isn't running")
    }
    if isMacOSVM(dir) {
        try sendVZCommand(dir, "stop")
        return
    }
    if !QMP.socketPath(dir).exists {
        throw CrabError("\(name) was booted without a control socket (by vmboot or an older crab), so it can't be shut down cleanly; force it off with: crab kill \(name)")
    }
    try QMP.systemPowerdown(dir)
}

/// Stops QEMU straight away: asks it to quit, then signals it if need be.
public func forceOff(_ dir: URL) throws(CrabError) {
    let name = dirName(dir)
    guard let pid = vmPID(dir) else {
        throw CrabError("\(name) isn't running")
    }
    if isMacOSVM(dir) {
        // The pid belongs to Crab.app, which may be hosting other windows.
        // Ask the guest to stop; don't signal the whole app.
        if (try? sendVZCommand(dir, "quit")) == nil {
            throw CrabError("\(name) is a macOS VM running inside Crab (pid \(pid)), and it isn't answering. Close its window, or quit Crab, to force it off.")
        }
        if !waitStopped(dir, timeout: 10) {
            throw CrabError("\(name) is still running. Close its window in Crab, or quit Crab.")
        }
        let layout = MacOSVMLayout(directory: dir)
        try? FileManager.default.removeItem(at: layout.pidFile)
        try? FileManager.default.removeItem(at: layout.socket)
        return
    }
    if (try? QMP.quit(dir)) == nil {
        kill(pid, SIGTERM)
    }
    if !waitStopped(dir, timeout: 5) {
        kill(pid, SIGKILL)
        if !waitStopped(dir, timeout: 2) {
            throw CrabError("\(name) (pid \(pid)) won't stop")
        }
    }
    try? FileManager.default.removeItem(at: dir.appending(path: "qemu.pid"))
    try? FileManager.default.removeItem(at: QMP.socketPath(dir))
}

/// Swaps the disc in a running VM's CD drive, or ejects it if `image` is
/// nil. Returns a message saying what happened.
public func changeDisc(_ dir: URL, to image: URL?) throws(CrabError) -> String {
    let name = dirName(dir)
    if isMacOSVM(dir) {
        throw CrabError("\(name) is a macOS VM. It has no CD drive to change; the restore image is only used while installing.")
    }
    let drive = try runningCDDrive(dir)
    if let image {
        guard image.isFile else {
            throw CrabError("no such image: \(image.path)")
        }
        try QMP.changeMedium(dir, device: drive.device, image: pathOpenedForBoot(image))
        return "Inserted \(image.lastPathComponent) into \(name)."
    }
    try QMP.changeMedium(dir, device: drive.device, image: nil)
    return "Ejected \(drive.image?.lastPathComponent ?? "the disc") from \(name)."
}

/// Checks the VM is running with a control socket, for `doing` (e.g. "its
/// disc can't be changed") to explain what's out of reach without one.
private func requireControlSocket(_ dir: URL, _ doing: String) throws(CrabError) {
    let name = dirName(dir)
    if vmPID(dir) == nil {
        throw CrabError("\(name) isn't running")
    }
    if !QMP.socketPath(dir).exists {
        throw CrabError("\(name) was booted without a control socket, so \(doing)")
    }
}

private func runningCDDrive(_ dir: URL) throws(CrabError) -> QMP.CDDrive {
    let name = dirName(dir)
    try requireControlSocket(dir, "its disc can't be changed")
    do throws(CrabError) {
        return try QMP.cdDrive(dir)
    } catch where error.message.hasSuffix("has no CD drive") {
        throw CrabError("\(name) has no CD drive (arm64 VMs only get one when booted with an image)")
    } catch {
        throw error
    }
}

/// QEMU key names (qcodes) `crab key` accepts, beyond letters and digits.
private let namedKeys = Set([
    "ctrl", "ctrl_r", "alt", "alt_r", "shift", "shift_r", "meta_l", "meta_r", "menu",
    "esc", "ret", "tab", "spc", "backspace", "delete", "insert", "home", "end", "pgup", "pgdn",
    "up", "down", "left", "right", "caps_lock", "num_lock", "scroll_lock", "print", "sysrq", "pause",
    "minus", "equal", "bracket_left", "bracket_right", "semicolon", "apostrophe", "grave_accent",
    "backslash", "comma", "dot", "slash",
]).union((1...12).map { "f\($0)" })

/// Friendlier spellings for QEMU's key names.
private let keyAliases = [
    "control": "ctrl", "option": "alt", "opt": "alt", "cmd": "meta_l", "command": "meta_l", "win": "meta_l",
    "super": "meta_l", "escape": "esc", "enter": "ret", "return": "ret", "space": "spc", "del": "delete",
    "bksp": "backspace", "ins": "insert", "pageup": "pgup", "pagedown": "pgdn", "prtsc": "print",
]

/// Parses a key combination like "f8", "ctrl-alt-delete" or "Ctrl+Alt+Del"
/// into QEMU key names (qcodes), pressed together.
public func parseKeyCombo(_ combo: String) throws(CrabError) -> [String] {
    let parts = combo.lowercased().split { $0 == "-" || $0 == "+" }.map(String.init)
    if parts.isEmpty {
        throw CrabError("no key given")
    }
    return try parts.map { (part: String) throws(CrabError) -> String in
        let key = keyAliases[part] ?? part
        let single = key.count == 1 && key.first!.isASCII && (key.first!.isLetter || key.first!.isNumber)
        guard single || namedKeys.contains(key) else {
            throw CrabError("unknown key '\(part)' (try f1-f12, esc, ret, tab, ctrl, alt, shift, delete, a letter or a digit)")
        }
        return key
    }
}

/// Presses each of `combos` in turn in a running VM: for keys the Mac can't
/// send to the guest, like Touch Bar function keys or Ctrl+Alt+Del.
/// Returns a message saying what was sent.
public func sendKeys(_ dir: URL, _ combos: [String]) throws(CrabError) -> String {
    if isMacOSVM(dir) {
        throw CrabError("\(dirName(dir)) is a macOS VM. Keys go to its window; crab key is for QEMU guests.")
    }
    let parsed = try combos.map { (c: String) throws(CrabError) in try parseKeyCombo(c) }
    try requireControlSocket(dir, "keys can't be sent to it")
    for keys in parsed {
        try QMP.sendKeys(dir, keys)
    }
    return "Sent \(combos.joined(separator: ", ")) to \(dirName(dir))."
}

/// `crab key NAME KEY...`.
public func cmdKey(_ paths: Paths, _ name: String, _ combos: [String]) throws(CrabError) {
    print(try sendKeys(try vmPath(paths, name), combos))
}

/// `crab disc NAME [IMAGE|eject]`. A bare file name is looked for in the
/// image folder too, so the next disc of a set is easy to name.
public func cmdDisc(_ paths: Paths, _ name: String, _ arg: String?) throws(CrabError) {
    let dir = try vmPath(paths, name)
    guard let arg else {
        let drive = try runningCDDrive(dir)
        print(drive.image.map { "\(name) has \($0.lastPathComponent) in its CD drive." } ?? "\(name)'s CD drive is empty.")
        return
    }
    if arg == "eject" {
        print(try changeDisc(dir, to: nil))
        return
    }
    var image = URL(filePath: arg)
    if !image.isFile && !arg.contains("/") {
        image = paths.searchDir.appending(path: arg)
    }
    print(try changeDisc(dir, to: image))
}

public func cmdStop(_ paths: Paths, _ name: String) throws(CrabError) {
    let dir = try vmPath(paths, name)
    try requestShutdown(dir)
    print("Asked \(name) to shut down. Waiting up to a minute...")
    if waitStopped(dir, timeout: 60) {
        print("\(name) has shut down.")
    } else if askYes("\(name) is still running. Force it off?") {
        try forceOff(dir)
        print("Forced \(name) off.")
    } else {
        print("Left \(name) running.")
    }
}

public func cmdKill(_ paths: Paths, _ name: String) throws(CrabError) {
    let dir = try vmPath(paths, name)
    try forceOff(dir)
    print("Forced \(name) off.")
}

public let settableKeys = [
    "mem", "cpus", "ssh_port", "ssh_user", "fwd", "firmware", "display", "gpu", "fullscreen", "hw",
]

/// Checks a value for `crab set`, returning it in the form vm.conf stores.
public func validateSetting(_ key: String, _ value: String, arch: String) throws(CrabError) -> String {
    func oneOf(_ choices: [String]) throws(CrabError) -> String {
        guard choices.contains(value) else {
            throw CrabError("\(key) wants \(choices.joined(separator: " or "))")
        }
        return value
    }
    switch key {
    case "mem":
        guard validMem(value) else { throw CrabError("mem wants a size like 2G or 512M") }
        return value
    case "cpus":
        guard validCPUs(value) else { throw CrabError("cpus wants a number of CPUs") }
        if arch == "ppc" && value != "1" {
            throw CrabError("PowerPC Macs (mac99) have one CPU")
        }
        if arch == "sparc64" && value != "1" {
            throw CrabError("SPARC64 (sun4u) has one CPU")
        }
        return value
    case "ssh_port":
        guard validPort(value) else { throw CrabError("ssh_port wants a port number (0 turns it off)") }
        return value
    case "ssh_user":
        guard isValidSSHUser(value) else {
            throw CrabError("ssh_user wants a user name")
        }
        return value
    case "fwd":
        return Forward.listToConf(try Forward.parseList(value))
    case "firmware":
        if arch == "ppc" {
            throw CrabError("PowerPC Macs always boot with Open Firmware")
        }
        if arch == "sparc64" {
            throw CrabError("SPARC64 guests always boot with OpenBIOS")
        }
        if arch == "arm64" && value == "bios" {
            throw CrabError("arm64 guests always boot with UEFI")
        }
        return try oneOf(["uefi", "bios"])
    case "display": return try oneOf(["window", "terminal"])
    case "gpu": return try oneOf(["virtio", "ramfb"])
    case "fullscreen": return try oneOf(["on", "off"])
    case "hw":
        if arch == "ppc" {
            throw CrabError("PowerPC Macs always use mac99 hardware")
        }
        if arch == "sparc64" {
            throw CrabError("SPARC64 guests always use sun4u hardware")
        }
        if arch == "arm64" && value != "virtio" {
            throw CrabError("arm64 guests always use virtio hardware")
        }
        return try oneOf(["standard", "virtio", "legacy"])
    default:
        throw CrabError("can't set '\(key)'; settable keys are: \(settableKeys.joined(separator: " "))")
    }
}

public func setSettings(_ paths: Paths, _ name: String, _ assignments: [String]) throws(CrabError) {
    let dir = try vmPath(paths, name)
    let arch = confGet(dir, "arch")
    let macos = isMacOSVM(dir) ? MacOSVMConfig.load(dir) : nil
    var updates: [(String, String)] = []
    for a in assignments {
        guard let eq = a.firstIndex(of: "=") else {
            throw CrabError("'\(a)' should look like key=value")
        }
        let key = String(a[..<eq])
        let value = String(a[a.index(after: eq)...])
        if let macos {
            updates.append((key, try validateMacOSSetting(key, value, config: macos)))
        } else {
            updates.append((key, try validateSetting(key, value, arch: arch)))
        }
    }
    do {
        try confSet(dir, updates)
    } catch {
        throw CrabError("failed to write vm.conf: \(error.localizedDescription)")
    }
}

public func cmdSet(_ paths: Paths, _ name: String, _ assignments: [String]) throws(CrabError) {
    let dir = try vmPath(paths, name)
    if assignments.isEmpty {
        if let c = try? String(contentsOf: dir.appending(path: "vm.conf"), encoding: .utf8) {
            print(c, terminator: "")
        } else {
            print("\(name) has no saved settings.")
        }
        return
    }
    try setSettings(paths, name, assignments)
    print(vmPID(dir) != nil ? "Saved. \(name) is running, so the change takes effect on its next boot." : "Saved.")
}

public func cloneVM(_ paths: Paths, _ src: String, _ dst: String) throws(CrabError) -> URL {
    let srcDir = try vmPath(paths, src)
    try requireStopped(srcDir)
    try checkName(dst)
    let dstDir = paths.vmRoot.appending(path: dst, directoryHint: .isDirectory)
    if dstDir.exists {
        throw CrabError("there's already a VM called '\(dst)'")
    }
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: false)
    } catch {
        throw CrabError("failed to create \(dstDir.path): \(error.localizedDescription)")
    }
    do {
        // copyItem clones files on APFS, so this is quick and shares disk blocks.
        let names = isMacOSVM(srcDir) ? MacOSVMLayout.cloneNames : ["disk.qcow2", "efivars.fd", "vm.conf", "arch"]
        for f in names {
            let from = srcDir.appending(path: f)
            if from.exists {
                try fm.copyItem(at: from, to: dstDir.appending(path: f))
            }
        }
        // Give the clone its own SSH port so both can run at once.
        let port = confGet(dstDir, "ssh_port")
        if !port.isEmpty && port != "0" {
            let newPort = pickFreePort(paths, ownDir: dstDir).map(String.init) ?? "0"
            try confSet(dstDir, [("ssh_port", newPort)])
        }
    } catch {
        try? fm.removeItem(at: dstDir)
        throw CrabError("failed to clone \(src): \(error.localizedDescription)")
    }
    return dstDir
}

public func cmdClone(_ paths: Paths, _ src: String, _ dst: String) throws(CrabError) {
    let dir = try cloneVM(paths, src, dst)
    print("Cloned \(src) to \(dst).")
    if isMacOSVM(dir) {
        print("Don't run \(src) and \(dst) at the same time: they share a machine identifier, and macOS VMs have no snapshots.")
    }
    let port = confGet(dir, "ssh_port")
    if !port.isEmpty && port != "0" {
        print("\(dst) forwards SSH from port \(port).")
    }
    if !((try? Forward.parseList(confGet(dir, "fwd"))) ?? []).isEmpty {
        print("Both VMs forward the same ports, so change them before running both: crab set \(dst) fwd=...")
    }
}

public func renameVM(_ paths: Paths, _ old: String, _ new: String) throws(CrabError) {
    let dir = try vmPath(paths, old)
    try requireStopped(dir)
    try checkName(new)
    let dest = paths.vmRoot.appending(path: new, directoryHint: .isDirectory)
    if dest.exists {
        throw CrabError("there's already a VM called '\(new)'")
    }
    do {
        try FileManager.default.moveItem(at: dir, to: dest)
    } catch {
        throw CrabError("failed to rename \(old): \(error.localizedDescription)")
    }
}

public func cmdRename(_ paths: Paths, _ old: String, _ new: String) throws(CrabError) {
    try renameVM(paths, old, new)
    print("Renamed \(old) to \(new).")
}

public func resizeDisk(_ paths: Paths, _ name: String, _ size: String) throws(CrabError) -> String {
    let dir = try vmPath(paths, name)
    try requireStopped(dir)
    if isMacOSVM(dir) {
        let disk = vmDiskURL(dir)
        guard let target = grownDiskBytes(current: logicalFileBytes(disk), spec: size) else {
            throw CrabError("couldn't resize \(name)'s disk (disks can only grow; SIZE looks like 80G or +10G)")
        }
        try growRawDisk(disk, to: target)
        let text = formatDiskBytes(target)
        do {
            try confSet(dir, [("disk", text)])
        } catch {
            throw CrabError("the disk grew, but vm.conf couldn't be updated: \(error.localizedDescription)")
        }
        return text
    }
    try needQemuImg()
    if !validDiskSize(size, relative: true) {
        throw CrabError("SIZE should look like 40G, or +10G to grow by that much")
    }
    let disk = dir.appending(path: "disk.qcow2")
    if !(try qemuImg(["resize", "-q", disk.path, size])).success {
        throw CrabError("couldn't resize \(name)'s disk (disks can only grow)")
    }
    return qemuImgVirtSize(disk)
}

public func cmdResize(_ paths: Paths, _ name: String, _ size: String) throws(CrabError) {
    let newSize = try resizeDisk(paths, name, size)
    print("\(name)'s disk is now \(newSize). Grow the partition and filesystem inside the guest to use the space.")
}

/// A login name ssh will not treat as an option. A leading `-` would be a
/// flag if it were glued onto the destination (`-oProxyCommand=…@localhost`),
/// and control characters can smuggle extra arguments. `-l` and `--` are
/// still used at the call site; this rejects the names those wouldn't save.
public func isValidSSHUser(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("-") else { return false }
    return value.allSatisfy { ch in
        ch != "@" && !ch.isWhitespace && ch.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control
        }
    }
}

/// The ssh command line for `[USER@]NAME`, using the VM's forwarded port.
public func sshCommand(_ paths: Paths, _ target: String) throws(CrabError) -> [String] {
    var user: String?
    var name = target
    if let at = target.firstIndex(of: "@") {
        user = String(target[..<at])
        name = String(target[target.index(after: at)...])
    }
    let dir = try vmPath(paths, name)
    if isMacOSVM(dir) {
        throw CrabError("\(name) is a macOS VM. Virtualization's NAT doesn't forward host ports, so crab ssh doesn't apply. Use the guest's window, or turn on Screen Sharing in the guest.")
    }
    let port = confGet(dir, "ssh_port")
    if port.isEmpty || port == "0" {
        throw CrabError("\(name) has no SSH port; give it one with: crab set \(name) ssh_port=2222 (then reboot it)")
    }
    if user == nil {
        let saved = confGet(dir, "ssh_user")
        user = saved.isEmpty ? nil : saved
    }
    if let user, !isValidSSHUser(user) {
        throw CrabError("ssh_user wants a user name")
    }
    // `-l` takes the next argument as the login name even when it looks like
    // a flag, and `--` stops option parsing before the destination. The
    // username is also rejected when it starts with `-` or contains a
    // control character, so a saved `ssh_user` can't be an ssh option.
    var argv = ["ssh", "-p", port, "-o", "HostKeyAlias=crab-\(name)"]
    if let user {
        argv += ["-l", user]
    }
    argv.append("--")
    argv.append("localhost")
    return argv
}

public func cmdSSH(_ paths: Paths, _ target: String, _ command: [String]) throws(CrabError) {
    let argv = try sshCommand(paths, target)
    let name = target.split(separator: "@").last.map(String.init) ?? target
    if vmPID(paths.vmRoot.appending(path: name)) == nil {
        throw CrabError("\(name) isn't running (boot it with: crab boot \(name))")
    }
    let ssh = findExecutable("ssh") ?? URL(filePath: "/usr/bin/ssh")
    do {
        try execReplacing(ssh, Array(argv.dropFirst()) + command)
    } catch {
        throw CrabError("failed to run ssh: \(error.localizedDescription)")
    }
}

extension String {
    /// Left-aligned in a column `width` characters wide.
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
