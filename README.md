# 🦀 crab

Try out OS images on macOS, Linux, and Windows (`x86_64`/`amd64` and `arm64`) in throwaway QEMU VMs, keep the ones you like, and trash the rest.

`crab` is the Rust rewrite of `vmboot`, adding a native desktop GUI (`iced`) alongside full CLI compatibility with existing `~/VMs` folders.

## Features

- **Throwaway VMs by default:** Point `crab` at an `.iso` or `.img`, or pick one from a menu of `~/Downloads` and `~/VMs`. When QEMU exits, `crab` asks whether to keep it—say no and both the VM and (optionally) the ISO are trashed. If nothing was written to the disk, it cleans up automatically without asking.
- **Native CLI & Desktop GUI:** Run `crab` in the terminal for classic numbered menus and flags, or run `crab gui` (or `crab --gui`) for a native desktop window to browse/manage VMs, snapshots, local ISOs, and distro downloads.
- **Built-in Release Catalog & Mirror Downloader:** Fetch the latest releases of **Fedora** (`workstation`, `kde`, `server`, `netinst`), **Ubuntu LTS** (`desktop`, `server`), **Alpine** (`standard`, `virt`, `extended`), and **OpenBSD** (`install`) with automatic SHA-256 verification and `.part` download resumption—all natively in Rust (no `jq`, `curl`, `file`, or `du` required).
- **Multi-Host & Multi-Architecture (`x86_64`/`amd64` & `arm64`):**
  - Automatically detects guest architecture (`arm64`, `amd64`, `i386`) from filenames, ISO 9660 volume labels, or embedded UEFI boot loaders (`BOOTAA64.EFI`, `BOOTX64.EFI`, `BOOTIA32.EFI`).
  - Uses native hardware acceleration when guest and host architectures match (`hvf` on macOS, `kvm` on Linux when `/dev/kvm` is accessible, `whpx` on Windows), falling back cleanly to `tcg` emulation otherwise.
  - Selects the appropriate display backend for each OS (`cocoa` on macOS, `gtk` on Linux, `sdl` on Windows) and locates UEFI firmware (`edk2-*`, `OVMF`, `AAVMF`) across Homebrew, Linux distro packages, and Windows QEMU installs.
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

Every VM crab boots gets a QMP control socket at `~/VMs/<name>/qmp.sock`. `crab stop`, `crab kill`, the live state in `crab list` (`running`, `paused`, `shutdown`, …) and the GUI's Shut Down / Force Off buttons use it. VMs booted by `vmboot` don't have one; `crab kill` still works for them.

## Development

```bash
cargo test                    # unit tests
cargo test boot::             # just one module's tests
crab -n IMAGE                 # check the QEMU command line without booting
```

## Requirements

- **macOS** (`arm64` Apple Silicon or `x86_64` Intel): `brew install qemu`
- **Linux** (`x86_64` or `aarch64`):
  - Debian/Ubuntu: `sudo apt install qemu-system-x86 qemu-system-arm qemu-utils ovmf qemu-efi-aarch64`
  - Fedora: `sudo dnf install qemu-system-x86 qemu-system-aarch64 qemu-img edk2-ovmf edk2-aarch64`
  - Arch: `sudo pacman -S qemu-full edk2-ovmf edk2-armvirt`
  - For hardware acceleration your user needs access to `/dev/kvm` (usually by joining the `kvm` group); without it, VMs run under emulation.
  - Building crab needs the GTK 3 development headers (e.g. `libgtk-3-dev`) for the GUI's file dialogs.
- **Windows** (`x86_64`): `winget install SoftwareFreedomConservancy.QEMU` (or install to `C:\Program Files\qemu`)
  - For hardware acceleration, turn on the **Windows Hypervisor Platform** optional feature. Without it, QEMU falls back to emulation (slow), printing `falling back to tcg`.

## Installation

```bash
cargo install --path .
```

## Quick Start

### Desktop GUI

```bash
crab gui       # or: crab --gui
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

You can also edit `~/VMs/mirrors` directly or manage folders, mirrors, and RSS feeds from the **Local Images** and **Mirrors & RSS** tabs in `crab gui`.

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
