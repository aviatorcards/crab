use crate::boot::{BootOptions, GuiSpawnedVm, spawn_from_gui};
use crate::catalog::{
    CatalogEntry, RssReleaseItem, add_mirror_entry, cmd_sync, default_variant, download_image,
    fetch_rss_feed, get_filename, load_catalog, mirror_rules, remove_mirror_matching,
};
use crate::config::{
    DEFAULT_CPUS, DEFAULT_DISK_SIZE, DEFAULT_MEM, ImageEntry, Paths, disk_kb, fmt_age, fmt_kb,
    host_arch, human_size, list_image_entries,
};
use crate::vm::{
    VmEntry, check_name, clean_leftover_scratch, create_snapshot, delete_snapshot, delete_vm_dir,
    force_off, list_vm_entries, qemu_img_snapshots, request_shutdown, restore_snapshot, vm_state,
};
use iced::border::Radius;
use iced::widget::{
    Column, Container, button, checkbox, column, container, horizontal_space, pick_list, row,
    scrollable, text, text_input, vertical_space,
};
use iced::{Alignment, Background, Border, Color, Element, Length, Padding, Shadow, Subscription, Task, Theme, Vector, time};
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewPage {
    Bucket,   // Unified Saved VMs + Local Images view
    Releases, // Distro catalog downloader
    Mirrors,  // Mirrors & RSS configuration
}

#[derive(Debug, Clone)]
pub enum Message {
    SwitchPage(ViewPage),
    Refresh,
    Tick,
    // Search directory settings
    SearchDirInputChanged(String),
    SaveSearchDir,
    BrowseSearchDir,
    SearchDirPicked(Option<PathBuf>),
    // Settings overrides
    MemChanged(String),
    CpusChanged(String),
    DiskSizeChanged(String),
    SshPortChanged(String),
    FirmwareSelected(String),
    ArchSelected(String),
    GpuSelected(String),
    KeepToggled(bool),
    LiveToggled(bool),
    FullscreenToggled(bool),
    NamedVmInputChanged(String),
    // VM actions
    SelectVm(String),
    BootVm(String),
    StopVm(String),
    KillVm(String),
    ConfirmDeleteVm(String),
    CancelDeleteVm,
    ExecuteDeleteVm(String),
    SnapshotInputChanged(String),
    CreateSnapshot(String),
    RestoreSnapshot(String, String),
    DeleteSnapshot(String, String),
    CleanScratch,
    // Image actions
    BrowseIso,
    IsoPicked(Option<PathBuf>),
    BootImage(PathBuf),
    ConfirmDeleteImage(PathBuf),
    CancelDeleteImage,
    ExecuteDeleteImage(PathBuf),
    // Catalog / Releases actions
    SyncCatalog,
    SyncFinished(Result<(), String>),
    DownloadRelease(CatalogEntry, bool), // (entry, boot_after)
    DownloadFinished(Result<(CatalogEntry, PathBuf, bool), String>),
    // Mirrors & RSS actions
    MirrorHostInputChanged(String),
    MirrorOfficialInputChanged(String),
    AddMirrorByProbe,
    AddMirrorExplicit,
    MirrorProbeFinished(Result<Vec<(String, String)>, String>),
    RemoveMirrorRule(String),
    ResetMirrors,
    RssUrlInputChanged(String),
    FetchRss,
    RssFetched(Result<Vec<RssReleaseItem>, String>),
    // Throwaway VM exit modal
    KeepThrowawayNameChanged(String),
    ConfirmKeepThrowaway,
    DiscardThrowaway(bool), // bool = also delete ISO
}

struct ActiveSession {
    spawned: GuiSpawnedVm,
}

#[derive(Debug, Clone)]
struct PendingThrowawayPrompt {
    scratch_dir: PathBuf,
    image_path: Option<PathBuf>,
    name_input: String,
    disk_size_human: String,
    disk_used_kb: u64,
    live: bool,
}

pub struct CrabGui {
    paths: Paths,
    page: ViewPage,
    vms: Vec<VmEntry>,
    images: Vec<ImageEntry>,
    catalog: Vec<CatalogEntry>,
    mirrors: Vec<(String, String)>,
    rss_items: Vec<RssReleaseItem>,
    search_dir_input: String,
    mirror_host_input: String,
    mirror_official_input: String,
    rss_url_input: String,
    selected_vm: Option<String>,
    vm_snapshots: Vec<String>,
    snapshot_tag_input: String,
    confirm_delete_vm: Option<String>,
    confirm_delete_image: Option<PathBuf>,
    // Boot options
    mem: String,
    cpus: String,
    disk_size: String,
    ssh_port: String,
    firmware: String,
    arch: String,
    gpu: String,
    keep: bool,
    live: bool,
    fullscreen: bool,
    named_vm_input: String,
    // Status & background
    status_msg: String,
    busy: bool,
    active_sessions: Arc<Mutex<Vec<ActiveSession>>>,
    throwaway_prompt: Option<PendingThrowawayPrompt>,
}

// ---- Palette & Styling Helpers ----

const BG_DARK: Color = Color::from_rgb(0.075, 0.082, 0.102);       // #13151A
const BG_PANEL: Color = Color::from_rgb(0.110, 0.122, 0.149);      // #1C1F26
const BG_CARD: Color = Color::from_rgb(0.137, 0.153, 0.188);       // #232730
const BORDER_SUBTLE: Color = Color::from_rgb(0.215, 0.239, 0.290); // #373D4A
const ACCENT_CRAB: Color = Color::from_rgb(0.918, 0.345, 0.200);   // #EA5833 (Warm crab orange-red)
const ACCENT_BLUE: Color = Color::from_rgb(0.231, 0.510, 0.965);   // #3B82F6
const ACCENT_GREEN: Color = Color::from_rgb(0.133, 0.773, 0.369);  // #22C55E
const DANGER_RED: Color = Color::from_rgb(0.937, 0.267, 0.267);    // #EF4444
const TEXT_MAIN: Color = Color::from_rgb(0.945, 0.961, 0.976);     // #F1F5F9
const TEXT_MUTED: Color = Color::from_rgb(0.580, 0.639, 0.722);    // #94A3B8
const TEXT_DIM: Color = Color::from_rgb(0.420, 0.475, 0.557);      // #6B798E

fn card_style(_theme: &Theme) -> container::Style {
    container::Style {
        background: Some(Background::Color(BG_CARD)),
        border: Border {
            color: BORDER_SUBTLE,
            width: 1.0,
            radius: Radius::from(10.0),
        },
        text_color: Some(TEXT_MAIN),
        shadow: Shadow {
            color: Color::from_rgba(0.0, 0.0, 0.0, 0.25),
            offset: Vector::new(0.0, 2.0),
            blur_radius: 6.0,
        },
    }
}

fn panel_style(_theme: &Theme) -> container::Style {
    container::Style {
        background: Some(Background::Color(BG_PANEL)),
        border: Border {
            color: BORDER_SUBTLE,
            width: 1.0,
            radius: Radius::from(10.0),
        },
        text_color: Some(TEXT_MAIN),
        shadow: Shadow::default(),
    }
}

fn badge_style(bg: Color, fg: Color) -> impl Fn(&Theme) -> container::Style {
    move |_theme: &Theme| container::Style {
        background: Some(Background::Color(bg)),
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            radius: Radius::from(6.0),
        },
        text_color: Some(fg),
        shadow: Shadow::default(),
    }
}

fn pill<'a>(label: impl Into<String>, bg: Color, fg: Color) -> Element<'a, Message> {
    container(text(label.into()).size(11))
        .padding([3, 8])
        .style(badge_style(bg, fg))
        .into()
}

fn nav_btn_style(active: bool) -> impl Fn(&Theme, button::Status) -> button::Style {
    move |_theme: &Theme, status: button::Status| {
        let base_bg = if active {
            ACCENT_CRAB
        } else {
            match status {
                button::Status::Hovered => Color::from_rgb(0.18, 0.20, 0.25),
                _ => Color::TRANSPARENT,
            }
        };
        let border_col = if active { ACCENT_CRAB } else { BORDER_SUBTLE };
        button::Style {
            background: Some(Background::Color(base_bg)),
            text_color: if active { Color::WHITE } else { TEXT_MAIN },
            border: Border {
                color: border_col,
                width: 1.0,
                radius: Radius::from(8.0),
            },
            shadow: Shadow::default(),
        }
    }
}

fn primary_btn_style(_theme: &Theme, status: button::Status) -> button::Style {
    let bg = match status {
        button::Status::Hovered => Color::from_rgb(0.30, 0.58, 1.0),
        button::Status::Pressed => Color::from_rgb(0.18, 0.44, 0.88),
        _ => ACCENT_BLUE,
    };
    button::Style {
        background: Some(Background::Color(bg)),
        text_color: Color::WHITE,
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            radius: Radius::from(7.0),
        },
        shadow: Shadow::default(),
    }
}

fn secondary_btn_style(_theme: &Theme, status: button::Status) -> button::Style {
    let bg = match status {
        button::Status::Hovered => Color::from_rgb(0.22, 0.25, 0.31),
        button::Status::Pressed => Color::from_rgb(0.16, 0.18, 0.22),
        _ => Color::from_rgb(0.18, 0.20, 0.25),
    };
    button::Style {
        background: Some(Background::Color(bg)),
        text_color: TEXT_MAIN,
        border: Border {
            color: BORDER_SUBTLE,
            width: 1.0,
            radius: Radius::from(7.0),
        },
        shadow: Shadow::default(),
    }
}

fn danger_btn_style(_theme: &Theme, status: button::Status) -> button::Style {
    let bg = match status {
        button::Status::Hovered => Color::from_rgba(0.937, 0.267, 0.267, 0.28),
        _ => Color::from_rgba(0.937, 0.267, 0.267, 0.15),
    };
    button::Style {
        background: Some(Background::Color(bg)),
        text_color: Color::from_rgb(0.98, 0.45, 0.45),
        border: Border {
            color: Color::from_rgba(0.937, 0.267, 0.267, 0.4),
            width: 1.0,
            radius: Radius::from(7.0),
        },
        shadow: Shadow::default(),
    }
}

fn danger_solid_btn_style(_theme: &Theme, _status: button::Status) -> button::Style {
    button::Style {
        background: Some(Background::Color(DANGER_RED)),
        text_color: Color::WHITE,
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            radius: Radius::from(7.0),
        },
        shadow: Shadow::default(),
    }
}

impl CrabGui {
    pub fn new(paths: Paths, initial_opts: BootOptions) -> (Self, Task<Message>) {
        let arch = initial_opts
            .arch
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| host_arch().to_string());
        let search_dir_input = paths.search_dir.display().to_string();
        let mut gui = Self {
            paths,
            page: ViewPage::Bucket,
            vms: Vec::new(),
            images: Vec::new(),
            catalog: Vec::new(),
            mirrors: Vec::new(),
            rss_items: Vec::new(),
            search_dir_input,
            mirror_host_input: String::new(),
            mirror_official_input: String::new(),
            rss_url_input: "https://distrowatch.com/news/dwd.xml".to_string(),
            selected_vm: None,
            vm_snapshots: Vec::new(),
            snapshot_tag_input: String::new(),
            confirm_delete_vm: None,
            confirm_delete_image: None,
            mem: initial_opts
                .mem
                .unwrap_or_else(|| DEFAULT_MEM.to_string()),
            cpus: initial_opts
                .cpus
                .unwrap_or_else(|| DEFAULT_CPUS.to_string()),
            disk_size: initial_opts
                .disk_size
                .unwrap_or_else(|| DEFAULT_DISK_SIZE.to_string()),
            ssh_port: initial_opts.ssh_port.unwrap_or_default(),
            firmware: initial_opts
                .firmware
                .unwrap_or_else(|| "auto".to_string()),
            arch,
            gpu: initial_opts.gpu.unwrap_or_else(|| "virtio".to_string()),
            keep: initial_opts.keep,
            live: initial_opts.live,
            fullscreen: initial_opts.fullscreen.as_deref() == Some("on"),
            named_vm_input: String::new(),
            status_msg: "Ready. Boot any saved VM or local ISO/IMG right from the bucket.".to_string(),
            busy: false,
            active_sessions: Arc::new(Mutex::new(Vec::new())),
            throwaway_prompt: None,
        };
        gui.reload_data();
        (gui, Task::none())
    }

    fn reload_data(&mut self) {
        self.vms = list_vm_entries(&self.paths);
        self.images = list_image_entries(&self.paths);
        self.catalog = load_catalog(&self.paths);
        self.mirrors = mirror_rules(&self.paths);
        self.search_dir_input = self.paths.search_dir.display().to_string();
        if let Some(ref sel) = self.selected_vm {
            if let Some(v) = self.vms.iter().find(|v| &v.name == sel) {
                self.vm_snapshots = qemu_img_snapshots(&v.disk);
            } else {
                self.selected_vm = None;
                self.vm_snapshots.clear();
            }
        }
    }

    fn build_boot_options(&self) -> BootOptions {
        BootOptions {
            search_dir: Some(self.paths.search_dir.clone()),
            arch: Some(self.arch.clone()),
            known_arch: None,
            download_only: false,
            keep: self.keep,
            live: self.live,
            mem: Some(self.mem.clone()),
            cpus: Some(self.cpus.clone()),
            disk_size: Some(self.disk_size.clone()),
            ssh_port: if self.ssh_port.trim().is_empty() {
                None
            } else {
                Some(self.ssh_port.trim().to_string())
            },
            // Keep each VM's saved port forwards.
            forwards: None,
            firmware: if self.firmware == "auto" {
                None
            } else {
                Some(self.firmware.clone())
            },
            // Keep each VM's saved display; the GUI opens a window regardless.
            display: None,
            fullscreen: Some(if self.fullscreen { "on" } else { "off" }.to_string()),
            gpu: Some(self.gpu.clone()),
            dry_run: false,
        }
    }

    pub fn title(&self) -> String {
        "Crab — Throwaway QEMU VM Bucket".to_string()
    }

    pub fn subscription(&self) -> Subscription<Message> {
        time::every(Duration::from_millis(800)).map(|_| Message::Tick)
    }

    pub fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::SwitchPage(p) => {
                self.page = p;
                self.reload_data();
            }
            Message::Refresh => {
                self.reload_data();
                self.status_msg = "Refreshed VMs, images, catalog, and mirrors.".to_string();
            }
            Message::SearchDirInputChanged(v) => {
                self.search_dir_input = v;
            }
            Message::SaveSearchDir => {
                let raw = self.search_dir_input.trim();
                let expanded = if let Some(rest) = raw.strip_prefix("~/") {
                    std::env::var("HOME")
                        .map(|h| PathBuf::from(h).join(rest))
                        .unwrap_or_else(|_| PathBuf::from(raw))
                } else {
                    PathBuf::from(raw)
                };
                match self.paths.save_search_dir(expanded.clone()) {
                    Ok(()) => {
                        self.reload_data();
                        self.status_msg = format!(
                            "Updated default ISO search/download folder to {}",
                            expanded.display()
                        );
                    }
                    Err(e) => {
                        self.status_msg = format!("Failed to save search folder: {e}");
                    }
                }
            }
            Message::BrowseSearchDir => {
                let start_dir = self.paths.search_dir.clone();
                return Task::perform(
                    async move {
                        rfd::AsyncFileDialog::new()
                            .set_directory(start_dir)
                            .pick_folder()
                            .await
                            .map(|h| h.path().to_path_buf())
                    },
                    Message::SearchDirPicked,
                );
            }
            Message::SearchDirPicked(Some(folder)) => {
                self.search_dir_input = folder.display().to_string();
                return self.update(Message::SaveSearchDir);
            }
            Message::SearchDirPicked(None) => {}
            Message::Tick => {
                // Pick up VMs started, stopped or paused outside this window too.
                let changed = self.vms.iter().any(|v| {
                    vm_state(&v.dir).unwrap_or_else(|| "stopped".to_string()) != v.state
                });
                if changed {
                    self.reload_data();
                }
                let mut exited_session: Option<ActiveSession> = None;
                if let Ok(mut sessions) = self.active_sessions.lock() {
                    let mut i = 0;
                    while i < sessions.len() {
                        if let Ok(Some(_status)) = sessions[i].spawned.child.try_wait() {
                            exited_session = Some(sessions.remove(i));
                            break;
                        } else {
                            i += 1;
                        }
                    }
                }
                if let Some(sess) = exited_session {
                    self.reload_data();
                    if let Some(scratch) = sess.spawned.scratch_dir {
                        let disk = scratch.join("disk.qcow2");
                        let used_kb = if sess.spawned.live {
                            0
                        } else {
                            disk_kb(&disk)
                        };
                        let disk_size_human = human_size(&disk);
                        if !sess.spawned.live
                            && used_kb < 1024
                            && sess.spawned.image_path.is_none()
                        {
                            let _ = fs::remove_dir_all(&scratch);
                            self.status_msg =
                                "Throwaway VM exited (nothing written to disk; auto-discarded)."
                                    .to_string();
                        } else {
                            self.throwaway_prompt = Some(PendingThrowawayPrompt {
                                scratch_dir: scratch,
                                image_path: sess.spawned.image_path,
                                name_input: sess.spawned.default_name,
                                disk_size_human,
                                disk_used_kb: used_kb,
                                live: sess.spawned.live,
                            });
                        }
                    } else {
                        self.status_msg =
                            format!("VM '{}' stopped.", sess.spawned.default_name);
                    }
                }
            }
            Message::MemChanged(v) => self.mem = v,
            Message::CpusChanged(v) => self.cpus = v,
            Message::DiskSizeChanged(v) => self.disk_size = v,
            Message::SshPortChanged(v) => self.ssh_port = v,
            Message::FirmwareSelected(v) => self.firmware = v,
            Message::ArchSelected(v) => self.arch = v,
            Message::GpuSelected(v) => self.gpu = v,
            Message::KeepToggled(v) => {
                self.keep = v;
                if v {
                    self.live = false;
                }
            }
            Message::LiveToggled(v) => {
                self.live = v;
                if v {
                    self.keep = false;
                }
            }
            Message::FullscreenToggled(v) => self.fullscreen = v,
            Message::NamedVmInputChanged(v) => self.named_vm_input = v,

            Message::SelectVm(name) => {
                if self.selected_vm.as_deref() == Some(&name) {
                    self.selected_vm = None;
                    self.vm_snapshots.clear();
                } else {
                    self.selected_vm = Some(name.clone());
                    if let Some(v) = self.vms.iter().find(|v| v.name == name) {
                        self.vm_snapshots = qemu_img_snapshots(&v.disk);
                        self.mem = v.mem.clone();
                        self.cpus = v.cpus.clone();
                        self.ssh_port = if v.ssh_port == "0" {
                            String::new()
                        } else {
                            v.ssh_port.clone()
                        };
                    }
                }
                self.confirm_delete_vm = None;
            }
            Message::BootVm(name) => {
                let opts = self.build_boot_options();
                match spawn_from_gui(&self.paths, &opts, Some(&name), None, None) {
                    Ok(spawned) => {
                        self.status_msg = format!("Booted VM '{name}'");
                        if let Ok(mut list) = self.active_sessions.lock() {
                            list.push(ActiveSession { spawned });
                        }
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Error booting '{name}': {e}"),
                }
            }
            Message::StopVm(name) => {
                let result = self
                    .vms
                    .iter()
                    .find(|v| v.name == name)
                    .ok_or_else(|| format!("no VM named '{name}'"))
                    .and_then(|v| request_shutdown(&v.dir));
                self.status_msg = match result {
                    Ok(()) => format!("Asked '{name}' to shut down."),
                    Err(e) => format!("Couldn't shut down '{name}': {e}"),
                };
            }
            Message::KillVm(name) => {
                let result = self
                    .vms
                    .iter()
                    .find(|v| v.name == name)
                    .ok_or_else(|| format!("no VM named '{name}'"))
                    .and_then(|v| force_off(&v.dir));
                self.status_msg = match result {
                    Ok(()) => format!("Forced '{name}' off."),
                    Err(e) => format!("Couldn't force '{name}' off: {e}"),
                };
                self.reload_data();
            }
            Message::ConfirmDeleteVm(name) => {
                self.confirm_delete_vm = Some(name);
            }
            Message::CancelDeleteVm => {
                self.confirm_delete_vm = None;
            }
            Message::ExecuteDeleteVm(name) => {
                match delete_vm_dir(&self.paths, &name) {
                    Ok(()) => {
                        self.status_msg = format!("Trashed VM '{name}'.");
                        self.confirm_delete_vm = None;
                        if self.selected_vm.as_deref() == Some(&name) {
                            self.selected_vm = None;
                        }
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Error deleting '{name}': {e}"),
                }
            }
            Message::SnapshotInputChanged(v) => self.snapshot_tag_input = v,
            Message::CreateSnapshot(name) => {
                let tag_opt = (!self.snapshot_tag_input.trim().is_empty())
                    .then(|| self.snapshot_tag_input.trim());
                match create_snapshot(&self.paths, &name, tag_opt) {
                    Ok(tag) => {
                        self.status_msg = format!("Created snapshot '{tag}' for {name}.");
                        self.snapshot_tag_input.clear();
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Snapshot error: {e}"),
                }
            }
            Message::RestoreSnapshot(name, tag) => {
                match restore_snapshot(&self.paths, &name, &tag) {
                    Ok(()) => {
                        self.status_msg = format!("Restored '{name}' to snapshot '{tag}'.");
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Restore error: {e}"),
                }
            }
            Message::DeleteSnapshot(name, tag) => {
                match delete_snapshot(&self.paths, &name, &tag) {
                    Ok(()) => {
                        self.status_msg = format!("Deleted snapshot '{tag}' from '{name}'.");
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Delete snapshot error: {e}"),
                }
            }
            Message::CleanScratch => {
                let (n, kb) = clean_leftover_scratch(&self.paths);
                self.status_msg = format!(
                    "Cleaned {n} leftover scratch VM(s), freed {}.",
                    fmt_kb(kb)
                );
                self.reload_data();
            }
            Message::BrowseIso => {
                let start_dir = self.paths.search_dir.clone();
                return Task::perform(
                    async move {
                        rfd::AsyncFileDialog::new()
                            .set_directory(start_dir)
                            .add_filter("OS Images", &["iso", "img", "ISO", "IMG"])
                            .pick_file()
                            .await
                            .map(|h| h.path().to_path_buf())
                    },
                    Message::IsoPicked,
                );
            }
            Message::IsoPicked(Some(path)) => {
                return self.update(Message::BootImage(path));
            }
            Message::IsoPicked(None) => {}
            Message::BootImage(path) => {
                let opts = self.build_boot_options();
                let named_target = (!self.named_vm_input.trim().is_empty())
                    .then(|| self.named_vm_input.trim());
                match spawn_from_gui(&self.paths, &opts, None, Some(&path), named_target) {
                    Ok(spawned) => {
                        let fname = path
                            .file_name()
                            .map(|s| s.to_string_lossy().to_string())
                            .unwrap_or_default();
                        self.status_msg = format!("Booted '{fname}' in throwaway QEMU VM.");
                        if let Ok(mut list) = self.active_sessions.lock() {
                            list.push(ActiveSession { spawned });
                        }
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Error booting image: {e}"),
                }
            }
            Message::ConfirmDeleteImage(path) => {
                self.confirm_delete_image = Some(path);
            }
            Message::CancelDeleteImage => {
                self.confirm_delete_image = None;
            }
            Message::ExecuteDeleteImage(path) => {
                let fname = path
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_default();
                match fs::remove_file(&path) {
                    Ok(()) => {
                        self.status_msg = format!("Trashed image '{fname}'.");
                        self.confirm_delete_image = None;
                        self.reload_data();
                    }
                    Err(e) => self.status_msg = format!("Failed to delete '{fname}': {e}"),
                }
            }
            Message::SyncCatalog => {
                if self.busy {
                    return Task::none();
                }
                self.busy = true;
                self.status_msg = "Syncing release catalog from upstream indexes...".to_string();
                let paths = self.paths.clone();
                return Task::perform(
                    async move {
                        tokio::task::spawn_blocking(move || cmd_sync(&paths))
                            .await
                            .unwrap()
                    },
                    Message::SyncFinished,
                );
            }
            Message::SyncFinished(res) => {
                self.busy = false;
                match res {
                    Ok(()) => {
                        self.reload_data();
                        self.status_msg = "Release catalog synced.".to_string();
                    }
                    Err(e) => {
                        self.status_msg = format!("Sync failed: {e}");
                    }
                }
            }
            Message::DownloadRelease(entry, boot_after) => {
                if self.busy {
                    return Task::none();
                }
                self.busy = true;
                let file = get_filename(&entry.distro, &entry.arch, &entry.url);
                self.status_msg = format!(
                    "Downloading {}/{} ({}) -> {}...",
                    entry.distro, entry.variant, entry.version, file
                );
                let paths = self.paths.clone();
                return Task::perform(
                    async move {
                        tokio::task::spawn_blocking(move || {
                            let dest =
                                download_image(&paths, &entry.url, &entry.sha256, &file, false)?;
                            Ok((entry, dest, boot_after))
                        })
                        .await
                        .unwrap()
                    },
                    Message::DownloadFinished,
                );
            }
            Message::DownloadFinished(res) => {
                self.busy = false;
                match res {
                    Ok((entry, path, boot_after)) => {
                        self.reload_data();
                        self.status_msg = format!("Downloaded {} ready.", path.display());
                        if boot_after {
                            let mut opts = self.build_boot_options();
                            opts.known_arch = Some(entry.arch.clone());
                            if !entry.display.is_empty() {
                                opts.display = Some(entry.display);
                            }
                            match spawn_from_gui(&self.paths, &opts, None, Some(&path), None) {
                                Ok(spawned) => {
                                    self.status_msg = format!(
                                        "Booted {}/{} in throwaway VM.",
                                        entry.distro, entry.variant
                                    );
                                    if let Ok(mut list) = self.active_sessions.lock() {
                                        list.push(ActiveSession { spawned });
                                    }
                                    self.reload_data();
                                }
                                Err(e) => self.status_msg = format!("Boot error: {e}"),
                            }
                        }
                    }
                    Err(e) => {
                        self.status_msg = format!("Download failed: {e}");
                    }
                }
            }
            // Mirrors & RSS
            Message::MirrorHostInputChanged(v) => self.mirror_host_input = v,
            Message::MirrorOfficialInputChanged(v) => self.mirror_official_input = v,
            Message::AddMirrorByProbe => {
                let host = self.mirror_host_input.trim().to_string();
                if host.is_empty() || self.busy {
                    return Task::none();
                }
                self.busy = true;
                self.status_msg =
                    format!("Probing mirror '{host}' for Fedora/Ubuntu/Alpine/OpenBSD trees...");
                let paths = self.paths.clone();
                return Task::perform(
                    async move {
                        tokio::task::spawn_blocking(move || add_mirror_entry(&paths, &host, None))
                            .await
                            .unwrap()
                    },
                    Message::MirrorProbeFinished,
                );
            }
            Message::AddMirrorExplicit => {
                let off = self.mirror_official_input.trim().to_string();
                let mir = self.mirror_host_input.trim().to_string();
                if off.is_empty() || mir.is_empty() {
                    self.status_msg =
                        "Enter both an official prefix and a mirror URL prefix.".to_string();
                    return Task::none();
                }
                match add_mirror_entry(&self.paths, &off, Some(&mir)) {
                    Ok(_) => {
                        self.mirror_official_input.clear();
                        self.mirror_host_input.clear();
                        self.reload_data();
                        self.status_msg = format!("Added mirror rule: {off} -> {mir}");
                    }
                    Err(e) => self.status_msg = format!("Error adding mirror: {e}"),
                }
            }
            Message::MirrorProbeFinished(res) => {
                self.busy = false;
                match res {
                    Ok(added) => {
                        self.mirror_host_input.clear();
                        self.reload_data();
                        self.status_msg = format!(
                            "Auto-detected and added {} mirror rule(s)!",
                            added.len()
                        );
                    }
                    Err(e) => {
                        self.status_msg = format!("Mirror probe failed: {e}");
                    }
                }
            }
            Message::RemoveMirrorRule(pattern) => {
                match remove_mirror_matching(&self.paths, &pattern) {
                    Ok(n) => {
                        self.reload_data();
                        self.status_msg = format!("Removed {n} mirror rule(s).");
                    }
                    Err(e) => self.status_msg = format!("Error removing mirror: {e}"),
                }
            }
            Message::ResetMirrors => {
                if self.paths.mirrors_file.is_file() {
                    let _ = fs::remove_file(&self.paths.mirrors_file);
                }
                self.reload_data();
                self.status_msg = "Reset mirrors to built-in defaults.".to_string();
            }
            Message::RssUrlInputChanged(v) => self.rss_url_input = v,
            Message::FetchRss => {
                let url = self.rss_url_input.trim().to_string();
                if url.is_empty() || self.busy {
                    return Task::none();
                }
                self.busy = true;
                self.status_msg = format!("Fetching RSS feed from {url}...");
                return Task::perform(
                    async move {
                        tokio::task::spawn_blocking(move || fetch_rss_feed(&url))
                            .await
                            .unwrap()
                    },
                    Message::RssFetched,
                );
            }
            Message::RssFetched(res) => {
                self.busy = false;
                match res {
                    Ok(items) => {
                        self.status_msg = format!("Loaded {} items from RSS feed.", items.len());
                        self.rss_items = items;
                    }
                    Err(e) => {
                        self.status_msg = format!("RSS fetch error: {e}");
                    }
                }
            }
            Message::KeepThrowawayNameChanged(v) => {
                if let Some(ref mut p) = self.throwaway_prompt {
                    p.name_input = v;
                }
            }
            Message::ConfirmKeepThrowaway => {
                if let Some(p) = self.throwaway_prompt.take() {
                    let name = p.name_input.trim().to_string();
                    if let Err(e) = check_name(&name) {
                        self.status_msg = e;
                        self.throwaway_prompt = Some(p);
                        return Task::none();
                    }
                    let dest = self.paths.vm_root.join(&name);
                    if dest.exists() {
                        self.status_msg = format!("There's already a VM called '{name}'.");
                        self.throwaway_prompt = Some(p);
                        return Task::none();
                    }
                    let _ = fs::remove_file(p.scratch_dir.join("qemu.pid"));
                    match fs::rename(&p.scratch_dir, &dest) {
                        Ok(()) => {
                            self.status_msg = format!("Kept throwaway VM as '{name}'.");
                            self.reload_data();
                        }
                        Err(e) => {
                            self.status_msg = format!("Failed to save VM: {e}");
                        }
                    }
                }
            }
            Message::DiscardThrowaway(delete_iso) => {
                if let Some(p) = self.throwaway_prompt.take() {
                    let _ = fs::remove_dir_all(&p.scratch_dir);
                    let mut msg = "Throwaway VM trashed.".to_string();
                    if delete_iso {
                        if let Some(ref img) = p.image_path {
                            if fs::remove_file(img).is_ok() {
                                let fname = img
                                    .file_name()
                                    .map(|s| s.to_string_lossy().to_string())
                                    .unwrap_or_default();
                                msg = format!("Throwaway VM and image '{fname}' trashed.");
                            }
                        }
                    }
                    self.status_msg = msg;
                    self.reload_data();
                }
            }
        }
        Task::none()
    }

    pub fn view(&self) -> Element<'_, Message> {
        let vm_count = self.vms.len();
        let iso_count = self.images.len();

        let header = row![
            column![
                text("CRAB").size(22).color(ACCENT_CRAB),
                text("Throwaway QEMU VM Bucket").size(12).color(TEXT_MUTED),
            ]
            .spacing(1),
            horizontal_space(),
            button(
                text(format!("Bucket ({vm_count} VMs, {iso_count} ISOs)")).size(13)
            )
            .padding([7, 14])
            .style(nav_btn_style(self.page == ViewPage::Bucket))
            .on_press(Message::SwitchPage(ViewPage::Bucket)),
            button(text("Get Distros").size(13))
                .padding([7, 14])
                .style(nav_btn_style(self.page == ViewPage::Releases))
                .on_press(Message::SwitchPage(ViewPage::Releases)),
            button(text("Mirrors & RSS").size(13))
                .padding([7, 14])
                .style(nav_btn_style(self.page == ViewPage::Mirrors))
                .on_press(Message::SwitchPage(ViewPage::Mirrors)),
            button(text("Boot ISO File...").size(13))
                .padding([7, 14])
                .style(primary_btn_style)
                .on_press(Message::BrowseIso),
            button(text("Refresh").size(13))
                .padding([7, 12])
                .style(secondary_btn_style)
                .on_press(Message::Refresh),
        ]
        .spacing(8)
        .align_y(Alignment::Center);

        let settings_bar = self.view_settings_bar();

        let main_area: Element<'_, Message> = if let Some(ref prompt) = self.throwaway_prompt {
            self.view_throwaway_modal(prompt)
        } else {
            match self.page {
                ViewPage::Bucket => self.view_bucket_page(),
                ViewPage::Releases => self.view_releases_page(),
                ViewPage::Mirrors => self.view_mirrors_page(),
            }
        };

        let footer = container(
            row![
                text(&self.status_msg).size(12).color(TEXT_MUTED),
                horizontal_space(),
                button(text("Clean Scratch").size(11))
                    .padding([4, 10])
                    .style(secondary_btn_style)
                    .on_press(Message::CleanScratch),
            ]
            .align_y(Alignment::Center),
        )
        .padding([8, 12])
        .style(panel_style);

        let content = column![
            header,
            settings_bar,
            Container::new(main_area)
                .width(Length::Fill)
                .height(Length::Fill),
            footer,
        ]
        .spacing(14)
        .padding([20, 26]);

        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .style(|_theme| container::Style {
                background: Some(Background::Color(BG_DARK)),
                text_color: Some(TEXT_MAIN),
                ..Default::default()
            })
            .into()
    }

    fn view_settings_bar(&self) -> Element<'_, Message> {
        let fw_options = vec!["auto".to_string(), "uefi".to_string(), "bios".to_string()];
        let arch_options = vec!["arm64".to_string(), "amd64".to_string()];
        let gpu_options = vec!["virtio".to_string(), "ramfb".to_string()];

        let row1 = row![
            text("Launch Settings").size(12).color(ACCENT_CRAB),
            text("RAM").size(12).color(TEXT_MUTED),
            text_input("2G", &self.mem)
                .on_input(Message::MemChanged)
                .size(13)
                .width(Length::Fixed(58.0)),
            text("CPUs").size(12).color(TEXT_MUTED),
            text_input("2", &self.cpus)
                .on_input(Message::CpusChanged)
                .size(13)
                .width(Length::Fixed(42.0)),
            text("New Disk").size(12).color(TEXT_MUTED),
            text_input("20G", &self.disk_size)
                .on_input(Message::DiskSizeChanged)
                .size(13)
                .width(Length::Fixed(58.0)),
            text("SSH Port").size(12).color(TEXT_MUTED),
            text_input("off", &self.ssh_port)
                .on_input(Message::SshPortChanged)
                .size(13)
                .width(Length::Fixed(58.0)),
            text("Arch").size(12).color(TEXT_MUTED),
            pick_list(arch_options, Some(self.arch.clone()), Message::ArchSelected).text_size(12),
            text("FW").size(12).color(TEXT_MUTED),
            pick_list(
                fw_options,
                Some(self.firmware.clone()),
                Message::FirmwareSelected
            )
            .text_size(12),
            text("GPU").size(12).color(TEXT_MUTED),
            pick_list(gpu_options, Some(self.gpu.clone()), Message::GpuSelected).text_size(12),
        ]
        .spacing(8)
        .align_y(Alignment::Center);

        let mut row2 = row![
            checkbox("Keep straight away (-k)", self.keep)
                .size(14)
                .text_size(12)
                .on_toggle(Message::KeepToggled),
            checkbox("Live CD only / no disk (-l)", self.live)
                .size(14)
                .text_size(12)
                .on_toggle(Message::LiveToggled),
            checkbox("Full screen (-F)", self.fullscreen)
                .size(14)
                .text_size(12)
                .on_toggle(Message::FullscreenToggled),
        ]
        .spacing(18)
        .align_y(Alignment::Center);

        if self.keep {
            row2 = row2
                .push(text("Save VM As:").size(12).color(TEXT_MUTED))
                .push(
                    text_input("default from ISO name...", &self.named_vm_input)
                        .on_input(Message::NamedVmInputChanged)
                        .size(12)
                        .width(Length::Fixed(170.0)),
                );
        }

        container(column![row1, row2].spacing(8))
            .padding([10, 14])
            .width(Length::Fill)
            .style(panel_style)
            .into()
    }

    fn view_throwaway_modal<'a>(
        &'a self,
        prompt: &'a PendingThrowawayPrompt,
    ) -> Element<'a, Message> {
        let mut col = column![
            text("Throwaway VM Exited").size(22).color(TEXT_MAIN),
            text(format!(
                "Scratch disk usage: {} ({} KB written)",
                prompt.disk_size_human, prompt.disk_used_kb
            ))
            .size(14)
            .color(TEXT_MUTED),
        ]
        .spacing(14);

        if !prompt.live && prompt.disk_used_kb >= 1024 {
            col = col.push(
                container(
                    row![
                        text("Keep as Saved VM:").size(14),
                        text_input("VM name", &prompt.name_input)
                            .on_input(Message::KeepThrowawayNameChanged)
                            .width(Length::Fixed(240.0)),
                        button(text("Keep in ~/VMs").size(13))
                            .padding([7, 14])
                            .style(primary_btn_style)
                            .on_press(Message::ConfirmKeepThrowaway),
                    ]
                    .spacing(10)
                    .align_y(Alignment::Center),
                )
                .padding(12)
                .style(panel_style),
            );
        } else if !prompt.live {
            col = col.push(
                text("Nothing significant was written to the disk (< 1 MB).")
                    .size(13)
                    .color(TEXT_DIM),
            );
        }

        let mut discard_row = row![
            button(text("Trash Throwaway VM").size(13))
                .padding([8, 16])
                .style(danger_btn_style)
                .on_press(Message::DiscardThrowaway(false)),
        ]
        .spacing(12);

        if let Some(ref img) = prompt.image_path {
            if img.is_file() {
                let fname = img
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_default();
                discard_row = discard_row.push(
                    button(text(format!("Trash VM + Delete '{fname}'")).size(13))
                        .padding([8, 16])
                        .style(danger_solid_btn_style)
                        .on_press(Message::DiscardThrowaway(true)),
                );
            }
        }

        col = col.push(discard_row);
        container(col).padding(24).style(card_style).into()
    }

    /// Unified Bucket view showing BOTH Saved VMs and Local Images (.iso/.img) on one screen!
    fn view_bucket_page(&self) -> Element<'_, Message> {
        let mut page_col = Column::new().spacing(14);

        // ---- SECTION 1: SAVED VMS ----
        let vms_header = row![
            text("SAVED VMs").size(13).color(TEXT_MUTED),
            pill(
                format!("{} in {}", self.vms.len(), self.paths.vm_root.display()),
                BG_PANEL,
                TEXT_DIM
            ),
        ]
        .spacing(8)
        .align_y(Alignment::Center);

        page_col = page_col.push(vms_header);

        if self.vms.is_empty() {
            page_col = page_col.push(
                container(
                    text("No saved VMs yet. Boot any ISO below and choose to keep it when QEMU exits!")
                        .size(13)
                        .color(TEXT_DIM),
                )
                .padding(14)
                .width(Length::Fill)
                .style(panel_style),
            );
        } else {
            let mut vms_list = Column::new().spacing(8);
            for v in &self.vms {
                let is_running = v.running_pid.is_some();
                let status_pill = if let Some(pid) = v.running_pid {
                    pill(
                        format!("{} ({pid})", v.state.to_uppercase()),
                        Color::from_rgba(0.133, 0.773, 0.369, 0.18),
                        ACCENT_GREEN,
                    )
                } else {
                    pill("STOPPED", BG_PANEL, TEXT_MUTED)
                };

                let arch_pill = pill(
                    v.arch.to_uppercase(),
                    Color::from_rgba(0.231, 0.510, 0.965, 0.16),
                    Color::from_rgb(0.55, 0.75, 1.0),
                );
                let fw_pill = pill(v.firmware.to_uppercase(), BG_PANEL, TEXT_MUTED);

                let mut meta_text = format!(
                    "{} RAM  •  {} CPUs  •  Disk: {} of {}  •  {} snap(s)  •  used {}",
                    v.mem,
                    v.cpus,
                    v.disk_used,
                    v.disk_virt,
                    v.snaps_count,
                    fmt_age(v.last_used_secs),
                );
                if !v.ssh_port.is_empty() && v.ssh_port != "0" {
                    meta_text.push_str(&format!("  •  ssh localhost:{}", v.ssh_port));
                }

                let title_row = row![text(&v.name).size(16), arch_pill, fw_pill, status_pill]
                    .spacing(8)
                    .align_y(Alignment::Center);

                let mut action_row = row![
                    column![title_row, text(meta_text).size(12).color(TEXT_MUTED)].spacing(4),
                    horizontal_space(),
                ]
                .spacing(8)
                .align_y(Alignment::Center);

                if is_running {
                    action_row = action_row
                        .push(
                            button(text("Shut Down").size(12))
                                .padding([6, 12])
                                .style(secondary_btn_style)
                                .on_press(Message::StopVm(v.name.clone())),
                        )
                        .push(
                            button(text("Force Off").size(12))
                                .padding([6, 12])
                                .style(danger_btn_style)
                                .on_press(Message::KillVm(v.name.clone())),
                        );
                } else {
                    action_row = action_row
                        .push(
                            button(text("Boot VM").size(12))
                                .padding([6, 14])
                                .style(primary_btn_style)
                                .on_press(Message::BootVm(v.name.clone())),
                        )
                        .push(
                            button(text(format!("Snapshots ({})", v.snaps_count)).size(12))
                                .padding([6, 12])
                                .style(secondary_btn_style)
                                .on_press(Message::SelectVm(v.name.clone())),
                        );

                    if self.confirm_delete_vm.as_deref() == Some(&v.name) {
                        action_row = action_row
                            .push(
                                button(text("Confirm Trash").size(12))
                                    .padding([6, 12])
                                    .style(danger_solid_btn_style)
                                    .on_press(Message::ExecuteDeleteVm(v.name.clone())),
                            )
                            .push(
                                button(text("Cancel").size(12))
                                    .padding([6, 10])
                                    .style(secondary_btn_style)
                                    .on_press(Message::CancelDeleteVm),
                            );
                    } else {
                        action_row = action_row.push(
                            button(text("Trash").size(12))
                                .padding([6, 12])
                                .style(danger_btn_style)
                                .on_press(Message::ConfirmDeleteVm(v.name.clone())),
                        );
                    }
                }

                let mut card_col = column![action_row].spacing(8);

                if self.selected_vm.as_deref() == Some(&v.name) {
                    let mut snap_box = column![
                        row![
                            text("Disk Snapshots").size(13).color(TEXT_MUTED),
                            text_input("tag (optional, default timestamp)", &self.snapshot_tag_input)
                                .on_input(Message::SnapshotInputChanged)
                                .size(12)
                                .width(Length::Fixed(210.0)),
                            button(text("+ Snapshot").size(12))
                                .padding([5, 10])
                                .style(secondary_btn_style)
                                .on_press(Message::CreateSnapshot(v.name.clone())),
                        ]
                        .spacing(8)
                        .align_y(Alignment::Center)
                    ]
                    .spacing(6);

                    if self.vm_snapshots.is_empty() {
                        snap_box = snap_box
                            .push(text("No snapshots saved yet.").size(12).color(TEXT_DIM));
                    } else {
                        for tag in &self.vm_snapshots {
                            snap_box = snap_box.push(
                                row![
                                    text(format!("• {tag}")).size(12),
                                    horizontal_space(),
                                    button(text("Restore").size(11))
                                        .padding([3, 8])
                                        .style(secondary_btn_style)
                                        .on_press(Message::RestoreSnapshot(
                                            v.name.clone(),
                                            tag.clone()
                                        )),
                                    button(text("Delete").size(11))
                                        .padding([3, 8])
                                        .style(danger_btn_style)
                                        .on_press(Message::DeleteSnapshot(
                                            v.name.clone(),
                                            tag.clone()
                                        )),
                                ]
                                .spacing(6)
                                .align_y(Alignment::Center),
                            );
                        }
                    }
                    card_col = card_col.push(
                        container(snap_box)
                            .padding(10)
                            .width(Length::Fill)
                            .style(panel_style),
                    );
                }

                vms_list = vms_list.push(
                    container(card_col)
                        .padding([12, 14])
                        .width(Length::Fill)
                        .style(card_style),
                );
            }
            page_col = page_col.push(vms_list);
        }

        page_col = page_col.push(vertical_space().height(4));

        // ---- SECTION 2: LOCAL IMAGES (.ISO / .IMG) ----
        let total_iso_kb: u64 = self.images.iter().map(|i| i.size_kb).sum();
        let images_header = row![
            text("LOCAL OS IMAGES (.ISO / .IMG)")
                .size(13)
                .color(TEXT_MUTED),
            pill(
                format!("{} files ({})", self.images.len(), fmt_kb(total_iso_kb)),
                BG_PANEL,
                TEXT_DIM,
            ),
            horizontal_space(),
            text("Folder:").size(12).color(TEXT_MUTED),
            text_input("~/Downloads", &self.search_dir_input)
                .on_input(Message::SearchDirInputChanged)
                .size(12)
                .width(Length::Fixed(220.0)),
            button(text("Save").size(11))
                .padding([4, 10])
                .style(secondary_btn_style)
                .on_press(Message::SaveSearchDir),
            button(text("Choose...").size(11))
                .padding([4, 10])
                .style(secondary_btn_style)
                .on_press(Message::BrowseSearchDir),
        ]
        .spacing(8)
        .align_y(Alignment::Center);

        page_col = page_col.push(images_header);

        if self.images.is_empty() {
            page_col = page_col.push(
                container(
                    text(format!(
                        "No .iso or .img files found in {}. Click 'Get Distros' to download one or change the folder above.",
                        self.paths.search_dir.display()
                    ))
                    .size(13)
                    .color(TEXT_DIM),
                )
                .padding(14)
                .width(Length::Fill)
                .style(panel_style),
            );
        } else {
            let mut img_list = Column::new().spacing(8);
            for img in &self.images {
                let booted_badge = match img.last_booted_secs {
                    Some(t) => pill(
                        format!("booted {}", fmt_age(t)),
                        Color::from_rgba(0.133, 0.773, 0.369, 0.14),
                        ACCENT_GREEN,
                    ),
                    None => pill("unbooted", BG_PANEL, TEXT_DIM),
                };
                let size_badge = pill(&img.size_human, BG_PANEL, TEXT_MUTED);

                let mut sub = format!("downloaded {}", fmt_age(img.downloaded_secs));
                if !img.file_info.is_empty() {
                    sub.push_str(&format!("  •  {}", img.file_info));
                }

                let top_line = row![text(&img.name).size(15), size_badge, booted_badge]
                    .spacing(8)
                    .align_y(Alignment::Center);

                let mut r = row![
                    column![top_line, text(sub).size(12).color(TEXT_MUTED)].spacing(3),
                    horizontal_space(),
                    button(text("Boot Throwaway").size(12))
                        .padding([6, 14])
                        .style(primary_btn_style)
                        .on_press(Message::BootImage(img.path.clone())),
                ]
                .spacing(8)
                .align_y(Alignment::Center);

                if self.confirm_delete_image.as_ref() == Some(&img.path) {
                    r = r
                        .push(
                            button(text("Confirm Trash ISO").size(12))
                                .padding([6, 12])
                                .style(danger_solid_btn_style)
                                .on_press(Message::ExecuteDeleteImage(img.path.clone())),
                        )
                        .push(
                            button(text("Cancel").size(12))
                                .padding([6, 10])
                                .style(secondary_btn_style)
                                .on_press(Message::CancelDeleteImage),
                        );
                } else {
                    r = r.push(
                        button(text("Trash ISO").size(12))
                            .padding([6, 12])
                            .style(danger_btn_style)
                            .on_press(Message::ConfirmDeleteImage(img.path.clone())),
                    );
                }

                img_list = img_list.push(
                    container(r)
                        .padding([10, 14])
                        .width(Length::Fill)
                        .style(card_style),
                );
            }
            page_col = page_col.push(img_list);
        }

        scrollable(
            container(page_col).padding(Padding {
                top: 2.0,
                right: 22.0,
                bottom: 8.0,
                left: 2.0,
            }),
        )
        .height(Length::Fill)
        .into()
    }

    fn view_releases_page(&self) -> Element<'_, Message> {
        let top_bar = row![
            column![
                text(format!("Official Release Catalog ({})", self.arch)).size(16),
                text(format!(
                    "Downloads are saved to {} and verified with official SHA-256 checksums",
                    self.paths.search_dir.display()
                ))
                .size(12)
                .color(TEXT_MUTED),
            ]
            .spacing(2),
            horizontal_space(),
            button(
                text(if self.busy {
                    "Syncing..."
                } else {
                    "Sync Release Catalog"
                })
                .size(13)
            )
            .padding([7, 14])
            .style(primary_btn_style)
            .on_press(Message::SyncCatalog),
        ]
        .align_y(Alignment::Center);

        let mut col = column![top_bar].spacing(10);

        let filtered: Vec<&CatalogEntry> = self
            .catalog
            .iter()
            .filter(|e| e.arch == self.arch)
            .collect();

        if filtered.is_empty() {
            col = col.push(
                container(
                    text("Catalog is empty for this architecture. Click 'Sync Release Catalog' to fetch current releases.")
                        .size(13)
                        .color(TEXT_MUTED),
                )
                .padding(16)
                .width(Length::Fill)
                .style(panel_style),
            );
        } else {
            for entry in filtered {
                let file = get_filename(&entry.distro, &entry.arch, &entry.url);
                let downloaded = self.paths.search_dir.join(&file).is_file();
                let is_def = entry.variant == default_variant(&entry.distro);

                let mut title_row = row![
                    text(format!("{}/{}", entry.distro, entry.variant)).size(16),
                    pill(format!("v{}", entry.version), BG_PANEL, TEXT_MUTED),
                ]
                .spacing(8)
                .align_y(Alignment::Center);

                if is_def {
                    title_row = title_row.push(pill(
                        "default",
                        Color::from_rgba(0.231, 0.510, 0.965, 0.16),
                        Color::from_rgb(0.55, 0.75, 1.0),
                    ));
                }
                if downloaded {
                    title_row = title_row.push(pill(
                        "downloaded",
                        Color::from_rgba(0.133, 0.773, 0.369, 0.16),
                        ACCENT_GREEN,
                    ));
                }

                let r = row![
                    column![title_row, text(file).size(12).color(TEXT_DIM)].spacing(3),
                    horizontal_space(),
                    button(
                        text(if downloaded {
                            "Verify Checksum"
                        } else {
                            "Download Only"
                        })
                        .size(12)
                    )
                    .padding([6, 12])
                    .style(secondary_btn_style)
                    .on_press(Message::DownloadRelease(entry.clone(), false)),
                    button(
                        text(if downloaded {
                            "Boot Now"
                        } else {
                            "Get & Boot"
                        })
                        .size(12)
                    )
                    .padding([6, 14])
                    .style(primary_btn_style)
                    .on_press(Message::DownloadRelease(entry.clone(), true)),
                ]
                .spacing(8)
                .align_y(Alignment::Center);

                col = col.push(
                    container(r)
                        .padding([11, 14])
                        .width(Length::Fill)
                        .style(card_style),
                );
            }
        }

        scrollable(
            container(col).padding(Padding {
                top: 2.0,
                right: 22.0,
                bottom: 8.0,
                left: 2.0,
            }),
        )
        .height(Length::Fill)
        .into()
    }

    fn view_mirrors_page(&self) -> Element<'_, Message> {
        let add_bar = container(
            column![
                text("Add Custom Download Mirror").size(14).color(TEXT_MAIN),
                row![
                    text("Mirror Host / URL:").size(12).color(TEXT_MUTED),
                    text_input(
                        "e.g. mirrors.rit.edu or https://plug-mirror.rcac.purdue.edu",
                        &self.mirror_host_input
                    )
                    .on_input(Message::MirrorHostInputChanged)
                    .size(13)
                    .width(Length::Fill),
                    button(text("Auto-Probe & Add").size(12))
                        .padding([6, 12])
                        .style(primary_btn_style)
                        .on_press(Message::AddMirrorByProbe),
                    button(text("Reset Defaults").size(12))
                        .padding([6, 12])
                        .style(secondary_btn_style)
                        .on_press(Message::ResetMirrors),
                ]
                .spacing(8)
                .align_y(Alignment::Center),
                row![
                    text("Optional Official Prefix:").size(12).color(TEXT_MUTED),
                    text_input(
                        "leave blank to auto-detect, or e.g. https://releases.ubuntu.com/",
                        &self.mirror_official_input
                    )
                    .on_input(Message::MirrorOfficialInputChanged)
                    .size(12)
                    .width(Length::Fill),
                    button(text("Add Explicit Rule").size(12))
                        .padding([5, 12])
                        .style(secondary_btn_style)
                        .on_press(Message::AddMirrorExplicit),
                ]
                .spacing(8)
                .align_y(Alignment::Center),
            ]
            .spacing(8),
        )
        .padding(14)
        .style(panel_style);

        let mut mirror_list = Column::new().spacing(6);
        for (off, mir) in &self.mirrors {
            mirror_list = mirror_list.push(
                container(
                    row![
                        text(off).size(12).color(TEXT_MUTED),
                        text("→").size(12).color(ACCENT_CRAB),
                        text(mir).size(13).color(TEXT_MAIN),
                        horizontal_space(),
                        button(text("Remove").size(11))
                            .padding([4, 10])
                            .style(danger_btn_style)
                            .on_press(Message::RemoveMirrorRule(mir.clone())),
                    ]
                    .spacing(8)
                    .align_y(Alignment::Center),
                )
                .padding([8, 12])
                .style(card_style),
            );
        }

        let rss_box = container(
            column![
                row![
                    text("OS Release RSS Feed").size(14),
                    text_input("https://distrowatch.com/news/dwd.xml", &self.rss_url_input)
                        .on_input(Message::RssUrlInputChanged)
                        .size(12)
                        .width(Length::Fill),
                    button(text("Fetch Feed").size(12))
                        .padding([6, 12])
                        .style(primary_btn_style)
                        .on_press(Message::FetchRss),
                ]
                .spacing(8)
                .align_y(Alignment::Center),
                {
                    let mut rss_col = Column::new().spacing(4);
                    if self.rss_items.is_empty() {
                        rss_col = rss_col.push(
                            text("Click 'Fetch Feed' to inspect recent OS ISO announcements via RSS.")
                                .size(12)
                                .color(TEXT_DIM),
                        );
                    } else {
                        for item in self.rss_items.iter().take(15) {
                            let line = if item.pub_date.is_empty() {
                                format!("• {}  ({})", item.title, item.link)
                            } else {
                                format!("• [{}] {}  ({})", item.pub_date, item.title, item.link)
                            };
                            rss_col = rss_col.push(text(line).size(12).color(TEXT_MUTED));
                        }
                    }
                    rss_col
                }
            ]
            .spacing(8),
        )
        .padding(14)
        .style(panel_style);

        let content = column![
            add_bar,
            text("Active Mirror Rules (~/VMs/mirrors)")
                .size(13)
                .color(TEXT_MUTED),
            mirror_list,
            rss_box,
        ]
        .spacing(12);

        scrollable(
            container(content).padding(Padding {
                top: 2.0,
                right: 22.0,
                bottom: 8.0,
                left: 2.0,
            }),
        )
        .height(Length::Fill)
        .into()
    }
}

pub fn run_gui(paths: Paths, opts: BootOptions) -> Result<(), String> {
    iced::application(CrabGui::title, CrabGui::update, CrabGui::view)
        .subscription(CrabGui::subscription)
        .theme(|_| Theme::Dark)
        .window_size((1020.0, 720.0))
        .run_with(move || CrabGui::new(paths, opts))
        .map_err(|e| format!("GUI error: {e}"))
}
