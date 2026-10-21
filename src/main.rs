mod boot;
mod catalog;
mod config;
mod gui;
mod qmp;
mod vm;

use boot::{BootOptions, cmd_boot};
use catalog::{cmd_get, cmd_mirrors, cmd_sync};
use config::{
    DEFAULT_CLEAN_DAYS, DEFAULT_CPUS, DEFAULT_DISK_SIZE, DEFAULT_MEM, DISTROS, Forward, Paths,
    valid_cpus, valid_mem, valid_port,
};
use std::env;
use std::path::{Path, PathBuf};
use std::process;
use vm::{
    cmd_clean, cmd_clone, cmd_delete, cmd_delsnap, cmd_images, cmd_kill, cmd_list, cmd_rename,
    cmd_resize, cmd_restore, cmd_set, cmd_snapshot, cmd_snapshots, cmd_ssh, cmd_stop,
};

fn usage(paths: &Paths) {
    println!(
        "\
Usage: crab [options]               pick an image or saved VM from a menu and boot it
       crab [options] IMAGE         try IMAGE in a throwaway VM
       crab gui                     open the native desktop GUI
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
       crab ssh [USER@]NAME [-- COMMAND...]
                                    ssh into a running VM through its forwarded port
       crab list                    list saved VMs
       crab set NAME [KEY=VALUE...] show or change a VM's saved settings
       crab clone NAME NEW          copy a VM, disk and snapshots included
       crab rename NAME NEW         rename a VM
       crab resize NAME SIZE        grow a VM's disk (SIZE like 40G, or +10G)
       crab images                  list images in the search folder
       crab clean [DAYS]            offer to delete images and VMs unused for DAYS
                                    (default {DEFAULT_CLEAN_DAYS})
       crab delete NAME             delete a saved VM and its disk
       crab snapshot NAME [TAG]     snapshot a VM's disk (TAG defaults to a timestamp)
       crab snapshots NAME          list a VM's snapshots
       crab restore NAME TAG        roll a VM's disk back to a snapshot
       crab delsnap NAME TAG        delete a snapshot

Images boot in a throwaway VM: when QEMU exits you're asked whether to keep
it, and if not, its disk is deleted.

Boot options:
  -s DIR    where to look for (and download) .iso/.img files (default: ~/Downloads)
  -a ARCH   with get: arm64 or amd64 (default: this Mac's)
  -d        with get: download only, don't boot
  -k        keep: make a named VM straight away instead of a throwaway one
  -l        live: boot the image with no disk at all (for live ISOs)
  -m MEM    guest RAM (default: {DEFAULT_MEM})
  -c N      guest CPUs (default: {DEFAULT_CPUS})
  -z SIZE   size of a new VM's disk (default: {DEFAULT_DISK_SIZE})
  -p PORT   forward localhost:PORT to the guest's SSH port (new VMs get a free
            port from 2222 up; -p 0 turns it off)
  -P H:G    forward localhost port H to guest port G (repeatable; udp:H:G for
            UDP; -P 0 drops saved forwards)
  -f FW     x86 firmware: uefi or bios (new x86 VMs default to uefi)
  -g        graphical window
  -t        serial console in this terminal (default for BSD installers)
  -F        start the window full screen
  -r        arm64: plain framebuffer (ramfb) instead of virtio-gpu, for OSes
            that only draw to the boot framebuffer (e.g. Redox)
  -n        dry run: print the QEMU command instead of running it
  --gui     open the native desktop GUI
  -h        show this help

-m, -c, -p, -P, -f, -g, -t, -F and -r are saved with a VM and reused on its next
boot; change them without booting using crab set (keys: {}).
VMs live in {}/<name>/ (set VM_ROOT to keep them elsewhere).

get knows: {}. Images come from the mirrors in {}/mirrors
(or the built-in ones) and fall back to the official site; checksums always
come from the official release index.",
        vm::SETTABLE_KEYS.join(" "),
        paths.vm_root.display(),
        DISTROS.join(" "),
        paths.vm_root.display()
    );
}

fn die(msg: &str) -> ! {
    eprintln!("crab: {msg}");
    process::exit(1);
}

fn bad_usage(msg: &str) -> ! {
    eprintln!("crab: {msg}");
    eprintln!("Run 'crab -h' for usage.");
    process::exit(2);
}

const COMMANDS: &[&str] = &[
    "boot", "get", "sync", "list", "images", "clean", "delete", "snapshot", "snapshots", "restore",
    "delsnap", "mirrors", "dir", "stop", "kill", "ssh", "set", "clone", "rename", "resize",
];

#[derive(Debug, Default)]
struct Cli {
    cmd: String,
    opts: BootOptions,
    positional: Vec<String>,
    gui: bool,
    help: bool,
}

/// Parses flags and the subcommand, which may come before or after the flags.
/// Short flags can be bundled (-kp2222). Errors are usage errors.
fn parse_args(mut raw_args: Vec<String>) -> Result<Cli, String> {
    let mut cli = Cli::default();
    if let Some(first) = raw_args.first() {
        if first == "gui" || COMMANDS.contains(&first.as_str()) {
            cli.cmd = raw_args.remove(0);
        }
    }
    cli.gui = cli.cmd == "gui";
    let opts = &mut cli.opts;

    let mut i = 0;
    while i < raw_args.len() {
        let arg = &raw_args[i];
        if arg == "--gui" {
            cli.gui = true;
            i += 1;
            continue;
        }
        if arg == "--help" {
            cli.help = true;
            return Ok(cli);
        }
        if arg == "--" {
            cli.positional.extend(raw_args[i + 1..].iter().cloned());
            break;
        }
        if arg.starts_with('-') && arg.len() > 1 {
            let chars: Vec<char> = arg[1..].chars().collect();
            let mut j = 0;
            while j < chars.len() {
                let c = chars[j];
                match c {
                    's' | 'a' | 'm' | 'c' | 'z' | 'p' | 'P' | 'f' => {
                        let val = if j + 1 < chars.len() {
                            chars[j + 1..].iter().collect::<String>()
                        } else {
                            i += 1;
                            if i >= raw_args.len() {
                                return Err(format!("-{c} needs a value"));
                            }
                            raw_args[i].clone()
                        };
                        match c {
                            's' => opts.search_dir = Some(PathBuf::from(val)),
                            'a' => opts.arch = Some(val),
                            'm' => opts.mem = Some(val),
                            'c' => opts.cpus = Some(val),
                            'z' => opts.disk_size = Some(val),
                            'p' => opts.ssh_port = Some(val),
                            'P' => {
                                let fwds = Forward::parse_list(&val)?;
                                opts.forwards.get_or_insert_with(Vec::new).extend(fwds);
                            }
                            'f' => opts.firmware = Some(val),
                            _ => unreachable!(),
                        }
                        break;
                    }
                    'd' => opts.download_only = true,
                    'k' => opts.keep = true,
                    'l' => opts.live = true,
                    'g' => opts.display = Some("window".to_string()),
                    't' => opts.display = Some("terminal".to_string()),
                    'F' => opts.fullscreen = Some("on".to_string()),
                    'r' => opts.gpu = Some("ramfb".to_string()),
                    'n' => opts.dry_run = true,
                    'h' => {
                        cli.help = true;
                        return Ok(cli);
                    }
                    _ => return Err(format!("unknown option -{c}")),
                }
                j += 1;
            }
        } else {
            cli.positional.push(arg.clone());
        }
        i += 1;
    }

    if let Some(ref m) = opts.mem {
        if !valid_mem(m) {
            return Err("-m wants a size like 2G or 512M".to_string());
        }
    }
    if let Some(ref c) = opts.cpus {
        if !valid_cpus(c) {
            return Err("-c wants a number of CPUs".to_string());
        }
    }
    if let Some(ref p) = opts.ssh_port {
        if !valid_port(p) {
            return Err("-p wants a port number".to_string());
        }
    }
    if let Some(ref fw) = opts.firmware {
        if fw != "uefi" && fw != "bios" {
            return Err("-f wants uefi or bios".to_string());
        }
    }
    if let Some(ref a) = opts.arch.clone() {
        match a.as_str() {
            "" | "arm64" | "amd64" => {}
            "aarch64" => opts.arch = Some("arm64".to_string()),
            "x86_64" => opts.arch = Some("amd64".to_string()),
            _ => return Err("-a wants arm64 or amd64".to_string()),
        }
    }
    if opts.keep && opts.live {
        return Err("-k and -l don't go together".to_string());
    }

    if cli.cmd.is_empty() && !cli.positional.is_empty() {
        let first = cli.positional[0].as_str();
        if first == "gui" {
            cli.gui = true;
            cli.positional.remove(0);
        } else if COMMANDS.contains(&first) {
            cli.cmd = cli.positional.remove(0);
        }
    }
    Ok(cli)
}

fn main() {
    let cli = parse_args(env::args().skip(1).collect()).unwrap_or_else(|e| bad_usage(&e));
    let Cli {
        cmd,
        opts,
        positional,
        gui: launch_gui,
        help,
    } = cli;

    let mut paths = Paths::new(opts.search_dir.clone());

    if help {
        usage(&paths);
        return;
    }

    if launch_gui {
        if let Err(e) = gui::run_gui(paths, opts) {
            die(&e);
        }
        return;
    }

    let nargs = positional.len();
    let first = positional.first().map(String::as_str);

    let res: Result<(), String> = match cmd.as_str() {
        "" => {
            if nargs == 0 {
                cmd_boot(&paths, &opts, None, None)
            } else if nargs == 1 && Path::new(first.unwrap()).is_file() {
                cmd_boot(&paths, &opts, None, Some(Path::new(first.unwrap())))
            } else if nargs == 1 {
                bad_usage(&format!("no such image or command: {}", first.unwrap()));
            } else {
                bad_usage("too many arguments");
            }
        }
        "boot" => {
            if nargs != 1 {
                bad_usage("usage: crab boot [options] NAME");
            }
            cmd_boot(&paths, &opts, first, None)
        }
        "stop" => {
            if nargs != 1 {
                bad_usage("usage: crab stop NAME");
            }
            cmd_stop(&paths, first.unwrap())
        }
        "kill" => {
            if nargs != 1 {
                bad_usage("usage: crab kill NAME");
            }
            cmd_kill(&paths, first.unwrap())
        }
        "ssh" => {
            if nargs == 0 {
                bad_usage("usage: crab ssh [USER@]NAME [-- COMMAND...]");
            }
            cmd_ssh(&paths, first.unwrap(), &positional[1..])
        }
        "set" => {
            if nargs == 0 {
                bad_usage("usage: crab set NAME [KEY=VALUE...]");
            }
            cmd_set(&paths, first.unwrap(), &positional[1..])
        }
        "clone" => {
            if nargs != 2 {
                bad_usage("usage: crab clone NAME NEW");
            }
            cmd_clone(&paths, first.unwrap(), &positional[1])
        }
        "rename" => {
            if nargs != 2 {
                bad_usage("usage: crab rename NAME NEW");
            }
            cmd_rename(&paths, first.unwrap(), &positional[1])
        }
        "resize" => {
            if nargs != 2 {
                bad_usage("usage: crab resize NAME SIZE");
            }
            cmd_resize(&paths, first.unwrap(), &positional[1])
        }
        "get" => {
            if nargs > 1 {
                bad_usage("usage: crab get [options] [DISTRO[/VARIANT]]");
            }
            cmd_get(&paths, &opts, first)
        }
        "sync" => {
            if nargs != 0 {
                bad_usage("usage: crab sync");
            }
            cmd_sync(&paths)
        }
        "list" => {
            if nargs != 0 {
                bad_usage("usage: crab list");
            }
            cmd_list(&paths);
            Ok(())
        }
        "images" => {
            if nargs != 0 {
                bad_usage("usage: crab images");
            }
            cmd_images(&paths);
            Ok(())
        }
        "clean" => {
            if nargs > 1 {
                bad_usage("usage: crab clean [DAYS]");
            }
            let days = match first {
                Some(s) => s
                    .parse::<u64>()
                    .unwrap_or_else(|_| bad_usage("DAYS should be a number")),
                None => DEFAULT_CLEAN_DAYS,
            };
            cmd_clean(&paths, days);
            Ok(())
        }
        "delete" => {
            if nargs != 1 {
                bad_usage("usage: crab delete NAME");
            }
            cmd_delete(&paths, first.unwrap())
        }
        "snapshot" => {
            if !(1..=2).contains(&nargs) {
                bad_usage("usage: crab snapshot NAME [TAG]");
            }
            cmd_snapshot(&paths, first.unwrap(), positional.get(1).map(String::as_str))
        }
        "snapshots" => {
            if nargs != 1 {
                bad_usage("usage: crab snapshots NAME");
            }
            cmd_snapshots(&paths, first.unwrap())
        }
        "restore" => {
            if nargs != 2 {
                bad_usage("usage: crab restore NAME TAG");
            }
            cmd_restore(&paths, first.unwrap(), &positional[1])
        }
        "delsnap" => {
            if nargs != 2 {
                bad_usage("usage: crab delsnap NAME TAG");
            }
            cmd_delsnap(&paths, first.unwrap(), &positional[1])
        }
        "mirrors" => cmd_mirrors(&paths, &positional),
        "dir" => {
            if nargs == 0 {
                println!("{}", paths.search_dir.display());
                Ok(())
            } else if nargs == 1 {
                let p = config::abs_path(Path::new(first.unwrap()));
                paths
                    .save_search_dir(p.clone())
                    .map(|()| {
                        println!("Default ISO search & download folder set to: {}", p.display());
                    })
                    .map_err(|e| format!("failed to save search dir: {e}"))
            } else {
                bad_usage("usage: crab dir [PATH]");
            }
        }
        _ => unreachable!(),
    };

    if let Err(e) = res {
        die(&e);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Cli, String> {
        parse_args(args.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn bundled_flags_and_values() {
        let cli = parse(&["-kp2222", "-m", "4G", "-tn", "x.iso"]).unwrap();
        assert!(cli.opts.keep && cli.opts.dry_run);
        assert_eq!(cli.opts.ssh_port.as_deref(), Some("2222"));
        assert_eq!(cli.opts.mem.as_deref(), Some("4G"));
        assert_eq!(cli.opts.display.as_deref(), Some("terminal"));
        assert_eq!(cli.positional, ["x.iso"]);
        assert_eq!(cli.cmd, "");
    }

    #[test]
    fn command_before_or_after_flags() {
        assert_eq!(parse(&["boot", "-p", "2200", "vm"]).unwrap().cmd, "boot");
        let cli = parse(&["-p", "2200", "boot", "vm"]).unwrap();
        assert_eq!((cli.cmd.as_str(), cli.positional.as_slice()), ("boot", &["vm".to_string()][..]));
        assert!(parse(&["gui"]).unwrap().gui);
        assert!(parse(&["-m2G", "gui"]).unwrap().gui);
        assert!(parse(&["--gui"]).unwrap().gui);
    }

    #[test]
    fn forwards_accumulate() {
        let cli = parse(&["-P", "8080:80", "-Pudp:5353:53", "boot", "vm"]).unwrap();
        let fwds = cli.opts.forwards.unwrap();
        assert_eq!(Forward::list_to_conf(&fwds), "8080:80,udp:5353:53");
        assert_eq!(parse(&["-P0", "boot", "vm"]).unwrap().opts.forwards, Some(vec![]));
        assert!(parse(&["-P", "80"]).is_err());
    }

    #[test]
    fn double_dash_passes_the_rest_through() {
        let cli = parse(&["ssh", "root@vm", "--", "uname", "-a"]).unwrap();
        assert_eq!(cli.cmd, "ssh");
        assert_eq!(cli.positional, ["root@vm", "uname", "-a"]);
    }

    #[test]
    fn usage_errors() {
        assert!(parse(&["-m", "lots"]).is_err());
        assert!(parse(&["-c0"]).is_err());
        assert!(parse(&["-p", "70000"]).is_err());
        assert!(parse(&["-f", "coreboot"]).is_err());
        assert!(parse(&["-a", "riscv64"]).is_err());
        assert!(parse(&["-k", "-l"]).is_err());
        assert!(parse(&["-x"]).is_err());
        assert!(parse(&["-m"]).is_err());
        assert_eq!(parse(&["-a", "aarch64"]).unwrap().opts.arch.as_deref(), Some("arm64"));
        assert!(parse(&["-h", "-x"]).unwrap().help);
    }
}
