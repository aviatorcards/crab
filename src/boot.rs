use crate::config::{
    DEFAULT_CPUS, DEFAULT_DISK_SIZE, DEFAULT_MEM, Forward, Paths, abs_path, ask_yes, disk_kb,
    file_brief, fmt_age, host_uname_m, human_size, install_qemu_hint, list_image_entries,
    log_image_boot, prompt_line,
};
use crate::qmp;
use crate::vm::{
    check_name, command_exists, conf_get, conf_set, find_executable, list_vm_dirs, list_vm_entries,
    need_qemu_img, qemu_img_bin, require_stopped, vm_path,
};
use std::fs;
use std::io::{self, Read};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Debug, Default)]
pub struct BootOptions {
    pub search_dir: Option<PathBuf>,
    pub arch: Option<String>,
    pub known_arch: Option<String>,
    pub download_only: bool,
    pub keep: bool,
    pub live: bool,
    pub mem: Option<String>,
    pub cpus: Option<String>,
    pub disk_size: Option<String>,
    pub ssh_port: Option<String>,
    /// Some(empty) clears the saved forwards (-P 0).
    pub forwards: Option<Vec<Forward>>,
    pub firmware: Option<String>,
    pub display: Option<String>,
    pub fullscreen: Option<String>,
    pub gpu: Option<String>,
    pub dry_run: bool,
}

pub fn arch_from_name(name: &str) -> Option<&'static str> {
    let lower = Path::new(name)
        .file_name()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_else(|| name.to_lowercase());
    if lower.contains("aarch64") || lower.contains("arm64") || lower.contains("evbarm") {
        Some("arm64")
    } else if lower.contains("amd64") || lower.contains("x86_64") || lower.contains("x64") {
        Some("amd64")
    } else if lower.contains("i386") || lower.contains("i686") {
        Some("i386")
    } else {
        None
    }
}

fn scan_efi_loaders(path: &Path) -> (bool, bool, bool) {
    // Searches for BOOTAA64 ?\.?EFI, BOOTX64 ?\.?EFI, BOOTIA32 ?\.?EFI
    let mut aa64 = false;
    let mut x64 = false;
    let mut ia32 = false;

    let Ok(mut f) = fs::File::open(path) else {
        return (false, false, false);
    };

    const CHUNK: usize = 1024 * 1024;
    const OVERLAP: usize = 32;
    let mut buf = vec![0u8; CHUNK + OVERLAP];
    let mut carry = 0usize;

    loop {
        let n = match f.read(&mut buf[carry..carry + CHUNK]) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let slice = &buf[..carry + n];
        if !aa64 && matches_efi(slice, b"BOOTAA64") {
            aa64 = true;
        }
        if !x64 && matches_efi(slice, b"BOOTX64") {
            x64 = true;
        }
        if !ia32 && matches_efi(slice, b"BOOTIA32") {
            ia32 = true;
        }
        if aa64 && x64 && ia32 {
            break;
        }
        if carry + n > OVERLAP {
            let start = carry + n - OVERLAP;
            buf.copy_within(start..carry + n, 0);
            carry = OVERLAP;
        } else {
            carry += n;
        }
    }

    (aa64, x64, ia32)
}

fn matches_efi(haystack: &[u8], prefix: &[u8]) -> bool {
    let plen = prefix.len();
    if haystack.len() < plen + 3 {
        return false;
    }
    let mut i = 0;
    while i + plen + 3 <= haystack.len() {
        if &haystack[i..i + plen] == prefix {
            let rest = &haystack[i + plen..];
            // Optional ' ', optional '.', then "EFI"
            let mut j = 0;
            if j < rest.len() && rest[j] == b' ' {
                j += 1;
            }
            if j < rest.len() && rest[j] == b'.' {
                j += 1;
            }
            if j + 3 <= rest.len() && &rest[j..j + 3] == b"EFI" {
                return true;
            }
        }
        i += 1;
    }
    false
}

pub fn detect_arch(path: &Path) -> Vec<&'static str> {
    if let Some(a) = arch_from_name(&path.to_string_lossy()) {
        return vec![a];
    }

    let label = file_brief(path).to_lowercase();
    if label.contains("aarch64") || label.contains("arm64") || label.contains("evbarm") {
        return vec!["arm64"];
    }
    if label.contains("amd64") || label.contains("x86_64") {
        return vec!["amd64"];
    }
    if label.contains("i386") {
        return vec!["i386"];
    }

    let (aa64, x64, ia32) = scan_efi_loaders(path);
    let mut found = Vec::new();
    if aa64 {
        found.push("arm64");
    }
    if x64 {
        found.push("amd64");
    }
    if ia32 {
        found.push("i386");
    }
    found
}

pub fn has_efi_loader(path: &Path) -> bool {
    let (aa64, x64, ia32) = scan_efi_loaders(path);
    aa64 || x64 || ia32
}

pub fn is_cd_image(path: &Path) -> bool {
    if path.is_file() {
        file_brief(path).contains("ISO 9660")
    } else {
        path.extension()
            .and_then(|e| e.to_str())
            .map(|e| e.eq_ignore_ascii_case("iso"))
            .unwrap_or(false)
    }
}

pub fn is_bsd_image(path: &Path) -> bool {
    let base = path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let fb = if path.is_file() {
        file_brief(path)
    } else {
        String::new()
    };
    let text = format!("{base} {fb}").to_lowercase();
    text.contains("openbsd") || text.contains("freebsd") || text.contains("netbsd")
}

pub enum MenuPick {
    Image(PathBuf),
    Vm(PathBuf),
}

pub fn select_numbered(labels: &[String], prompt_header: Option<&str>) -> Option<usize> {
    if let Some(h) = prompt_header {
        println!("{h}");
    }
    for (i, label) in labels.iter().enumerate() {
        println!("{}) {}", i + 1, label);
    }
    loop {
        let reply = prompt_line("> ")?;
        if let Ok(n) = reply.trim().parse::<usize>() {
            if n >= 1 && n <= labels.len() {
                return Some(n - 1);
            }
        }
        println!("Pick a number from 1 to {}.", labels.len());
    }
}

pub fn pick_from_menu(paths: &Paths) -> Result<MenuPick, String> {
    let mut choices = Vec::new();
    let mut labels = Vec::new();

    for img in list_image_entries(paths) {
        let mut extra = img.size_human.clone();
        if !img.file_info.is_empty() {
            extra.push_str(&format!(", {}", img.file_info));
        }
        if let Some(b) = img.last_booted_secs {
            extra.push_str(&format!(", booted {}", fmt_age(b)));
        }
        choices.push(MenuPick::Image(img.path));
        labels.push(format!("{}  ({extra})", img.name));
    }

    for v in list_vm_entries(paths) {
        let arch = if v.arch.is_empty() { "?" } else { &v.arch };
        let mut details = format!("{arch}, {}, {} CPUs", v.mem, v.cpus);
        if !v.ssh_port.is_empty() && v.ssh_port != "0" {
            details.push_str(&format!(", ssh :{}", v.ssh_port));
        }
        if v.running_pid.is_some() {
            details.push_str(", running");
        }
        choices.push(MenuPick::Vm(v.dir));
        labels.push(format!("[VM] {}  ({details})", v.name));
    }

    if choices.is_empty() {
        return Err(format!(
            "no .iso/.img files in {} and no VMs in {}",
            paths.search_dir.display(),
            paths.vm_root.display()
        ));
    }

    let idx = select_numbered(&labels, Some("Choose something to boot:"))
        .ok_or_else(|| "nothing chosen".to_string())?;
    Ok(choices.swap_remove(idx))
}

fn create_scratch_dir(scratch_root: &Path) -> io::Result<PathBuf> {
    fs::create_dir_all(scratch_root)?;
    let pid = std::process::id();
    for i in 0..1000u32 {
        let candidate = scratch_root.join(format!("crab-{pid}-{i}"));
        if !candidate.exists() {
            fs::create_dir(&candidate)?;
            return Ok(candidate);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate scratch dir",
    ))
}

pub fn port_in_use(port_str: &str) -> bool {
    if let Ok(port) = port_str.parse::<u16>() {
        if port > 0 {
            return TcpListener::bind(("127.0.0.1", port)).is_err();
        }
    }
    false
}

fn qemu_share_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        if let Ok(out) = Command::new("brew").args(["--prefix", "qemu"]).output() {
            if out.status.success() {
                let prefix = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !prefix.is_empty() {
                    return PathBuf::from(prefix).join("share/qemu");
                }
            }
        }
        let opt = PathBuf::from("/opt/homebrew/share/qemu");
        if opt.is_dir() {
            return opt;
        }
        return PathBuf::from("/usr/local/share/qemu");
    }
    if cfg!(target_os = "windows") {
        for d in [r"C:\Program Files\qemu\share", r"C:\Program Files (x86)\qemu\share"] {
            let p = PathBuf::from(d);
            if p.is_dir() {
                return p;
            }
        }
    }
    for bin_name in ["qemu-system-x86_64", "qemu-system-aarch64"] {
        if let Some(bin_path) = find_executable(bin_name) {
            if let Some(bin_dir) = bin_path.parent() {
                let share = bin_dir.join("share");
                if share.is_dir() {
                    return share;
                }
                if let Some(prefix) = bin_dir.parent() {
                    let pshare = prefix.join("share/qemu");
                    if pshare.is_dir() {
                        return pshare;
                    }
                }
            }
        }
    }
    PathBuf::from("/usr/share/qemu")
}

/// QEMU's arm64 `virt` machine needs both pflash images padded to exactly 64 MiB.
#[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
const AARCH64_PFLASH_SIZE: u64 = 64 * 1024 * 1024;

/// Distro OVMF / AAVMF packages, as (code, vars template) pairs that belong
/// together. Each code image must be paired with the vars file built for it:
/// 4M code with 4M vars, and padded arm64 images only.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn distro_uefi_pairs(arch: &str) -> &'static [(&'static str, &'static str)] {
    match arch {
        "arm64" => &[
            // Debian / Ubuntu (qemu-efi-aarch64)
            ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"),
            // Fedora (edk2-aarch64)
            (
                "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw",
                "/usr/share/edk2/aarch64/vars-template-pflash.raw",
            ),
        ],
        "amd64" => &[
            // Debian / Ubuntu (ovmf)
            ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
            ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
            // Arch (edk2-ovmf)
            ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd"),
            // Fedora (edk2-ovmf)
            ("/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
            ("/usr/share/edk2-ovmf/x64/OVMF_CODE.fd", "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"),
        ],
        _ => &[
            // Debian / Ubuntu (ovmf-ia32)
            ("/usr/share/OVMF/OVMF32_CODE_4M.fd", "/usr/share/OVMF/OVMF32_VARS_4M.fd"),
            // Arch (edk2-ovmf)
            ("/usr/share/edk2/ia32/OVMF_CODE.4m.fd", "/usr/share/edk2/ia32/OVMF_VARS.4m.fd"),
        ],
    }
}

/// The first pair whose files both exist and, for arm64, are padded pflash images.
#[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
fn first_usable_uefi_pair<'a>(
    arch: &str,
    pairs: impl IntoIterator<Item = (&'a Path, &'a Path)>,
) -> Option<(PathBuf, PathBuf)> {
    let size = |p: &Path| fs::metadata(p).ok().filter(|m| m.is_file()).map(|m| m.len());
    pairs.into_iter().find_map(|(code, vars)| {
        let (cs, vs) = (size(code)?, size(vars)?);
        if arch == "arm64" && (cs != AARCH64_PFLASH_SIZE || vs != AARCH64_PFLASH_SIZE) {
            return None;
        }
        Some((code.to_path_buf(), vars.to_path_buf()))
    })
}

/// The (code, vars template) file names QEMU ships in its share directory.
fn qemu_uefi_names(arch: &str) -> (&'static str, &'static str) {
    match arch {
        "arm64" => ("edk2-aarch64-code.fd", "edk2-arm-vars.fd"),
        "amd64" => ("edk2-x86_64-code.fd", "edk2-i386-vars.fd"),
        _ => ("edk2-i386-code.fd", "edk2-i386-vars.fd"),
    }
}

/// Resolves UEFI firmware (`code`, `vars_template`) in `qemu_share` first (Homebrew, Windows
/// installs, QEMU built from source), falling back on Linux to distro OVMF / AAVMF packages.
/// If nothing usable is found, returns the `qemu_share` paths so the error names them.
fn resolve_uefi_pair(arch: &str, qemu_share: &Path) -> (PathBuf, PathBuf) {
    let (code_name, vars_name) = qemu_uefi_names(arch);
    let primary = (qemu_share.join(code_name), qemu_share.join(vars_name));
    // QEMU's bundled edk2 images are already the right size for their machines.
    if primary.0.is_file() && primary.1.is_file() {
        return primary;
    }

    #[cfg(target_os = "linux")]
    {
        let pairs = distro_uefi_pairs(arch)
            .iter()
            .map(|(c, v)| (Path::new(*c), Path::new(*v)));
        if let Some(found) = first_usable_uefi_pair(arch, pairs) {
            return found;
        }
    }

    primary
}

fn current_host_spec() -> String {
    let arch = host_uname_m();
    if cfg!(target_os = "macos") {
        format!("macos-{arch}")
    } else if cfg!(target_os = "linux") {
        let kvm_ok = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/kvm")
            .is_ok();
        if kvm_ok {
            format!("linux-{arch}")
        } else {
            format!("linux-tcg-{arch}")
        }
    } else if cfg!(target_os = "windows") {
        format!("windows-{arch}")
    } else {
        format!("other-{arch}")
    }
}

fn parse_host_spec(host: &str) -> (&str, &str, &'static str) {
    if let Some(arch) = host.strip_prefix("macos-") {
        ("macos", arch, "hvf")
    } else if let Some(arch) = host.strip_prefix("linux-tcg-") {
        ("linux", arch, "tcg")
    } else if let Some(arch) = host.strip_prefix("linux-") {
        ("linux", arch, "kvm")
    } else if let Some(arch) = host.strip_prefix("windows-") {
        ("windows", arch, "whpx")
    } else if let Some(arch) = host.strip_prefix("other-") {
        ("other", arch, "tcg")
    } else {
        ("macos", host, "hvf")
    }
}

fn host_window_display_for(host_os: &str, fullscreen: &str) -> String {
    match host_os {
        "macos" => format!("cocoa,zoom-to-fit=on,full-screen={fullscreen}"),
        "windows" => {
            if fullscreen == "on" {
                "sdl,gl=off,window-close=on".to_string()
            } else {
                "sdl,gl=off".to_string()
            }
        }
        _ => format!("gtk,zoom-to-fit=on,full-screen={fullscreen}"),
    }
}

fn base_name(path: &Path) -> String {
    path.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// Names a new VM after its image, adding the arch unless it's already in there.
pub fn default_vm_name(image: &Path, arch: &str) -> String {
    let mut name = image
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "vm".to_string());
    if arch_from_name(&name) != Some(arch) {
        name.push('-');
        name.push_str(arch);
    }
    name
}

/// Picks a host port for a new VM's SSH forward that no saved VM uses and
/// nothing on this Mac is listening on.
pub fn pick_free_port(paths: &Paths, own_dir: &Path) -> Option<u16> {
    let mut taken = Vec::new();
    for dir in list_vm_dirs(paths) {
        if dir == own_dir {
            continue;
        }
        if let Ok(p) = conf_get(&dir, "ssh_port").parse::<u16>() {
            taken.push(p);
        }
        if let Ok(fwds) = Forward::parse_list(&conf_get(&dir, "fwd")) {
            taken.extend(fwds.iter().map(|f| f.host));
        }
    }
    (2222..2300).find(|p| !taken.contains(p) && !port_in_use(&p.to_string()))
}

fn after_throwaway(
    paths: &Paths,
    scratch: &Path,
    image: Option<&Path>,
    default_name: &str,
    live: bool,
) -> Result<(), String> {
    let disk = scratch.join("disk.qcow2");
    if !live {
        let used_kb = disk_kb(&disk);
        if used_kb < 1024 {
            println!("Nothing was written to the disk, so there's nothing to keep.");
        } else if ask_yes(&format!("Keep this VM ({})?", human_size(&disk))) {
            loop {
                let Some(input) = prompt_line(&format!("Name [{default_name}]: ")) else {
                    let _ = fs::remove_dir_all(scratch);
                    return Err("no name given; discarding the VM".to_string());
                };
                let name = if input.trim().is_empty() {
                    default_name.to_string()
                } else {
                    input.trim().to_string()
                };
                if name.is_empty() || name.starts_with('.') || name.contains('/') {
                    println!("Names can't start with a dot or contain '/'.");
                    continue;
                }
                let dest = paths.vm_root.join(&name);
                if dest.exists() {
                    println!("There's already a VM called '{name}'.");
                    continue;
                }
                let _ = fs::remove_file(scratch.join("qemu.pid"));
                let _ = fs::remove_file(qmp::socket_path(scratch));
                fs::rename(scratch, &dest)
                    .map_err(|e| format!("failed to move scratch VM to {}: {e}", dest.display()))?;
                println!("Kept as '{name}'. Boot it again with: crab boot {name}");
                return Ok(());
            }
        }
    }

    let _ = fs::remove_dir_all(scratch);
    println!("Throwaway VM deleted.");
    if let Some(img) = image {
        if img.is_file() {
            let base = base_name(img);
            if ask_yes(&format!(
                "Delete the image {base} ({}) too?",
                human_size(img)
            )) {
                let _ = fs::remove_file(img);
                println!("Deleted {base}.");
            }
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BootMode {
    Vm,
    Named,
    Throwaway,
    Live,
}

/// What we know about the image being booted, worked out once up front.
#[derive(Clone, Debug)]
pub struct ImageInfo {
    pub path: PathBuf,
    pub is_cd: bool,
    pub is_bsd: bool,
}

impl ImageInfo {
    pub fn probe(path: &Path) -> Self {
        Self {
            path: path.to_path_buf(),
            is_cd: is_cd_image(path),
            is_bsd: is_bsd_image(path),
        }
    }
}

/// Everything needed to boot, once the CLI or GUI has decided which VM
/// directory to use and (for images) which architecture it is.
#[derive(Clone, Debug)]
pub struct BootRequest {
    pub mode: BootMode,
    pub vm_dir: PathBuf,
    pub image: Option<ImageInfo>,
    /// Empty means "use the VM's saved architecture".
    pub arch: String,
    pub default_name: String,
    pub new_vm: bool,
}

impl BootRequest {
    /// The name QEMU shows in its window title.
    fn display_name(&self) -> String {
        match self.mode {
            BootMode::Vm | BootMode::Named => self
                .vm_dir
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| self.default_name.clone()),
            BootMode::Throwaway | BootMode::Live => self.default_name.clone(),
        }
    }
}

/// A VM's settings after combining flags, its vm.conf and the defaults.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VmSettings {
    pub arch: String,
    pub firmware: String,
    pub mem: String,
    pub cpus: String,
    pub display: String,
    /// Empty when SSH isn't forwarded.
    pub ssh_port: String,
    pub forwards: Vec<Forward>,
    pub hw: String,
    pub gpu: String,
    pub fullscreen: String,
}

impl VmSettings {
    fn conf_entries(&self) -> Vec<(&'static str, String)> {
        let ssh_port = if self.ssh_port.is_empty() {
            "0".to_string()
        } else {
            self.ssh_port.clone()
        };
        vec![
            ("arch", self.arch.clone()),
            ("firmware", self.firmware.clone()),
            ("mem", self.mem.clone()),
            ("cpus", self.cpus.clone()),
            ("display", self.display.clone()),
            ("ssh_port", ssh_port),
            ("fwd", Forward::list_to_conf(&self.forwards)),
            ("hw", self.hw.clone()),
            ("gpu", self.gpu.clone()),
            ("fullscreen", self.fullscreen.clone()),
        ]
    }
}

/// A flag if one was given, else the saved value if there is one.
fn flag_or_saved(flag: &Option<String>, saved: String) -> Option<String> {
    flag.clone()
        .filter(|s| !s.is_empty())
        .or((!saved.is_empty()).then_some(saved))
}

/// Settings come from flags first, then the VM's saved values, then defaults.
/// `has_efi` is only called when the firmware has to be guessed, since it
/// reads the whole image. Returns the settings plus notes for the user.
fn resolve_settings(
    opts: &BootOptions,
    conf: &dyn Fn(&str) -> String,
    arch: &str,
    image: Option<&ImageInfo>,
    new_vm: bool,
    has_efi: &dyn Fn() -> bool,
    pick_port: &dyn Fn() -> Option<u16>,
) -> Result<(VmSettings, Vec<String>), String> {
    let mut notes = Vec::new();

    let mem = flag_or_saved(&opts.mem, conf("mem")).unwrap_or_else(|| DEFAULT_MEM.to_string());
    let cpus =
        flag_or_saved(&opts.cpus, conf("cpus")).unwrap_or_else(|| DEFAULT_CPUS.to_string());

    // New VMs get a free SSH port unless one was asked for; -p 0 turns it off.
    let mut ssh_port = match opts.ssh_port.clone().filter(|s| !s.is_empty()) {
        Some(p) => p,
        None if new_vm => pick_port().map(|p| p.to_string()).unwrap_or_default(),
        None => conf("ssh_port"),
    };
    if ssh_port == "0" {
        ssh_port.clear();
    }

    let forwards = match &opts.forwards {
        Some(f) => f.clone(),
        None => Forward::parse_list(&conf("fwd")).map_err(|e| format!("vm.conf: {e}"))?,
    };

    let display = flag_or_saved(&opts.display, conf("display")).unwrap_or_else(|| {
        let terminal = match image {
            Some(img) => img.is_bsd,
            // VMs from older versions of vmboot: arm64 used the serial console.
            None => arch == "arm64",
        };
        if terminal { "terminal" } else { "window" }.to_string()
    });

    let firmware = match flag_or_saved(&opts.firmware, conf("firmware")) {
        Some(f) => f,
        None => match image {
            Some(img) if arch != "arm64" && !has_efi() => {
                notes.push(format!(
                    "No UEFI boot loader in {}; using legacy BIOS.",
                    base_name(&img.path)
                ));
                "bios".to_string()
            }
            _ => "uefi".to_string(),
        },
    };
    if arch == "arm64" && firmware == "bios" {
        return Err("arm64 guests always boot with UEFI".to_string());
    }

    let gpu = flag_or_saved(&opts.gpu, conf("gpu")).unwrap_or_else(|| "virtio".to_string());
    let fullscreen =
        flag_or_saved(&opts.fullscreen, conf("fullscreen")).unwrap_or_else(|| "off".to_string());

    // New x86 VMs get an AHCI disk and an e1000 network card, which every x86
    // OS has drivers for. arm64 OSes all speak virtio, and so did VMs from
    // older versions of vmboot.
    let hw = flag_or_saved(&None, conf("hw")).unwrap_or_else(|| {
        if new_vm && arch != "arm64" { "standard" } else { "virtio" }.to_string()
    });

    let settings = VmSettings {
        arch: arch.to_string(),
        firmware,
        mem,
        cpus,
        display,
        ssh_port,
        forwards,
        hw,
        gpu,
        fullscreen,
    };
    Ok((settings, notes))
}

/// The QEMU binary and arguments for a boot, with no side effects.
#[derive(Clone, Debug)]
pub struct QemuCommand {
    pub qemu: String,
    pub args: Vec<String>,
    pub fw_code: Option<PathBuf>,
    pub fw_vars_template: Option<PathBuf>,
    pub notes: Vec<String>,
}

/// The `-accel` and `-cpu` arguments for a guest (`"arm64"` or `"x86"`) on
/// this host, plus a note if it will run under emulation.
fn accel_args(guest: &str, host_arch: &str, native_accel: &str) -> (Vec<String>, Option<String>) {
    let to_args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let same_arch = match guest {
        "arm64" => host_arch == "arm64",
        _ => host_arch == "x86_64",
    };
    if !same_arch {
        let note = match guest {
            "arm64" => "Note: arm64 guest on an x86_64 host runs under emulation (slow).",
            _ => "Note: x86 guest on an arm64 host runs under emulation (works, but slow).",
        };
        return (to_args(&["-accel", "tcg", "-cpu", "max"]), Some(note.to_string()));
    }
    match native_accel {
        // WHPX needs the Windows Hypervisor Platform feature turned on, and
        // crab can't easily tell whether it is, so QEMU falls back to TCG if
        // WHPX won't start. That works because -cpu max suits both, whereas
        // -cpu host would fail under TCG.
        "whpx" => (to_args(&["-accel", "whpx", "-accel", "tcg", "-cpu", "max"]), None),
        "tcg" => (
            to_args(&["-accel", "tcg", "-cpu", "max"]),
            Some(
                "Note: no hardware acceleration (can't open /dev/kvm), so the guest runs under emulation (slow)."
                    .to_string(),
            ),
        ),
        accel => (to_args(&["-accel", accel, "-cpu", "host"]), None),
    }
}

/// Builds the QEMU command line, with no filesystem access: `uefi` finds the
/// (code, vars template) firmware pair for an arch. `force_window` opens a
/// window even for VMs set to use the serial console, since the GUI has no terminal.
fn build_qemu_command(
    s: &VmSettings,
    req: &BootRequest,
    host: &str,
    uefi: &dyn Fn(&str) -> (PathBuf, PathBuf),
    force_window: bool,
) -> Result<QemuCommand, String> {
    let mut args: Vec<String> = Vec::new();
    let mut notes = Vec::new();
    let qemu: String;
    let mut fw_code: Option<PathBuf>;
    let mut fw_vars_template: Option<PathBuf>;
    let arch = s.arch.as_str();
    let (host_os, host_arch, native_accel) = parse_host_spec(host);

    match arch {
        "arm64" => {
            qemu = "qemu-system-aarch64".to_string();
            args.extend(["-M".to_string(), "virt".to_string()]);
            let (c, v) = uefi("arm64");
            fw_code = Some(c);
            fw_vars_template = Some(v);
            let (accel, note) = accel_args("arm64", host_arch, native_accel);
            args.extend(accel);
            notes.extend(note);
        }
        "amd64" | "i386" => {
            qemu = if arch == "amd64" {
                "qemu-system-x86_64".to_string()
            } else {
                "qemu-system-i386".to_string()
            };
            let (c, v) = uefi(arch);
            fw_code = Some(c);
            fw_vars_template = Some(v);
            if s.firmware == "bios" {
                fw_code = None;
                fw_vars_template = None;
            }
            args.extend(["-M".to_string(), "q35".to_string()]);
            let (accel, note) = accel_args("x86", host_arch, native_accel);
            args.extend(accel);
            notes.extend(note);
        }
        _ => return Err(format!("unsupported architecture: {arch}")),
    }

    let vm_dir = &req.vm_dir;
    let disk = vm_dir.join("disk.qcow2");
    let vars = vm_dir.join("efivars.fd");

    if let Some(code) = &fw_code {
        args.extend([
            "-drive".into(),
            format!("if=pflash,format=raw,unit=0,readonly=on,file={}", code.display()),
            "-drive".into(),
            format!("if=pflash,format=raw,unit=1,file={}", vars.display()),
        ]);
    }

    let (disk_if, nic) = if s.hw == "standard" {
        ("ide", "e1000")
    } else {
        ("virtio", "virtio-net-pci")
    };

    args.extend([
        "-name".into(),
        req.display_name(),
        "-m".into(),
        s.mem.clone(),
        "-smp".into(),
        s.cpus.clone(),
    ]);

    if req.mode != BootMode::Live {
        args.extend([
            "-drive".into(),
            format!("file={},if={disk_if},format=qcow2", disk.display()),
        ]);
    }

    let mut nic_arg = format!("user,model={nic}");
    if !s.ssh_port.is_empty() {
        nic_arg.push_str(&format!(",hostfwd=tcp:127.0.0.1:{}-:22", s.ssh_port));
    }
    for f in &s.forwards {
        nic_arg.push_str(&format!(",hostfwd={}", f.hostfwd()));
    }
    args.extend(["-nic".into(), nic_arg]);
    args.extend([
        "-pidfile".into(),
        vm_dir.join("qemu.pid").display().to_string(),
    ]);
    if host_os != "windows" {
        match qmp::usable_socket_path_for_os(vm_dir, host_os) {
            Some(sock) => args.extend([
                "-qmp".into(),
                format!("unix:{},server=on,wait=off", sock.display()),
            ]),
            None => notes.push(format!(
                "Note: {} is too long a path for a control socket, so crab stop won't work for this VM.",
                vm_dir.display()
            )),
        }
    }

    if let Some(img) = &req.image {
        let path = img.path.display();
        if !img.is_cd {
            args.extend([
                "-drive".into(),
                format!("file={path},if={disk_if},format=raw,snapshot=on"),
            ]);
        } else if arch == "arm64" {
            args.extend([
                "-device".into(),
                "virtio-scsi-pci".into(),
                "-drive".into(),
                format!("if=none,id=cd,media=cdrom,readonly=on,file={path}"),
                "-device".into(),
                "scsi-cd,drive=cd".into(),
            ]);
        } else {
            args.extend([
                "-drive".into(),
                format!("file={path},media=cdrom,readonly=on"),
            ]);
        }
    }

    if s.display == "terminal" && !force_window {
        args.push("-nographic".into());
    } else {
        args.extend(["-display".into(), host_window_display_for(host_os, &s.fullscreen)]);
        if host_os == "windows" && s.fullscreen == "on" {
            args.push("-full-screen".into());
        }
        if arch == "arm64" {
            if s.gpu == "ramfb" {
                args.extend(["-device".into(), "ramfb".into()]);
            } else {
                args.extend(["-device".into(), "virtio-gpu-pci".into()]);
            }
            args.extend([
                "-device".into(),
                "qemu-xhci".into(),
                "-device".into(),
                "usb-kbd".into(),
                "-device".into(),
                "usb-tablet".into(),
            ]);
        }
    }

    Ok(QemuCommand {
        qemu,
        args,
        fw_code,
        fw_vars_template,
        notes,
    })
}

/// A boot that's ready to go: the VM directory is set up (unless this is a
/// dry run) and all that's left is to run QEMU.
#[derive(Debug)]
pub struct BootPlan {
    pub qemu: String,
    pub args: Vec<String>,
    pub settings: VmSettings,
    pub notes: Vec<String>,
}

impl BootPlan {
    pub fn command_line(&self) -> String {
        format!("{} {}", self.qemu, self.args.join(" "))
    }
}

/// Shared by the CLI and the GUI: resolves settings, checks that QEMU, its
/// firmware and the host ports are available, then creates the disk, UEFI
/// variable store and vm.conf.
pub fn prepare_boot(
    paths: &Paths,
    opts: &BootOptions,
    req: &BootRequest,
    force_window: bool,
) -> Result<BootPlan, String> {
    let vm_dir = &req.vm_dir;
    require_stopped(vm_dir)?;

    let arch = if req.arch.is_empty() {
        let a = conf_get(vm_dir, "arch");
        if a.is_empty() {
            return Err(format!(
                "{} has no saved architecture; can't tell which QEMU to use",
                vm_dir.display()
            ));
        }
        a
    } else {
        req.arch.clone()
    };

    let conf = |key: &str| conf_get(vm_dir, key);
    let has_efi = || match &req.image {
        Some(img) => !img.path.is_file() || has_efi_loader(&img.path),
        None => true,
    };
    let pick_port = || pick_free_port(paths, vm_dir);
    let (settings, mut notes) = resolve_settings(
        opts,
        &conf,
        &arch,
        req.image.as_ref(),
        req.new_vm,
        &has_efi,
        &pick_port,
    )?;

    if !settings.ssh_port.is_empty() && port_in_use(&settings.ssh_port) {
        return Err(format!(
            "port {} is already in use on this Mac; pick another with -p",
            settings.ssh_port
        ));
    }
    for f in &settings.forwards {
        if f.host.to_string() == settings.ssh_port {
            return Err(format!("port {} is forwarded twice", f.host));
        }
        if !f.udp && port_in_use(&f.host.to_string()) {
            return Err(format!(
                "port {} is already in use on this Mac; change it with -P",
                f.host
            ));
        }
    }

    let qemu_share = qemu_share_dir();
    let uefi = |arch: &str| resolve_uefi_pair(arch, &qemu_share);
    let cmd = build_qemu_command(&settings, req, &current_host_spec(), &uefi, force_window)?;
    notes.extend(cmd.notes);

    if !command_exists(&cmd.qemu) {
        return Err(format!("{} not found ({})", cmd.qemu, install_qemu_hint()));
    }
    need_qemu_img()?;
    if let Some(code) = &cmd.fw_code {
        if !code.is_file() {
            return Err(format!(
                "UEFI firmware not found at {} ({})",
                code.display(),
                install_qemu_hint()
            ));
        }
    }
    if let Some(tmpl) = &cmd.fw_vars_template {
        if !tmpl.is_file() {
            return Err(format!(
                "UEFI variable store template not found at {}",
                tmpl.display()
            ));
        }
    }

    let disk = vm_dir.join("disk.qcow2");
    let disk_size = opts
        .disk_size
        .clone()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_DISK_SIZE.to_string());
    if req.mode == BootMode::Named && req.new_vm {
        notes.push(format!("New {disk_size} disk at {}", disk.display()));
    }

    if !opts.dry_run {
        fs::create_dir_all(vm_dir)
            .map_err(|e| format!("failed to create {}: {e}", vm_dir.display()))?;
        if req.mode != BootMode::Live && !disk.is_file() {
            let status = Command::new(qemu_img_bin())
                .args(["create", "-q", "-f", "qcow2"])
                .arg(&disk)
                .arg(&disk_size)
                .status()
                .map_err(|e| format!("failed to run qemu-img: {e}"))?;
            if !status.success() {
                return Err("qemu-img create failed".to_string());
            }
        }
        let vars = vm_dir.join("efivars.fd");
        if let Some(tmpl) = &cmd.fw_vars_template {
            if !vars.is_file() {
                fs::copy(tmpl, &vars).map_err(|e| format!("failed to copy efivars.fd: {e}"))?;
            }
        }
        conf_set(vm_dir, &settings.conf_entries())
            .map_err(|e| format!("failed to write vm.conf: {e}"))?;
        let _ = fs::remove_file(qmp::socket_path(vm_dir));
    }

    if let Some(img) = &req.image {
        log_image_boot(paths, &img.path, opts.dry_run);
    }

    Ok(BootPlan {
        qemu: cmd.qemu,
        args: cmd.args,
        settings,
        notes,
    })
}

pub fn cmd_boot(
    paths: &Paths,
    opts: &BootOptions,
    vm_name_arg: Option<&str>,
    image_arg: Option<&Path>,
) -> Result<(), String> {
    let mut image: Option<PathBuf> = None;
    let mut vm_dir: Option<PathBuf> = None;

    if let Some(vn) = vm_name_arg.filter(|s| !s.is_empty()) {
        vm_dir = Some(vm_path(paths, vn)?);
    } else if let Some(img) = image_arg {
        image = Some(abs_path(img));
    } else {
        match pick_from_menu(paths)? {
            MenuPick::Image(p) => image = Some(p),
            MenuPick::Vm(d) => vm_dir = Some(d),
        }
    }

    let mode = if image.is_none() {
        if opts.live || opts.keep {
            return Err("-k and -l are for booting images, not saved VMs\nRun 'crab -h' for usage.".to_string());
        }
        BootMode::Vm
    } else if opts.keep {
        BootMode::Named
    } else if opts.live {
        BootMode::Live
    } else {
        BootMode::Throwaway
    };

    let mut arch = String::new();
    let mut default_name = String::new();

    if let Some(ref img) = image {
        let detected = if let Some(ref ka) = opts.known_arch {
            ka.clone()
        } else if let Some(ref oa) = opts.arch {
            oa.clone()
        } else {
            let candidates = detect_arch(img);
            if candidates.len() == 1 {
                let d = candidates[0].to_string();
                println!("Detected architecture: {d}");
                d
            } else {
                let base = base_name(img);
                let list: Vec<String> = if candidates.is_empty() {
                    println!("Couldn't detect the architecture of {base}.");
                    vec!["arm64".into(), "amd64".into(), "i386".into()]
                } else {
                    println!("{base} has boot loaders for more than one architecture. Which is it?");
                    candidates.into_iter().map(String::from).collect()
                };
                let idx = select_numbered(&list, None)
                    .ok_or_else(|| "no architecture chosen".to_string())?;
                list[idx].clone()
            }
        };
        default_name = default_vm_name(img, &detected);
        arch = detected;
    }

    let mut new_vm = false;
    let mut scratch_dir: Option<PathBuf> = None;

    let target_vm_dir = match mode {
        BootMode::Vm => vm_dir.unwrap(),
        BootMode::Named => {
            let input = prompt_line(&format!("VM name [{default_name}]: ")).unwrap_or_default();
            let chosen = if input.trim().is_empty() {
                default_name.clone()
            } else {
                input.trim().to_string()
            };
            check_name(&chosen)?;
            let d = paths.vm_root.join(&chosen);
            if d.join("disk.qcow2").is_file() {
                println!("Using the existing VM '{chosen}', with the installer attached.");
                let saved = conf_get(&d, "arch");
                if !saved.is_empty() && saved != arch {
                    println!(
                        "Note: this VM is {saved}, but the image looks like {arch}. Keeping {saved}."
                    );
                }
                arch.clear();
            } else {
                new_vm = true;
            }
            d
        }
        BootMode::Throwaway | BootMode::Live => {
            new_vm = true;
            if opts.dry_run {
                paths.scratch_root.join("DRY-RUN")
            } else {
                let s = create_scratch_dir(&paths.scratch_root)
                    .map_err(|e| format!("failed to create scratch dir: {e}"))?;
                scratch_dir = Some(s.clone());
                s
            }
        }
    };

    let req = BootRequest {
        mode,
        vm_dir: target_vm_dir,
        image: image.as_deref().map(ImageInfo::probe),
        arch,
        default_name,
        new_vm,
    };
    let result = run_cli_boot(paths, opts, &req);

    if result.is_err() {
        if let Some(ref s) = scratch_dir {
            let _ = fs::remove_dir_all(s);
        }
    }
    result
}

fn run_cli_boot(paths: &Paths, opts: &BootOptions, req: &BootRequest) -> Result<(), String> {
    let plan = prepare_boot(paths, opts, req, false)?;
    let s = &plan.settings;
    for note in &plan.notes {
        println!("{note}");
    }

    match req.mode {
        BootMode::Throwaway => {
            println!("Throwaway VM: you'll be asked whether to keep it when QEMU exits.");
        }
        BootMode::Live => {
            println!("Live boot: no disk attached, nothing is kept.");
        }
        BootMode::Vm | BootMode::Named => {}
    }

    if s.display == "terminal" {
        println!("Serial console in this terminal. Quit QEMU with Ctrl-A then X.");
        if s.arch != "arm64" {
            println!("Tip: if output stops after the boot loader, type 'set tty com0' at the boot> prompt.");
        }
    } else {
        if s.fullscreen != "on" {
            println!("Window: drag it bigger to scale the screen up, or boot with -F for full screen.");
        }
        if s.arch == "arm64" && s.gpu == "virtio" {
            println!("Tip: if the window stays blank once the OS is up, try again with -r, or -t for the serial console.");
        }
    }
    if !s.ssh_port.is_empty() {
        match req.mode {
            BootMode::Vm | BootMode::Named => println!(
                "SSH: once the guest runs sshd, connect with: crab ssh {}  (or ssh -p {} <user>@localhost)",
                req.display_name(),
                s.ssh_port
            ),
            BootMode::Throwaway | BootMode::Live => println!(
                "SSH: once the guest runs sshd, connect with: ssh -p {} <user>@localhost",
                s.ssh_port
            ),
        }
    }
    for f in &s.forwards {
        let proto = if f.udp { " (udp)" } else { "" };
        println!("Forwarding localhost:{} to guest port {}{proto}.", f.host, f.guest);
    }

    println!();
    println!("{}", plan.command_line());
    println!();

    if opts.dry_run {
        return Ok(());
    }

    let qemu_bin = find_executable(&plan.qemu).unwrap_or_else(|| PathBuf::from(&plan.qemu));

    match req.mode {
        BootMode::Vm | BootMode::Named => {
            #[cfg(unix)]
            {
                use std::os::unix::process::CommandExt;
                let err = Command::new(&qemu_bin).args(&plan.args).exec();
                Err(format!("failed to exec {}: {err}", plan.qemu))
            }
            #[cfg(not(unix))]
            {
                let status = Command::new(&qemu_bin)
                    .args(&plan.args)
                    .status()
                    .map_err(|e| format!("failed to run {}: {e}", plan.qemu))?;
                if !status.success() {
                    std::process::exit(status.code().unwrap_or(1));
                }
                Ok(())
            }
        }
        BootMode::Throwaway | BootMode::Live => {
            // Ignore SIGINT in parent while QEMU is running so we survive to ask what to keep.
            #[cfg(unix)]
            unsafe {
                libc::signal(libc::SIGINT, libc::SIG_IGN);
            }
            let status = Command::new(&qemu_bin).args(&plan.args).status();
            #[cfg(unix)]
            unsafe {
                libc::signal(libc::SIGINT, libc::SIG_DFL);
            }
            println!();
            match status {
                Ok(s) => {
                    if !s.success() {
                        let code = s.code().unwrap_or(1);
                        println!("QEMU exited with status {code}.");
                    }
                }
                Err(e) => {
                    let _ = fs::remove_dir_all(&req.vm_dir);
                    return Err(format!("failed to run {}: {e}", plan.qemu));
                }
            }
            after_throwaway(
                paths,
                &req.vm_dir,
                req.image.as_ref().map(|i| i.path.as_path()),
                &req.default_name,
                req.mode == BootMode::Live,
            )
        }
    }
}

/// Helper used by the GUI to prepare and spawn a VM or image in a QEMU window
/// and return the child process / scratch path so the GUI can prompt to keep/discard when QEMU exits.
#[allow(dead_code)]
pub struct GuiSpawnedVm {
    pub child: std::process::Child,
    pub scratch_dir: Option<PathBuf>,
    pub image_path: Option<PathBuf>,
    pub default_name: String,
    pub live: bool,
    pub qemu_cmd_line: String,
}

pub fn spawn_from_gui(
    paths: &Paths,
    opts: &BootOptions,
    vm_name: Option<&str>,
    image_path: Option<&Path>,
    named_vm_target: Option<&str>,
) -> Result<GuiSpawnedVm, String> {
    let mut arch = String::new();
    let mut default_name = String::new();
    let image = image_path.map(abs_path);

    let mode = if image.is_none() {
        BootMode::Vm
    } else if opts.keep {
        BootMode::Named
    } else if opts.live {
        BootMode::Live
    } else {
        BootMode::Throwaway
    };

    // The GUI can't ask, so it goes with the first detected arch, or this Mac's.
    if let Some(ref img) = image {
        let detected = opts
            .known_arch
            .clone()
            .or_else(|| opts.arch.clone())
            .unwrap_or_else(|| {
                detect_arch(img)
                    .first()
                    .copied()
                    .unwrap_or_else(|| crate::config::host_arch())
                    .to_string()
            });
        default_name = default_vm_name(img, &detected);
        arch = detected;
    }

    let mut new_vm = false;
    let mut scratch_dir = None;

    let vm_dir = match mode {
        BootMode::Vm => vm_path(paths, vm_name.ok_or("no VM selected")?)?,
        BootMode::Named => {
            let chosen = named_vm_target
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(&default_name);
            check_name(chosen)?;
            let d = paths.vm_root.join(chosen);
            if d.join("disk.qcow2").is_file() {
                arch.clear();
            } else {
                new_vm = true;
            }
            d
        }
        BootMode::Throwaway | BootMode::Live => {
            new_vm = true;
            let s = create_scratch_dir(&paths.scratch_root)
                .map_err(|e| format!("failed to create scratch dir: {e}"))?;
            scratch_dir = Some(s.clone());
            s
        }
    };

    let req = BootRequest {
        mode,
        vm_dir,
        image: image.as_deref().map(ImageInfo::probe),
        arch,
        default_name: default_name.clone(),
        new_vm,
    };
    let spawned = prepare_boot(paths, opts, &req, true).and_then(|plan| {
        let qemu_bin = find_executable(&plan.qemu).unwrap_or_else(|| PathBuf::from(&plan.qemu));
        Command::new(&qemu_bin)
            .args(&plan.args)
            .spawn()
            .map(|child| (child, plan.command_line()))
            .map_err(|e| format!("failed to spawn {}: {e}", plan.qemu))
    });
    let (child, qemu_cmd_line) = match spawned {
        Ok(ok) => ok,
        Err(e) => {
            if let Some(ref s) = scratch_dir {
                let _ = fs::remove_dir_all(s);
            }
            return Err(e);
        }
    };

    Ok(GuiSpawnedVm {
        child,
        scratch_dir,
        image_path: image,
        default_name,
        live: mode == BootMode::Live,
        qemu_cmd_line,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn arch_from_names() {
        assert_eq!(arch_from_name("Fedora-Workstation-Live-aarch64-41.iso"), Some("arm64"));
        assert_eq!(arch_from_name("/some/amd64/dir/install76.img"), None);
        assert_eq!(arch_from_name("ubuntu-24.04-live-server-amd64.iso"), Some("amd64"));
        assert_eq!(arch_from_name("alpine-virt-3.20-x86_64.iso"), Some("amd64"));
        assert_eq!(arch_from_name("debian-i386.iso"), Some("i386"));
        assert_eq!(arch_from_name("NetBSD-10-evbarm.img"), Some("arm64"));
        assert_eq!(arch_from_name("livedisk.iso"), None);
    }

    #[test]
    fn efi_loader_names() {
        assert!(matches_efi(b"..EFI/BOOT/BOOTAA64.EFI..", b"BOOTAA64"));
        assert!(matches_efi(b"BOOTX64 EFI", b"BOOTX64"));
        assert!(matches_efi(b"xxBOOTIA32EFI", b"BOOTIA32"));
        assert!(!matches_efi(b"BOOTX64.EXE", b"BOOTX64"));
        assert!(!matches_efi(b"BOOTX64", b"BOOTX64"));
    }

    #[test]
    fn efi_scan_across_chunk_boundary() {
        let dir = crate::config::test_dir("efi-scan");
        let img = dir.join("disk.img");
        let mut data = vec![0u8; 1024 * 1024 - 4];
        data.extend_from_slice(b"BOOTX64.EFI");
        data.extend(vec![0u8; 100]);
        fs::write(&img, data).unwrap();
        assert_eq!(scan_efi_loaders(&img), (false, true, false));
        assert!(has_efi_loader(&img));
    }

    #[test]
    fn default_names() {
        let p = Path::new("/x/openbsd-install76.img");
        assert_eq!(default_vm_name(p, "amd64"), "openbsd-install76-amd64");
        let p = Path::new("/x/Fedora-41-aarch64.iso");
        assert_eq!(default_vm_name(p, "arm64"), "Fedora-41-aarch64");
    }

    fn image(name: &str, is_cd: bool, is_bsd: bool) -> ImageInfo {
        ImageInfo { path: PathBuf::from(format!("/img/{name}")), is_cd, is_bsd }
    }

    fn resolve(
        opts: &BootOptions,
        saved: &[(&str, &str)],
        arch: &str,
        img: Option<&ImageInfo>,
        new_vm: bool,
        efi: bool,
    ) -> Result<(VmSettings, Vec<String>), String> {
        let saved: HashMap<String, String> =
            saved.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        let conf = move |k: &str| saved.get(k).cloned().unwrap_or_default();
        resolve_settings(opts, &conf, arch, img, new_vm, &|| efi, &|| Some(2222))
    }

    #[test]
    fn new_x86_vm_defaults() {
        let img = image("alpine-x86_64.iso", true, false);
        let (s, notes) = resolve(&BootOptions::default(), &[], "amd64", Some(&img), true, true).unwrap();
        assert_eq!(s.hw, "standard");
        assert_eq!(s.firmware, "uefi");
        assert_eq!(s.display, "window");
        assert_eq!(s.ssh_port, "2222", "new VMs get a free SSH port");
        assert_eq!((s.mem.as_str(), s.cpus.as_str()), (DEFAULT_MEM, "2"));
        assert!(notes.is_empty());
    }

    #[test]
    fn bsd_installer_without_efi() {
        let img = image("install76.img", false, true);
        let (s, notes) = resolve(&BootOptions::default(), &[], "amd64", Some(&img), true, false).unwrap();
        assert_eq!(s.firmware, "bios");
        assert_eq!(s.display, "terminal");
        assert_eq!(notes, ["No UEFI boot loader in install76.img; using legacy BIOS."]);
    }

    #[test]
    fn flags_beat_saved_values_beat_defaults() {
        let opts = BootOptions {
            mem: Some("4G".into()),
            ssh_port: Some("0".into()),
            ..Default::default()
        };
        let saved = [("mem", "1G"), ("cpus", "6"), ("ssh_port", "2200"), ("fwd", "8080:80")];
        let (s, _) = resolve(&opts, &saved, "arm64", None, false, true).unwrap();
        assert_eq!(s.mem, "4G");
        assert_eq!(s.cpus, "6");
        assert_eq!(s.ssh_port, "", "-p 0 turns SSH off");
        assert_eq!(s.forwards, [Forward { udp: false, host: 8080, guest: 80 }]);

        let opts = BootOptions { forwards: Some(vec![]), ..Default::default() };
        let (s, _) = resolve(&opts, &saved, "arm64", None, false, true).unwrap();
        assert_eq!(s.ssh_port, "2200");
        assert!(s.forwards.is_empty(), "-P 0 clears saved forwards");
    }

    #[test]
    fn old_vmboot_vms_keep_their_hardware() {
        // No hw or display saved: x86 VMs from older vmboot used virtio, and
        // arm64 ones used the serial console.
        let (s, _) = resolve(&BootOptions::default(), &[("arch", "amd64")], "amd64", None, false, true).unwrap();
        assert_eq!((s.hw.as_str(), s.display.as_str()), ("virtio", "window"));
        let (s, _) = resolve(&BootOptions::default(), &[("arch", "arm64")], "arm64", None, false, true).unwrap();
        assert_eq!((s.hw.as_str(), s.display.as_str()), ("virtio", "terminal"));
        assert_eq!(s.ssh_port, "", "existing VMs don't get a port picked");
    }

    #[test]
    fn arm64_cannot_use_bios() {
        let opts = BootOptions { firmware: Some("bios".into()), ..Default::default() };
        assert!(resolve(&opts, &[], "arm64", None, false, true).is_err());
    }

    fn settings(arch: &str) -> VmSettings {
        VmSettings {
            arch: arch.into(),
            firmware: "uefi".into(),
            mem: "2G".into(),
            cpus: "2".into(),
            display: "window".into(),
            ssh_port: "2222".into(),
            forwards: vec![Forward { udp: false, host: 8080, guest: 80 }],
            hw: "virtio".into(),
            gpu: "virtio".into(),
            fullscreen: "off".into(),
        }
    }

    /// Firmware as if QEMU's share directory were /share.
    fn share(arch: &str) -> (PathBuf, PathBuf) {
        let (code, vars) = qemu_uefi_names(arch);
        (Path::new("/share").join(code), Path::new("/share").join(vars))
    }

    fn request(mode: BootMode, image: Option<ImageInfo>) -> BootRequest {
        BootRequest {
            mode,
            vm_dir: PathBuf::from("/vms/test"),
            image,
            arch: String::new(),
            default_name: "test".into(),
            new_vm: false,
        }
    }

    // The expected command lines use Unix paths.
    #[cfg(unix)]
    #[test]
    fn arm64_throwaway_command() {
        let req = request(BootMode::Throwaway, Some(image("fedora.iso", true, false)));
        let cmd = build_qemu_command(&settings("arm64"), &req, "arm64", &share, false).unwrap();
        assert_eq!(cmd.qemu, "qemu-system-aarch64");
        assert_eq!(
            cmd.args.join(" "),
            "-M virt -accel hvf -cpu host \
             -drive if=pflash,format=raw,unit=0,readonly=on,file=/share/edk2-aarch64-code.fd \
             -drive if=pflash,format=raw,unit=1,file=/vms/test/efivars.fd \
             -name test -m 2G -smp 2 \
             -drive file=/vms/test/disk.qcow2,if=virtio,format=qcow2 \
             -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80 \
             -pidfile /vms/test/qemu.pid \
             -qmp unix:/vms/test/qmp.sock,server=on,wait=off \
             -device virtio-scsi-pci -drive if=none,id=cd,media=cdrom,readonly=on,file=/img/fedora.iso \
             -device scsi-cd,drive=cd \
             -display cocoa,zoom-to-fit=on,full-screen=off \
             -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet"
        );
        assert_eq!(cmd.fw_vars_template, Some(PathBuf::from("/share/edk2-arm-vars.fd")));
        assert!(cmd.notes.is_empty());
    }

    // The expected command lines use Unix paths.
    #[cfg(unix)]
    #[test]
    fn x86_bios_live_under_emulation() {
        let mut s = settings("amd64");
        s.firmware = "bios".into();
        s.hw = "standard".into();
        s.display = "terminal".into();
        s.ssh_port.clear();
        s.forwards.clear();
        let req = request(BootMode::Live, Some(image("install76.img", false, true)));
        let cmd = build_qemu_command(&s, &req, "arm64", &share, false).unwrap();
        assert_eq!(cmd.qemu, "qemu-system-x86_64");
        assert_eq!(
            cmd.args.join(" "),
            "-M q35 -accel tcg -cpu max -name test -m 2G -smp 2 \
             -nic user,model=e1000 -pidfile /vms/test/qemu.pid \
             -qmp unix:/vms/test/qmp.sock,server=on,wait=off \
             -drive file=/img/install76.img,if=ide,format=raw,snapshot=on -nographic"
        );
        assert_eq!(cmd.fw_vars_template, None);
        assert_eq!(cmd.notes.len(), 1);
    }

    #[test]
    fn gui_forces_a_window() {
        let mut s = settings("amd64");
        s.display = "terminal".into();
        let req = request(BootMode::Vm, None);
        let cmd = build_qemu_command(&s, &req, "x86_64", &share, true).unwrap();
        assert!(!cmd.args.contains(&"-nographic".to_string()));
        assert!(cmd.args.contains(&"cocoa,zoom-to-fit=on,full-screen=off".to_string()));
        assert!(cmd.args.windows(2).any(|w| w == ["-accel", "hvf"]));
    }

    #[test]
    fn linux_x86_64_kvm_and_tcg_commands() {
        let s = settings("amd64");
        let req = request(BootMode::Vm, None);
        let cmd = build_qemu_command(&s, &req, "linux-x86_64", &share, false).unwrap();
        assert_eq!(cmd.qemu, "qemu-system-x86_64");
        assert!(cmd.args.windows(4).any(|w| w == ["-accel", "kvm", "-cpu", "host"]));
        assert!(cmd.args.contains(&"gtk,zoom-to-fit=on,full-screen=off".to_string()));
        assert!(cmd.notes.is_empty());

        let cmd_nokvm =
            build_qemu_command(&s, &req, "linux-tcg-x86_64", &share, false).unwrap();
        assert!(cmd_nokvm.args.windows(4).any(|w| w == ["-accel", "tcg", "-cpu", "max"]));
        assert!(cmd_nokvm.notes[0].contains("/dev/kvm"), "{:?}", cmd_nokvm.notes);
    }

    #[test]
    fn windows_x86_64_whpx_command() {
        let mut s = settings("amd64");
        s.fullscreen = "on".into();
        let req = request(BootMode::Vm, None);
        let cmd =
            build_qemu_command(&s, &req, "windows-x86_64", &share, false).unwrap();
        assert_eq!(cmd.qemu, "qemu-system-x86_64");
        assert!(
            cmd.args.windows(6).any(|w| w == ["-accel", "whpx", "-accel", "tcg", "-cpu", "max"]),
            "WHPX falls back to TCG: {:?}",
            cmd.args
        );
        assert!(cmd.args.contains(&"sdl,gl=off,window-close=on".to_string()));
        assert!(cmd.args.contains(&"-full-screen".to_string()));
        assert!(!cmd.args.contains(&"-qmp".to_string()));
        assert!(cmd.notes.is_empty());
    }

    #[test]
    fn uefi_pairs_must_match() {
        let dir = crate::config::test_dir("uefi-pairs");
        let file = |name: &str, len: u64| {
            let p = dir.join(name);
            fs::File::create(&p).unwrap().set_len(len).unwrap();
            p
        };
        let small_code = file("QEMU_EFI.fd", 2 * 1024 * 1024);
        let padded_code = file("AAVMF_CODE.fd", AARCH64_PFLASH_SIZE);
        let padded_vars = file("AAVMF_VARS.fd", AARCH64_PFLASH_SIZE);
        let missing = dir.join("missing.fd");

        // An unpadded arm64 image is skipped in favour of a padded pair.
        let pairs = [
            (small_code.as_path(), padded_vars.as_path()),
            (padded_code.as_path(), padded_vars.as_path()),
        ];
        assert_eq!(
            first_usable_uefi_pair("arm64", pairs),
            Some((padded_code.clone(), padded_vars.clone()))
        );
        assert_eq!(first_usable_uefi_pair("arm64", [pairs[0]]), None);

        // x86 code and vars sizes differ legitimately, but both must exist.
        let ovmf_code = file("OVMF_CODE_4M.fd", 4 * 1024 * 1024);
        let ovmf_vars = file("OVMF_VARS_4M.fd", 540_672);
        let pairs = [
            (ovmf_code.as_path(), missing.as_path()),
            (ovmf_code.as_path(), ovmf_vars.as_path()),
        ];
        assert_eq!(first_usable_uefi_pair("amd64", pairs), Some((ovmf_code, ovmf_vars)));
    }

    #[test]
    fn distro_uefi_pairs_are_consistent() {
        for arch in ["arm64", "amd64", "i386"] {
            for (code, vars) in distro_uefi_pairs(arch) {
                // A 4M code image needs the 4M vars store built with it.
                let four_m = |p: &str| p.contains("_4M") || p.contains(".4m");
                assert_eq!(four_m(code), four_m(vars), "{code} paired with {vars}");
                assert!(!code.ends_with("/QEMU_EFI.fd"), "{code} isn't padded for pflash");
            }
        }
    }

    #[test]
    fn accelerators() {
        let args = |guest, host_arch, accel| accel_args(guest, host_arch, accel).0.join(" ");
        assert_eq!(args("arm64", "arm64", "hvf"), "-accel hvf -cpu host");
        assert_eq!(args("x86", "x86_64", "kvm"), "-accel kvm -cpu host");
        assert_eq!(args("x86", "x86_64", "whpx"), "-accel whpx -accel tcg -cpu max");
        assert_eq!(args("x86", "arm64", "hvf"), "-accel tcg -cpu max");
        assert_eq!(args("arm64", "x86_64", "whpx"), "-accel tcg -cpu max");

        let note = |guest, host_arch, accel| accel_args(guest, host_arch, accel).1;
        assert_eq!(note("arm64", "arm64", "hvf"), None);
        assert!(note("x86", "arm64", "kvm").unwrap().contains("x86 guest on an arm64 host"));
        assert!(note("arm64", "x86_64", "hvf").unwrap().contains("arm64 guest on an x86_64 host"));
    }

    #[test]
    fn unknown_arch() {
        let req = request(BootMode::Vm, None);
        assert!(build_qemu_command(&settings("riscv64"), &req, "arm64", &share, false).is_err());
    }
}
