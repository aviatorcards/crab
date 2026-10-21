use crate::boot::{BootOptions, arch_from_name, cmd_boot};
use crate::config::{
    CATALOG_MAX_AGE_DAYS, DISTROS, Paths, file_mtime, fmt_age, host_arch, now_secs,
};
use indicatif::{ProgressBar, ProgressStyle};
use reqwest::blocking::Client;
use reqwest::header::RANGE;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct CatalogEntry {
    pub distro: String,
    pub variant: String,
    pub version: String,
    pub arch: String,
    pub url: String,
    pub sha256: String,
    pub display: String,
}

impl CatalogEntry {
    pub fn to_tsv_line(&self) -> String {
        format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            self.distro,
            self.variant,
            self.version,
            self.arch,
            self.url,
            self.sha256,
            self.display
        )
    }

    pub fn from_tsv_line(line: &str) -> Option<Self> {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 6 {
            return None;
        }
        Some(Self {
            distro: parts[0].to_string(),
            variant: parts[1].to_string(),
            version: parts[2].to_string(),
            arch: parts[3].to_string(),
            url: parts[4].to_string(),
            sha256: parts[5].to_string(),
            display: parts.get(6).copied().unwrap_or("").to_string(),
        })
    }
}

fn http_client() -> Result<Client, String> {
    Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(60))
        .user_agent("crab/0.1")
        .build()
        .map_err(|e| format!("failed to build HTTP client: {e}"))
}

#[derive(Deserialize)]
struct FedoraRelease {
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    arch: Option<String>,
    #[serde(default)]
    link: Option<String>,
    #[serde(default)]
    sha256: Option<String>,
}

fn sync_fedora(client: &Client) -> Result<Vec<CatalogEntry>, String> {
    let releases: Vec<FedoraRelease> = client
        .get("https://getfedora.org/releases.json")
        .send()
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .json()
        .map_err(|e| e.to_string())?;

    let max_ver = releases
        .iter()
        .filter_map(|r| {
            let v = r.version.as_deref()?;
            if v.chars().all(|c| c.is_ascii_digit()) && !v.is_empty() {
                v.parse::<u32>().ok()
            } else {
                None
            }
        })
        .max()
        .ok_or("no numeric fedora version found")?
        .to_string();

    let mut items: Vec<(u8, CatalogEntry)> = Vec::new();
    for r in releases {
        let (Some(version), Some(arch_raw), Some(link), Some(sha256)) =
            (r.version, r.arch, r.link, r.sha256)
        else {
            continue;
        };
        if version != max_ver || (arch_raw != "aarch64" && arch_raw != "x86_64") {
            continue;
        }
        let (order, variant, display) = if link.contains("Workstation-Live") {
            (0, "workstation", "window")
        } else if link.contains("KDE-Desktop-Live") {
            (1, "kde", "window")
        } else if link.contains("Server-dvd") {
            (2, "server", "")
        } else if link.contains("Everything-netinst") {
            (3, "netinst", "")
        } else {
            continue;
        };
        let arch = if arch_raw == "aarch64" { "arm64" } else { "amd64" };
        items.push((
            order,
            CatalogEntry {
                distro: "fedora".into(),
                variant: variant.into(),
                version,
                arch: arch.into(),
                url: link,
                sha256,
                display: display.into(),
            },
        ));
    }
    items.sort_by_key(|(o, _)| *o);
    Ok(items.into_iter().map(|(_, e)| e).collect())
}

fn sync_alpine(client: &Client) -> Result<Vec<CatalogEntry>, String> {
    let mut all = Vec::new();
    for (a, arch) in [("aarch64", "arm64"), ("x86_64", "amd64")] {
        let url = format!(
            "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/{a}/latest-releases.yaml"
        );
        let yaml = client
            .get(&url)
            .send()
            .map_err(|e| e.to_string())?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .text()
            .map_err(|e| e.to_string())?;

        let mut current: HashMap<String, String> = HashMap::new();
        let mut standard = Vec::new();
        let mut rest = Vec::new();

        let flush = |r: &mut HashMap<String, String>,
                     standard: &mut Vec<CatalogEntry>,
                     rest: &mut Vec<CatalogEntry>| {
            if let (Some(file), Some(flavor), Some(version), Some(branch), Some(sha256)) = (
                r.get("file"),
                r.get("flavor"),
                r.get("version"),
                r.get("branch"),
                r.get("sha256"),
            ) {
                if file.ends_with(".iso")
                    && (flavor == "alpine-standard"
                        || flavor == "alpine-virt"
                        || flavor == "alpine-extended")
                {
                    let v = flavor.strip_prefix("alpine-").unwrap_or(flavor);
                    let entry = CatalogEntry {
                        distro: "alpine".into(),
                        variant: v.into(),
                        version: version.clone(),
                        arch: arch.into(),
                        url: format!(
                            "https://dl-cdn.alpinelinux.org/alpine/{branch}/releases/{a}/{file}"
                        ),
                        sha256: sha256.clone(),
                        display: String::new(),
                    };
                    if v == "standard" {
                        standard.push(entry);
                    } else {
                        rest.push(entry);
                    }
                }
            }
            r.clear();
        };

        for line in yaml.lines() {
            if line.starts_with('-') {
                flush(&mut current, &mut standard, &mut rest);
            } else if let Some(stripped) = line.strip_prefix("  ") {
                if let Some((k, v)) = stripped.split_once(": ") {
                    if !k.is_empty() && k.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
                        current.insert(k.to_string(), v.trim().to_string());
                    }
                }
            }
        }
        flush(&mut current, &mut standard, &mut rest);
        all.extend(standard);
        all.extend(rest);
    }
    Ok(all)
}

fn version_key(s: &str) -> Vec<u32> {
    s.split(|c: char| !c.is_ascii_digit())
        .filter(|p| !p.is_empty())
        .filter_map(|p| p.parse::<u32>().ok())
        .collect()
}

fn sync_ubuntu(client: &Client) -> Result<Vec<CatalogEntry>, String> {
    let meta = client
        .get("https://changelogs.ubuntu.com/meta-release-lts")
        .send()
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .text()
        .map_err(|e| e.to_string())?;

    let mut cur_v = String::new();
    let mut supported_v = String::new();
    for line in meta.lines() {
        if let Some(rest) = line.strip_prefix("Version:") {
            if let Some(tok) = rest.split_whitespace().next() {
                cur_v = tok.to_string();
            }
        } else if line.trim() == "Supported: 1" {
            supported_v = cur_v.clone();
        }
    }
    if supported_v.is_empty() {
        return Err("no supported Ubuntu LTS found".into());
    }

    let dir: String = supported_v
        .split('.')
        .take(2)
        .collect::<Vec<_>>()
        .join(".");

    let mut entries = Vec::new();
    for arch in ["amd64", "arm64"] {
        let base = if arch == "amd64" {
            format!("https://releases.ubuntu.com/{dir}")
        } else {
            format!("https://cdimage.ubuntu.com/releases/{dir}/release")
        };
        let sums = client
            .get(format!("{base}/SHA256SUMS"))
            .send()
            .map_err(|e| e.to_string())?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .text()
            .map_err(|e| e.to_string())?;

        for kind in ["desktop", "live-server"] {
            let suffix = format!("-{kind}-{arch}.iso");
            let mut best: Option<(Vec<u32>, String, String)> = None;
            for line in sums.lines() {
                if let Some((sum_part, file_part)) = line.split_once(" *") {
                    if file_part.starts_with("ubuntu-") && file_part.ends_with(&suffix) {
                        let mid = &file_part["ubuntu-".len()..file_part.len() - suffix.len()];
                        if !mid.is_empty() && mid.chars().all(|c| c.is_ascii_digit() || c == '.') {
                            let k = version_key(file_part);
                            if best.as_ref().is_none_or(|(bk, _, _)| k >= *bk) {
                                best = Some((k, sum_part.trim().to_string(), file_part.to_string()));
                            }
                        }
                    }
                }
            }
            if let Some((_, sum, file)) = best {
                let ver = file
                    .strip_prefix("ubuntu-")
                    .and_then(|s| s.strip_suffix(&suffix))
                    .unwrap_or(&dir)
                    .to_string();
                let variant = if kind == "desktop" { "desktop" } else { "server" };
                let display = if kind == "desktop" { "window" } else { "" };
                entries.push(CatalogEntry {
                    distro: "ubuntu".into(),
                    variant: variant.into(),
                    version: ver,
                    arch: arch.into(),
                    url: format!("{base}/{file}"),
                    sha256: sum,
                    display: display.into(),
                });
            }
        }
    }
    Ok(entries)
}

fn sync_openbsd(client: &Client) -> Result<Vec<CatalogEntry>, String> {
    let index = client
        .get("https://cdn.openbsd.org/pub/OpenBSD/")
        .send()
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .text()
        .map_err(|e| e.to_string())?;

    let mut versions: Vec<(u32, u32, String)> = Vec::new();
    let mut search_from = 0;
    while let Some(pos) = index[search_from..].find("href=\"") {
        let start = search_from + pos + 6;
        if let Some(end) = index[start..].find('"') {
            let href = &index[start..start + end];
            if let Some(ver_str) = href.strip_suffix('/') {
                if let Some((maj_s, min_s)) = ver_str.split_once('.') {
                    if !maj_s.is_empty()
                        && !min_s.is_empty()
                        && maj_s.chars().all(|c| c.is_ascii_digit())
                        && min_s.chars().all(|c| c.is_ascii_digit())
                    {
                        if let (Ok(maj), Ok(min)) = (maj_s.parse::<u32>(), min_s.parse::<u32>()) {
                            let v = ver_str.to_string();
                            if !versions.iter().any(|(_, _, s)| s == &v) {
                                versions.push((maj, min, v));
                            }
                        }
                    }
                }
            }
            search_from = start + end + 1;
        } else {
            break;
        }
    }

    versions.sort_by(|a, b| (b.0, b.1).cmp(&(a.0, a.1)));
    versions.truncate(3);

    let mut entries = Vec::new();
    for arch in ["arm64", "amd64"] {
        for (_, _, v) in &versions {
            let short_v = v.replace('.', "");
            let file = if arch == "arm64" {
                format!("install{short_v}.img")
            } else {
                format!("install{short_v}.iso")
            };
            let sums_url = format!("https://cdn.openbsd.org/pub/OpenBSD/{v}/{arch}/SHA256");
            let Ok(resp) = client.get(&sums_url).send() else {
                continue;
            };
            let Ok(resp) = resp.error_for_status() else {
                continue;
            };
            let Ok(sums) = resp.text() else {
                continue;
            };
            let prefix = format!("SHA256 ({file}) = ");
            if let Some(sum) = sums
                .lines()
                .find_map(|l| l.strip_prefix(&prefix))
                .map(|s| s.trim().to_string())
            {
                if !sum.is_empty() {
                    entries.push(CatalogEntry {
                        distro: "openbsd".into(),
                        variant: "install".into(),
                        version: v.clone(),
                        arch: arch.into(),
                        url: format!("https://cdn.openbsd.org/pub/OpenBSD/{v}/{arch}/{file}"),
                        sha256: sum,
                        display: String::new(),
                    });
                    break;
                }
            }
        }
    }
    Ok(entries)
}

pub fn load_catalog(paths: &Paths) -> Vec<CatalogEntry> {
    let Ok(content) = fs::read_to_string(&paths.catalog) else {
        return Vec::new();
    };
    content
        .lines()
        .filter_map(CatalogEntry::from_tsv_line)
        .collect()
}

pub fn cmd_sync(paths: &Paths) -> Result<(), String> {
    fs::create_dir_all(&paths.vm_root)
        .map_err(|e| format!("failed to create {}: {e}", paths.vm_root.display()))?;
    let existing = load_catalog(paths);
    let client = http_client()?;
    let mut new_entries: Vec<CatalogEntry> = Vec::new();

    println!("Checking current releases:");
    for &d in DISTROS {
        print!("  {:<8} ", d);
        let _ = io::stdout().flush();
        let res = match d {
            "fedora" => sync_fedora(&client),
            "ubuntu" => sync_ubuntu(&client),
            "alpine" => sync_alpine(&client),
            "openbsd" => sync_openbsd(&client),
            _ => Err("unknown distro".into()),
        };
        match res {
            Ok(list) if !list.is_empty() => {
                let mut vers = BTreeSet::new();
                for e in &list {
                    vers.insert(e.version.clone());
                }
                let ver_line = vers.into_iter().collect::<Vec<_>>().join(" ");
                println!("{ver_line} ");
                new_entries.extend(list);
            }
            _ => {
                println!("couldn't check; keeping what the catalog had");
                new_entries.extend(existing.iter().filter(|e| e.distro == d).cloned());
            }
        }
    }

    let mut out = String::new();
    for e in &new_entries {
        out.push_str(&e.to_tsv_line());
        out.push('\n');
    }
    fs::write(&paths.catalog, out)
        .map_err(|e| format!("failed to write catalog {}: {e}", paths.catalog.display()))?;
    Ok(())
}

pub fn ensure_catalog(paths: &Paths) -> Result<(), String> {
    if !paths.catalog.is_file() {
        cmd_sync(paths)?;
    } else {
        let mtime = file_mtime(&paths.catalog);
        if mtime < now_secs().saturating_sub(CATALOG_MAX_AGE_DAYS * 86400) {
            println!("The release list is over {CATALOG_MAX_AGE_DAYS} days old; refreshing it.");
            if cmd_sync(paths).is_err() {
                println!("Couldn't refresh it; using the old one.");
            }
        }
    }
    println!();
    Ok(())
}

pub fn default_variant(distro: &str) -> &'static str {
    match distro {
        "fedora" => "workstation",
        "ubuntu" => "desktop",
        "alpine" => "standard",
        "openbsd" => "install",
        _ => "",
    }
}

pub fn get_filename(distro: &str, arch: &str, url: &str) -> String {
    let mut file = url
        .rsplit('/')
        .next()
        .unwrap_or("image.iso")
        .to_string();
    if !file.to_lowercase().contains(distro) {
        file = format!("{distro}-{file}");
    }
    if arch_from_name(&file).is_none() {
        if let Some((stem, ext)) = file.rsplit_once('.') {
            file = format!("{stem}-{arch}.{ext}");
        } else {
            file = format!("{file}-{arch}");
        }
    }
    file
}

pub fn default_mirror_rules() -> Vec<(String, String)> {
    vec![
        (
            "https://download.fedoraproject.org/pub/fedora/".into(),
            "https://mirrors.rit.edu/fedora/fedora/".into(),
        ),
        (
            "https://download.fedoraproject.org/pub/fedora/".into(),
            "https://plug-mirror.rcac.purdue.edu/fedora/fedora/".into(),
        ),
        (
            "https://dl-cdn.alpinelinux.org/alpine/".into(),
            "https://plug-mirror.rcac.purdue.edu/alpine/".into(),
        ),
        (
            "https://releases.ubuntu.com/".into(),
            "https://mirrors.rit.edu/ubuntu-releases/".into(),
        ),
        (
            "https://releases.ubuntu.com/".into(),
            "https://plug-mirror.rcac.purdue.edu/ubuntu-releases/".into(),
        ),
        (
            "https://cdimage.ubuntu.com/".into(),
            "https://mirrors.rit.edu/ubuntu-cdimage/".into(),
        ),
        (
            "https://cdn.openbsd.org/pub/OpenBSD/".into(),
            "https://mirrors.rit.edu/OpenBSD/".into(),
        ),
        (
            "https://cdn.openbsd.org/pub/OpenBSD/".into(),
            "https://plug-mirror.rcac.purdue.edu/openbsd/".into(),
        ),
    ]
}

pub fn mirror_rules(paths: &Paths) -> Vec<(String, String)> {
    if paths.mirrors_file.is_file() {
        if let Ok(content) = fs::read_to_string(&paths.mirrors_file) {
            let mut rules = Vec::new();
            for line in content.lines() {
                let trimmed = line.trim();
                if trimmed.is_empty() || trimmed.starts_with('#') {
                    continue;
                }
                let mut parts = trimmed.split_whitespace();
                if let (Some(off), Some(mir)) = (parts.next(), parts.next()) {
                    rules.push((off.to_string(), mir.to_string()));
                }
            }
            return rules;
        }
    }
    default_mirror_rules()
}

pub fn normalize_mirror_base(input: &str) -> String {
    let trimmed = input.trim().trim_end_matches('/');
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    }
}

/// Probes a mirror root (e.g. `https://mirrors.rit.edu` or `mirrors.example.edu`) by parsing its
/// top-level HTML directory index (and checking well-known paths) to discover which official distro
/// prefixes it mirrors.
pub fn probe_mirror_site(site_input: &str) -> Result<Vec<(String, String)>, String> {
    let base = normalize_mirror_base(site_input);
    let client = http_client()?;
    let index_html = client
        .get(format!("{base}/"))
        .send()
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.text())
        .unwrap_or_default();

    // Extract folder hrefs from HTML directory listing
    let mut dirs = BTreeSet::new();
    let mut search_from = 0;
    while let Some(pos) = index_html[search_from..].find("href=\"") {
        let start = search_from + pos + 6;
        if let Some(end) = index_html[start..].find('"') {
            let href = &index_html[start..start + end];
            if let Some(dir_name) = href.strip_suffix('/') {
                if !dir_name.is_empty() && !dir_name.contains('/') && !dir_name.starts_with('.') {
                    dirs.insert(dir_name.to_string());
                }
            }
            search_from = start + end + 1;
        } else {
            break;
        }
    }

    let check_url = |url: &str| -> bool {
        client
            .head(url)
            .send()
            .map(|r| r.status().is_success())
            .unwrap_or_else(|_| {
                client
                    .get(url)
                    .send()
                    .map(|r| r.status().is_success())
                    .unwrap_or(false)
            })
    };

    let mut discovered = Vec::new();

    // Fedora
    if dirs.contains("fedora") || check_url(&format!("{base}/fedora/")) {
        if check_url(&format!("{base}/fedora/fedora/linux/")) {
            discovered.push((
                "https://download.fedoraproject.org/pub/fedora/".to_string(),
                format!("{base}/fedora/fedora/"),
            ));
        } else if check_url(&format!("{base}/fedora/linux/")) {
            discovered.push((
                "https://download.fedoraproject.org/pub/fedora/".to_string(),
                format!("{base}/fedora/"),
            ));
        }
    }

    // Alpine
    if dirs.contains("alpine") || check_url(&format!("{base}/alpine/")) {
        discovered.push((
            "https://dl-cdn.alpinelinux.org/alpine/".to_string(),
            format!("{base}/alpine/"),
        ));
    }

    // Ubuntu Releases
    for cand in ["ubuntu-releases", "ubuntu"] {
        if dirs.contains(cand) || check_url(&format!("{base}/{cand}/")) {
            discovered.push((
                "https://releases.ubuntu.com/".to_string(),
                format!("{base}/{cand}/"),
            ));
            break;
        }
    }

    // Ubuntu CDImage
    if dirs.contains("ubuntu-cdimage") || check_url(&format!("{base}/ubuntu-cdimage/")) {
        discovered.push((
            "https://cdimage.ubuntu.com/".to_string(),
            format!("{base}/ubuntu-cdimage/"),
        ));
    }

    // OpenBSD
    for cand in ["OpenBSD", "openbsd"] {
        if dirs.contains(cand) || check_url(&format!("{base}/{cand}/")) {
            discovered.push((
                "https://cdn.openbsd.org/pub/OpenBSD/".to_string(),
                format!("{base}/{cand}/"),
            ));
            break;
        }
    }

    if discovered.is_empty() {
        return Err(format!(
            "couldn't auto-detect fedora/ubuntu/alpine/openbsd trees on {base} (you can pass an explicit 'OFFICIAL_PREFIX MIRROR_PREFIX' pair)"
        ));
    }

    Ok(discovered)
}

pub fn save_mirror_rules(paths: &Paths, rules: &[(String, String)]) -> io::Result<()> {
    fs::create_dir_all(&paths.vm_root)?;
    let mut out = String::from("# crab mirror mappings (official_prefix mirror_prefix)\n");
    for (off, mir) in rules {
        out.push_str(&format!("{off:<48} {mir}\n"));
    }
    fs::write(&paths.mirrors_file, out)
}

pub fn add_mirror_entry(
    paths: &Paths,
    arg1: &str,
    arg2: Option<&str>,
) -> Result<Vec<(String, String)>, String> {
    let mut rules = mirror_rules(paths);
    let added = if let Some(mir) = arg2 {
        let off = if arg1.ends_with('/') {
            arg1.to_string()
        } else {
            format!("{arg1}/")
        };
        let m = if mir.ends_with('/') {
            mir.to_string()
        } else {
            format!("{mir}/")
        };
        vec![(off, m)]
    } else {
        println!("Probing mirror {}...", arg1);
        probe_mirror_site(arg1)?
    };

    for pair in &added {
        if !rules.contains(pair) {
            rules.push(pair.clone());
        }
    }
    save_mirror_rules(paths, &rules).map_err(|e| format!("failed to save mirrors: {e}"))?;
    Ok(added)
}

pub fn remove_mirror_matching(paths: &Paths, pattern: &str) -> Result<usize, String> {
    let rules = mirror_rules(paths);
    let orig_len = rules.len();
    let kept: Vec<(String, String)> = rules
        .into_iter()
        .filter(|(off, mir)| !off.contains(pattern) && !mir.contains(pattern))
        .collect();
    let removed = orig_len.saturating_sub(kept.len());
    save_mirror_rules(paths, &kept).map_err(|e| format!("failed to save mirrors: {e}"))?;
    Ok(removed)
}

#[derive(Clone, Debug)]
pub struct RssReleaseItem {
    pub title: String,
    pub link: String,
    pub pub_date: String,
}

/// Fetches and parses an RSS/Atom feed (e.g., DistroWatch ISO feed or a custom mirror RSS feed)
pub fn fetch_rss_feed(feed_url: &str) -> Result<Vec<RssReleaseItem>, String> {
    let client = http_client()?;
    let xml = client
        .get(feed_url)
        .send()
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .text()
        .map_err(|e| e.to_string())?;

    let mut items = Vec::new();
    for chunk in xml.split("<item").skip(1) {
        let end = chunk.find("</item>").unwrap_or(chunk.len());
        let body = &chunk[..end];
        let title = extract_xml_tag(body, "title").unwrap_or_default();
        let link = extract_xml_tag(body, "link").unwrap_or_default();
        let pub_date = extract_xml_tag(body, "pubDate")
            .or_else(|| extract_xml_tag(body, "dc:date"))
            .unwrap_or_default();
        if !title.is_empty() {
            items.push(RssReleaseItem {
                title,
                link,
                pub_date,
            });
        }
    }
    Ok(items)
}

fn extract_xml_tag(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&close)? + start;
    let raw = xml[start..end].trim();
    let cleaned = raw
        .strip_prefix("<![CDATA[")
        .and_then(|s| s.strip_suffix("]]>"))
        .unwrap_or(raw);
    Some(cleaned.trim().to_string())
}

pub fn cmd_mirrors(paths: &Paths, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        let source_note = if paths.mirrors_file.is_file() {
            format!("from {}", paths.mirrors_file.display())
        } else {
            "built-in defaults (run 'crab mirrors add <host>' to customize)".to_string()
        };
        println!("Configured mirrors ({source_note}):");
        for (off, mir) in mirror_rules(paths) {
            println!("  {off:<46} -> {mir}");
        }
        return Ok(());
    }

    match args[0].as_str() {
        "add" => {
            if args.len() < 2 || args.len() > 3 {
                return Err(
                    "usage: crab mirrors add <MIRROR_HOST_OR_URL>  OR  crab mirrors add <OFFICIAL_PREFIX> <MIRROR_PREFIX>".into(),
                );
            }
            let added = add_mirror_entry(paths, &args[1], args.get(2).map(String::as_str))?;
            for (off, mir) in added {
                println!("Added mirror rule: {off} -> {mir}");
            }
            Ok(())
        }
        "remove" | "rm" => {
            if args.len() != 2 {
                return Err("usage: crab mirrors remove <HOST_OR_SUBSTRING>".into());
            }
            let n = remove_mirror_matching(paths, &args[1])?;
            println!("Removed {n} matching mirror rule(s).");
            Ok(())
        }
        "reset" => {
            if paths.mirrors_file.is_file() {
                fs::remove_file(&paths.mirrors_file).map_err(|e| e.to_string())?;
            }
            println!("Reset mirrors to built-in defaults.");
            Ok(())
        }
        "rss" => {
            let url = args
                .get(1)
                .map(String::as_str)
                .unwrap_or("https://distrowatch.com/news/dwd.xml");
            println!("Fetching release RSS feed from {url}...");
            let items = fetch_rss_feed(url)?;
            for item in items.iter().take(15) {
                if item.pub_date.is_empty() {
                    println!("  • {}  ({})", item.title, item.link);
                } else {
                    println!("  • [{}] {}  ({})", item.pub_date, item.title, item.link);
                }
            }
            Ok(())
        }
        other => Err(format!(
            "unknown mirrors action '{other}' (try: crab mirrors [add|remove|reset|rss])"
        )),
    }
}

pub fn sources_for(paths: &Paths, url: &str) -> Vec<String> {
    let mut out = Vec::new();
    for (official, mirror) in mirror_rules(paths) {
        if let Some(rest) = url.strip_prefix(&official) {
            out.push(format!("{mirror}{rest}"));
        }
    }
    out.push(url.to_string());
    out
}

pub fn sha256_of_file(path: &Path) -> io::Result<String> {
    let mut f = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn host_from_url(url: &str) -> String {
    url.split("://")
        .nth(1)
        .and_then(|s| s.split('/').next())
        .unwrap_or(url)
        .to_string()
}

pub fn download_image(
    paths: &Paths,
    url: &str,
    sum: &str,
    file: &str,
    dry_run: bool,
) -> Result<PathBuf, String> {
    let dest = paths.search_dir.join(file);
    let part = paths.search_dir.join(format!("{file}.part"));

    if dest.is_file() {
        let actual = sha256_of_file(&dest).map_err(|e| e.to_string())?;
        if actual.eq_ignore_ascii_case(sum) {
            println!("Already downloaded: {}", dest.display());
            return Ok(dest);
        }
        return Err(format!(
            "{} is there but doesn't match the release checksum; move it aside first",
            dest.display()
        ));
    }

    let sources = sources_for(paths, url);
    if dry_run {
        println!("Would download {file}, trying in order:");
        for s in &sources {
            println!("  {s}");
        }
        return Ok(dest);
    }

    fs::create_dir_all(&paths.search_dir).map_err(|e| e.to_string())?;

    let client = Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .user_agent("crab/0.1")
        .build()
        .map_err(|e| e.to_string())?;

    for src in &sources {
        let host = host_from_url(src);
        println!("Downloading {file} from {host}");

        let existing_len = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        let mut req = client.get(src);
        if existing_len > 0 {
            req = req.header(RANGE, format!("bytes={existing_len}-"));
        }

        let mut finished = true;
        match req.send() {
            Ok(mut resp) => {
                let status = resp.status();
                if !status.is_success() && status.as_u16() != 206 {
                    finished = false;
                    println!("  couldn't get it from {host}");
                } else {
                    let append = status.as_u16() == 206 && existing_len > 0;
                    let total_bytes = resp
                        .content_length()
                        .map(|cl| if append { existing_len + cl } else { cl })
                        .unwrap_or(0);

                    let pb = if total_bytes > 0 {
                        let pb = ProgressBar::new(total_bytes);
                        pb.set_style(
                            ProgressStyle::with_template(
                                "{bar:50.cyan/blue} {bytes}/{total_bytes} ({eta})",
                            )
                            .unwrap()
                            .progress_chars("##-"),
                        );
                        if append {
                            pb.set_position(existing_len);
                        }
                        pb
                    } else {
                        ProgressBar::new_spinner()
                    };

                    let file_res = if append {
                        fs::OpenOptions::new().create(true).append(true).open(&part)
                    } else {
                        fs::File::create(&part)
                    };

                    match file_res {
                        Ok(mut out_f) => {
                            let mut buf = [0u8; 64 * 1024];
                            loop {
                                match resp.read(&mut buf) {
                                    Ok(0) => break,
                                    Ok(n) => {
                                        if out_f.write_all(&buf[..n]).is_err() {
                                            finished = false;
                                            break;
                                        }
                                        pb.inc(n as u64);
                                    }
                                    Err(_) => {
                                        finished = false;
                                        println!("  couldn't get it from {host}");
                                        break;
                                    }
                                }
                            }
                            pb.finish_and_clear();
                        }
                        Err(_) => {
                            finished = false;
                            pb.finish_and_clear();
                            println!("  couldn't get it from {host}");
                        }
                    }
                }
            }
            Err(_) => {
                finished = false;
                println!("  couldn't get it from {host}");
            }
        }

        if !part.is_file() {
            continue;
        }
        if let Ok(actual) = sha256_of_file(&part) {
            if actual.eq_ignore_ascii_case(sum) {
                fs::rename(&part, &dest).map_err(|e| e.to_string())?;
                println!("Checksum OK: {}", dest.display());
                return Ok(dest);
            }
        }
        if finished {
            println!("  the file from {host} doesn't match the checksum; discarding it");
            let _ = fs::remove_file(&part);
        }
    }

    Err(format!(
        "couldn't download {file} from any source (a partial download is kept as {})",
        part.display()
    ))
}

pub fn cmd_get_list(paths: &Paths, arch: &str) {
    let age = fmt_age(file_mtime(&paths.catalog));
    println!(
        "Available for {arch}, last checked {age} (crab sync to refresh, -a for other architectures):"
    );
    for entry in load_catalog(paths) {
        if entry.arch != arch {
            continue;
        }
        let file = get_filename(&entry.distro, &entry.arch, &entry.url);
        let mut marks = Vec::new();
        if paths.search_dir.join(&file).is_file() {
            marks.push("downloaded");
        }
        if entry.variant == default_variant(&entry.distro) {
            marks.push("default");
        }
        let mark_str = if marks.is_empty() {
            String::new()
        } else {
            format!("({})", marks.join(", "))
        };
        let dv = format!("{}/{}", entry.distro, entry.variant);
        println!("  {:<22} {:<9} {:<46} {}", dv, entry.version, file, mark_str);
    }
}

pub fn cmd_get(paths: &Paths, opts: &BootOptions, spec: Option<&str>) -> Result<(), String> {
    let arch = opts
        .arch
        .as_deref()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| host_arch());
    ensure_catalog(paths)?;

    let Some(spec_str) = spec.filter(|s| !s.is_empty()) else {
        cmd_get_list(paths, arch);
        return Ok(());
    };

    let (distro_raw, variant_opt) = match spec_str.split_once('/') {
        Some((d, v)) => (d, (!v.is_empty()).then_some(v)),
        None => (spec_str, None),
    };
    let distro = distro_raw.to_lowercase();
    if !DISTROS.contains(&distro.as_str()) {
        return Err(format!(
            "don't know how to get '{distro}' (I know: {})",
            DISTROS.join(" ")
        ));
    }
    let variant = variant_opt.unwrap_or_else(|| default_variant(&distro));

    let catalog = load_catalog(paths);
    let found = catalog
        .iter()
        .find(|e| e.distro == distro && e.variant == variant && e.arch == arch);

    let Some(entry) = found else {
        eprintln!("No {distro}/{variant} for {arch} in the release list. What there is for {distro}:");
        for e in catalog.iter().filter(|e| e.distro == distro) {
            eprintln!("  {}/{} ({})", e.distro, e.variant, e.arch);
        }
        std::process::exit(1);
    };

    let file = get_filename(&distro, arch, &entry.url);
    println!("{distro}/{variant} {} for {arch}", entry.version);

    let image_path = download_image(paths, &entry.url, &entry.sha256, &file, opts.dry_run)?;
    if opts.download_only {
        return Ok(());
    }
    println!();

    let mut boot_opts = opts.clone();
    boot_opts.known_arch = Some(arch.to_string());
    if boot_opts.display.is_none() && !entry.display.is_empty() {
        boot_opts.display = Some(entry.display.clone());
    }

    cmd_boot(paths, &boot_opts, None, Some(&image_path))
}
