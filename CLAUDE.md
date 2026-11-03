# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`crab` boots OS images (`.iso`/`.img`) on macOS in throwaway QEMU VMs, with a native SwiftUI desktop GUI (`Crab.app`) and a command-line tool (`crab`). It is a Swift rewrite of `vmboot.sh`, which is not in this repo. It must stay compatible with VM folders that `vmboot` created, so treat the on-disk layout and fallbacks below as the compatibility contract.

Runtime requirements: QEMU and its UEFI firmware (install via `brew install qemu`). The code calls `qemu-system-*` (aarch64, x86_64, i386, ppc) and `qemu-img`, plus `brew --prefix qemu` to find Homebrew installs, and `ps` on Unix.

## Commands

```bash
xcodegen                      # generate Crab.xcodeproj from project.yml
xcodebuild -scheme Crab -derivedDataPath build/dd build    # build the app and CLI
xcodebuild -scheme Crab -derivedDataPath build/dd test     # run all unit tests (Swift Testing)
```

Tests use the Swift Testing framework (`@Test`, `@Suite`). Filesystem tests use `testDir(name)` and `testPaths(root)` rather than `Paths.default`, which reads `HOME`/`VM_ROOT`. `QMPTests` run a fake QMP server on a Unix socket. Golden QEMU-command tests in `BootTests` spell out paths and arguments. Keep `buildQemuCommand` free of filesystem access by passing the firmware lookup in, or tests will pick up whatever OVMF/AAVMF the machine has installed.

CI (`.github/workflows/ci.yml`) generates the project with XcodeGen and runs tests via `xcodebuild`.

To experiment without touching real VMs, set `VM_ROOT=/some/tmp/dir`. Use `-s DIR` or `CRAB_SEARCH_DIR` to change the image search folder.

## Architecture

Managed via XcodeGen (`project.yml`), producing `Crab.xcodeproj` with four targets:

- **`CrabKit`**: static framework containing core logic:
  - `Arguments.swift`: command-line argument parsing and flag extraction.
  - `Boot.swift`: architecture detection (filename → ISO 9660 label → embedded `BOOT*.EFI` scan, refined by the El Torito boot catalog; floppy boot sectors; Apple partition maps → `ppc`; `unsupportedImageReason` for ppc64/SPARC/ARM32/`.dmg`), picker menu, and building the QEMU command line (binary, machine, accelerator `hvf`/`tcg`, firmware, disk/CD attach, display, SSH forward).
  - `Catalog.swift`: release catalog sync for Fedora, Ubuntu, Alpine and OpenBSD from official indexes, mirror rules (built-in or `~/VMs/mirrors` with auto-probing), RSS release feeds, and resumable `.part` downloads with SHA-256 verification.
  - `Config.swift`: `Paths` (on-disk locations derived from `VM_ROOT`, default `~/VMs`), default constants, validators (`validMem` etc.), `Forward` port-forward type, and shared helpers.
  - `Process.swift`: process execution helpers, finding executables, and child process management.
  - `QMP.swift`: synchronous QMP client for `<vm>/qmp.sock` (`queryStatus`, `systemPowerdown`, `quit`, `cdDrive`/`changeMedium` for disc swaps, `sendKeys`). macOS caps socket paths at 104 bytes, so `usableSocketPath` returns nil for long paths and those VMs boot without a socket.
  - `VM.swift`: saved-VM bookkeeping (`confGet`/`confSet`, inspecting/listing VMs, snapshots, resize, stop/kill, set, clone/rename, ssh).
- **`crab`**: the command-line executable (`crab/main.swift`).
- **`Crab`**: SwiftUI macOS application (`CrabApp.swift`, `ContentView.swift`, `AppModel.swift`, `VMListView.swift`, `ImageListView.swift`, `ReleasesView.swift`, `MirrorsView.swift`, `LaunchSettingsView.swift`, `ThrowawaySheet.swift`). Embeds the `crab` binary in `Contents/Helpers/crab`.
- **`CrabKitTests`**: unit tests written using Swift Testing (`@Suite`, `@Test`).

### Boot pipeline

The CLI and GUI each choose a VM directory and architecture their own way, then share everything after that:

1. Build a `BootRequest` (mode, vmDir, `ImageInfo`, arch, default name, whether it's a new VM). `cmdBoot` prompts for anything it needs. `spawnFromGUI` never prompts, so it uses the first detected arch (or the host's).
2. `prepareBoot` runs these steps in order:
   - `resolveSettings` (pure): flags, then vm.conf, then defaults, giving `VmSettings` plus user-facing notes.
   - Host port checks.
   - `buildQemuCommand` (pure): binary and args.
   - Checks that QEMU and the firmware are installed.
   - Unless this is a dry run: create the disk and efivars, then write `vm.conf` with `confSet`.
3. The CLI (`runCLIBoot`) prints notes and tips. It then `exec()`s QEMU for saved/named VMs, or runs it as a child with SIGINT ignored for throwaway/live VMs, followed by `afterThrowaway`. The GUI spawns QEMU and manages the process in `AppModel`.

Boot behavior changes (flags, hardware defaults, QEMU args) go in `resolveSettings`/`buildQemuCommand`, and the golden-args tests in `BootTests.swift` must be updated with them. `buildQemuCommand`'s `forceWindow` lets the GUI open a window without overwriting a VM's saved `display=terminal`.

### Boot modes and settings precedence

`BootMode`: `vm` (saved VM by name), `named` (`-k`, which creates or reuses `~/VMs/<name>` with the image attached), `throwaway` (default for images, runs in `~/VMs/.scratch/XXXXXX`), and `live` (`-l`, no disk).

Each setting is resolved in this order: CLI flag, then the VM's saved `vm.conf` value, then a default. `-m -c -p -P -f -g -t -F -r` are written back to `vm.conf` so the next boot reuses them. `confSet` keeps keys it isn't updating (such as `ssh_user`). New VMs get a free SSH port from 2222 up (`pickFreePort`, which skips ports any saved VM uses) unless `-p` is given.

### On-disk layout (shared with vmboot)

```
~/VMs/<name>/disk.qcow2   disk (snapshots stored inside it)
~/VMs/<name>/vm.conf      key=value settings; the last occurrence of a key wins
                          (fwd=8080:80,udp:53:53 and ssh_user= are crab-only keys)
~/VMs/<name>/efivars.fd   per-VM UEFI vars
~/VMs/<name>/qemu.pid     present while running
~/VMs/<name>/qmp.sock     QMP control socket while running (not created by vmboot)
~/VMs/<name>/arch         legacy (pre-vm.conf) VMs only: confGet falls back to it
~/VMs/.scratch/           throwaway VMs
~/VMs/.image-history      last-boot times per image
~/VMs/.catalog            synced release list (refreshed after 7 days)
~/VMs/mirrors             optional mirror overrides
~/VMs/config              crab-only settings (e.g. search_dir=)
```

Hardware defaults depend on whether the VM was created by older vmboot versions. New x86 VMs get `hw=standard` (q35, AHCI + e1000), or `hw=legacy` (i440fx, IDE + PCnet; crab-only) when they boot with BIOS, while arm64 VMs and older VMs get `virtio`. arm64 only allows `virtio`. `ppc` VMs (mac99, OpenBIOS, one CPU) always save `hw=mac99` and `firmware=openbios`. VMs without a `display` key default to the serial terminal on arm64. Don't change these fallbacks without accounting for existing VMs.
