//! A minimal client for QEMU's machine protocol (QMP), spoken over the
//! `qmp.sock` Unix socket that crab gives every VM it boots on Unix hosts.

use serde_json::Value;
#[cfg(unix)]
use serde_json::json;
#[cfg(unix)]
use std::io::BufReader;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::time::Duration;

/// macOS limits Unix socket paths to 104 bytes, including the terminating NUL;
/// Linux allows 108 bytes.
#[cfg(target_os = "macos")]
const MAX_SOCKET_PATH: usize = 103;
#[cfg(not(target_os = "macos"))]
const MAX_SOCKET_PATH: usize = 107;

pub fn socket_path(vm_dir: &Path) -> PathBuf {
    vm_dir.join("qmp.sock")
}

/// The socket path to give QEMU, or None if it's too long or unsupported on this platform.
#[allow(dead_code)]
pub fn usable_socket_path(vm_dir: &Path) -> Option<PathBuf> {
    let os = if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(unix) {
        "unix"
    } else {
        "windows"
    };
    usable_socket_path_for_os(vm_dir, os)
}

pub fn usable_socket_path_for_os(vm_dir: &Path, host_os: &str) -> Option<PathBuf> {
    if host_os == "windows" {
        return None;
    }
    let max_len = if host_os == "macos" { 103 } else { MAX_SOCKET_PATH };
    let p = socket_path(vm_dir);
    (p.as_os_str().len() <= max_len).then_some(p)
}

/// Runs one QMP command against the VM in `vm_dir` and returns its "return" value.
#[cfg(unix)]
pub fn execute(vm_dir: &Path, command: &str, arguments: Option<Value>) -> Result<Value, String> {
    use std::os::unix::net::UnixStream;
    let stream = UnixStream::connect(socket_path(vm_dir))
        .map_err(|e| format!("can't reach the VM's control socket: {e}"))?;
    run_session(stream, command, arguments)
}

#[cfg(not(unix))]
pub fn execute(_vm_dir: &Path, _command: &str, _arguments: Option<Value>) -> Result<Value, String> {
    Err("QMP Unix sockets are not supported on Windows; close the QEMU window or use 'crab kill'".to_string())
}

#[cfg(unix)]
fn run_session(
    stream: std::os::unix::net::UnixStream,
    command: &str,
    arguments: Option<Value>,
) -> Result<Value, String> {
    let io_err = |e: std::io::Error| format!("QMP: {e}");
    stream.set_read_timeout(Some(Duration::from_secs(3))).map_err(io_err)?;
    stream.set_write_timeout(Some(Duration::from_secs(3))).map_err(io_err)?;
    let mut reader = BufReader::new(stream.try_clone().map_err(io_err)?);
    let mut writer = stream;

    let greeting = read_message(&mut reader)?;
    if greeting.get("QMP").is_none() {
        return Err("QMP: unexpected greeting".to_string());
    }
    send(&mut writer, &json!({ "execute": "qmp_capabilities" }))?;
    read_reply(&mut reader)?;

    let mut msg = json!({ "execute": command });
    if let Some(args) = arguments {
        msg["arguments"] = args;
    }
    send(&mut writer, &msg)?;
    read_reply(&mut reader)
}

#[allow(dead_code)]
fn send(w: &mut impl Write, msg: &Value) -> Result<(), String> {
    writeln!(w, "{msg}")
        .and_then(|()| w.flush())
        .map_err(|e| format!("QMP: {e}"))
}

#[allow(dead_code)]
fn read_message(r: &mut impl BufRead) -> Result<Value, String> {
    let mut line = String::new();
    match r.read_line(&mut line) {
        Ok(0) => Err("QMP: connection closed".to_string()),
        Ok(_) => serde_json::from_str(&line).map_err(|e| format!("QMP: bad message: {e}")),
        Err(e) => Err(format!("QMP: {e}")),
    }
}

/// Reads until the reply to the last command, skipping asynchronous events.
#[allow(dead_code)]
fn read_reply(r: &mut impl BufRead) -> Result<Value, String> {
    loop {
        let msg = read_message(r)?;
        if let Some(ret) = msg.get("return") {
            return Ok(ret.clone());
        }
        if let Some(err) = msg.get("error") {
            let desc = err["desc"].as_str().unwrap_or("unknown error");
            return Err(format!("QEMU: {desc}"));
        }
    }
}

/// The guest's run state, e.g. "running", "paused" or "shutdown".
pub fn query_status(vm_dir: &Path) -> Option<String> {
    let ret = execute(vm_dir, "query-status", None).ok()?;
    ret["status"].as_str().map(String::from)
}

/// Presses the virtual power button so the guest can shut down cleanly.
pub fn system_powerdown(vm_dir: &Path) -> Result<(), String> {
    execute(vm_dir, "system_powerdown", None).map(|_| ())
}

/// Tells QEMU to exit right away, like pulling the plug.
pub fn quit(vm_dir: &Path) -> Result<(), String> {
    match execute(vm_dir, "quit", None) {
        // QEMU may close the socket before its reply arrives.
        Err(e) if e.contains("connection closed") => Ok(()),
        other => other.map(|_| ()),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::thread;

    /// Serves one QMP session: greeting, capabilities, then replies to the
    /// command with an event first (which the client must skip) and `reply`.
    fn fake_qemu(dir: &Path, reply: &'static str) -> thread::JoinHandle<String> {
        let listener = UnixListener::bind(socket_path(dir)).unwrap();
        thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut w = stream;
            writeln!(w, r#"{{"QMP": {{"version": {{}}, "capabilities": []}}}}"#).unwrap();
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("qmp_capabilities"));
            writeln!(w, r#"{{"return": {{}}}}"#).unwrap();
            let mut cmd = String::new();
            reader.read_line(&mut cmd).unwrap();
            writeln!(w, r#"{{"event": "RESUME", "timestamp": {{}}}}"#).unwrap();
            writeln!(w, "{reply}").unwrap();
            cmd
        })
    }

    #[test]
    fn query_status_skips_events() {
        let dir = crate::config::test_dir("qmp-status");
        let server = fake_qemu(&dir, r#"{"return": {"status": "paused", "running": false}}"#);
        assert_eq!(query_status(&dir).as_deref(), Some("paused"));
        assert!(server.join().unwrap().contains(r#""execute":"query-status""#));
    }

    #[test]
    fn errors_are_reported() {
        let dir = crate::config::test_dir("qmp-error");
        let server = fake_qemu(&dir, r#"{"error": {"class": "GenericError", "desc": "nope"}}"#);
        assert_eq!(system_powerdown(&dir), Err("QEMU: nope".to_string()));
        server.join().unwrap();
    }

    #[test]
    fn missing_socket() {
        let dir = crate::config::test_dir("qmp-missing");
        assert!(query_status(&dir).is_none());
    }

    #[test]
    fn socket_path_length() {
        let short = Path::new("/Users/me/VMs/openbsd");
        let long = format!("/Users/me/VMs/{}", "x".repeat(90));
        let long = Path::new(&long);
        assert!(usable_socket_path_for_os(short, "macos").is_some());
        assert!(usable_socket_path_for_os(long, "macos").is_none());
        assert!(usable_socket_path_for_os(long, "windows").is_none());
    }
}
