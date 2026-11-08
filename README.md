# 🦀 crab

Try out OS images on your Mac (Apple Silicon or Intel) in throwaway QEMU VMs, keep the ones you like, and trash the rest.

`crab` is a Swift rewrite of `vmboot`: a `crab` command-line tool plus a native SwiftUI Mac app, both fully compatible with existing `~/VMs` folders. On Apple Silicon it can also install a current macOS guest from Apple's restore image, using Virtualization.framework rather than QEMU.

## Features

- **Throwaway VMs by default:** Point `crab` at an `.iso` or `.img`, or pick one from a menu of `~/Downloads` and `~/VMs`. When QEMU exits, `crab` asks whether to keep it—say no and both the VM and (optionally) the ISO are trashed. The question is asked for every throwaway that had a disk; the size is only shown so you can decide. Recoverable sessions (waiting on Keep or Discard, or left behind after a quit/crash) are preserved safely in `~/.scratch/` until explicitly resolved.
- **CLI & Mac App:** Run `crab` in the terminal for classic numbered menus and flags, or open **Crab.app** (or run `crab gui`) to browse and manage VMs, snapshots, local ISOs, and distro downloads.
- **Built-in Release Catalog & Mirror Downloader:** Fetch the latest releases straight from each project's own release index or open directory, with automatic SHA-256 verification and `.part` download resumption—no `jq`, `curl`, `file`, or `du` required:

  | Distro | Variants (default first) | Architectures |
  | --- | --- | --- |
  | Fedora | `workstation`, `kde`, `server`, `netinst` | arm64, amd64 |
  | Ubuntu LTS | `desktop`, `server` | arm64, amd64 |
  | Debian | `netinst` | arm64, amd64 |
  | Alpine | `standard`, `virt`, `extended` | arm64, amd64 |
  | Arch Linux | `live` | amd64 |
  | openSUSE Tumbleweed | `net`, `dvd` | arm64, amd64 |
  | Rocky Linux, AlmaLinux | `minimal`, `boot`, `dvd` | arm64, amd64 |
  | FreeBSD | `disc1`, `bootonly` | arm64, amd64 |
  | OpenBSD | `install` | arm64, amd64 |
  | Haiku | `anyboot` | amd64 |
  | Redox (daily builds) | `desktop`, `server`, `demo` | arm64, amd64 |
  | 9front | `live` | amd64 |
  | ZealOS | `uefi`, `bios` | amd64 |
  | macOS | `restore` | arm64 (Apple Silicon hosts only) |

  Redox and 9front images are packed with zstd and gzip, and are unpacked after download (zstd comes with Homebrew's QEMU). 9front publishes no checksums, so its downloads are marked unverified. macOS restore images are checked against the SHA-1 Apple publishes for the same IPSW, when that checksum is in the feed.
- **Multi-Architecture (`arm64`, `amd64`, `i386`, `ppc`, `sparc64`):**
  - Automatically detects guest architecture (`arm64`, `amd64`, `i386`, `ppc`, `sparc64`) from filenames, ISO 9660 volume labels, embedded UEFI boot loaders (`BOOTAA64.EFI`, `BOOTX64.EFI`, `BOOTIA32.EFI`), the ISO's El Torito boot catalog, Apple partition maps, or PC floppy boot sectors. Images for other machines (32-bit SPARC, MIPS, 32-bit ARM, `.dmg`) are refused with a clear message.
  - PowerPC Mac discs (Mac OS 9, Mac OS X up to 10.5, macppc BSDs) boot as `ppc` guests on QEMU's `mac99` G4 Power Mac with Open Firmware, under emulation.
  - SPARC64 discs (OpenBSD, NetBSD, Debian SPARC64, ...) boot as `sparc64` guests on QEMU's `sun4u` (Sun Ultra 5) with OpenBIOS, under emulation.
  - Older x86 OSes that can only boot with BIOS (DOS, Windows 9x/XP, ...) get a legacy PC (`-H legacy`: i440fx, IDE, PCnet); newer ones get q35 with AHCI and e1000.
  - Uses Hypervisor.framework (`hvf`) when the guest matches your Mac's architecture, falling back to `tcg` emulation otherwise.
  - Opens guests in QEMU's `cocoa` window and uses the UEFI firmware (`edk2-*`) that ships with Homebrew's QEMU.
  - Attaches real ISO 9660 images as CD-ROMs and hybrid/raw disk images (like OpenBSD `install*.img` or Redox `livedisk.iso`) with a temporary snapshot overlay so the source image is never modified.
  - Safely handles image symlinks in search folders: trashing or cleaning an image link unlinks the symlink itself without touching or deleting the target file.
- **Live Installation without Disk**
  `crab` can boot operating systems directly from ISOs or disk images without creating a persistent virtual disk. When you run `crab -l image.iso`, it boots the guest *only for the duration of the session*. The OS installer runs inside a temporary, throwaway VM. Once the installer closes, the VM is deleted, and no trace is left behind. This is perfect for trying out live installers from **Fedora**, **Ubuntu**, **Alpine**, **OpenBSD**, or **Arch** without cluttering your system with virtual hard drives.
  **Niche Operating Systems**
  `crab` is not limited to the major Linux distributions. It can boot a wide range of operating systems, including:
  - TempleOS/ZealOS
  - Haiku
  - ReactOS
  - Redox
  - Plan 9/9front
  - OpenBSD, NetBSD, or Debian on SPARC64 (`sun4u`)

### SSH and Port Forwards

New VMs get an SSH forward on the first free port from 2222 up (`-p PORT` picks one, `-p 0` turns it off), so `crab ssh NAME` works as soon as the guest runs `sshd`. Host keys are remembered per VM name, not per port. Extra forwards are given with `-P HOST:GUEST` (or `udp:HOST:GUEST`), saved with the VM, and cleared with `-P 0`. SSH logins are hardened against option injection by validating user names and invoking `ssh` with `-l <user>` and `--` before the host.

### Control Socket

Every VM crab boots gets a QMP control socket at `~/VMs/<name>/qmp.sock`. `crab stop`, `crab kill`, `crab disc`, `crab key`, the live state in `crab list` (`running`, `paused`, `shutdown`, …) and the app's Shut Down / Force Off / Change Disc / Send Key controls use it. VMs booted by `vmboot` don't have one; `crab kill` still works for them.

## macOS guests (Apple Silicon)

Current macOS does not run under QEMU here. On an Apple Silicon Mac, `crab` installs it with Apple's Virtualization.framework instead. Intel Macs get a clear refusal: the framework can run Linux on Intel, but it will not install macOS there, and QEMU can't either. Older PowerPC Mac OS X discs (up to 10.5) still boot as `ppc` guests on either Mac.

```bash
crab sync                     # the catalog gains macos/restore rows, one per published version
crab get                      # on Apple Silicon, macOS is listed next to the other arm64 releases
crab get macos                # download the newest image this Mac can install, then install it
crab get macos/list           # every restore image Apple has published for the virtual Mac
crab get macos/15             # the newest 15.x; macos/14.6.1 or a build (macos/23G93) work too
crab get -d macos             # download only
crab boot sequoia             # open a saved macOS VM in Crab.app
```

`crab get macos` asks `VZMacOSRestoreImage.latestSupported` for the restore image this Mac supports, and falls back to the newest `VirtualMac2,1` entry in Apple's feed (`https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml`) if that call fails. Apple's feed only lists the current release, so `crab sync` also reads the `VirtualMac2,1` firmware list from ipsw.me (`https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw`), the index Mist uses, for older builds and their SHA-256. Entries from that list are only kept when the file is on Apple's servers (`updates.cdn-apple.com`), so downloads always come from Apple. If either source can't be reached, sync uses the other. Asking for a version newer than this Mac's `latestSupported` prints a warning, because the host may not be able to install it. The IPSW is saved in the image folder under Apple's own file name and resumed like any other download. The CLI then hands the install to **Crab.app**, which is the process signed with `com.apple.security.virtualization` and the one that can show `VZVirtualMachineView`. The same window is what you get from **Get Distros** or by booting a `.ipsw` in **Local Images**.

Installation creates a VM beside the QEMU ones:

```
~/VMs/<name>/vm.conf              backend=vz, guest=macos, arch=arm64, firmware=vz,
                                  mem, cpus, disk, macos_version, macos_build,
                                  restore_image, installed, min_mem_mb, min_cpus
~/VMs/<name>/Disk.img             raw disk (sparse). QEMU VMs keep using disk.qcow2
~/VMs/<name>/HardwareModel        VZMacHardwareModel
~/VMs/<name>/MachineIdentifier    VZMacMachineIdentifier
~/VMs/<name>/AuxiliaryStorage     VZMacAuxiliaryStorage
~/VMs/<name>/vz.pid               present while Crab is running this guest
~/VMs/<name>/vz.sock              stop / force-off from `crab stop` and `crab kill`
```

Throwaway installs land in `~/VMs/.scratch/` and, when the window closes, the app asks whether to keep them, same as a QEMU throwaway. `crab list`, `crab delete`, `crab rename`, and `crab clone` include these VMs. `crab resize` grows `Disk.img` (the guest still has to grow its APFS container). `crab set` can change `mem` and `cpus` for the next boot.

What macOS VMs don't do:

- **Snapshots.** Virtualization.framework has no disk-snapshot API. `crab snapshot`, `crab restore`, and `crab delsnap` say so, and the app shows **No Snapshots**. QEMU snapshots are unchanged.
- **SSH and port forwards.** The guest uses NAT for outbound network only. `crab ssh`, `crab disc`, and `crab key` don't apply; use the window (or Screen Sharing inside the guest).
- **Live boot (`-l`).** Installing macOS needs a disk.
- **Running two clones at once.** A clone copies the machine identifier along with the disk. Apple treats that identifier as the VM's identity.

A new macOS VM gets at least 4G of RAM, 2 CPUs, and a 64G disk. Smaller `-m`, `-c`, or `-z` values are raised to that, and the restore image's own minimums can raise them further. The first boot is the installer and takes a while; later boots skip it (`installed=1` in `vm.conf`).

### Manual test on an Apple Silicon Mac

This tree can't be built or tested on Linux. On an Apple Silicon Mac with Xcode 26 or later:

```bash
xcodegen
xcodebuild -scheme Crab -derivedDataPath build/dd test
```

Then, with `VM_ROOT` pointed at a temporary directory if you don't want to touch `~/VMs`:

1. `codesign -d --entitlements :- build/dd/Build/Products/Debug/Crab.app` shows `com.apple.security.virtualization`.
2. `crab sync`, then `crab get` (host arch arm64) lists `macos/restore` (the newest build of each major version) next to the other releases. `crab get macos/list` lists every build. The app's **Get Distros** page shows the same rows, with the older builds under **All Builds**.
3. On an Intel Mac, `crab get macos` refuses before downloading, and names Apple Silicon. PowerPC Mac OS X discs still boot.
4. `crab get -n macos` prints the IPSW URL and the disk/RAM/CPU plan and does not open a window.
5. `crab get -d macos` downloads `UniversalMac_…_Restore.ipsw` with a progress bar. Interrupt it and run the command again; the `.part` file resumes. The checksum line reports SHA-1 when Apple published one.
6. `crab get macos` (or **Get & Boot** in the app) opens a Crab window, shows install progress, then the guest display. The guest has a keyboard, trackpad, and outbound network.
7. Closing the window asks whether to keep the throwaway. Keeping it makes `crab list` show `firmware=vz`, disk used-of-virtual, and `-` in the snapshots column.
8. `crab boot <name>` brings the window back without reinstalling. `crab stop <name>` asks the guest to shut down; `crab kill <name>` forces it off without quitting Crab.
9. `crab snapshot <name>` explains that snapshots aren't supported. `crab ssh <name>` explains that NAT has no host port forward. A QEMU VM's snapshot and SSH commands still behave as before.
10. `crab resize <name> +10G` grows `Disk.img`. `crab clone` copies the bundle. `crab delete` removes it.
11. Quit Crab mid-install and launch it again. The scratch VM is offered as a throwaway. A kept VM that never finished (`installed=0`) runs the installer again from `restore_image` in `vm.conf`; the half-written disk is replaced.

## Requirements

- macOS 15 or later, on Apple Silicon or Intel
- QEMU: `brew install qemu` (provides `qemu-system-aarch64`, `qemu-system-x86_64`, `qemu-system-i386`, `qemu-system-ppc`, `qemu-system-sparc64`; not used by macOS guests)
- macOS guests: an Apple Silicon Mac. The app and the `crab` tool are signed with `com.apple.security.virtualization` (ad-hoc signing is enough locally)
- To build: Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building and Installing

```bash
xcodegen                      # generate Crab.xcodeproj from project.yml
open Crab.xcodeproj           # build and run the Crab scheme in Xcode, or:
xcodebuild -scheme Crab -configuration Release -derivedDataPath build/dd build
cp -R build/dd/Build/Products/Release/Crab.app /Applications/
ln -s /Applications/Crab.app/Contents/Helpers/crab /usr/local/bin/crab   # or anywhere on your PATH
```

The `crab` command is bundled inside Crab.app, so `crab gui` opens the app it came with.

## Development

```bash
xcodebuild -scheme Crab -derivedDataPath build/dd test    # unit tests (Swift Testing)
crab -n IMAGE                                             # check the QEMU command line without booting
```

## Quick Start

### Mac App

Open **Crab** from Applications, or from the terminal:

```bash
crab gui       # or: crab --gui; boot flags like -m 4G become the app's launch settings
```

### Command Line

```bash
crab ~/Downloads/fedora.iso   # try an image in a throwaway VM
crab                          # pick from ~/Downloads and ~/VMs
crab -l live.iso              # live ISO: no disk at all, nothing to keep
crab -k openbsd.iso           # make a saved VM straight away
crab boot openbsd             # boot a saved VM
crab boot openbsd -p 2222     # ...with ssh -p 2222 user@localhost forwarded in
crab boot web -P 8080:80      # ...and forward localhost:8080 to the guest's port 80 (repeatable)
crab -n                       # dry run: print the QEMU command only
crab -h                       # all options
```

### Downloading Distros

```bash
crab get                      # list what's available for this Mac's architecture
crab get fedora               # download Fedora Workstation and try it
crab get ubuntu/server        # download a specific variant
crab get -a amd64 alpine      # get the x86_64 image instead
crab get -d openbsd           # download only, don't boot
crab sync                     # refresh the release catalog (~/.catalog)
```

### Customizing the Search Folder & Mirrors

```bash
crab dir                              # show the current ISO search/download folder (defaults to ~/Downloads)
crab dir ~/ISOs                       # persist a new default folder in ~/VMs/config
crab -s /tmp/isos images              # one-off override with -s

crab mirrors                          # list configured mirror rules
crab mirrors add mirrors.rit.edu      # auto-probe a mirror site's root index and add its distro trees
crab mirrors add https://releases.ubuntu.com/ https://mirrors.example.edu/ubuntu-releases/
crab mirrors remove mirrors.rit.edu   # remove matching rules
crab mirrors reset                    # reset to built-in mirrors
crab mirrors rss                      # check recent OS releases via RSS (defaults to DistroWatch feed)
crab mirrors rss https://example.org/releases.xml
```

You can also edit `~/VMs/mirrors` directly or manage folders, mirrors, and RSS feeds from the **Local Images** and **Mirrors & RSS** sections of the app.

### Managing Saved VMs & Cleaning Up

```bash
crab list                     # arch, firmware, RAM, CPUs, SSH, disk use, snapshots, state, last used
crab stop openbsd             # press the power button and wait (offers to force it off after a minute)
crab kill openbsd             # force it off now
crab disc panther "Apple Mac OS X 10.3.0 - Disk 2.iso"   # swap the CD in a running VM (for multi-disc installers)
crab disc panther eject       # empty its CD drive
crab key w2k f8               # press keys in a running VM (Touch Bar F-keys, ctrl-alt-delete, ...)
crab ssh openbsd              # ssh in through the VM's forwarded port
crab ssh root@openbsd -- uname -a
crab set openbsd              # show saved settings
crab set openbsd mem=4G ssh_user=root fwd=8080:80   # change them without booting
crab clone openbsd scratch    # copy a VM (instant on APFS); the copy gets its own SSH port
crab rename scratch play      # rename a VM
crab resize openbsd +10G      # grow a VM's disk (then grow the partition inside the guest)
crab images                   # ISOs in ~/Downloads: size, when downloaded, when last booted
crab clean                    # offer to delete images and VMs unused for 30 days (and leftover scratch VMs)
crab clean 7                  # ...or unused for 7 days
crab snapshot openbsd fresh   # snapshot a VM's disk (tag defaults to a timestamp)
crab snapshots openbsd        # list snapshots
crab restore openbsd fresh    # roll back to a snapshot
crab delsnap openbsd fresh    # delete a snapshot
crab delete openbsd           # delete a saved VM (asks for confirmation)
```
