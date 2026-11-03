import Foundation
import Testing
@testable import CrabKit

struct BootTests {
    @Test func archFromNames() {
        #expect(CrabKit.archFromName("Fedora-Workstation-Live-aarch64-41.iso") == "arm64")
        #expect(CrabKit.archFromName("/some/amd64/dir/install76.img") == nil)
        #expect(CrabKit.archFromName("ubuntu-24.04-live-server-amd64.iso") == "amd64")
        #expect(CrabKit.archFromName("alpine-virt-3.20-x86_64.iso") == "amd64")
        #expect(CrabKit.archFromName("debian-i386.iso") == "i386")
        #expect(CrabKit.archFromName("NetBSD-10-evbarm.img") == "arm64")
        #expect(CrabKit.archFromName("livedisk.iso") == nil)
        #expect(CrabKit.archFromName("en_windows_xp_professional_x86_cd.iso") == "i386")
        #expect(CrabKit.archFromName("distro-x86-64.iso") == "amd64")
    }

    @Test func efiLoaderNames() {
        #expect(matchesEFI(Array("..EFI/BOOT/BOOTAA64.EFI..".utf8), "BOOTAA64"))
        #expect(matchesEFI(Array("BOOTX64 EFI".utf8), "BOOTX64"))
        #expect(matchesEFI(Array("xxBOOTIA32EFI".utf8), "BOOTIA32"))
        #expect(!matchesEFI(Array("BOOTX64.EXE".utf8), "BOOTX64"))
        #expect(!matchesEFI(Array("BOOTX64".utf8), "BOOTX64"))
    }

    @Test func efiScanAcrossChunkBoundary() throws {
        let img = testDir("efi-scan").appending(path: "disk.img")
        var data = Data(count: 1024 * 1024 - 4)
        data.append(contentsOf: Array("BOOTX64.EFI".utf8))
        data.append(Data(count: 100))
        try data.write(to: img)
        let found = scanEFILoaders(img)
        #expect(!found.aa64 && found.x64 && !found.ia32)
        #expect(hasEFILoader(img))
    }

    @Test func defaultNames() {
        #expect(defaultVMName(URL(filePath: "/x/openbsd-install76.img"), arch: "amd64") == "openbsd-install76-amd64")
        #expect(defaultVMName(URL(filePath: "/x/Fedora-41-aarch64.iso"), arch: "arm64") == "Fedora-41-aarch64")
    }

    func image(_ name: String, isCD: Bool, isBSD: Bool) -> ImageInfo {
        ImageInfo(path: URL(filePath: "/img/\(name)"), isCD: isCD, isBSD: isBSD)
    }

    func resolve(
        _ opts: BootOptions = BootOptions(),
        saved: [String: String] = [:],
        arch: String,
        image: ImageInfo? = nil,
        newVM: Bool,
        efi: Bool = true
    ) throws(CrabError) -> (VMSettings, [String]) {
        try resolveSettings(
            opts, conf: { saved[$0] ?? "" }, arch: arch, image: image, newVM: newVM,
            hasEFI: { efi }, pickPort: { 2222 }
        )
    }

    @Test func newX86VMDefaults() throws {
        let (s, notes) = try resolve(arch: "amd64", image: image("alpine-x86_64.iso", isCD: true, isBSD: false), newVM: true)
        #expect(s.hw == "standard")
        #expect(s.firmware == "uefi")
        #expect(s.display == "window")
        #expect(s.sshPort == "2222", "new VMs get a free SSH port")
        #expect(s.mem == defaultMem && s.cpus == "2")
        #expect(notes.isEmpty)
    }

    @Test func bsdInstallerWithoutEFI() throws {
        let (s, notes) = try resolve(arch: "amd64", image: image("install76.img", isCD: false, isBSD: true), newVM: true, efi: false)
        #expect(s.firmware == "bios")
        #expect(s.hw == "legacy", "BIOS-only x86 images get the legacy PC")
        #expect(s.display == "terminal")
        #expect(notes == ["No UEFI boot loader in install76.img; using legacy BIOS."])
    }

    @Test func flagsBeatSavedValuesBeatDefaults() throws {
        var opts = BootOptions()
        opts.mem = "4G"
        opts.sshPort = "0"
        let saved = ["mem": "1G", "cpus": "6", "ssh_port": "2200", "fwd": "8080:80"]
        var (s, _) = try resolve(opts, saved: saved, arch: "arm64", newVM: false)
        #expect(s.mem == "4G")
        #expect(s.cpus == "6")
        #expect(s.sshPort == "", "-p 0 turns SSH off")
        #expect(s.forwards == [Forward(udp: false, host: 8080, guest: 80)])

        opts = BootOptions()
        opts.forwards = []
        (s, _) = try resolve(opts, saved: saved, arch: "arm64", newVM: false)
        #expect(s.sshPort == "2200")
        #expect(s.forwards.isEmpty, "-P 0 clears saved forwards")
    }

    @Test func oldVmbootVMsKeepTheirHardware() throws {
        // No hw or display saved: x86 VMs from older vmboot used virtio, and
        // arm64 ones used the serial console.
        var (s, _) = try resolve(saved: ["arch": "amd64"], arch: "amd64", newVM: false)
        #expect(s.hw == "virtio" && s.display == "window")
        (s, _) = try resolve(saved: ["arch": "arm64"], arch: "arm64", newVM: false)
        #expect(s.hw == "virtio" && s.display == "terminal")
        #expect(s.sshPort == "", "existing VMs don't get a port picked")
    }

    @Test func arm64CannotUseBIOS() {
        var opts = BootOptions()
        opts.firmware = "bios"
        #expect(throws: CrabError.self) { try resolve(opts, arch: "arm64", newVM: false) }
    }

    func settings(_ arch: String) -> VMSettings {
        VMSettings(
            arch: arch, firmware: "uefi", mem: "2G", cpus: "2", display: "window", sshPort: "2222",
            forwards: [Forward(udp: false, host: 8080, guest: 80)], hw: "virtio", gpu: "virtio", fullscreen: "off"
        )
    }

    /// Firmware as if QEMU's share directory were /share.
    func share(_ arch: String) -> (URL, URL) {
        let names = qemuUEFINames(arch)
        return (URL(filePath: "/share/\(names.code)"), URL(filePath: "/share/\(names.vars)"))
    }

    func request(_ mode: BootMode, _ image: ImageInfo? = nil) -> BootRequest {
        BootRequest(mode: mode, vmDir: URL(filePath: "/vms/test"), image: image, arch: "", defaultName: "test", newVM: false)
    }

    @Test func arm64ThrowawayCommand() throws {
        let req = request(.throwaway, image("fedora.iso", isCD: true, isBSD: false))
        let cmd = try buildQemuCommand(settings("arm64"), req, hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(cmd.qemu == "qemu-system-aarch64")
        #expect(cmd.args.joined(separator: " ") == """
            -M virt -accel hvf -cpu host \
            -drive if=pflash,format=raw,unit=0,readonly=on,file=/share/edk2-aarch64-code.fd \
            -drive if=pflash,format=raw,unit=1,file=/vms/test/efivars.fd \
            -name test -m 2G -smp 2 \
            -drive file=/vms/test/disk.qcow2,if=none,id=disk,format=qcow2 \
            -device virtio-blk-pci,drive=disk,bootindex=0 \
            -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80 \
            -pidfile /vms/test/qemu.pid \
            -qmp unix:/vms/test/qmp.sock,server=on,wait=off \
            -device virtio-scsi-pci -drive if=none,id=cd,media=cdrom,readonly=on,file=/img/fedora.iso \
            -device scsi-cd,drive=cd,bootindex=1 \
            -display cocoa,zoom-to-fit=on,full-screen=off \
            -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet
            """)
        #expect(cmd.fwVarsTemplate == URL(filePath: "/share/edk2-arm-vars.fd"))
        #expect(cmd.notes.isEmpty)
    }

    @Test func arm64BootOrderIsOnlySetWithACD() throws {
        let cmd = try buildQemuCommand(settings("arm64"), request(.vm), hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(!cmd.args.contains { $0.contains("bootindex") })
    }

    @Test func x86BIOSLiveUnderEmulation() throws {
        var s = settings("amd64")
        s.firmware = "bios"
        s.hw = "standard"
        s.display = "terminal"
        s.sshPort = ""
        s.forwards = []
        let req = request(.live, image("install76.img", isCD: false, isBSD: true))
        let cmd = try buildQemuCommand(s, req, hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(cmd.qemu == "qemu-system-x86_64")
        #expect(cmd.args.joined(separator: " ") == """
            -M q35 -accel tcg -cpu max -name test -m 2G -smp 2 \
            -nic user,model=e1000 -pidfile /vms/test/qemu.pid \
            -qmp unix:/vms/test/qmp.sock,server=on,wait=off \
            -drive file=/img/install76.img,if=ide,format=raw,snapshot=on -nographic
            """)
        #expect(cmd.fwVarsTemplate == nil)
        #expect(cmd.notes.count == 1)
    }

    @Test func guiForcesAWindow() throws {
        var s = settings("amd64")
        s.display = "terminal"
        let cmd = try buildQemuCommand(s, request(.vm), hostArch: "x86_64", uefi: share, forceWindow: true)
        #expect(!cmd.args.contains("-nographic"))
        #expect(cmd.args.contains("cocoa,zoom-to-fit=on,full-screen=off"))
        #expect(cmd.args.joined(separator: " ").contains("-accel hvf"))
    }

    @Test func longVMDirsGetNoControlSocket() throws {
        var req = request(.vm)
        req.vmDir = URL(filePath: "/Users/me/VMs/" + String(repeating: "x", count: 90))
        let cmd = try buildQemuCommand(settings("arm64"), req, hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(!cmd.args.contains("-qmp"))
        #expect(cmd.notes.first?.contains("too long a path for a control socket") == true)
    }

    @Test func accelerators() {
        let args = { (guest: String, host: String) in accelArgs(guest: guest, hostArch: host).0.joined(separator: " ") }
        #expect(args("arm64", "arm64") == "-accel hvf -cpu host")
        #expect(args("x86", "x86_64") == "-accel hvf -cpu host")
        #expect(args("x86", "arm64") == "-accel tcg -cpu max")
        #expect(args("arm64", "x86_64") == "-accel tcg -cpu max")

        let note = { (guest: String, host: String) in accelArgs(guest: guest, hostArch: host).1 }
        #expect(note("arm64", "arm64") == nil)
        #expect(note("x86", "arm64")?.contains("x86 guest on an arm64 host") == true)
        #expect(note("arm64", "x86_64")?.contains("arm64 guest on an x86_64 host") == true)
    }

    @Test func unknownArch() {
        #expect(throws: CrabError.self) {
            try buildQemuCommand(settings("riscv64"), request(.vm), hostArch: "arm64", uefi: share, forceWindow: false)
        }
    }

    @Test func extraQemuFlagsParsing() {
        #expect(parseExtraQemuFlags("").isEmpty)
        #expect(parseExtraQemuFlags("   ").isEmpty)
        #expect(parseExtraQemuFlags("-cpu host -smp 4") == ["-cpu", "host", "-smp", "4"])
        #expect(parseExtraQemuFlags("-device \"virtio-net-pci,netdev=net0\" -snapshot") == ["-device", "virtio-net-pci,netdev=net0", "-snapshot"])
        #expect(parseExtraQemuFlags("-name 'My Test VM'") == ["-name", "My Test VM"])
    }

    @Test func guiArchPrefersDetectionOverFallback() throws {
        var opts = BootOptions()
        opts.fallbackArch = "arm64"
        #expect(try guiImageArch(opts) { ["amd64"] } == "amd64")
        #expect(try guiImageArch(opts) { [] } == "arm64")
        opts.knownArch = "i386"
        #expect(try guiImageArch(opts) { ["amd64"] } == "i386")
    }

    @Test func existingVMsKeepSavedSettingsFromGUI() throws {
        var opts = BootOptions()
        opts.mem = "2G"
        opts.cpus = "2"
        opts.gpu = "virtio"
        opts.fullscreen = "off"
        opts.firmware = "uefi"
        opts.extraQemuArgs = ["-s"]
        let kept = opts.withoutSavedSettings()
        #expect(kept.extraQemuArgs == ["-s"])
        let saved = ["mem": "8G", "cpus": "6", "gpu": "ramfb", "fullscreen": "on", "firmware": "bios", "ssh_port": "2233"]
        let (s, _) = try resolve(kept, saved: saved, arch: "amd64", newVM: false)
        #expect(s.mem == "8G" && s.cpus == "6" && s.gpu == "ramfb" && s.fullscreen == "on" && s.firmware == "bios")
        #expect(s.sshPort == "2233")
    }

    // MARK: - Detection from the image's contents

    /// An ISO with an El Torito catalog listing `platforms` (each bootable),
    /// plus `extra` bytes (e.g. boot loader names) after the catalog.
    func elToritoISO(_ name: String, platforms: [UInt8], extra: String = "") throws -> URL {
        var data = Data(count: 2048 * 20)
        func put(_ bytes: [UInt8], at offset: Int) {
            data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        put([1] + Array("CD001".utf8), at: 16 * 2048)
        put([0] + Array("CD001".utf8) + [1] + Array("EL TORITO SPECIFICATION".utf8), at: 17 * 2048)
        put([19, 0, 0, 0], at: 17 * 2048 + 0x47)
        put([255] + Array("CD001".utf8), at: 18 * 2048)
        let cat = 19 * 2048
        put([1, platforms[0]], at: cat)
        put([0x88], at: cat + 32)
        var at = cat + 64
        for (n, p) in platforms.dropFirst().enumerated() {
            put([n == platforms.count - 2 ? 0x91 : 0x90, p, 1, 0], at: at)
            put([0x88], at: at + 32)
            at += 64
        }
        data.append(contentsOf: Array(extra.utf8))
        let url = testDir("eltorito-\(name)").appending(path: "\(name).iso")
        try data.write(to: url)
        return url
    }

    @Test func elToritoCatalog() throws {
        let iso = try elToritoISO("zeal", platforms: [0, 0xEF])
        #expect(elToritoPlatforms(iso) == [0, 0xEF])
        #expect(elToritoPlatforms(try elToritoISO("efi", platforms: [0xEF])) == [0xEF])
    }

    @Test func x86BIOSEntryBeatsAnArm64Loader() throws {
        // ZealOS: Limine carries loaders for every architecture, but the disc boots x86 BIOS.
        let iso = try elToritoISO("zealos", platforms: [0, 0xEF], extra: "BOOTAA64.EFI BOOTX64.EFI BOOTIA32.EFI")
        #expect(detectArch(iso) == ["amd64"])
    }

    @Test func biosOnlyDiscsAreX86() throws {
        #expect(detectArch(try elToritoISO("xp", platforms: [0])) == ["amd64"])
    }

    @Test func arm64DiscsWithAMislabeledEFIImageStayArm64() throws {
        let iso = try elToritoISO("obsd", platforms: [0], extra: "BOOTAA64.EFI")
        #expect(detectArch(iso) == ["arm64"])
    }

    @Test func floppyImagesAreX86() throws {
        var floppy = Data(count: 1_474_560)
        floppy[510] = 0x55
        floppy[511] = 0xAA
        let url = testDir("floppy").appending(path: "boot.img")
        try floppy.write(to: url)
        #expect(detectArch(url) == ["amd64"])
        try Data(count: 1_474_560).write(to: url)
        #expect(detectArch(url).isEmpty, "no boot sector")
    }

    @Test func unsupportedImages() throws {
        let dir = testDir("unsupported")
        func file(_ name: String, _ bytes: [UInt8] = []) throws -> URL {
            let url = dir.appending(path: name)
            var data = Data(bytes)
            data.append(Data(count: 4096))
            try data.write(to: url)
            return url
        }
        #expect(unsupportedImageReason(try file("debian-12-ppc64el-netinst.iso"))?.contains("64-bit POWER") == true)
        #expect(unsupportedImageReason(try file("NetBSD-11.0-sparc64.iso"))?.contains("SPARC") == true)
        #expect(unsupportedImageReason(try file("haiku-arm-mmc.image"))?.contains("32-bit ARM") == true)
        #expect(unsupportedImageReason(try file("app.dmg"))?.contains(".dmg") == true)
        #expect(unsupportedImageReason(try file("plain.iso")) == nil)
        #expect(throws: CrabError.self) { try detectBootableArch(dir.appending(path: "NetBSD-11.0-sparc64.iso")) }
        #expect(try detectBootableArch(dir.appending(path: "plain.iso")).isEmpty)
    }

    // MARK: - PowerPC Macs

    @Test func powerPCDetection() throws {
        #expect(CrabKit.archFromName("macos_921_ppc.iso") == "ppc")
        #expect(CrabKit.archFromName("NetBSD-10.0-macppc.iso") == "ppc")
        #expect(CrabKit.archFromName("debian-powerpc-netinst.iso") == "ppc")
        #expect(CrabKit.archFromName("debian-ppc64el-netinst.iso") == nil)
        #expect(CrabKit.archFromName("snappcraft.iso") == nil, "ppc only as a whole word")

        let dir = testDir("ppc")
        let apm = Data([UInt8]("ER".utf8) + [UInt8](repeating: 0, count: 510) + [UInt8]("PM".utf8)) + Data(count: 4096)
        let disc = dir.appending(path: "Apple Mac OS X 10.3.0 - Disk 1.iso")
        try apm.write(to: disc)
        #expect(detectArch(disc) == ["ppc"])
        #expect(isCDImage(disc), "HFS Mac CDs have no ISO 9660 filesystem")
        let macDisk = dir.appending(path: "hd.img")
        try apm.write(to: macDisk)
        #expect(!isCDImage(macDisk), "a .img with a Mac partition map is a disk")
        #expect(defaultVMName(disc, arch: "ppc") == "Apple Mac OS X 10.3.0 - Disk 1-ppc")

        // A hybrid Linux ISO with a Mac partition map that also boots PCs isn't PowerPC.
        let hybrid = try elToritoISO("hybrid", platforms: [0, 0xEF], extra: "BOOTX64.EFI")
        var data = try Data(contentsOf: hybrid)
        data.replaceSubrange(0..<2, with: Array("ER".utf8))
        data.replaceSubrange(512..<514, with: Array("PM".utf8))
        try data.write(to: hybrid)
        #expect(detectArch(hybrid) == ["amd64"])
    }

    @Test func powerPCSettings() throws {
        let os9 = image("macos_921_ppc.iso", isCD: true, isBSD: false)
        var (s, notes) = try resolve(arch: "ppc", image: os9, newVM: true)
        #expect(s.mem == "512M" && s.cpus == "1")
        #expect(s.firmware == "openbios" && s.hw == "mac99" && s.display == "window")
        #expect(notes.isEmpty)

        var opts = BootOptions()
        opts.cpus = "2"
        (s, notes) = try resolve(opts, arch: "ppc", image: os9, newVM: true)
        #expect(s.cpus == "1")
        #expect(notes == ["PowerPC Macs (mac99) have one CPU; using 1."])

        opts = BootOptions()
        opts.mem = "2G"
        (s, notes) = try resolve(opts, arch: "ppc", image: os9, newVM: true)
        #expect(s.mem == "1536M", "Mac OS 9 won't boot with more")
        #expect(notes.first?.contains("at most 1536M") == true)
        opts.mem = "1G"
        #expect(try resolve(opts, arch: "ppc", newVM: true).0.mem == "1G")
        #expect(memMB("2G") == 2048 && memMB("512m") == 512 && memMB("768") == 768 && memMB("x") == nil)

        opts = BootOptions()
        opts.firmware = "bios"
        #expect(throws: CrabError.self) { try resolve(opts, arch: "ppc", newVM: true) }
        opts = BootOptions()
        opts.hw = "legacy"
        #expect(throws: CrabError.self) { try resolve(opts, arch: "ppc", newVM: true) }

        #expect(throws: CrabError.self) { try validateSetting("cpus", "2", arch: "ppc") }
        #expect(throws: CrabError.self) { try validateSetting("firmware", "uefi", arch: "ppc") }
        #expect(throws: CrabError.self) { try validateSetting("hw", "standard", arch: "ppc") }
    }

    @Test func powerPCCommand() throws {
        var s = settings("ppc")
        s.firmware = "openbios"
        s.hw = "mac99"
        s.mem = "512M"
        s.cpus = "1"
        s.forwards = []
        let req = request(.throwaway, image("macos_921_ppc.iso", isCD: true, isBSD: false))
        let cmd = try buildQemuCommand(s, req, hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(cmd.qemu == "qemu-system-ppc")
        #expect(cmd.args.joined(separator: " ") == """
            -M mac99,via=pmu -accel tcg -prom-env auto-boot?=true -prom-env vga-ndrv?=true \
            -name test -m 512M -smp 1 \
            -drive file=/vms/test/disk.qcow2,if=ide,format=qcow2 \
            -nic user,model=sungem,hostfwd=tcp:127.0.0.1:2222-:22 -pidfile /vms/test/qemu.pid \
            -qmp unix:/vms/test/qmp.sock,server=on,wait=off \
            -drive file=/img/macos_921_ppc.iso,media=cdrom,readonly=on,index=2 -boot d \
            -display cocoa,zoom-to-fit=on,full-screen=off
            """)
        #expect(cmd.fwCode == nil && cmd.fwVarsTemplate == nil)

        let saved = try buildQemuCommand(s, request(.vm), hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(saved.args.joined(separator: " ").contains("-boot c"), "boots the disk with no CD attached")
    }

    // MARK: - Legacy PC hardware

    @Test func hwFlagAndArm64() throws {
        var opts = BootOptions()
        opts.hw = "legacy"
        let (s, _) = try resolve(opts, saved: ["hw": "standard"], arch: "amd64", newVM: false)
        #expect(s.hw == "legacy", "-H beats the saved value")
        #expect(throws: CrabError.self) { try resolve(opts, arch: "arm64", newVM: true) }
        #expect(try parseArgs(["-H", "legacy", "x.iso"]).opts.hw == "legacy")
        #expect(throws: CrabError.self) { try parseArgs(["-H", "retro"]) }
        #expect(try validateSetting("hw", "legacy", arch: "amd64") == "legacy")
        #expect(throws: CrabError.self) { try validateSetting("hw", "legacy", arch: "arm64") }
    }

    @Test func legacyPCCommand() throws {
        var s = settings("i386")
        s.firmware = "bios"
        s.hw = "legacy"
        s.sshPort = ""
        s.forwards = []
        let req = request(.throwaway, image("winxp.iso", isCD: true, isBSD: false))
        let cmd = try buildQemuCommand(s, req, hostArch: "arm64", uefi: share, forceWindow: false)
        #expect(cmd.qemu == "qemu-system-i386")
        #expect(cmd.args.joined(separator: " ") == """
            -M pc -accel tcg -cpu max -name test -m 2G -smp 2 \
            -drive file=/vms/test/disk.qcow2,if=ide,format=qcow2 \
            -nic user,model=pcnet -pidfile /vms/test/qemu.pid \
            -qmp unix:/vms/test/qmp.sock,server=on,wait=off \
            -drive file=/img/winxp.iso,media=cdrom,readonly=on,index=2 \
            -display cocoa,zoom-to-fit=on,full-screen=off
            """)
    }
}
