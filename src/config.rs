use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

pub const CATALOG_MAX_AGE_DAYS: u64 = 7;
pub const DISTROS: &[&str] = &["fedora", "ubuntu", "alpine", "openbsd"];
pub const DEFAULT_MEM: &str = "2G";
pub const DEFAULT_CPUS: u32 = 2;
pub const DEFAULT_DISK_SIZE: &str = "20G";
pub const DEFAULT_CLEAN_DAYS: u64 = 30;

#[derive(Clone, Debug)]
pub struct Paths {
    pub vm_root: PathBuf,
    pub scratch_root: PathBuf,
    pub history: PathBuf,
    pub catalog: PathBuf,
    pub mirrors_file: PathBuf,
    pub config_file: PathBuf,
    pub search_dir: PathBuf,
}

impl Paths {
    pub fn new(search_dir_override: Option<PathBuf>) -> Self {
        let home = env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."));
        let vm_root = env::var("VM_ROOT")
            .ok()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("VMs"));
        let scratch_root = vm_root.join(".scratch");
        let history = vm_root.join(".image-history");
        let catalog = vm_root.join(".catalog");
        let mirrors_file = vm_root.join("mirrors");
        let config_file = vm_root.join("config");
        let search_dir = search_dir_override
            .or_else(|| {
                env::var("CRAB_SEARCH_DIR")
                    .ok()
                    .filter(|s| !s.is_empty())
                    .map(PathBuf::from)
            })
            .or_else(|| read_config_key(&config_file, "search_dir").map(PathBuf::from))
            .unwrap_or_else(|| home.join("Downloads"));

        Self {
            vm_root,
            scratch_root,
            history,
            catalog,
            mirrors_file,
            config_file,
            search_dir,
        }
    }

    pub fn save_search_dir(&mut self, new_dir: PathBuf) -> io::Result<()> {
        self.search_dir = new_dir.clone();
        fs::create_dir_all(&self.vm_root)?;
        let mut lines = Vec::new();
        let mut found = false;
        if let Ok(existing) = fs::read_to_string(&self.config_file) {
            for line in existing.lines() {
                if line.starts_with("search_dir=") {
                    lines.push(format!("search_dir={}", new_dir.display()));
                    found = true;
                } else {
                    lines.push(line.to_string());
                }
            }
        }
        if !found {
            lines.push(format!("search_dir={}", new_dir.display()));
        }
        fs::write(&self.config_file, lines.join("\n") + "\n")
    }
}

pub fn read_config_key(config_file: &Path, key: &str) -> Option<String> {
    let content = fs::read_to_string(config_file).ok()?;
    let prefix = format!("{key}=");
    let mut val = None;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') || trimmed.is_empty() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix(&prefix) {
            if !rest.trim().is_empty() {
                val = Some(rest.trim().to_string());
            }
        }
    }
    val
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn fmt_age(unix_secs: u64) -> String {
    let now = now_secs();
    let days = now.saturating_sub(unix_secs) / 86400;
    match days {
        0 => "today".to_string(),
        1 => "1 day ago".to_string(),
        d => format!("{d} days ago"),
    }
}

pub fn human_size(path: &Path) -> String {
    let out = Command::new("du")
        .arg("-sh")
        .arg(path)
        .stderr(Stdio::null())
        .output();
    if let Ok(out) = out {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            if let Some(first) = s.split('\t').next() {
                return first.trim().to_string();
            }
        }
    }
    "?".to_string()
}

pub fn disk_kb(path: &Path) -> u64 {
    let flag = if path.is_dir() { "-sk" } else { "-k" };
    let out = Command::new("du")
        .arg(flag)
        .arg(path)
        .stderr(Stdio::null())
        .output();
    if let Ok(out) = out {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            if let Some(first) = s.split('\t').next() {
                if let Ok(kb) = first.trim().parse::<u64>() {
                    return kb;
                }
            }
        }
    }
    0
}

pub fn fmt_kb(kb: u64) -> String {
    if kb < 1_048_576 {
        format!("{}M", (kb + 512) / 1024)
    } else {
        format!("{:.1}G", kb as f64 / 1_048_576.0)
    }
}

pub fn abs_path(p: &Path) -> PathBuf {
    if let Ok(canon) = fs::canonicalize(p) {
        return canon;
    }
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        env::current_dir().unwrap_or_default().join(p)
    }
}

pub fn file_mtime(path: &Path) -> u64 {
    fs::metadata(path)
        .map(|m| m.mtime() as u64)
        .unwrap_or_else(|_| now_secs())
}

pub fn file_birthtime(path: &Path) -> u64 {
    if let Ok(meta) = fs::metadata(path) {
        if let Ok(created) = meta.created() {
            if let Ok(dur) = created.duration_since(UNIX_EPOCH) {
                return dur.as_secs();
            }
        }
        return meta.mtime() as u64;
    }
    now_secs()
}

pub fn ask_yes(prompt: &str) -> bool {
    print!("{prompt} [y/N] ");
    let _ = io::stdout().flush();
    let mut answer = String::new();
    if io::stdin().read_line(&mut answer).is_ok() {
        let trimmed = answer.trim();
        trimmed.eq_ignore_ascii_case("y") || trimmed.eq_ignore_ascii_case("yes")
    } else {
        false
    }
}

pub fn prompt_line(prompt: &str) -> Option<String> {
    print!("{prompt}");
    let _ = io::stdout().flush();
    let mut line = String::new();
    match io::stdin().read_line(&mut line) {
        Ok(0) | Err(_) => None,
        Ok(_) => Some(line.trim_end_matches(&['\r', '\n'][..]).to_string()),
    }
}

pub fn host_arch() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    }
}

pub fn host_uname_m() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    }
}

pub fn log_image_boot(paths: &Paths, image_path: &Path, dry_run: bool) {
    if dry_run {
        return;
    }
    let _ = fs::create_dir_all(&paths.vm_root);
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&paths.history)
    {
        let _ = writeln!(f, "{}\t{}", now_secs(), image_path.display());
    }
}

pub fn image_last_boot(paths: &Paths, image_path: &Path) -> Option<u64> {
    let f = fs::File::open(&paths.history).ok()?;
    let target = image_path.to_string_lossy();
    let mut last_t = None;
    for line in io::BufReader::new(f).lines().map_while(Result::ok) {
        let mut parts = line.splitn(2, '\t');
        if let (Some(t_str), Some(p_str)) = (parts.next(), parts.next()) {
            if p_str == target {
                if let Ok(t) = t_str.parse::<u64>() {
                    last_t = Some(t);
                }
            }
        }
    }
    last_t
}

pub fn image_last_used(paths: &Paths, image_path: &Path) -> u64 {
    let added = file_birthtime(image_path);
    match image_last_boot(paths, image_path) {
        Some(booted) if booted > added => booted,
        _ => added,
    }
}

#[derive(Clone, Debug)]
pub struct ImageEntry {
    pub path: PathBuf,
    pub name: String,
    pub size_human: String,
    pub size_kb: u64,
    pub downloaded_secs: u64,
    pub last_booted_secs: Option<u64>,
    pub file_info: String,
}

pub fn list_image_paths(paths: &Paths) -> Vec<PathBuf> {
    let mut isos = Vec::new();
    let mut imgs = Vec::new();
    if let Ok(entries) = fs::read_dir(&paths.search_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() {
                if let Some(ext) = p.extension().and_then(|e| e.to_str()) {
                    if ext.eq_ignore_ascii_case("iso") {
                        isos.push(abs_path(&p));
                    } else if ext.eq_ignore_ascii_case("img") {
                        imgs.push(abs_path(&p));
                    }
                }
            }
        }
    }
    isos.sort();
    imgs.sort();
    isos.extend(imgs);
    isos
}

pub fn file_brief(path: &Path) -> String {
    Command::new("file")
        .arg("-b")
        .arg(path)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

pub fn extract_quoted_label(file_output: &str) -> String {
    // sed -n "s/.*'\(.*\)'.*/\1/p" | tr -s ' '
    // interesting that an AI would comment out a line at all.
    if let (Some(first), Some(last)) = (file_output.find('\''), file_output.rfind('\'')) {
        if last > first {
            let inner = &file_output[first + 1..last];
            return inner.split_whitespace().collect::<Vec<_>>().join(" ");
        }
    }
    String::new()
}

pub fn list_image_entries(paths: &Paths) -> Vec<ImageEntry> {
    list_image_paths(paths)
        .into_iter()
        .map(|p| {
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            let size_human = human_size(&p);
            let size_kb = disk_kb(&p);
            let downloaded_secs = file_birthtime(&p);
            let last_booted_secs = image_last_boot(paths, &p);
            let fb = file_brief(&p);
            let file_info = extract_quoted_label(&fb);
            ImageEntry {
                path: p,
                name,
                size_human,
                size_kb,
                downloaded_secs,
                last_booted_secs,
                file_info,
            }
        })
        .collect()
}

pub fn valid_mem(s: &str) -> bool {
    let num_part = s.strip_suffix(['M', 'm', 'G', 'g']).unwrap_or(s);
    !num_part.is_empty() && num_part.chars().all(|c| c.is_ascii_digit())
}

pub fn valid_cpus(s: &str) -> bool {
    !s.is_empty() && !s.starts_with('0') && s.chars().all(|c| c.is_ascii_digit())
}

pub fn valid_port(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()) && s.parse::<u16>().is_ok()
}

/// A disk size for qemu-img: digits with an M, G or T suffix, optionally
/// prefixed with + (grow by) when `relative` is allowed.
pub fn valid_disk_size(s: &str, relative: bool) -> bool {
    let s = if relative { s.strip_prefix('+').unwrap_or(s) } else { s };
    let Some(num_part) = s.strip_suffix(['M', 'm', 'G', 'g', 'T', 't']) else {
        return false;
    };
    !num_part.is_empty() && num_part.chars().all(|c| c.is_ascii_digit()) && num_part != "0"
}

/// A host port forwarded into the guest, written as `[udp:]HOST:GUEST`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Forward {
    pub udp: bool,
    pub host: u16,
    pub guest: u16,
}

impl Forward {
    pub fn parse(s: &str) -> Option<Forward> {
        let (udp, rest) = if let Some(r) = s.strip_prefix("udp:") {
            (true, r)
        } else {
            (false, s.strip_prefix("tcp:").unwrap_or(s))
        };
        let (host, guest) = rest.split_once(':')?;
        if !valid_port(host) || !valid_port(guest) {
            return None;
        }
        let (host, guest) = (host.parse().ok()?, guest.parse().ok()?);
        (host != 0 && guest != 0).then_some(Forward { udp, host, guest })
    }

    /// Parses a comma-separated list as saved in vm.conf; "" and "0" mean none.
    pub fn parse_list(s: &str) -> Result<Vec<Forward>, String> {
        let s = s.trim();
        if s.is_empty() || s == "0" {
            return Ok(Vec::new());
        }
        s.split(',')
            .map(|item| {
                Forward::parse(item.trim())
                    .ok_or_else(|| format!("bad port forward '{item}' (want HOST:GUEST or udp:HOST:GUEST)"))
            })
            .collect()
    }

    pub fn list_to_conf(fwds: &[Forward]) -> String {
        if fwds.is_empty() {
            return "0".to_string();
        }
        fwds.iter().map(Forward::to_string).collect::<Vec<_>>().join(",")
    }

    /// The `hostfwd=` value for QEMU's user-mode network.
    pub fn hostfwd(&self) -> String {
        let proto = if self.udp { "udp" } else { "tcp" };
        format!("{proto}:127.0.0.1:{}-:{}", self.host, self.guest)
    }
}

impl std::fmt::Display for Forward {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.udp {
            write!(f, "udp:{}:{}", self.host, self.guest)
        } else {
            write!(f, "{}:{}", self.host, self.guest)
        }
    }
}

/// A fresh, empty directory for a test, unique per test name and process.
#[cfg(test)]
pub fn test_dir(name: &str) -> PathBuf {
    let dir = env::temp_dir().join(format!("crab-test-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[cfg(test)]
pub fn test_paths(root: &Path) -> Paths {
    Paths {
        vm_root: root.to_path_buf(),
        scratch_root: root.join(".scratch"),
        history: root.join(".image-history"),
        catalog: root.join(".catalog"),
        mirrors_file: root.join("mirrors"),
        config_file: root.join("config"),
        search_dir: root.join("images"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mem_sizes() {
        assert!(valid_mem("2G") && valid_mem("512M") && valid_mem("4096") && valid_mem("1g"));
        assert!(!valid_mem("") && !valid_mem("G") && !valid_mem("2T") && !valid_mem("2.5G"));
    }

    #[test]
    fn cpus_and_ports() {
        assert!(valid_cpus("4") && !valid_cpus("0") && !valid_cpus("04") && !valid_cpus("x"));
        assert!(valid_port("0") && valid_port("65535") && !valid_port("65536") && !valid_port("-1"));
    }

    #[test]
    fn disk_sizes() {
        assert!(valid_disk_size("20G", false) && valid_disk_size("1T", false));
        assert!(!valid_disk_size("+10G", false) && valid_disk_size("+10G", true));
        assert!(!valid_disk_size("20", false) && !valid_disk_size("0G", false));
    }

    #[test]
    fn forwards() {
        assert_eq!(
            Forward::parse("8080:80"),
            Some(Forward { udp: false, host: 8080, guest: 80 })
        );
        assert_eq!(
            Forward::parse("udp:5353:53"),
            Some(Forward { udp: true, host: 5353, guest: 53 })
        );
        assert_eq!(Forward::parse("tcp:1:2").map(|f| f.to_string()), Some("1:2".into()));
        assert!(Forward::parse("80").is_none() && Forward::parse("0:80").is_none());
        assert!(Forward::parse("sctp:1:2").is_none() && Forward::parse("1:99999").is_none());

        let list = Forward::parse_list("8080:80, udp:5353:53").unwrap();
        assert_eq!(Forward::list_to_conf(&list), "8080:80,udp:5353:53");
        assert_eq!(list[1].hostfwd(), "udp:127.0.0.1:5353-:53");
        assert!(Forward::parse_list("0").unwrap().is_empty());
        assert!(Forward::parse_list("8080").is_err());
        assert_eq!(Forward::list_to_conf(&[]), "0");
    }
}
