# 🦀 crab

Try out OS images on your Mac (Apple Silicon or Intel) in throwaway QEMU VMs, keep the ones you like, and trash the rest.

`crab` is a Swift rewrite of `vmboot`: a `crab` command-line tool plus a native SwiftUI Mac app, both fully compatible with existing `~/VMs` folders.

## Features

- **Throwaway VMs by default:** Point `crab` at an `.iso` or `.img`, or pick one from a menu of `~/Downloads` and `~/VMs`. When QEMU exits, `crab` asks whether to keep it—say no and both the VM and (optionally) the ISO are trashed. If nothing was written to the disk, it cleans up automatically without asking.
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

  Redox and 9front images are packed with zstd and gzip, and are unpacked after download (zstd comes with Homebrew's QEMU). 9front publishes no checksums, so its downloads are marked unverified.
- **Multi-Architecture (`arm64`, `amd64`, `i386`):**
  - Automatically detects guest architecture (`arm64`, `amd64`, `i386`) from filenames, ISO 9660 volume labels, or embedded UEFI boot loaders (`BOOTAA64.EFI`, `BOOTX64.EFI`, `BOOTIA32.EFI`).
  - Uses Hypervisor.framework (`hvf`) when the guest matches your Mac's architecture, falling back to `tcg` emulation otherwise.
  - Opens guests in QEMU's `cocoa` window and uses the UEFI firmware (`edk2-*`) that ships with Homebrew's QEMU.
  - Attaches real ISO 9660 images as CD-ROMs and hybrid/raw disk images (like OpenBSD `install*.img` or Redox `livedisk.iso`) with a temporary snapshot overlay so the source image is never modified.
- **Live Installation without Disk**
  `crab` can boot operating systems directly from ISOs or disk images without creating a persistent virtual disk. When you run `crab -l image.iso`, it boots the guest *only for the duration of the session*. The OS installer runs inside a temporary, throwaway VM. Once the installer closes, the VM is deleted, and no trace is left behind. This is perfect for trying out live installers from **Fedora**, **Ubuntu**, **Alpine**, **OpenBSD**, or **Arch** without cluttering your system with virtual hard drives.
  **Niche Operating Systems**
  `crab` is not limited to the major Linux distributions. It can boot a wide range of operating systems, including:
  - TempleOS/ZealOS
  - Haiku
  - ReactOS
  - Redox
  - Plan 9/9front

### SSH and Port Forwards

New VMs get an SSH forward on the first free port from 2222 up (`-p PORT` picks one, `-p 0` turns it off), so `crab ssh NAME` works as soon as the guest runs `sshd`. Host keys are remembered per VM name, not per port. Extra forwards are given with `-P HOST:GUEST` (or `udp:HOST:GUEST`), saved with the VM, and cleared with `-P 0`.

### Control Socket

Every VM crab boots gets a QMP control socket at `~/VMs/<name>/qmp.sock`. `crab stop`, `crab kill`, the live state in `crab list` (`running`, `paused`, `shutdown`, …) and the app's Shut Down / Force Off buttons use it. VMs booted by `vmboot` don't have one; `crab kill` still works for them.

## Requirements

- macOS 15 or later, on Apple Silicon or Intel
- QEMU: `brew install qemu`
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
