use crate::boot::pick_free_port;
use crate::config::{
    DEFAULT_CPUS, DEFAULT_MEM, Forward, Paths, ask_yes, disk_kb, file_mtime, fmt_age, fmt_kb,
    human_size, image_last_boot, image_last_used, list_image_entries, list_image_paths, now_secs,
    prompt_line, valid_cpus, valid_disk_size, valid_mem, valid_port,
};
use crate::qmp;
use chrono::Local;
use std::fs;
use std::io;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct VmEntry {
    pub name: String,
    pub dir: PathBuf,
    pub disk: PathBuf,
    pub arch: String,
    pub firmware: String,
    pub mem: String,
    pub cpus: String,
    pub ssh_port: String,
    pub display: String,
    pub hw: String,
    pub gpu: String,
    pub fullscreen: String,
    pub ssh_user: String,
    pub forwards: String,
    pub disk_used: String,
    pub disk_virt: String,
    pub snaps_count: usize,
    pub running_pid: Option<u32>,
    /// "stopped", or QEMU's run state: "running", "paused", "shutdown", ...
    pub state: String,
    pub last_used_secs: u64,
}

pub fn conf_get(dir: &Path, key: &str) -> String {
    let conf_path = dir.join("vm.conf");
    if conf_path.is_file() {
        if let Ok(content) = fs::read_to_string(&conf_path) {
            let prefix = format!("{key}=");
            let mut last = String::new();
            for line in content.lines() {
                if let Some(val) = line.strip_prefix(&prefix) {
                    last = val.trim().to_string();
                }
            }
            return last;
        }
    } else {
        let arch_path = dir.join("arch");
        if arch_path.is_file() {
            let arch = fs::read_to_string(&arch_path)
                .unwrap_or_default()
                .trim()
                .to_string();
            match key {
                "arch" => return arch,
                "firmware" => {
                    return if arch == "arm64" {
                        "uefi".to_string()
                    } else {
                        "bios".to_string()
                    };
                }
                _ => {}
            }
        }
    }
    String::new()
}

/// Sets keys in a VM's vm.conf, replacing earlier values and keeping any
/// other keys. VMs from old versions of vmboot only have an `arch` file, so
/// its values are carried over when vm.conf is first created.
pub fn conf_set(dir: &Path, updates: &[(&str, String)]) -> io::Result<()> {
    let conf_path = dir.join("vm.conf");
    let mut lines: Vec<String> = match fs::read_to_string(&conf_path) {
        Ok(content) => content.lines().map(String::from).collect(),
        Err(_) => ["arch", "firmware"]
            .iter()
            .map(|k| (k, conf_get(dir, k)))
            .filter(|(_, v)| !v.is_empty())
            .map(|(k, v)| format!("{k}={v}"))
            .collect(),
    };
    for (key, value) in updates {
        let prefix = format!("{key}=");
        let new_line = format!("{key}={value}");
        let mut placed = false;
        lines.retain_mut(|line| {
            if !line.starts_with(&prefix) {
                return true;
            }
            if placed {
                return false;
            }
            *line = new_line.clone();
            placed = true;
            true
        });
        if !placed {
            lines.push(new_line);
        }
    }
    fs::write(conf_path, lines.join("\n") + "\n")
}

fn dir_name(dir: &Path) -> String {
    dir.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| dir.display().to_string())
}

pub fn check_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.starts_with('.') || name.contains('/') {
        return Err(format!("invalid VM name: '{name}'"));
    }
    Ok(())
}

pub fn vm_path(paths: &Paths, name: &str) -> Result<PathBuf, String> {
    check_name(name)?;
    let dir = paths.vm_root.join(name);
    if !dir.join("disk.qcow2").is_file() {
        return Err(format!(
            "no VM named '{name}' in {} (try: crab list)",
            paths.vm_root.display()
        ));
    }
    Ok(dir)
}

pub fn vm_pid(dir: &Path) -> Option<u32> {
    let pid_file = dir.join("qemu.pid");
    let pid_str = fs::read_to_string(&pid_file).ok()?;
    let pid: u32 = pid_str.trim().parse().ok()?;
    let out = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if out.status.success() {
        let comm = String::from_utf8_lossy(&out.stdout);
        if comm.contains("qemu") {
            return Some(pid);
        }
    }
    None
}

pub fn require_stopped(dir: &Path) -> Result<(), String> {
    if let Some(pid) = vm_pid(dir) {
        let name = dir_name(dir);
        return Err(format!(
            "{name} is running (pid {pid}); shut it down first (crab stop {name})"
        ));
    }
    Ok(())
}

pub fn list_vm_dirs(paths: &Paths) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(entries) = fs::read_dir(&paths.vm_root) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    if !name.starts_with('.') && p.join("disk.qcow2").is_file() {
                        dirs.push(p);
                    }
                }
            }
        }
    }
    dirs.sort();
    dirs
}

pub fn command_exists(cmd: &str) -> bool {
    Command::new("which")
        .arg(cmd)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn need_qemu_img() -> Result<(), String> {
    if !command_exists("qemu-img") {
        return Err("qemu-img not found (brew install qemu)".to_string());
    }
    Ok(())
}

pub fn qemu_img_virt_size(disk: &Path) -> String {
    let out = Command::new("qemu-img")
        .args(["info", "-U"])
        .arg(disk)
        .stderr(Stdio::null())
        .output();
    if let Ok(out) = out {
        let text = String::from_utf8_lossy(&out.stdout);
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("virtual size: ") {
                // e.g. "20 GiB (21474836480 bytes)" -> "20G"
                let parts: Vec<&str> = rest.split_whitespace().collect();
                if parts.len() >= 2 {
                    let num = parts[0];
                    let unit = parts[1].trim_end_matches("iB").trim_end_matches('B');
                    return format!("{num}{unit}");
                }
            }
        }
    }
    "?".to_string()
}

pub fn qemu_img_snapshots(disk: &Path) -> Vec<String> {
    let out = Command::new("qemu-img")
        .args(["snapshot", "-l", "-U"])
        .arg(disk)
        .stderr(Stdio::null())
        .output();
    let mut tags = Vec::new();
    if let Ok(out) = out {
        let text = String::from_utf8_lossy(&out.stdout);
        for (i, line) in text.lines().enumerate() {
            if i >= 2 {
                let cols: Vec<&str> = line.split_whitespace().collect();
                if cols.len() >= 2 {
                    tags.push(cols[1].to_string());
                }
            }
        }
    }
    tags
}

pub fn inspect_vm(dir: &Path) -> VmEntry {
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let disk = dir.join("disk.qcow2");
    let arch = conf_get(dir, "arch");
    let firmware = conf_get(dir, "firmware");
    let mem_raw = conf_get(dir, "mem");
    let mem = if mem_raw.is_empty() {
        DEFAULT_MEM.to_string()
    } else {
        mem_raw
    };
    let cpus_raw = conf_get(dir, "cpus");
    let cpus = if cpus_raw.is_empty() {
        DEFAULT_CPUS.to_string()
    } else {
        cpus_raw
    };
    let ssh_port = conf_get(dir, "ssh_port");
    let display = conf_get(dir, "display");
    let hw = conf_get(dir, "hw");
    let gpu = conf_get(dir, "gpu");
    let fullscreen = conf_get(dir, "fullscreen");
    let ssh_user = conf_get(dir, "ssh_user");
    let forwards = conf_get(dir, "fwd");
    let disk_used = human_size(&disk);
    let disk_virt = qemu_img_virt_size(&disk);
    let snaps_count = qemu_img_snapshots(&disk).len();
    let running_pid = vm_pid(dir);
    let state = vm_state(dir).unwrap_or_else(|| "stopped".to_string());
    let last_used_secs = file_mtime(&disk);

    VmEntry {
        name,
        dir: dir.to_path_buf(),
        disk,
        arch,
        firmware,
        mem,
        cpus,
        ssh_port,
        display,
        hw,
        gpu,
        fullscreen,
        ssh_user,
        forwards,
        disk_used,
        disk_virt,
        snaps_count,
        running_pid,
        state,
        last_used_secs,
    }
}

pub fn list_vm_entries(paths: &Paths) -> Vec<VmEntry> {
    list_vm_dirs(paths)
        .iter()
        .map(|d| inspect_vm(d))
        .collect()
}

pub fn cmd_list(paths: &Paths) {
    let vms = list_vm_entries(paths);
    if vms.is_empty() {
        println!("No VMs in {}", paths.vm_root.display());
        return;
    }
    let w = vms.iter().map(|v| v.name.len()).max().unwrap_or(4).max(4);
    println!(
        "{:<w$}  {:<6} {:<5} {:<5} {:<4} {:<6} {:<14} {:<5} {:<8} {}",
        "NAME",
        "ARCH",
        "FW",
        "MEM",
        "CPUS",
        "SSH",
        "DISK",
        "SNAPS",
        "STATE",
        "LAST USED",
        w = w
    );
    for v in vms {
        let ssh_str = if !v.ssh_port.is_empty() && v.ssh_port != "0" {
            v.ssh_port.as_str()
        } else {
            "-"
        };
        let disk_col = format!("{} of {}", v.disk_used, v.disk_virt);
        println!(
            "{:<w$}  {:<6} {:<5} {:<5} {:<4} {:<6} {:<14} {:<5} {:<8} {}",
            v.name,
            v.arch,
            v.firmware,
            v.mem,
            v.cpus,
            ssh_str,
            disk_col,
            v.snaps_count,
            v.state,
            fmt_age(v.last_used_secs),
            w = w
        );
    }
}

pub fn cmd_images(paths: &Paths) {
    let images = list_image_entries(paths);
    if images.is_empty() {
        println!("No .iso/.img files in {}", paths.search_dir.display());
        return;
    }
    let w = images
        .iter()
        .map(|img| img.name.len())
        .max()
        .unwrap_or(5)
        .max(5);
    println!(
        "{:<w$}  {:<7} {:<14} {}",
        "IMAGE",
        "SIZE",
        "DOWNLOADED",
        "LAST BOOTED",
        w = w
    );
    let mut total_kb = 0u64;
    for img in images {
        let booted_str = match img.last_booted_secs {
            Some(t) => fmt_age(t),
            None => "never".to_string(),
        };
        println!(
            "{:<w$}  {:<7} {:<14} {}",
            img.name,
            img.size_human,
            fmt_age(img.downloaded_secs),
            booted_str,
            w = w
        );
        total_kb += img.size_kb;
    }
    println!();
    println!("{} in {}", fmt_kb(total_kb), paths.search_dir.display());
}

pub fn clean_leftover_scratch(paths: &Paths) -> (usize, u64) {
    let mut n = 0usize;
    let mut freed_kb = 0u64;
    if let Ok(entries) = fs::read_dir(&paths.scratch_root) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                if vm_pid(&p).is_some() {
                    continue;
                }
                let kb = disk_kb(&p);
                if fs::remove_dir_all(&p).is_ok() {
                    freed_kb += kb;
                    n += 1;
                }
            }
        }
    }
    (n, freed_kb)
}

pub fn cmd_clean(paths: &Paths, days: u64) {
    let cutoff = now_secs().saturating_sub(days * 86400);
    let (scratch_count, mut freed) = clean_leftover_scratch(paths);
    if scratch_count > 0 {
        println!("Removed {scratch_count} leftover throwaway VM(s).");
    }

    println!("Looking for images and VMs not used in {days} days. Answer y to delete, q to stop.");
    let mut n = 0usize;
    let mut quit = false;

    for f in list_image_paths(paths) {
        if image_last_used(paths, &f) >= cutoff {
            continue;
        }
        n += 1;
        let base = f
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let booted = image_last_boot(paths, &f)
            .map(fmt_age)
            .unwrap_or_else(|| "never".to_string());
        let prompt = format!(
            "  image {} ({}, downloaded {}, last booted {})? [y/N/q] ",
            base,
            human_size(&f),
            fmt_age(crate::config::file_birthtime(&f)),
            booted
        );
        let ans = prompt_line(&prompt).unwrap_or_else(|| "q".to_string());
        match ans.trim() {
            "y" | "Y" => {
                let kb = disk_kb(&f);
                if fs::remove_file(&f).is_ok() {
                    freed += kb;
                }
            }
            "q" | "Q" => {
                quit = true;
                break;
            }
            _ => {}
        }
    }

    if !quit {
        for d in list_vm_dirs(paths) {
            let disk = d.join("disk.qcow2");
            let mtime = file_mtime(&disk);
            if mtime >= cutoff {
                continue;
            }
            if vm_pid(&d).is_some() {
                continue;
            }
            n += 1;
            let base = d
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default();
            let prompt = format!(
                "  VM {} ({}, last used {})? [y/N/q] ",
                base,
                human_size(&d),
                fmt_age(mtime)
            );
            let ans = prompt_line(&prompt).unwrap_or_else(|| "q".to_string());
            match ans.trim() {
                "y" | "Y" => {
                    let kb = disk_kb(&d);
                    if fs::remove_dir_all(&d).is_ok() {
                        freed += kb;
                    }
                }
                "q" | "Q" => break,
                _ => {}
            }
        }
    }

    if n == 0 {
        println!("  Nothing that old.");
    }
    println!("Freed {}.", fmt_kb(freed));
}

pub fn delete_vm_dir(paths: &Paths, name: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    require_stopped(&dir)?;
    fs::remove_dir_all(&dir).map_err(|e| format!("failed to delete {}: {e}", dir.display()))
}

pub fn cmd_delete(paths: &Paths, name: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    require_stopped(&dir)?;
    println!(
        "This deletes {} ({}), including its disk and snapshots.",
        dir.display(),
        human_size(&dir)
    );
    let answer = prompt_line("Type the VM name to confirm: ").unwrap_or_default();
    if answer.trim() != name {
        return Err("names don't match; nothing deleted".to_string());
    }
    fs::remove_dir_all(&dir).map_err(|e| format!("failed to delete {}: {e}", dir.display()))?;
    println!("Deleted {name}.");
    Ok(())
}

pub fn create_snapshot(paths: &Paths, name: &str, tag_opt: Option<&str>) -> Result<String, String> {
    let dir = vm_path(paths, name)?;
    need_qemu_img()?;
    require_stopped(&dir)?;
    let tag = match tag_opt.filter(|s| !s.is_empty()) {
        Some(t) => t.to_string(),
        None => Local::now().format("%Y%m%d-%H%M%S").to_string(),
    };
    let disk = dir.join("disk.qcow2");
    let existing = qemu_img_snapshots(&disk);
    if existing.iter().any(|t| t == &tag) {
        return Err(format!("{name} already has a snapshot called '{tag}'"));
    }
    let status = Command::new("qemu-img")
        .args(["snapshot", "-c", &tag])
        .arg(&disk)
        .status()
        .map_err(|e| format!("failed to run qemu-img: {e}"))?;
    if !status.success() {
        return Err(format!("qemu-img snapshot -c '{tag}' failed"));
    }
    Ok(tag)
}

pub fn cmd_snapshot(paths: &Paths, name: &str, tag_opt: Option<&str>) -> Result<(), String> {
    let tag = create_snapshot(paths, name, tag_opt)?;
    println!("Created snapshot '{tag}' of {name}.");
    Ok(())
}

pub fn list_snapshots_raw(paths: &Paths, name: &str) -> Result<String, String> {
    let dir = vm_path(paths, name)?;
    need_qemu_img()?;
    let out = Command::new("qemu-img")
        .args(["snapshot", "-l", "-U"])
        .arg(dir.join("disk.qcow2"))
        .output()
        .map_err(|e| format!("failed to run qemu-img: {e}"))?;
    Ok(String::from_utf8_lossy(&out.stdout).trim_end().to_string())
}

pub fn cmd_snapshots(paths: &Paths, name: &str) -> Result<(), String> {
    let out = list_snapshots_raw(paths, name)?;
    if out.is_empty() {
        println!("{name} has no snapshots.");
    } else {
        println!("{out}");
    }
    Ok(())
}

pub fn restore_snapshot(paths: &Paths, name: &str, tag: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    need_qemu_img()?;
    require_stopped(&dir)?;
    let status = Command::new("qemu-img")
        .args(["snapshot", "-a", tag])
        .arg(dir.join("disk.qcow2"))
        .status()
        .map_err(|e| format!("failed to run qemu-img: {e}"))?;
    if !status.success() {
        return Err(format!("failed to restore {name} to '{tag}'"));
    }
    Ok(())
}

pub fn cmd_restore(paths: &Paths, name: &str, tag: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    need_qemu_img()?;
    require_stopped(&dir)?;
    if !ask_yes(&format!(
        "Roll {name} back to '{tag}'? Changes since then are lost."
    )) {
        return Err("nothing changed".to_string());
    }
    restore_snapshot(paths, name, tag)?;
    println!("Restored {name} to '{tag}'.");
    Ok(())
}

pub fn delete_snapshot(paths: &Paths, name: &str, tag: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    need_qemu_img()?;
    require_stopped(&dir)?;
    let status = Command::new("qemu-img")
        .args(["snapshot", "-d", tag])
        .arg(dir.join("disk.qcow2"))
        .status()
        .map_err(|e| format!("failed to run qemu-img: {e}"))?;
    if !status.success() {
        return Err(format!("failed to delete snapshot '{tag}' of {name}"));
    }
    Ok(())
}

pub fn cmd_delsnap(paths: &Paths, name: &str, tag: &str) -> Result<(), String> {
    delete_snapshot(paths, name, tag)?;
    println!("Deleted snapshot '{tag}' of {name}.");
    Ok(())
}

/// None if the VM isn't running, else QEMU's run state (falling back to
/// "running" for VMs booted without a control socket).
pub fn vm_state(dir: &Path) -> Option<String> {
    vm_pid(dir)?;
    Some(qmp::query_status(dir).unwrap_or_else(|| "running".to_string()))
}

pub fn wait_stopped(dir: &Path, timeout: Duration) -> bool {
    let start = Instant::now();
    while vm_pid(dir).is_some() {
        if start.elapsed() >= timeout {
            return false;
        }
        thread::sleep(Duration::from_millis(500));
    }
    true
}

/// Presses the VM's power button; the guest decides when to actually stop.
pub fn request_shutdown(dir: &Path) -> Result<(), String> {
    let name = dir_name(dir);
    if vm_pid(dir).is_none() {
        return Err(format!("{name} isn't running"));
    }
    if !qmp::socket_path(dir).exists() {
        return Err(format!(
            "{name} was booted without a control socket (by vmboot or an older crab), \
             so it can't be shut down cleanly; force it off with: crab kill {name}"
        ));
    }
    qmp::system_powerdown(dir)
}

/// Stops QEMU straight away: asks it to quit, then signals it if need be.
pub fn force_off(dir: &Path) -> Result<(), String> {
    let name = dir_name(dir);
    let Some(pid) = vm_pid(dir) else {
        return Err(format!("{name} isn't running"));
    };
    if qmp::quit(dir).is_err() {
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
    }
    if !wait_stopped(dir, Duration::from_secs(5)) {
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGKILL);
        }
        if !wait_stopped(dir, Duration::from_secs(2)) {
            return Err(format!("{name} (pid {pid}) won't stop"));
        }
    }
    let _ = fs::remove_file(dir.join("qemu.pid"));
    let _ = fs::remove_file(qmp::socket_path(dir));
    Ok(())
}

pub fn cmd_stop(paths: &Paths, name: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    request_shutdown(&dir)?;
    println!("Asked {name} to shut down. Waiting up to a minute...");
    if wait_stopped(&dir, Duration::from_secs(60)) {
        println!("{name} has shut down.");
    } else if ask_yes(&format!("{name} is still running. Force it off?")) {
        force_off(&dir)?;
        println!("Forced {name} off.");
    } else {
        println!("Left {name} running.");
    }
    Ok(())
}

pub fn cmd_kill(paths: &Paths, name: &str) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    force_off(&dir)?;
    println!("Forced {name} off.");
    Ok(())
}

pub const SETTABLE_KEYS: &[&str] = &[
    "mem", "cpus", "ssh_port", "ssh_user", "fwd", "firmware", "display", "gpu", "fullscreen", "hw",
];

/// Checks a value for `crab set`, returning it in the form vm.conf stores.
pub fn validate_setting(key: &str, value: &str, arch: &str) -> Result<String, String> {
    let one_of = |choices: &[&str]| {
        if choices.contains(&value) {
            Ok(value.to_string())
        } else {
            Err(format!("{key} wants {}", choices.join(" or ")))
        }
    };
    match key {
        "mem" if valid_mem(value) => Ok(value.to_string()),
        "mem" => Err("mem wants a size like 2G or 512M".to_string()),
        "cpus" if valid_cpus(value) => Ok(value.to_string()),
        "cpus" => Err("cpus wants a number of CPUs".to_string()),
        "ssh_port" if valid_port(value) => Ok(value.to_string()),
        "ssh_port" => Err("ssh_port wants a port number (0 turns it off)".to_string()),
        "ssh_user" if !value.is_empty() && !value.contains(['@', ' ', '\t']) => {
            Ok(value.to_string())
        }
        "ssh_user" => Err("ssh_user wants a user name".to_string()),
        "fwd" => Forward::parse_list(value).map(|f| Forward::list_to_conf(&f)),
        "firmware" if arch == "arm64" && value == "bios" => {
            Err("arm64 guests always boot with UEFI".to_string())
        }
        "firmware" => one_of(&["uefi", "bios"]),
        "display" => one_of(&["window", "terminal"]),
        "gpu" => one_of(&["virtio", "ramfb"]),
        "fullscreen" => one_of(&["on", "off"]),
        "hw" => one_of(&["standard", "virtio"]),
        _ => Err(format!(
            "can't set '{key}'; settable keys are: {}",
            SETTABLE_KEYS.join(" ")
        )),
    }
}

pub fn set_settings(paths: &Paths, name: &str, assignments: &[String]) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    let arch = conf_get(&dir, "arch");
    let mut updates = Vec::new();
    for a in assignments {
        let (key, value) = a
            .split_once('=')
            .ok_or_else(|| format!("'{a}' should look like key=value"))?;
        updates.push((key, validate_setting(key, value, &arch)?));
    }
    conf_set(&dir, &updates).map_err(|e| format!("failed to write vm.conf: {e}"))
}

pub fn cmd_set(paths: &Paths, name: &str, assignments: &[String]) -> Result<(), String> {
    let dir = vm_path(paths, name)?;
    if assignments.is_empty() {
        match fs::read_to_string(dir.join("vm.conf")) {
            Ok(c) => print!("{c}"),
            Err(_) => println!("{name} has no saved settings."),
        }
        return Ok(());
    }
    set_settings(paths, name, assignments)?;
    if vm_pid(&dir).is_some() {
        println!("Saved. {name} is running, so the change takes effect on its next boot.");
    } else {
        println!("Saved.");
    }
    Ok(())
}

pub fn clone_vm(paths: &Paths, src: &str, dst: &str) -> Result<PathBuf, String> {
    let src_dir = vm_path(paths, src)?;
    require_stopped(&src_dir)?;
    check_name(dst)?;
    let dst_dir = paths.vm_root.join(dst);
    if dst_dir.exists() {
        return Err(format!("there's already a VM called '{dst}'"));
    }
    fs::create_dir(&dst_dir).map_err(|e| format!("failed to create {}: {e}", dst_dir.display()))?;
    let copy_all = || -> io::Result<()> {
        // fs::copy clones files on APFS, so this is quick and shares disk blocks.
        for f in ["disk.qcow2", "efivars.fd", "vm.conf", "arch"] {
            let from = src_dir.join(f);
            if from.is_file() {
                fs::copy(&from, dst_dir.join(f))?;
            }
        }
        // Give the clone its own SSH port so both can run at once.
        let port = conf_get(&dst_dir, "ssh_port");
        if !port.is_empty() && port != "0" {
            let new_port = pick_free_port(paths, &dst_dir).map_or("0".to_string(), |p| p.to_string());
            conf_set(&dst_dir, &[("ssh_port", new_port)])?;
        }
        Ok(())
    };
    if let Err(e) = copy_all() {
        let _ = fs::remove_dir_all(&dst_dir);
        return Err(format!("failed to clone {src}: {e}"));
    }
    Ok(dst_dir)
}

pub fn cmd_clone(paths: &Paths, src: &str, dst: &str) -> Result<(), String> {
    let dir = clone_vm(paths, src, dst)?;
    println!("Cloned {src} to {dst}.");
    let port = conf_get(&dir, "ssh_port");
    if !port.is_empty() && port != "0" {
        println!("{dst} forwards SSH from port {port}.");
    }
    if !Forward::parse_list(&conf_get(&dir, "fwd")).unwrap_or_default().is_empty() {
        println!("Both VMs forward the same ports, so change them before running both: crab set {dst} fwd=...");
    }
    Ok(())
}

pub fn rename_vm(paths: &Paths, old: &str, new: &str) -> Result<(), String> {
    let dir = vm_path(paths, old)?;
    require_stopped(&dir)?;
    check_name(new)?;
    let dest = paths.vm_root.join(new);
    if dest.exists() {
        return Err(format!("there's already a VM called '{new}'"));
    }
    fs::rename(&dir, &dest).map_err(|e| format!("failed to rename {old}: {e}"))
}

pub fn cmd_rename(paths: &Paths, old: &str, new: &str) -> Result<(), String> {
    rename_vm(paths, old, new)?;
    println!("Renamed {old} to {new}.");
    Ok(())
}

pub fn resize_disk(paths: &Paths, name: &str, size: &str) -> Result<String, String> {
    let dir = vm_path(paths, name)?;
    need_qemu_img()?;
    require_stopped(&dir)?;
    if !valid_disk_size(size, true) {
        return Err("SIZE should look like 40G, or +10G to grow by that much".to_string());
    }
    let disk = dir.join("disk.qcow2");
    let status = Command::new("qemu-img")
        .args(["resize", "-q"])
        .arg(&disk)
        .arg(size)
        .status()
        .map_err(|e| format!("failed to run qemu-img: {e}"))?;
    if !status.success() {
        return Err(format!("couldn't resize {name}'s disk (disks can only grow)"));
    }
    Ok(qemu_img_virt_size(&disk))
}

pub fn cmd_resize(paths: &Paths, name: &str, size: &str) -> Result<(), String> {
    let new_size = resize_disk(paths, name, size)?;
    println!("{name}'s disk is now {new_size}. Grow the partition and filesystem inside the guest to use the space.");
    Ok(())
}

/// The ssh command line for `[USER@]NAME`, using the VM's forwarded port.
pub fn ssh_command(paths: &Paths, target: &str) -> Result<Vec<String>, String> {
    let (user, name) = match target.split_once('@') {
        Some((u, n)) => (Some(u.to_string()), n),
        None => (None, target),
    };
    let dir = vm_path(paths, name)?;
    let port = conf_get(&dir, "ssh_port");
    if port.is_empty() || port == "0" {
        return Err(format!(
            "{name} has no SSH port; give it one with: crab set {name} ssh_port=2222 (then reboot it)"
        ));
    }
    let user = user.or_else(|| Some(conf_get(&dir, "ssh_user")).filter(|u| !u.is_empty()));
    let host = match user {
        Some(u) => format!("{u}@localhost"),
        None => "localhost".to_string(),
    };
    // Key the guest's host key by VM name, not by port, since ports get reused.
    Ok(vec![
        "ssh".to_string(),
        "-p".to_string(),
        port,
        "-o".to_string(),
        format!("HostKeyAlias=crab-{name}"),
        host,
    ])
}

pub fn cmd_ssh(paths: &Paths, target: &str, command: &[String]) -> Result<(), String> {
    let argv = ssh_command(paths, target)?;
    let name = target.rsplit('@').next().unwrap_or(target);
    if vm_pid(&paths.vm_root.join(name)).is_none() {
        return Err(format!("{name} isn't running (boot it with: crab boot {name})"));
    }
    let err = Command::new(&argv[0]).args(&argv[1..]).args(command).exec();
    Err(format!("failed to run ssh: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{test_dir, test_paths};

    fn make_vm(root: &Path, name: &str, conf: &str) -> PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("disk.qcow2"), b"fake disk").unwrap();
        if !conf.is_empty() {
            fs::write(dir.join("vm.conf"), conf).unwrap();
        }
        dir
    }

    #[test]
    fn conf_get_takes_last_value() {
        let root = test_dir("conf-get");
        let dir = make_vm(&root, "a", "mem=1G\ncpus=2\nmem=4G\n");
        assert_eq!(conf_get(&dir, "mem"), "4G");
        assert_eq!(conf_get(&dir, "gpu"), "");
    }

    #[test]
    fn legacy_arch_file() {
        let root = test_dir("conf-legacy");
        let dir = make_vm(&root, "old", "");
        fs::write(dir.join("arch"), "amd64\n").unwrap();
        assert_eq!(conf_get(&dir, "arch"), "amd64");
        assert_eq!(conf_get(&dir, "firmware"), "bios");

        // Writing vm.conf for the first time keeps what the arch file said.
        conf_set(&dir, &[("mem", "3G".into())]).unwrap();
        assert_eq!(conf_get(&dir, "arch"), "amd64");
        assert_eq!(conf_get(&dir, "firmware"), "bios");
        assert_eq!(conf_get(&dir, "mem"), "3G");
    }

    #[test]
    fn conf_set_replaces_and_keeps_other_keys() {
        let root = test_dir("conf-set");
        let dir = make_vm(&root, "a", "arch=arm64\nmem=1G\nssh_user=me\nmem=2G\n");
        conf_set(&dir, &[("mem", "8G".into()), ("gpu", "ramfb".into())]).unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("vm.conf")).unwrap(),
            "arch=arm64\nmem=8G\nssh_user=me\ngpu=ramfb\n"
        );
    }

    #[test]
    fn settings_validation() {
        assert_eq!(validate_setting("fwd", "8080:80, udp:53:53", "amd64").unwrap(), "8080:80,udp:53:53");
        assert_eq!(validate_setting("fwd", "", "amd64").unwrap(), "0");
        assert!(validate_setting("firmware", "bios", "arm64").is_err());
        assert!(validate_setting("firmware", "bios", "amd64").is_ok());
        assert!(validate_setting("display", "vnc", "amd64").is_err());
        assert!(validate_setting("ssh_user", "a@b", "amd64").is_err());
        assert!(validate_setting("arch", "amd64", "amd64").is_err());
        assert!(validate_setting("mem", "lots", "amd64").is_err());
    }

    #[test]
    fn set_rejects_unknown_keys_without_writing() {
        let root = test_dir("set");
        let paths = test_paths(&root);
        let dir = make_vm(&root, "a", "arch=amd64\n");
        assert!(set_settings(&paths, "a", &["mem=4G".into(), "colour=red".into()]).is_err());
        assert_eq!(conf_get(&dir, "mem"), "");
        set_settings(&paths, "a", &["mem=4G".into(), "fwd=8080:80".into()]).unwrap();
        assert_eq!(conf_get(&dir, "mem"), "4G");
        assert_eq!(conf_get(&dir, "fwd"), "8080:80");
    }

    #[test]
    fn clone_gets_its_own_port() {
        let root = test_dir("clone");
        let paths = test_paths(&root);
        make_vm(&root, "src", "arch=arm64\nssh_port=2222\n");
        let dst = clone_vm(&paths, "src", "dst").unwrap();
        assert_eq!(fs::read(dst.join("disk.qcow2")).unwrap(), b"fake disk");
        assert_eq!(conf_get(&dst, "arch"), "arm64");
        let port = conf_get(&dst, "ssh_port");
        assert!(!port.is_empty() && port != "2222", "got {port}");
        assert!(clone_vm(&paths, "src", "dst").is_err(), "won't overwrite");
        assert!(clone_vm(&paths, "src", ".hidden").is_err());
    }

    #[test]
    fn rename() {
        let root = test_dir("rename");
        let paths = test_paths(&root);
        make_vm(&root, "a", "arch=arm64\n");
        make_vm(&root, "b", "arch=arm64\n");
        assert!(rename_vm(&paths, "a", "b").is_err());
        rename_vm(&paths, "a", "c").unwrap();
        assert!(root.join("c/disk.qcow2").is_file() && !root.join("a").exists());
    }

    #[test]
    fn ssh_targets() {
        let root = test_dir("ssh");
        let paths = test_paths(&root);
        make_vm(&root, "bsd", "arch=amd64\nssh_port=2201\nssh_user=root\n");
        make_vm(&root, "nossh", "arch=amd64\nssh_port=0\n");
        assert_eq!(
            ssh_command(&paths, "bsd").unwrap().join(" "),
            "ssh -p 2201 -o HostKeyAlias=crab-bsd root@localhost"
        );
        assert!(ssh_command(&paths, "me@bsd").unwrap().ends_with(&["me@localhost".to_string()]));
        assert!(ssh_command(&paths, "nossh").unwrap_err().contains("no SSH port"));
        assert!(ssh_command(&paths, "missing").is_err());
    }

    #[test]
    fn stopped_vms() {
        let root = test_dir("stopped");
        let dir = make_vm(&root, "a", "arch=amd64\n");
        // A stale pid file pointing at a process that isn't QEMU.
        fs::write(dir.join("qemu.pid"), format!("{}\n", std::process::id())).unwrap();
        assert_eq!(vm_state(&dir), None);
        assert!(request_shutdown(&dir).unwrap_err().contains("isn't running"));
        assert!(force_off(&dir).is_err());
    }
}
