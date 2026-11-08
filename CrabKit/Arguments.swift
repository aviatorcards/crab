import Foundation

public let commands = [
    "boot", "get", "sync", "list", "images", "clean", "delete", "snapshot", "snapshots", "restore",
    "delsnap", "mirrors", "dir", "stop", "kill", "ssh", "set", "clone", "rename", "resize", "disc", "key",
]

public struct CLI: Sendable, Equatable {
    public var cmd = ""
    public var opts = BootOptions()
    public var positional: [String] = []
    public var gui = false
    public var help = false
}

/// Parses flags and the subcommand, which may come before or after the flags.
/// Short flags can be bundled (-kp2222), and everything after `--` is positional.
/// Errors are usage errors.
public func parseArgs(_ rawArgs: [String]) throws(CrabError) -> CLI {
    var rawArgs = rawArgs
    var cli = CLI()
    if let first = rawArgs.first, first == "gui" || commands.contains(first) {
        cli.cmd = rawArgs.removeFirst()
    }
    cli.gui = cli.cmd == "gui"

    var i = 0
    argLoop: while i < rawArgs.count {
        let arg = rawArgs[i]
        if arg == "--gui" {
            cli.gui = true
            i += 1
            continue
        }
        if arg == "--help" {
            cli.help = true
            return cli
        }
        if arg == "--" {
            cli.positional += rawArgs[(i + 1)...]
            break
        }
        if arg.hasPrefix("-") && arg.count > 1 {
            let chars = Array(arg.dropFirst())
            var j = 0
            while j < chars.count {
                let c = chars[j]
                switch c {
                case "s", "a", "m", "c", "z", "p", "P", "f", "H":
                    let val: String
                    if j + 1 < chars.count {
                        val = String(chars[(j + 1)...])
                    } else {
                        i += 1
                        guard i < rawArgs.count else {
                            throw CrabError("-\(c) needs a value")
                        }
                        val = rawArgs[i]
                    }
                    switch c {
                    case "s": cli.opts.searchDir = expandTilde(val)
                    case "a": cli.opts.arch = val
                    case "m": cli.opts.mem = val
                    case "c": cli.opts.cpus = val
                    case "z": cli.opts.diskSize = val
                    case "p": cli.opts.sshPort = val
                    case "P": cli.opts.forwards = (cli.opts.forwards ?? []) + (try Forward.parseList(val))
                    case "H": cli.opts.hw = val
                    default: cli.opts.firmware = val
                    }
                    i += 1
                    continue argLoop
                case "d": cli.opts.downloadOnly = true
                case "k": cli.opts.keep = true
                case "l": cli.opts.live = true
                case "g": cli.opts.display = "window"
                case "t": cli.opts.display = "terminal"
                case "F": cli.opts.fullscreen = "on"
                case "r": cli.opts.gpu = "ramfb"
                case "n": cli.opts.dryRun = true
                case "h":
                    cli.help = true
                    return cli
                default:
                    throw CrabError("unknown option -\(c)")
                }
                j += 1
            }
        } else {
            cli.positional.append(arg)
        }
        i += 1
    }

    let opts = cli.opts
    if let m = opts.mem, !validMem(m) {
        throw CrabError("-m wants a size like 2G or 512M")
    }
    if let c = opts.cpus, !validCPUs(c) {
        throw CrabError("-c wants a number of CPUs")
    }
    if let p = opts.sshPort, !validPort(p) {
        throw CrabError("-p wants a port number")
    }
    if let fw = opts.firmware, fw != "uefi" && fw != "bios" {
        throw CrabError("-f wants uefi or bios")
    }
    if let hw = opts.hw, !["standard", "virtio", "legacy"].contains(hw) {
        throw CrabError("-H wants standard, virtio or legacy")
    }
    switch opts.arch {
    case nil, "", "arm64", "amd64", "sparc64": break
    case "aarch64": cli.opts.arch = "arm64"
    case "x86_64": cli.opts.arch = "amd64"
    case "sun4u": cli.opts.arch = "sparc64"
    default: throw CrabError("-a wants arm64, amd64 or sparc64")
    }
    if opts.keep && opts.live {
        throw CrabError("-k and -l don't go together")
    }

    if cli.cmd.isEmpty, let first = cli.positional.first {
        if first == "gui" {
            cli.gui = true
            cli.positional.removeFirst()
        } else if commands.contains(first) {
            cli.cmd = cli.positional.removeFirst()
        }
    }
    return cli
}

public func usageText(_ paths: Paths) -> String {
    """
    Usage: crab [options]               pick an image or saved VM from a menu and boot it
           crab [options] IMAGE         try IMAGE in a throwaway VM
           crab gui                     open the Crab app
           crab get [options] DISTRO[/VARIANT]
                                        download the current release and try it
           crab get                     list what's available to get
           crab sync                    refresh the list of current releases
           crab mirrors [add|remove|reset|rss]
                                        list, auto-probe & add custom mirrors, or check RSS feeds
           crab dir [PATH]              show or persist the default ISO search/download directory
           crab boot [options] NAME     boot a saved VM
           crab stop NAME               ask a running VM to shut down
           crab kill NAME               force a running VM off
           crab disc NAME [IMAGE|eject] show, change or eject a running VM's CD
                                        (IMAGE may be a file name in the search folder)
           crab key NAME KEY...         press keys in a running VM, e.g. f8 or
                                        ctrl-alt-delete (for Touch Bar Macs and
                                        keys macOS keeps for itself)
           crab ssh [USER@]NAME [-- COMMAND...]
                                        ssh into a running VM through its forwarded port
           crab list                    list saved VMs
           crab set NAME [KEY=VALUE...] show or change a VM's saved settings
           crab clone NAME NEW          copy a VM, disk and snapshots included
           crab rename NAME NEW         rename a VM
           crab resize NAME SIZE        grow a VM's disk (SIZE like 40G, or +10G)
           crab images                  list images in the search folder
           crab clean [DAYS]            offer to delete images and VMs unused for DAYS
                                        (default \(defaultCleanDays))
           crab delete NAME             delete a saved VM and its disk
           crab snapshot NAME [TAG]     snapshot a VM's disk (TAG defaults to a timestamp)
           crab snapshots NAME          list a VM's snapshots
           crab restore NAME TAG        roll a VM's disk back to a snapshot
           crab delsnap NAME TAG        delete a snapshot

    Images boot in a throwaway VM: when QEMU exits you're asked whether to keep
    it, and if not, its disk is deleted. crab boots arm64, x86 (amd64, i386),
    PowerPC Mac (ppc: Mac OS 9, Mac OS X up to 10.5) and SPARC64 (sparc64: Sun Ultra 5) guests.

    Boot options:
      -s DIR    where to look for (and download) .iso/.img files (default: ~/Downloads)
      -a ARCH   with get: arm64 or amd64 (default: this Mac's)
      -d        with get: download only, don't boot
      -k        keep: make a named VM straight away instead of a throwaway one
      -l        live: boot the image with no disk at all (for live ISOs)
      -m MEM    guest RAM (default: \(defaultMem); PowerPC: \(defaultPPCMem))
      -c N      guest CPUs (default: \(defaultCPUs); PowerPC Macs have one)
      -z SIZE   size of a new VM's disk (default: \(defaultDiskSize))
      -p PORT   forward localhost:PORT to the guest's SSH port (new VMs get a free
                port from 2222 up; -p 0 turns it off)
      -P H:G    forward localhost port H to guest port G (repeatable; udp:H:G for
                UDP; -P 0 drops saved forwards)
      -f FW     x86 firmware: uefi or bios (new x86 VMs default to uefi)
      -H HW     x86 hardware: standard (q35, AHCI, e1000), legacy (i440fx, IDE,
                PCnet: for DOS, Windows 9x/XP and other pre-2006 OSes) or virtio.
                New x86 VMs that boot with BIOS default to legacy, others to standard
      -g        graphical window
      -t        serial console in this terminal (default for BSD installers)
      -F        start the window full screen
      -r        arm64: plain framebuffer (ramfb) instead of virtio-gpu, for OSes
                that only draw to the boot framebuffer (e.g. Redox)
      -n        dry run: print the QEMU command instead of running it
      --gui     open the Crab app
      -h        show this help

    -m, -c, -p, -P, -f, -H, -g, -t, -F and -r are saved with a VM and reused on its next
    boot; change them without booting using crab set (keys: \(settableKeys.joined(separator: " "))).
    VMs live in \(paths.vmRoot.path)/<name>/ (set VM_ROOT to keep them elsewhere).

    get knows: \(distros.joined(separator: " ")). Images come from the mirrors in \(paths.vmRoot.path)/mirrors
    (or the built-in ones) and fall back to the official site; checksums always
    come from the official release index.
    """
}
