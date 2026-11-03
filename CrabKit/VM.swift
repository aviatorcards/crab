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
    public var id: String { name }
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
        throw CrabError("invalid VM name: '\(name)'")
    }
}

public func vmPath(_ paths: Paths, _ name: String) throws(CrabError) -> URL {
    try checkName(name)
    let dir = paths.vmRoot.appending(path: name, directoryHint: .isDirectory)
    if !dir.appending(path: "disk.qcow2").isFile {
        throw CrabError("no VM named '\(name)' in \(paths.vmRoot.path) (try: crab list)")
    }
    return dir
}

/// The pid of the VM's QEMU process, if it's running.
public func vmPID(_ dir: URL) -> Int32? {
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
        .filter { $0.isDirectory && !$0.lastPathComponent.hasPrefix(".") && $0.appending(path: "disk.qcow2").isFile }
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
    let disk = dir.appending(path: "disk.qcow2")
    let mem = confGet(dir, "mem")
    let cpus = confGet(dir, "cpus")
    return VMEntry(
        name: dir.lastPathComponent,
        dir: dir,
        disk: disk,
        arch: confGet(dir, "arch"),
        firmware: confGet(dir, "firmware"),
        mem: mem.isEmpty ? defaultMem : mem,
        cpus: cpus.isEmpty ? String(defaultCPUs) : cpus,
        sshPort: confGet(dir, "ssh_port"),
        display: confGet(dir, "display"),
        hw: confGet(dir, "hw"),
        gpu: confGet(dir, "gpu"),
        fullscreen: confGet(dir, "fullscreen"),
        sshUser: confGet(dir, "ssh_user"),
        forwards: confGet(dir, "fwd"),
        diskUsed: humanSize(disk),
        diskVirt: qemuImgVirtSize(disk),
        snapsCount: qemuImgSnapshots(disk).count,
        runningPID: vmPID(dir),
        state: vmState(dir) ?? "stopped",
        lastUsedSecs: fileMtime(disk)
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
        print(row([v.name, v.arch, v.firmware, v.mem, v.cpus, ssh, "\(v.diskUsed) of \(v.diskVirt)",
                   String(v.snapsCount), v.state, fmtAge(v.lastUsedSecs)]))
    }
}

public func cmdImages(_ paths: Paths) {
    let images = listImageEntries(paths)
    if images.isEmpty {
        print("No .iso/.img files in \(paths.searchDir.path)")
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

/// Deletes throwaway VMs left behind (e.g. by a crash), skipping running ones.
/// Returns how many were removed and the KB freed.
public func cleanLeftoverScratch(_ paths: Paths) -> (count: Int, freedKB: Int) {
    var n = 0
    var freed = 0
    let entries = (try? FileManager.default.contentsOfDirectory(at: paths.scratchRoot, includingPropertiesForKeys: nil)) ?? []
    for p in entries where p.isDirectory && vmPID(p) == nil {
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
        let prompt = "  image \(f.lastPathComponent) (\(humanSize(f)), downloaded \(fmtAge(fileBirthtime(f))), last booted \(booted))? [y/N/q] "
        let ans = promptLine(prompt) ?? "q"
        switch ans.trimmed {
        case "y", "Y":
            let kb = diskKB(f)
            if (try? FileManager.default.removeItem(at: f)) != nil {
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
            let mtime = fileMtime(d.appending(path: "disk.qcow2"))
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
    print("This deletes \(dir.path) (\(humanSize(dir))), including its disk and snapshots.")
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
    let drive = try runningCDDrive(dir)
    if let image {
        guard image.isFile else {
            throw CrabError("no such image: \(image.path)")
        }
        try QMP.changeMedium(dir, device: drive.device, image: absPath(image))
        return "Inserted \(image.lastPathComponent) into \(name)."
    }
    try QMP.changeMedium(dir, device: drive.device, image: nil)
    return "Ejected \(drive.image?.lastPathComponent ?? "the disc") from \(name)."
}

private func runningCDDrive(_ dir: URL) throws(CrabError) -> QMP.CDDrive {
    let name = dirName(dir)
    if vmPID(dir) == nil {
        throw CrabError("\(name) isn't running")
    }
    if !QMP.socketPath(dir).exists {
        throw CrabError("\(name) was booted without a control socket, so its disc can't be changed")
    }
    do throws(CrabError) {
        return try QMP.cdDrive(dir)
    } catch where error.message.hasSuffix("has no CD drive") {
        throw CrabError("\(name) has no CD drive (arm64 VMs only get one when booted with an image)")
    } catch {
        throw error
    }
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
        return value
    case "ssh_port":
        guard validPort(value) else { throw CrabError("ssh_port wants a port number (0 turns it off)") }
        return value
    case "ssh_user":
        guard !value.isEmpty, !value.contains(where: { "@ \t".contains($0) }) else {
            throw CrabError("ssh_user wants a user name")
        }
        return value
    case "fwd":
        return Forward.listToConf(try Forward.parseList(value))
    case "firmware":
        if arch == "ppc" {
            throw CrabError("PowerPC Macs always boot with Open Firmware")
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
    var updates: [(String, String)] = []
    for a in assignments {
        guard let eq = a.firstIndex(of: "=") else {
            throw CrabError("'\(a)' should look like key=value")
        }
        let key = String(a[..<eq])
        updates.append((key, try validateSetting(key, String(a[a.index(after: eq)...]), arch: arch)))
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
        for f in ["disk.qcow2", "efivars.fd", "vm.conf", "arch"] {
            let from = srcDir.appending(path: f)
            if from.isFile {
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
    try needQemuImg()
    try requireStopped(dir)
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

/// The ssh command line for `[USER@]NAME`, using the VM's forwarded port.
public func sshCommand(_ paths: Paths, _ target: String) throws(CrabError) -> [String] {
    var user: String?
    var name = target
    if let at = target.firstIndex(of: "@") {
        user = String(target[..<at])
        name = String(target[target.index(after: at)...])
    }
    let dir = try vmPath(paths, name)
    let port = confGet(dir, "ssh_port")
    if port.isEmpty || port == "0" {
        throw CrabError("\(name) has no SSH port; give it one with: crab set \(name) ssh_port=2222 (then reboot it)")
    }
    if user == nil {
        let saved = confGet(dir, "ssh_user")
        user = saved.isEmpty ? nil : saved
    }
    let host = user.map { "\($0)@localhost" } ?? "localhost"
    // Key the guest's host key by VM name, not by port, since ports get reused.
    return ["ssh", "-p", port, "-o", "HostKeyAlias=crab-\(name)", host]
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
