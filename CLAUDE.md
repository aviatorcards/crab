# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`crab` boots OS images (`.iso`/`.img`) on macOS in throwaway QEMU VMs, with an optional `iced` desktop GUI. It is a Rust rewrite of `vmboot.sh` (kept in the repo as the reference implementation). The Rust version must stay compatible with VM folders that `vmboot` created, so check `vmboot.sh` when you're unsure how something should behave.

Runtime requirements: macOS, plus QEMU from Homebrew (`brew install qemu`). The code calls `qemu-system-*`, `qemu-img`, `brew --prefix qemu`, `file`, `du`, `ps` and `which`.

## Commands

```bash
cargo build                    # build
cargo run -- -h                # CLI help
cargo run -- -n some.iso       # dry run: print the QEMU command without booting (safe for checking boot logic)
cargo run -- gui               # launch the GUI
cargo test                     # all unit tests
cargo test boot::tests::arm64  # tests matching a name
cargo clippy                   # lint (the existing collapsible_if warnings are known)
cargo install --path .         # install the `crab` binary
```

Tests are inline `#[cfg(test)]` modules (binary crate, no lib). Filesystem tests use `config::test_dir(name)` and `config::test_paths(root)` rather than `Paths::new`, which reads `HOME`/`VM_ROOT`. `qmp.rs` tests run a fake QMP server on a Unix socket. The code isn't consistently `rustfmt`-formatted, so don't reformat whole files as part of unrelated changes.

To experiment without touching real VMs, set `VM_ROOT=/some/tmp/dir`. Use `-s DIR` or `CRAB_SEARCH_DIR` to change the image search folder.

## Architecture

Single binary crate, five modules under `src/`:

- **`main.rs`**: hand-rolled argument parsing (no clap) in `parse_args`, which returns `Err` for usage errors (main turns these into exit code 2). It handles bundled short flags like `-kp2222`, accepts subcommands before or after flags, and passes everything after `--` through as positional arguments. New subcommands must be added to `COMMANDS`. `crab gui` / `--gui` goes to `gui::run_gui`. Exit codes: `die` → 1, `bad_usage` → 2.
- **`config.rs`**: `Paths` (every on-disk location, derived from `VM_ROOT`, default `~/VMs`), default constants, value validators (`valid_mem` etc.), the `Forward` port-forward type, and shared helpers (prompts, sizes, ages, image listing, and boot history).
- **`vm.rs`**: saved-VM bookkeeping. Covers `conf_get`/`conf_set` for `vm.conf`, inspecting and listing VMs, `list`/`images`/`clean`/`delete`, snapshots and `resize` (all via `qemu-img`), `stop`/`kill`, `set` (only keys in `SETTABLE_KEYS`, checked by `validate_setting`), `clone`/`rename`, and `ssh`. Logic used by the GUI is split out of the `cmd_*` printers into functions such as `clone_vm`, `force_off` and `request_shutdown`.
- **`qmp.rs`**: a small synchronous QMP client for `<vm>/qmp.sock` (`query_status`, `system_powerdown`, `quit`). It skips async events while waiting for a reply. macOS caps socket paths at 104 bytes, so `usable_socket_path` returns None for long VM dirs and those VMs boot without a socket.
- **`boot.rs`**: architecture detection (filename → ISO 9660 label → embedded `BOOT*.EFI` scan), the image/VM picker menu, and building the QEMU command line (binary, machine, accelerator `hvf`/`tcg`, firmware, disk/CD attach, display, SSH forward).
- **`catalog.rs`**: release catalog sync for Fedora, Ubuntu, Alpine and OpenBSD from the official indexes, mirror rules (built-in or `~/VMs/mirrors`, with auto-probing), RSS release feeds, and resumable `.part` downloads with SHA-256 verification. It uses blocking `reqwest`.
- **`gui.rs`**: an `iced` 0.13 app in Elm style (`Message` enum, `update`/`view`). Slow work (catalog sync, downloads, mirror probes, RSS) runs through `Task::perform` with `tokio::task::spawn_blocking`, which reuses the blocking code from the CLI modules. A `time::every(800ms)` subscription (`Message::Tick`) polls running QEMU children (`try_wait`) in `active_sessions`. When a throwaway VM exits, that poll triggers the keep/discard prompt.

### Boot pipeline

The CLI and GUI each choose a VM directory and architecture their own way, then share everything after that:

1. Build a `BootRequest` (mode, vm_dir, `ImageInfo`, arch, default name, whether it's a new VM). `cmd_boot` prompts for anything it needs. `spawn_from_gui` never prompts, so it uses the first detected arch (or the host's).
2. `prepare_boot` runs these steps in order:
   - `resolve_settings` (pure): flags, then vm.conf, then defaults, giving `VmSettings` plus user-facing notes.
   - Host port checks.
   - `build_qemu_command` (pure): binary and args.
   - Checks that QEMU and the firmware are installed.
   - Unless this is a dry run: create the disk and efivars, then write `vm.conf` with `conf_set`.
3. The CLI (`run_cli_boot`) prints notes and tips. It then `exec()`s QEMU for saved/named VMs, or runs it as a child with SIGINT ignored for throwaway/live VMs, followed by `after_throwaway`. The GUI spawns QEMU and keeps the `Child` in a `GuiSpawnedVm`.

Boot behavior changes (flags, hardware defaults, QEMU args) go in `resolve_settings`/`build_qemu_command`, and the golden-args tests in `boot.rs` must be updated with them. `build_qemu_command`'s `force_window` lets the GUI open a window without overwriting a VM's saved `display=terminal`.

### Boot modes and settings precedence

`BootMode`: `Vm` (saved VM by name), `Named` (`-k`, which creates or reuses `~/VMs/<name>` with the image attached), `Throwaway` (default for images, runs in `~/VMs/.scratch/XXXXXX`), and `Live` (`-l`, no disk).

Each setting is resolved in this order: CLI flag, then the VM's saved `vm.conf` value, then a default. `-m -c -p -P -f -g -t -F -r` are written back to `vm.conf` so the next boot reuses them. `conf_set` keeps keys it isn't updating (such as `ssh_user`). New VMs get a free SSH port from 2222 up (`pick_free_port`, which skips ports any saved VM uses) unless `-p` is given.

### On-disk layout (shared with vmboot)

```
~/VMs/<name>/disk.qcow2   disk (snapshots stored inside it)
~/VMs/<name>/vm.conf      key=value settings; the last occurrence of a key wins
                          (fwd=8080:80,udp:53:53 and ssh_user= are crab-only keys)
~/VMs/<name>/efivars.fd   per-VM UEFI vars
~/VMs/<name>/qemu.pid     present while running
~/VMs/<name>/qmp.sock     QMP control socket while running (not created by vmboot)
~/VMs/<name>/arch         legacy (pre-vm.conf) VMs only: conf_get falls back to it
~/VMs/.scratch/           throwaway VMs
~/VMs/.image-history      last-boot times per image
~/VMs/.catalog            synced release list (refreshed after 7 days)
~/VMs/mirrors             optional mirror overrides
~/VMs/config              crab-only settings (e.g. search_dir=)
```

Hardware defaults depend on whether the VM was created by older vmboot versions. New x86 VMs get `hw=standard` (AHCI + e1000), while arm64 VMs and older VMs get `virtio`. VMs without a `display` key default to the serial terminal on arm64. Don't change these fallbacks without accounting for existing VMs.
