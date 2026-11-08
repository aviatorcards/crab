import Foundation
import Observation
import Virtualization

/// The latest restore image this Mac can install, or nil if Virtualization
/// can't say (offline, or not Apple Silicon). The URL points at Apple; the
/// file still has to be downloaded before `VZMacOSInstaller` will take it.
func fetchLatestSupportedMacOSRestore() async -> MacOSRestoreChoice? {
    if macosGuestRefusal(hostArchitecture: hostArch()) != nil {
        return nil
    }
    do {
        let image: VZMacOSRestoreImage = try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                cont.resume(with: result)
            }
        }
        return MacOSRestoreChoice(
            version: macosRestoreVersion(image),
            build: image.buildVersion,
            url: image.url.absoluteString
        )
    } catch {
        return nil
    }
}

/// Why a guest can't be started right now, including a Mac that is Apple
/// Silicon but has virtualization turned off.
public func macosHostBlockReason() -> String? {
    if let reason = macosGuestRefusal(hostArchitecture: hostArch()) {
        return reason
    }
    if !VZVirtualMachine.isSupported {
        return "This Mac can't run virtual machines (Virtualization.framework says they're unavailable)."
    }
    return nil
}

private func macosRestoreVersion(_ image: VZMacOSRestoreImage) -> String {
    let version = image.operatingSystemVersion
    if version.majorVersion > 0 {
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    return macosVersionFromIPSWName(image.url.absoluteString) ?? ""
}

/// A macOS guest running in this process. Create and use it on the main thread;
/// Virtualization delivers delegate callbacks on the queue the VM was created on.
@MainActor
@Observable
public final class MacOSGuest {
    public enum Phase: String, Sendable {
        case preparing, installing, starting, running, stopped, failed
    }

    public let directory: URL
    public let displayName: String
    public let throwaway: ThrowawayInfo?
    public let notes: [String]
    public private(set) var phase: Phase = .preparing
    public private(set) var message: String
    public private(set) var installFraction: Double?
    /// Ignored by Observation: the view watches `showsDisplay` and then reads this.
    @ObservationIgnored public private(set) var virtualMachine: VZVirtualMachine?
    public private(set) var showsDisplay = false

    @ObservationIgnored private let imageURL: URL?
    @ObservationIgnored private let needsInstall: Bool
    @ObservationIgnored private let ownsNewDirectory: Bool
    @ObservationIgnored private let plan: MacOSHardwarePlan
    @ObservationIgnored private var versionHint: String
    @ObservationIgnored private var buildHint: String
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var finishWait: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let commands = CommandBox()
    @ObservationIgnored private let delegate: MacOSVMDelegate
    @ObservationIgnored private var control: VZControlServer?

    public static func make(
        paths: Paths,
        image: URL?,
        savedName: String?,
        keep: Bool,
        keepName: String?,
        mem: String?,
        cpus: String?,
        disk: String?
    ) async throws(CrabError) -> MacOSGuest {
        if let reason = macosHostBlockReason() {
            throw CrabError(reason)
        }
        if let savedName {
            let dir = try vmPath(paths, savedName)
            guard isMacOSVM(dir) else {
                throw CrabError("\(savedName) is not a macOS VM")
            }
            var config = MacOSVMConfig.load(dir)
            if let mem, !mem.isEmpty {
                config.mem = try validateMacOSSetting("mem", mem, config: config)
            }
            if let cpus, !cpus.isEmpty {
                config.cpus = try validateMacOSSetting("cpus", cpus, config: config)
            }
            do {
                try confSet(dir, [("mem", config.mem), ("cpus", config.cpus)])
            } catch {
                throw CrabError("failed to write vm.conf: \(error.localizedDescription)")
            }
            let plan = resolveMacOSHardware(mem: config.mem, cpus: config.cpus, disk: config.disk)
            let imageURL: URL?
            if config.installed {
                imageURL = nil
            } else {
                let path = config.restoreImage
                guard !path.isEmpty, URL(filePath: path).isFile else {
                    throw CrabError("\(savedName) never finished installing, and its restore image is missing\(path.isEmpty ? "" : " (\(path))"). Delete it and run crab get macos again.")
                }
                imageURL = URL(filePath: path)
            }
            return MacOSGuest(
                directory: dir, displayName: savedName, throwaway: nil, imageURL: imageURL,
                needsInstall: imageURL != nil, ownsNewDirectory: false, plan: plan,
                versionHint: config.version, buildHint: config.build
            )
        }

        guard let image, image.isFile else {
            throw CrabError("no macOS restore image to install")
        }
        let imageURL = absPath(image)
        let plan = resolveMacOSHardware(mem: mem, cpus: cpus, disk: disk)
        let version = macosVersionFromIPSWName(imageURL.path) ?? ""
        let build = macosBuildFromIPSWName(imageURL.path) ?? ""
        if keep {
            let name = keepName.flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed } ?? defaultVMName(imageURL, arch: "arm64")
            try checkName(name)
            let dir = paths.vmRoot.appending(path: name, directoryHint: .isDirectory)
            if dir.exists {
                throw CrabError("there's already a VM called '\(name)'")
            }
            return MacOSGuest(
                directory: dir, displayName: name, throwaway: nil, imageURL: imageURL,
                needsInstall: true, ownsNewDirectory: true, plan: plan,
                versionHint: version, buildHint: build
            )
        }
        let scratch: URL
        do {
            scratch = try createScratchDir(paths.scratchRoot)
        } catch let error as CrabError {
            throw error
        } catch {
            throw CrabError("failed to create scratch dir: \(error.localizedDescription)")
        }
        let name = defaultVMName(imageURL, arch: "arm64")
        let info = ThrowawayInfo(dir: scratch, imagePath: imageURL, defaultName: name, live: false)
        do {
            try saveThrowawayInfo(info)
        } catch {
            throw CrabError("failed to write \(throwawayInfoFile(scratch).path): \(error.localizedDescription)")
        }
        return MacOSGuest(
            directory: scratch, displayName: name, throwaway: info, imageURL: imageURL,
            needsInstall: true, ownsNewDirectory: false, plan: plan,
            versionHint: version, buildHint: build
        )
    }

    init(
        directory: URL,
        displayName: String,
        throwaway: ThrowawayInfo?,
        imageURL: URL?,
        needsInstall: Bool,
        ownsNewDirectory: Bool,
        plan: MacOSHardwarePlan,
        versionHint: String,
        buildHint: String
    ) {
        self.directory = directory
        self.displayName = displayName
        self.throwaway = throwaway
        self.imageURL = imageURL
        self.needsInstall = needsInstall
        self.ownsNewDirectory = ownsNewDirectory
        self.plan = plan
        self.versionHint = versionHint
        self.buildHint = buildHint
        self.notes = plan.notes
        self.message = needsInstall ? "Reading the restore image…" : "Starting \(displayName)…"
        delegate = MacOSVMDelegate(commands: commands)
        commands.guest = self
    }

    /// Installs if this VM has never finished installing, then starts it, then
    /// waits until the guest stops or `requestStop` / `forceStop` runs.
    public func run() async {
        do {
            try await bootOrInstall()
        } catch {
            // A stop during install already finished the guest.
            if !finished {
                phase = .failed
                message = (error as? CrabError)?.message ?? error.localizedDescription
                cleanupRuntime()
                // Drop a named directory only when installation never finished.
                // A VM that installed and then failed to start is still worth keeping.
                if ownsNewDirectory && !MacOSVMConfig.load(directory).installed {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            return
        }
        if finished { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if finished {
                cont.resume()
            } else {
                finishWait = cont
            }
        }
    }

    public func requestStop() {
        guard !finished else { return }
        guard let virtualMachine, phase == .running || phase == .installing || phase == .starting else {
            didStop(error: nil)
            return
        }
        message = "Shutting down…"
        if virtualMachine.canRequestStop {
            virtualMachine.requestStop()
        } else {
            Task { await forceStop() }
        }
    }

    public func forceStop() async {
        guard !finished else { return }
        guard let virtualMachine else {
            didStop(error: nil)
            return
        }
        message = "Forcing off…"
        do {
            try await virtualMachine.stop()
            didStop(error: nil)
        } catch {
            didStop(error: error)
        }
    }

    func handleControl(_ command: String) {
        switch command {
        case "quit":
            Task { await forceStop() }
        default:
            requestStop()
        }
    }

    private func bootOrInstall() async throws(CrabError) {
        let layout = MacOSVMLayout(directory: directory)
        if needsInstall {
            guard let imageURL else {
                throw CrabError("\(displayName) has no restore image to install")
            }
            let image = try await loadRestoreImage(imageURL)
            if finished { return }
            guard let requirements = image.mostFeaturefulSupportedConfiguration else {
                throw CrabError("This Mac can't install \(imageURL.lastPathComponent). Use crab get macos so Virtualization picks the restore image this Mac supports.")
            }
            guard requirements.hardwareModel.isSupported else {
                throw CrabError("This Mac doesn't support the hardware model in \(imageURL.lastPathComponent).")
            }
            let version = macosRestoreVersion(image)
            if !version.isEmpty { versionHint = version }
            if !image.buildVersion.isEmpty { buildHint = image.buildVersion }
            try prepareInstallFiles(layout: layout, requirements: requirements, image: imageURL)
            let platform = try loadPlatform(layout)
            let resources = clampedResources(
                minimumMemory: requirements.minimumSupportedMemorySize,
                minimumCPUs: requirements.minimumSupportedCPUCount
            )
            let vm = try makeVirtualMachine(platform: platform, disk: layout.disk, resources: resources)
            virtualMachine = vm
            showsDisplay = true
            startControl()
            await Task.yield()
            phase = .installing
            message = "Installing macOS \(versionHint). This takes a while."
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
            do {
                try await runInstaller(installer)
            } catch {
                if finished { return }
                throw CrabError("macOS installation failed: \(error.localizedDescription)")
            }
            if finished { return }
            do {
                try confSet(directory, [("installed", "1")])
            } catch {
                throw CrabError("macOS installed, but vm.conf couldn't be updated: \(error.localizedDescription)")
            }
            phase = .starting
            message = "Starting…"
            do {
                try await vm.start()
            } catch {
                if finished { return }
                throw CrabError("macOS installed, but it didn't start: \(error.localizedDescription)")
            }
        } else {
            let platform = try loadPlatform(layout)
            let saved = MacOSVMConfig.load(directory)
            let resources = clampedResources(
                minimumMemory: UInt64(saved.minMemoryMB) * 1024 * 1024,
                minimumCPUs: saved.minCPUs
            )
            let vm = try makeVirtualMachine(platform: platform, disk: layout.disk, resources: resources)
            virtualMachine = vm
            showsDisplay = true
            startControl()
            await Task.yield()
            phase = .starting
            message = "Starting…"
            do {
                try await vm.start()
            } catch {
                if finished { return }
                throw CrabError("couldn't start \(displayName): \(error.localizedDescription)")
            }
        }
        if finished { return }
        phase = .running
        message = ""
    }

    private func prepareInstallFiles(layout: MacOSVMLayout, requirements: VZMacOSConfigurationRequirements, image: URL) throws(CrabError) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: layout.directory, withIntermediateDirectories: true)
        } catch {
            throw CrabError("failed to create \(layout.directory.path): \(error.localizedDescription)")
        }
        // An interrupted install must not reuse a half-written disk or identifier.
        for url in [layout.disk, layout.hardwareModel, layout.machineIdentifier, layout.auxiliaryStorage] {
            try? fm.removeItem(at: url)
        }
        do {
            try requirements.hardwareModel.dataRepresentation.write(to: layout.hardwareModel)
            try VZMacMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: layout.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [])
        } catch {
            throw CrabError("couldn't create the VM's hardware files: \(error.localizedDescription)")
        }
        try createSparseDisk(layout.disk, bytes: plan.diskBytes)
        let minBytes = requirements.minimumSupportedMemorySize
        let minMemoryMB = max(Int((minBytes + 1024 * 1024 - 1) / (1024 * 1024)), minMacOSMemoryMB)
        let minCPUs = max(requirements.minimumSupportedCPUCount, minMacOSCPUs)
        // Save the values the guest will actually boot with, so `crab list` matches.
        let config = MacOSVMConfig(
            version: versionHint,
            build: buildHint,
            mem: formatMemoryMB(max(plan.memoryMB, minMemoryMB)),
            cpus: String(max(plan.cpus, minCPUs)),
            disk: plan.diskText,
            installed: false,
            restoreImage: image.path,
            minMemoryMB: minMemoryMB,
            minCPUs: minCPUs
        )
        do {
            try confSet(layout.directory, config.updates())
        } catch {
            throw CrabError("failed to write vm.conf: \(error.localizedDescription)")
        }
    }

    private func clampedResources(minimumMemory: UInt64, minimumCPUs: Int) -> (memory: UInt64, cpus: Int) {
        let step: UInt64 = 1024 * 1024
        let wanted = UInt64(plan.memoryMB) * step
        let floor = max(minimumMemory, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        var memory = max(wanted, floor)
        memory = min(memory, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        memory = max((memory / step) * step, (floor + step - 1) / step * step)
        if memory > VZVirtualMachineConfiguration.maximumAllowedMemorySize {
            memory = VZVirtualMachineConfiguration.maximumAllowedMemorySize / step * step
        }
        let cpuFloor = max(minimumCPUs, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let cpus = min(max(plan.cpus, cpuFloor), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return (memory, cpus)
    }

    private func makeVirtualMachine(platform: VZMacPlatformConfiguration, disk: URL, resources: (memory: UInt64, cpus: Int)) throws(CrabError) -> VZVirtualMachine {
        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = resources.cpus
        config.memorySize = resources.memory
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full
            )
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        } catch {
            throw CrabError("couldn't attach \(disk.lastPathComponent): \(error.localizedDescription)")
        }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80),
        ]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [
            VZMacTrackpadConfiguration(),
            VZUSBScreenCoordinatePointingDeviceConfiguration(),
        ]
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        config.audioDevices = [sound]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        do {
            try config.validate()
        } catch {
            throw CrabError("this Mac rejected the macOS VM configuration: \(error.localizedDescription)")
        }
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = delegate
        return vm
    }

    private func loadPlatform(_ layout: MacOSVMLayout) throws(CrabError) -> VZMacPlatformConfiguration {
        let hardwareData: Data
        let identifierData: Data
        do {
            hardwareData = try Data(contentsOf: layout.hardwareModel)
            identifierData = try Data(contentsOf: layout.machineIdentifier)
        } catch {
            throw CrabError("couldn't read \(displayName)'s hardware files: \(error.localizedDescription)")
        }
        guard let hardware = VZMacHardwareModel(dataRepresentation: hardwareData), hardware.isSupported else {
            throw CrabError("This Mac doesn't support \(displayName)'s hardware model. It was probably created on a newer Mac.")
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw CrabError("\(displayName)'s machine identifier is unreadable.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: layout.auxiliaryStorage)
        return platform
    }

    private func loadRestoreImage(_ url: URL) async throws(CrabError) -> VZMacOSRestoreImage {
        do {
            return try await withCheckedThrowingContinuation { cont in
                VZMacOSRestoreImage.load(from: url) { result in
                    cont.resume(with: result)
                }
            }
        } catch {
            throw CrabError("couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func runInstaller(_ installer: VZMacOSInstaller) async throws {
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                self.installFraction = installer.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            installer.install { result in
                cont.resume(with: result)
            }
        }
    }

    private func startControl() {
        let layout = MacOSVMLayout(directory: directory)
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: layout.pidFile, atomically: true, encoding: .utf8)
        guard layout.socket.path.utf8.count <= QMP.maxSocketPath else { return }
        let server = VZControlServer()
        control = server
        let box = commands
        try? server.start(at: layout.socket.path) { command in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.guest?.handleControl(command)
                }
            }
        }
    }

    private func cleanupRuntime() {
        control?.stop()
        control = nil
        let layout = MacOSVMLayout(directory: directory)
        try? FileManager.default.removeItem(at: layout.pidFile)
        try? FileManager.default.removeItem(at: layout.socket)
    }

    fileprivate func didStop(error: Error?) {
        guard !finished else { return }
        finished = true
        showsDisplay = false
        cleanupRuntime()
        if phase != .failed {
            if let error {
                phase = .failed
                message = (error as? CrabError)?.message ?? error.localizedDescription
            } else {
                phase = .stopped
                message = "Stopped."
            }
        }
        finishWait?.resume()
        finishWait = nil
    }
}

/// Holds the guest for the control-socket thread without making `MacOSGuest` sendable.
private final class CommandBox: @unchecked Sendable {
    nonisolated(unsafe) weak var guest: MacOSGuest?
}

/// Forwards Virtualization callbacks onto the main actor. The delegate is
/// invoked on the queue the VM was created on, which is the main queue.
private final class MacOSVMDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let commands: CommandBox

    init(commands: CommandBox) {
        self.commands = commands
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let commands = commands
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                commands.guest?.didStop(error: nil)
            }
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let commands = commands
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                commands.guest?.didStop(error: error)
            }
        }
    }
}
