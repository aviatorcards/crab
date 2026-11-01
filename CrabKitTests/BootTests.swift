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
}
