import AppKit
import CrabKit
import Foundation
import Observation

enum Page: String, CaseIterable, Identifiable {
    case vms, images, releases, mirrors
    var id: Self { self }

    var title: String {
        switch self {
        case .vms: "Saved VMs"
        case .images: "Local Images"
        case .releases: "Get Distros"
        case .mirrors: "Mirrors & RSS"
        }
    }

    var systemImage: String {
        switch self {
        case .vms: "desktopcomputer"
        case .images: "opticaldisc"
        case .releases: "arrow.down.circle"
        case .mirrors: "network"
        }
    }
}

/// The mode used when booting an image from the app.
enum ImageLaunchMode: String, CaseIterable, Identifiable {
    case temporary
    case keep
    case live

    var id: Self { self }

    var title: String {
        switch self {
        case .temporary: return "Temporary"
        case .keep: return "Save permanently"
        case .live: return "Live (no disk)"
        }
    }

    var footerDescription: String {
        switch self {
        case .temporary:
            return "Temporary VMs prompt whether to keep or discard changes when the VM closes."
        case .keep:
            return "Creates a permanent VM saved to your VM library."
        case .live:
            return "Runs directly from the image without a virtual disk; changes will not be saved."
        }
    }
}

/// A throwaway VM whose QEMU has exited, waiting for keep or discard.
struct ThrowawayPrompt: Identifiable {
    let id = UUID()
    let scratchDir: URL
    let imagePath: URL?
    var name: String
    let diskSizeHuman: String
    let diskUsedKB: Int
    let live: Bool

    /// Whether enough was written to the disk to be worth keeping.
    var canKeep: Bool { !live && diskUsedKB >= 1024 }
}

/// The release download in progress.
struct ActiveDownload {
    let label: String
    var note = ""
    var done: Int64 = 0
    var total: Int64?
    let cancel: CancelFlag

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return Double(done) / Double(total)
    }
}

/// Everything a reload reads from disk, gathered off the main thread.
private struct LoadedData: Sendable {
    var vms: [VMEntry]
    var images: [ImageEntry]
    var catalog: [CatalogEntry]
    var mirrors: [MirrorRule]
    var catalogAge: String?
}

@MainActor
@Observable
final class AppModel {
    private(set) var paths: Paths
    private(set) var vms: [VMEntry] = []
    private(set) var images: [ImageEntry] = []
    private(set) var catalog: [CatalogEntry] = []
    private(set) var catalogAge: String?
    private(set) var mirrors: [MirrorRule] = []
    private(set) var rssItems: [RSSReleaseItem] = []

    // Launch settings, used for every boot from the app.
    var mem: String {
        didSet { UserDefaults.standard.set(mem, forKey: "defaultMem") }
    }
    var cpus: String {
        didSet { UserDefaults.standard.set(cpus, forKey: "defaultCPUs") }
    }
    var diskSize: String {
        didSet { UserDefaults.standard.set(diskSize, forKey: "defaultDiskSize") }
    }
    var sshPort: String
    /// "auto", "uefi" or "bios".
    var firmware: String
    /// "auto", "standard", "legacy" or "virtio".
    var hw: String
    var arch: String
    var gpu: String {
        didSet { UserDefaults.standard.set(gpu, forKey: "defaultGPU") }
    }
    var keep: Bool { didSet { if keep { live = false } } }
    var live: Bool { didSet { if live { keep = false } } }
    var launchMode: ImageLaunchMode {
        get {
            if keep { return .keep }
            if live { return .live }
            return .temporary
        }
        set {
            switch newValue {
            case .temporary:
                keep = false
                live = false
            case .keep:
                keep = true
                live = false
            case .live:
                keep = false
                live = true
            }
        }
    }
    var fullscreen: Bool {
        didSet { UserDefaults.standard.set(fullscreen, forKey: "startFullScreen") }
    }
    var extraQemuFlags: String {
        didSet { UserDefaults.standard.set(extraQemuFlags, forKey: "extraQemuFlags") }
    }
    var namedVMInput = ""

    var status = "Ready. Boot a saved VM, a local image, or download a distro."
    var showImagePicker = false
    var showSettingsDialog = false
    /// Exited throwaway VMs, asked about one at a time.
    private(set) var throwawayPrompts: [ThrowawayPrompt] = []

    /// The throwaway VM being asked about. The sheet's buttons resolve it, so
    /// setting this to nil (dismissing) does nothing.
    var currentThrowaway: ThrowawayPrompt? {
        get { throwawayPrompts.first }
        set { }
    }
    private(set) var download: ActiveDownload?
    /// A catalog sync, mirror probe or RSS fetch is running.
    private(set) var busy = false
    /// VMs with a stop, kill, delete or snapshot operation in flight.
    private(set) var vmOps: Set<String> = []
    /// Images being prepared for boot (scanned, disk created) before QEMU starts.
    private(set) var booting: Set<String> = []

    /// Bumped by every reload so results from older, slower loads are dropped.
    private var reloadGen = 0
    /// QEMU processes started from this window.
    private var sessions: [ObjectIdentifier: SpawnedVM] = [:]

    /// Throwaway and live VMs started from this window that are still running.
    /// Saved VMs show up in `vms` instead.
    var runningThrowaways: [SpawnedVM] {
        sessions.values.filter { $0.scratchDir != nil }.sorted { $0.defaultName < $1.defaultName }
    }

    init() {
        // `crab gui` passes its flags through; ignore the ones macOS and Xcode add.
        var args: [String] = []
        var raw = CommandLine.arguments.dropFirst()[...]
        while let arg = raw.popFirst() {
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                _ = raw.popFirst()
            } else {
                args.append(arg)
            }
        }
        let opts = (try? parseArgs(args).opts) ?? BootOptions()

        paths = Paths(searchDirOverride: opts.searchDir)
        let defaults = UserDefaults.standard
        extraQemuFlags = defaults.string(forKey: "extraQemuFlags") ?? ""
        mem = opts.mem ?? defaults.string(forKey: "defaultMem") ?? defaultMem
        cpus = opts.cpus ?? defaults.string(forKey: "defaultCPUs") ?? String(defaultCPUs)
        diskSize = opts.diskSize ?? defaults.string(forKey: "defaultDiskSize") ?? defaultDiskSize
        sshPort = opts.sshPort ?? ""
        firmware = opts.firmware ?? "auto"
        hw = opts.hw ?? "auto"
        arch = opts.arch.flatMap { $0.isEmpty ? nil : $0 } ?? hostArch()
        gpu = opts.gpu ?? defaults.string(forKey: "defaultGPU") ?? "virtio"
        keep = opts.keep
        live = opts.live
        if opts.fullscreen != nil {
            fullscreen = opts.fullscreen == "on"
        } else if defaults.object(forKey: "startFullScreen") != nil {
            fullscreen = defaults.bool(forKey: "startFullScreen")
        } else {
            fullscreen = false
        }
    }

    var vmRootDisplay: String { abbreviate(paths.vmRoot) }
    var searchDirDisplay: String { abbreviate(paths.searchDir) }

    func chooseSearchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = paths.searchDir
        if panel.runModal() == .OK, let url = panel.url {
            try? paths.saveSearchDir(url)
            reload()
        }
    }

    func revealSearchDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.searchDir])
    }

    func revealVMRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.vmRoot])
    }

    var detectedQemuArmPath: String? {
        findExecutable("qemu-system-aarch64")?.path
    }

    var detectedQemuX86Path: String? {
        findExecutable("qemu-system-x86_64")?.path
    }

    var detectedQemuImgPath: String? {
        findExecutable("qemu-img")?.path
    }

    // MARK: - Loading

    /// Re-reads VMs, images, catalog and mirrors in the background.
    func reload() {
        reloadGen += 1
        let generation = reloadGen
        let paths = paths
        Task {
            let data = await Task.detached {
                LoadedData(
                    vms: listVMEntries(paths),
                    images: listImageEntries(paths),
                    catalog: loadCatalog(paths),
                    mirrors: mirrorRules(paths),
                    catalogAge: FileManager.default.fileExists(atPath: paths.catalog.path)
                        ? fmtAge(fileMtime(paths.catalog)) : nil
                )
            }.value
            // A newer reload is on its way.
            guard generation == reloadGen else { return }
            vms = data.vms
            images = data.images
            catalog = data.catalog
            mirrors = data.mirrors
            catalogAge = data.catalogAge
        }
    }

    /// Polls the VMs' run states (which runs ps and talks QMP) every couple of
    /// seconds, reloading if any changed, so VMs started or stopped elsewhere show up.
    func pollStates() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let dirs = vms.map { ($0.name, $0.dir) }
            let states = await Task.detached {
                dirs.map { ($0.0, vmState($0.1) ?? "stopped") }
            }.value
            let changed = states.contains { name, state in
                vms.first { $0.name == name }.map { $0.state != state } ?? false
            }
            if changed {
                reload()
            }
        }
    }

    // MARK: - Booting

    private func bootOptions() -> BootOptions {
        var opts = BootOptions()
        opts.searchDir = paths.searchDir
        // Only a fallback: images boot as their detected architecture.
        opts.fallbackArch = arch
        opts.keep = keep
        opts.live = live
        opts.mem = mem
        opts.cpus = cpus
        opts.diskSize = effectiveDiskSize
        let port = sshPort.trimmingCharacters(in: .whitespaces)
        opts.sshPort = port.isEmpty ? nil : port
        // Keep each VM's saved port forwards and display; the app opens a window regardless.
        opts.forwards = nil
        opts.display = nil
        opts.firmware = firmware == "auto" ? nil : firmware
        opts.hw = hw == "auto" ? nil : hw
        opts.fullscreen = fullscreen ? "on" : "off"
        opts.gpu = gpu
        opts.extraQemuArgs = parseExtraQemuFlags(extraQemuFlags)
        return opts
    }

    /// The New Disk field as qemu-img wants it: blank means the default and a
    /// bare number means gigabytes, like the RAM field.
    private var effectiveDiskSize: String {
        let s = diskSize.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return defaultDiskSize }
        return s.allSatisfy({ $0.isASCII && $0.isNumber }) ? s + "G" : s
    }

    /// Checks the launch settings the way the CLI checks its flags.
    private func launchSettingsError() -> String? {
        if !validMem(mem) { return "RAM wants a size like 2G or 512M." }
        if !validCPUs(cpus) { return "CPUs wants a number." }
        if !validDiskSize(effectiveDiskSize, relative: false) { return "New Disk wants a size like 20G." }
        let port = sshPort.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty && !validPort(port) { return "SSH Port wants a port number, or blank." }
        return nil
    }

    func bootVM(_ name: String) {
        spawn(key: name, vmName: name, image: nil, opts: bootOptions(), started: "Booted '\(name)'.")
    }

    func bootImage(_ url: URL, opts: BootOptions? = nil, label: String? = nil) {
        let opts = opts ?? bootOptions()
        let named = namedVMInput.trimmingCharacters(in: .whitespaces)
        let what = label ?? "'\(url.lastPathComponent)'"
        let started = opts.keep ? "Booted \(what) as a saved VM." : opts.live ? "Booted \(what) live, with no disk." : "Booted \(what) in a throwaway VM."
        spawn(key: url.path, image: url, namedTarget: named.isEmpty ? nil : named, opts: opts, started: started)
    }

    private func spawn(key: String, vmName: String? = nil, image: URL?, namedTarget: String? = nil, opts: BootOptions, started: String) {
        if let error = launchSettingsError() {
            status = error
            return
        }
        guard booting.insert(key).inserted else { return }
        status = "Starting \(vmName ?? image?.lastPathComponent ?? "VM")..."
        let paths = paths
        Task {
            let result = await Task.detached { () async -> Result<SpawnedVM, CrabError> in
                await attempt { () throws(CrabError) in
                    try spawnFromGUI(paths, opts, vmName: vmName, image: image, namedTarget: namedTarget) { spawned in
                        Task { @MainActor in self.sessionExited(spawned) }
                    }
                }
            }.value
            booting.remove(key)
            switch result {
            case .success(let spawned):
                // It may already have exited, in which case sessionExited ran first.
                if spawned.process.isRunning {
                    sessions[ObjectIdentifier(spawned)] = spawned
                }
                status = started
            case .failure(let error):
                status = "Couldn't boot: \(error.message)"
            }
            reload()
        }
    }

    private func sessionExited(_ spawned: SpawnedVM) {
        sessions[ObjectIdentifier(spawned)] = nil
        reload()
        guard let scratch = spawned.scratchDir else {
            status = "'\(spawned.defaultName)' stopped."
            return
        }
        let disk = scratch.appending(path: "disk.qcow2")
        let usedKB = spawned.live ? 0 : diskKB(disk)
        if !spawned.live && usedKB < 1024 && spawned.imagePath == nil {
            try? FileManager.default.removeItem(at: scratch)
            status = "Throwaway VM exited with nothing written to its disk, so it was discarded."
            return
        }
        throwawayPrompts.append(ThrowawayPrompt(
            scratchDir: scratch, imagePath: spawned.imagePath, name: spawned.defaultName,
            diskSizeHuman: humanSize(disk), diskUsedKB: usedKB, live: spawned.live
        ))
    }

    /// Moves a throwaway VM into ~/VMs as `name`. Returns false (with the
    /// reason in `status`) if the name won't do.
    func keepThrowaway(_ prompt: ThrowawayPrompt, as name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        do {
            try checkName(name)
        } catch {
            status = error.message
            return false
        }
        let dest = paths.vmRoot.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: dest.path) {
            status = "There's already a VM called '\(name)'."
            return false
        }
        try? FileManager.default.removeItem(at: prompt.scratchDir.appending(path: "qemu.pid"))
        try? FileManager.default.removeItem(at: QMP.socketPath(prompt.scratchDir))
        do {
            try FileManager.default.moveItem(at: prompt.scratchDir, to: dest)
        } catch {
            status = "Couldn't save the VM: \(error.localizedDescription)"
            return false
        }
        status = "Kept the throwaway VM as '\(name)'."
        throwawayPrompts.removeAll { $0.id == prompt.id }
        reload()
        return true
    }

    func discardThrowaway(_ prompt: ThrowawayPrompt, deleteImage: Bool) {
        try? FileManager.default.trashItem(at: prompt.scratchDir, resultingItemURL: nil)
        status = "Throwaway VM trashed."
        if deleteImage, let img = prompt.imagePath, (try? FileManager.default.trashItem(at: img, resultingItemURL: nil)) != nil {
            status = "Throwaway VM and image '\(img.lastPathComponent)' trashed."
        }
        throwawayPrompts.removeAll { $0.id == prompt.id }
        reload()
    }

    // MARK: - VM operations

    /// Runs a slow operation on VM `name` in the background, at most one per
    /// VM at a time. `work` returns the status message either way.
    private func vmOp(_ name: String, pending: String, _ work: @escaping @Sendable (Paths) -> String) {
        guard vmOps.insert(name).inserted else { return }
        status = pending
        let paths = paths
        Task {
            status = await Task.detached { work(paths) }.value
            vmOps.remove(name)
            reload()
        }
    }

    func stopVM(_ name: String) {
        vmOp(name, pending: "Asking '\(name)' to shut down...") { paths in
            report { () throws(CrabError) in try requestShutdown(vmPath(paths, name)) }
                .map { "Couldn't shut down '\(name)': \($0)" } ?? "Asked '\(name)' to shut down."
        }
    }

    func forceOffVM(_ name: String) {
        vmOp(name, pending: "Forcing '\(name)' off...") { paths in
            report { () throws(CrabError) in try forceOff(vmPath(paths, name)) }
                .map { "Couldn't force '\(name)' off: \($0)" } ?? "Forced '\(name)' off."
        }
    }

    /// Swaps the disc in a running VM's CD drive, or ejects it if `image` is nil.
    /// `name` keys the operation, so it works for throwaway VMs too.
    func changeDisc(_ dir: URL, name: String, to image: URL?) {
        let pending = image.map { "Inserting \($0.lastPathComponent) into '\(name)'..." } ?? "Ejecting the disc from '\(name)'..."
        vmOp(name, pending: pending) { _ in
            do throws(CrabError) {
                return try CrabKit.changeDisc(dir, to: image)
            } catch {
                return "Couldn't change the disc: \(error.message)"
            }
        }
    }

    /// Presses a key combination (e.g. "f8", "ctrl-alt-delete") in a running VM.
    func sendKey(_ dir: URL, name: String, combo: String, label: String) {
        vmOp(name, pending: "Sending \(label) to '\(name)'...") { _ in
            do throws(CrabError) {
                _ = try CrabKit.sendKeys(dir, [combo])
                return "Sent \(label) to '\(name)'."
            } catch {
                return "Couldn't send \(label): \(error.message)"
            }
        }
    }

    /// Forces off a throwaway VM; its keep-or-discard prompt follows as usual.
    func forceOffThrowaway(_ vm: SpawnedVM) {
        guard let dir = vm.scratchDir else { return }
        vmOp(vm.defaultName, pending: "Forcing '\(vm.defaultName)' off...") { _ in
            report { () throws(CrabError) in try forceOff(dir) }
                .map { "Couldn't force '\(vm.defaultName)' off: \($0)" } ?? "Forced '\(vm.defaultName)' off."
        }
    }

    func deleteVM(_ name: String) {
        vmOp(name, pending: "Trashing '\(name)'...") { paths in
            report { () throws(CrabError) in try deleteVMDir(paths, name, toTrash: true) }
                .map { "Couldn't delete '\(name)': \($0)" } ?? "Trashed '\(name)'."
        }
    }

    func cloneVM(_ name: String, to newName: String) {
        vmOp(name, pending: "Cloning '\(name)'...") { paths in
            report { () throws(CrabError) in _ = try CrabKit.cloneVM(paths, name, newName) }
                .map { "Couldn't clone '\(name)': \($0)" } ?? "Cloned '\(name)' to '\(newName)'."
        }
    }

    func renameVM(_ name: String, to newName: String) {
        vmOp(name, pending: "Renaming '\(name)'...") { paths in
            report { () throws(CrabError) in try CrabKit.renameVM(paths, name, newName) }
                .map { "Couldn't rename '\(name)': \($0)" } ?? "Renamed '\(name)' to '\(newName)'."
        }
    }

    func createSnapshot(_ name: String, tag: String) {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        vmOp(name, pending: "Snapshotting '\(name)'...") { paths in
            do throws(CrabError) {
                let made = try CrabKit.createSnapshot(paths, name, tag: tag.isEmpty ? nil : tag)
                return "Created snapshot '\(made)' of '\(name)'."
            } catch {
                return "Couldn't snapshot '\(name)': \(error.message)"
            }
        }
    }

    func restoreSnapshot(_ name: String, tag: String) {
        vmOp(name, pending: "Restoring '\(name)' to '\(tag)'...") { paths in
            report { () throws(CrabError) in try CrabKit.restoreSnapshot(paths, name, tag) }
                .map { "Couldn't restore '\(name)': \($0)" } ?? "Restored '\(name)' to '\(tag)'."
        }
    }

    func deleteSnapshot(_ name: String, tag: String) {
        vmOp(name, pending: "Deleting snapshot '\(tag)'...") { paths in
            report { () throws(CrabError) in try CrabKit.deleteSnapshot(paths, name, tag) }
                .map { "Couldn't delete snapshot '\(tag)': \($0)" } ?? "Deleted snapshot '\(tag)' of '\(name)'."
        }
    }

    func snapshots(of vm: VMEntry) async -> [String] {
        let disk = vm.disk
        return await Task.detached { qemuImgSnapshots(disk) }.value
    }

    func cleanScratch() {
        status = "Cleaning leftover throwaway VMs..."
        let paths = paths
        Task {
            let (n, kb) = await Task.detached { cleanLeftoverScratch(paths) }.value
            status = "Cleaned \(n) leftover throwaway VM(s), freed \(fmtKB(kb))."
            reload()
        }
    }

    // MARK: - Images

    func deleteImage(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            status = "Trashed image '\(url.lastPathComponent)'."
        } catch {
            status = "Couldn't delete '\(url.lastPathComponent)': \(error.localizedDescription)"
        }
        reload()
    }

    func setSearchDir(_ url: URL) {
        do {
            try paths.saveSearchDir(url)
            status = "Images now come from \(abbreviate(url))."
        } catch {
            status = "Couldn't save the image folder: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: - Releases

    func isDownloaded(_ entry: CatalogEntry) -> Bool {
        let file = getFilename(distro: entry.distro, arch: entry.arch, url: entry.url)
        return FileManager.default.fileExists(atPath: paths.searchDir.appending(path: file).path)
    }

    func syncCatalog() {
        guard !busy else { return }
        busy = true
        status = "Checking the current releases..."
        let paths = paths
        Task {
            let result = await Task.detached { await attempt { () async throws(CrabError) in try await cmdSync(paths) } }.value
            busy = false
            switch result {
            case .success: status = "Release list updated."
            case .failure(let error): status = "Couldn't update the release list: \(error.message)"
            }
            reload()
        }
    }

    func downloadRelease(_ entry: CatalogEntry, bootAfter: Bool) {
        guard download == nil else { return }
        let file = getFilename(distro: entry.distro, arch: entry.arch, url: entry.url)
        let cancel = CancelFlag()
        let label = "\(entry.distro)/\(entry.variant) \(entry.version)"
        download = ActiveDownload(label: label, cancel: cancel)
        status = "Downloading \(label)..."
        let paths = paths

        // A message per 64K chunk would flood the UI, so progress is throttled.
        let throttle = ProgressThrottle()
        let report: DownloadReport = { event in
            switch event {
            case .note(let note):
                Task { @MainActor in self.download?.note = note.trimmingCharacters(in: .whitespaces) }
            case .progress(let done, let total):
                guard throttle.shouldReport(final: total == done) else { return }
                Task { @MainActor in
                    self.download?.done = done
                    self.download?.total = total
                }
            }
        }

        Task {
            let result = await Task.detached {
                await attempt { () async throws(CrabError) in
                    try await downloadImage(paths, url: entry.url, sha256: entry.sha256, file: file, dryRun: false, cancel: cancel, report: report)
                }
            }.value
            download = nil
            switch result {
            case .success(let path):
                status = "Downloaded \(path.lastPathComponent)."
                if bootAfter {
                    var opts = bootOptions()
                    opts.knownArch = entry.arch
                    // Download-and-boot is always a throwaway try-out, like `crab get`.
                    opts.keep = false
                    opts.live = false
                    if !entry.display.isEmpty {
                        opts.display = entry.display
                    }
                    bootImage(path, opts: opts, label: "\(entry.distro)/\(entry.variant)")
                }
            case .failure where cancel.isCancelled:
                status = "Download cancelled. The partial file is kept and resumes next time."
            case .failure(let error):
                status = "Download failed: \(error.message)"
            }
            reload()
        }
    }

    func cancelDownload() {
        guard let download else { return }
        download.cancel.cancel()
        status = "Cancelling the \(download.label) download..."
    }

    // MARK: - Mirrors & RSS

    func addMirror(host: String, official: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        let official = official.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !busy else { return }
        busy = true
        status = official.isEmpty ? "Probing '\(host)' for Fedora, Ubuntu, Alpine and OpenBSD trees..." : "Adding mirror rule..."
        let paths = paths
        Task {
            let result = await Task.detached {
                await attempt { () async throws(CrabError) in
                    try await addMirrorEntry(paths, official.isEmpty ? host : official, official.isEmpty ? nil : host)
                }
            }.value
            busy = false
            switch result {
            case .success(let added): status = "Added \(added.count) mirror rule(s)."
            case .failure(let error): status = "Couldn't add the mirror: \(error.message)"
            }
            reload()
        }
    }

    func removeMirror(_ rule: MirrorRule) {
        do {
            let n = try removeMirrorMatching(paths, rule.mirror)
            status = "Removed \(n) mirror rule(s)."
        } catch {
            status = error.message
        }
        reload()
    }

    func resetMirrors() {
        do {
            try CrabKit.resetMirrors(paths)
            status = "Mirrors reset to the built-in defaults."
        } catch {
            status = error.message
        }
        reload()
    }

    func fetchRSS(_ url: String) {
        let url = url.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !busy else { return }
        busy = true
        status = "Fetching \(url)..."
        Task {
            let result = await Task.detached { await attempt { () async throws(CrabError) in try await fetchRSSFeed(url) } }.value
            busy = false
            switch result {
            case .success(let items):
                rssItems = items
                status = "Loaded \(items.count) items from the feed."
            case .failure(let error):
                status = "Couldn't fetch the feed: \(error.message)"
            }
        }
    }

    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Runs `work`, returning its error message, or nil if it succeeded.
private func report(_ work: () throws(CrabError) -> Void) -> String? {
    do {
        try work()
        return nil
    } catch {
        return error.message
    }
}

/// Lets through at most one progress update every 100ms, plus the last one.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldReport(final: Bool) -> Bool {
        lock.withLock {
            guard final || Date().timeIntervalSince(last) >= 0.1 else { return false }
            last = Date()
            return true
        }
    }
}

/// Runs `body`, capturing its outcome as a Result.
private func attempt<T>(_ body: () async throws(CrabError) -> T) async -> Result<T, CrabError> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}
