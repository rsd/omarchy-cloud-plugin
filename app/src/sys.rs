//! Running commands, reading their output, and the few filesystem operations
//! the TUI performs. Parsers are pure and tested; the rest is thin glue.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::validate::is_valid_name;

/// Output kept from a command (bounded, so a runaway command cannot eat memory).
const MAX_OUTPUT: usize = 256 * 1024;

/// Command time limits (see `timeout_for`).
pub const T_QUICK: Duration = Duration::from_secs(30);
pub const T_MEDIUM: Duration = Duration::from_secs(120);
pub const T_SLOW: Duration = Duration::from_secs(300);
pub const T_LONG: Duration = Duration::from_secs(12 * 3600);
/// After SIGTERM, how long a process group gets before SIGKILL.
pub const KILL_GRACE: Duration = Duration::from_secs(3);
/// The same for a bisync run: on SIGTERM rclone bisync lets its transfers
/// drain for 30s, then cancels them and may take up to 60s more to clean up
/// and remove its lock file; a SIGKILL leaves the lock behind (it expires
/// after --max-lock). So the grace covers both (90s) with a margin.
pub const SYNC_GRACE: Duration = Duration::from_secs(120);

/// Process groups of the commands running right now (one per worker), with
/// their SIGTERM grace (`term_grace`).
static CHILDREN: Mutex<Vec<(i32, Duration)>> = Mutex::new(Vec::new());
/// Set when the app quits: no new command starts after that.
static QUITTING: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Default)]
pub struct Output {
    /// None when the command could not start or was killed by a signal.
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl Output {
    pub fn ok(&self) -> bool {
        self.code == Some(0)
    }
    /// stdout and stderr together, trimmed, for a message or a view.
    pub fn text(&self) -> String {
        let mut s = self.stdout.trim_end().to_string();
        let e = self.stderr.trim_end();
        if !e.is_empty() {
            if !s.is_empty() {
                s.push('\n');
            }
            s.push_str(e);
        }
        s
    }
    /// The last non-empty line, for the message line.
    pub fn last_line(&self) -> String {
        self.text()
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("")
            .trim()
            .to_string()
    }
}

/// The time limit for a command, by what it is. Pure.
pub fn timeout_for(argv: &[String]) -> Duration {
    let prog = argv
        .first()
        .map(|p| p.rsplit('/').next().unwrap_or(p))
        .unwrap_or("");
    let sub = argv.get(1).map(String::as_str).unwrap_or("");
    let has = |a: &str| argv.iter().skip(1).any(|x| x == a);
    match prog {
        "rclone-bisync" | "rclone-backup" => match sub {
            "run" | "check" | "resync" | "dry-run" => T_LONG,
            _ => T_MEDIUM,
        },
        "rclone" => match sub {
            "copy" | "bisync" | "check" | "sync" => T_LONG,
            _ => T_QUICK,
        },
        "systemctl" if has("--no-block") => T_QUICK,
        "systemctl" if has("stop") || has("restart") || has("start") || has("--now") => T_SLOW,
        "systemctl" | "journalctl" | "timeout" => T_QUICK,
        _ => T_MEDIUM,
    }
}

/// How long a command gets between SIGTERM and SIGKILL, by what it is: a
/// bisync run (the helper's run, resync or dry-run, or rclone bisync)
/// SYNC_GRACE, anything else KILL_GRACE. Pure.
pub fn term_grace(argv: &[String]) -> Duration {
    let prog = argv
        .first()
        .map(|p| p.rsplit('/').next().unwrap_or(p))
        .unwrap_or("");
    let sub = argv.get(1).map(String::as_str).unwrap_or("");
    match (prog, sub) {
        ("rclone-bisync", "run" | "resync" | "dry-run") | ("rclone", "bisync") => SYNC_GRACE,
        _ => KILL_GRACE,
    }
}

fn kill_group(pgid: i32, sig: i32) {
    if pgid > 1 {
        // SAFETY: kill(2) with a negative pid signals that process group only.
        unsafe {
            libc::kill(-pgid, sig);
        }
    }
}

/// True while any process of the group `pgid` is alive.
fn group_alive(pgid: i32) -> bool {
    if pgid <= 1 {
        return false;
    }
    // SAFETY: kill(2) with signal 0 only checks that the group exists.
    let r = unsafe { libc::kill(-pgid, 0) };
    r == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

/// Waits (polling) until the process group `pgid` is gone, up to `limit`.
/// True when it is gone.
pub fn wait_group_gone(pgid: i32, limit: Duration) -> bool {
    let until = Instant::now() + limit;
    loop {
        if !group_alive(pgid) {
            return true;
        }
        if Instant::now() >= until {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Called once when the app quits with a task running: no new command
/// starts, and the running ones get SIGTERM (`hard`: SIGKILL). Returns the
/// longest SIGTERM grace among them (`term_grace`; KILL_GRACE when none).
pub fn stop_children(hard: bool) -> Duration {
    QUITTING.store(true, Ordering::SeqCst);
    let sig = if hard { libc::SIGKILL } else { libc::SIGTERM };
    let mut grace = KILL_GRACE;
    if let Ok(list) = CHILDREN.lock() {
        for &(g, t) in list.iter() {
            kill_group(g, sig);
            grace = grace.max(t);
        }
    }
    grace
}

fn drain(mut r: impl Read) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match r.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let room = MAX_OUTPUT.saturating_sub(buf.len());
                buf.extend_from_slice(&chunk[..n.min(room)]);
            }
        }
    }
    buf
}

/// Runs an argument vector with stdin closed, captures its output and stops
/// it at its time limit (`timeout_for`).
pub fn run(argv: &[String]) -> Output {
    run_for(argv, timeout_for(argv))
}

/// As `run`, with an explicit time limit. The command runs in its own process
/// group, so a timeout or a quit stops its children too.
pub fn run_for(argv: &[String], limit: Duration) -> Output {
    let fail = |e: String| Output {
        code: None,
        stdout: String::new(),
        stderr: e,
    };
    let Some((prog, args)) = argv.split_first() else {
        return fail("empty command".into());
    };
    if QUITTING.load(Ordering::SeqCst) {
        return fail(format!("{prog}: not started, quitting"));
    }
    let mut child = match Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return fail(format!("{prog}: {e}")),
    };
    let pgid = child.id() as i32;
    let grace = term_grace(argv);
    if let Ok(mut l) = CHILDREN.lock() {
        l.push((pgid, grace));
    }
    let (otx, orx) = channel();
    if let Some(o) = child.stdout.take() {
        let t = otx.clone();
        std::thread::spawn(move || {
            let _ = t.send((0, drain(o)));
        });
    }
    if let Some(e) = child.stderr.take() {
        let t = otx.clone();
        std::thread::spawn(move || {
            let _ = t.send((1, drain(e)));
        });
    }
    drop(otx);
    let (wtx, wrx) = channel();
    std::thread::spawn(move || {
        let _ = wtx.send(child.wait());
    });
    let mut timed_out = false;
    let mut since_term = None;
    let status = match wrx.recv_timeout(limit) {
        Ok(s) => s.ok(),
        Err(RecvTimeoutError::Disconnected) => None,
        Err(RecvTimeoutError::Timeout) => {
            timed_out = true;
            since_term = Some(Instant::now());
            kill_group(pgid, libc::SIGTERM);
            match wrx.recv_timeout(grace) {
                Ok(s) => s.ok(),
                _ => {
                    kill_group(pgid, libc::SIGKILL);
                    wrx.recv().ok().and_then(Result::ok)
                }
            }
        }
    };
    // Stopped (a timeout, or the app quitting): the leader (the helper's
    // bash) dies at once, but rclone below it drains and removes its lock.
    // Wait for the whole group, with the pipe readers alive, so it never
    // writes to a closed pipe (SIGPIPE would kill it mid-cleanup). Bounded
    // by the grace; the group stays in CHILDREN meanwhile, so a forced quit
    // still reaches it. On quit, the main thread sends the SIGKILL.
    if timed_out || QUITTING.load(Ordering::SeqCst) {
        let left = since_term.map_or(grace, |t| grace.saturating_sub(t.elapsed()));
        if !wait_group_gone(pgid, left) && timed_out {
            kill_group(pgid, libc::SIGKILL);
            wait_group_gone(pgid, Duration::from_secs(2));
        }
    }
    if let Ok(mut l) = CHILDREN.lock() {
        l.retain(|&(g, _)| g != pgid);
    }
    // A grandchild that left the group could hold the pipes open: wait for
    // the readers only briefly.
    let mut out = Output {
        code: status.and_then(|s| s.code()),
        ..Output::default()
    };
    for _ in 0..2 {
        match orx.recv_timeout(Duration::from_secs(2)) {
            Ok((0, b)) => out.stdout = String::from_utf8_lossy(&b).into_owned(),
            Ok((_, b)) => out.stderr = String::from_utf8_lossy(&b).into_owned(),
            Err(_) => break,
        }
    }
    if timed_out {
        out.code = None;
        if !out.stderr.is_empty() && !out.stderr.ends_with('\n') {
            out.stderr.push('\n');
        }
        out.stderr
            .push_str(&format!("{prog}: timed out after {}s", limit.as_secs()));
    }
    out
}

/// Runs an argument vector on the terminal (inherited stdio). The caller has
/// already left the alternate screen and raw mode. This process ignores
/// SIGINT meanwhile (Ctrl-C belongs to the child, which gets the default
/// disposition back); no time limit, the user drives it.
pub fn run_interactive(argv: &[String]) -> Result<i32, String> {
    let (prog, args) = argv.split_first().ok_or("empty command")?;
    let mut c = Command::new(prog);
    c.args(args);
    // SAFETY: signal(2) is async-signal-safe; it only resets SIGINT in the
    // forked child before exec.
    unsafe {
        c.pre_exec(|| {
            libc::signal(libc::SIGINT, libc::SIG_DFL);
            Ok(())
        });
    }
    // SAFETY: plain signal-disposition changes on this process.
    let prev = unsafe { libc::signal(libc::SIGINT, libc::SIG_IGN) };
    let res = c.status();
    if prev != libc::SIG_ERR {
        unsafe {
            libc::signal(libc::SIGINT, prev);
        }
    }
    let status = res.map_err(|e| format!("{prog}: {e}"))?;
    Ok(status.code().unwrap_or(-1))
}

// ---------------------------------------------------------------- mounts

/// Undoes the octal escapes of /proc/self/mounts (`\040` = space).
fn unescape_mount(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\'
            && i + 3 < b.len()
            && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c))
        {
            let v = (b[i + 1] - b'0') * 64 + (b[i + 2] - b'0') * 8 + (b[i + 3] - b'0');
            out.push(v);
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// True when a mounts table (`/proc/self/mounts` format) lists `path` as a
/// mount point. Pure.
pub fn mounts_contain(text: &str, path: &Path) -> bool {
    let want = path.to_string_lossy();
    text.lines()
        .filter_map(|l| l.split(' ').nth(1))
        .any(|m| unescape_mount(m) == want)
}

/// The FUSE mount points of a mounts table (`/proc/self/mounts` format):
/// fstype `fuse` or `fuse.*` (rclone, gvfs, sshfs…), not `fusectl`, with
/// the octal escapes undone. Pure.
pub fn parse_fuse_mounts(text: &str) -> Vec<PathBuf> {
    text.lines()
        .filter_map(|l| {
            let mut f = l.split(' ');
            let (_, point, fstype) = (f.next()?, f.next()?, f.next()?);
            (fstype == "fuse" || fstype.starts_with("fuse."))
                .then(|| PathBuf::from(unescape_mount(point)))
        })
        .collect()
}

/// The FUSE mount points right now (empty when the table cannot be read).
pub fn fuse_mounts() -> Vec<PathBuf> {
    read_small(Path::new("/proc/self/mounts"))
        .map(|t| parse_fuse_mounts(&t))
        .unwrap_or_default()
}

/// Whether `path` is a mount point now; None when the table cannot be read.
pub fn is_mounted(path: &Path) -> Option<bool> {
    read_small(Path::new("/proc/self/mounts")).map(|t| mounts_contain(&t, path))
}

/// `systemctl --user is-active <unit>` → its state word ("" when unknown).
pub fn unit_active_state(unit: &str) -> String {
    let o = run(&crate::cmd::is_active_cmd(unit));
    o.stdout.trim().to_string()
}

/// A path with its longest existing ancestor resolved (symlinks, `..`), the
/// rest appended as is.
pub fn canonical_lenient(p: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut cur = p.to_path_buf();
    loop {
        if let Ok(c) = fs::canonicalize(&cur) {
            let mut out = c;
            for r in rest.iter().rev() {
                out.push(r);
            }
            return out;
        }
        match (cur.file_name(), cur.parent()) {
            (Some(n), Some(par)) => {
                rest.push(n.to_owned());
                cur = par.to_path_buf();
            }
            _ => return p.to_path_buf(),
        }
    }
}

// ------------------------------------------------------------ listremotes

/// `rclone listremotes --long`: `name:   type` per line. Invalid names are
/// skipped (they could not be used safely anyway).
pub fn parse_listremotes(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let Some((name, rest)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if !is_valid_name(name) {
            continue;
        }
        let kind = rest.split_whitespace().next().unwrap_or("").to_string();
        out.push((name.to_string(), kind));
    }
    out
}

// ------------------------------------------------------- systemctl show

pub type UnitProps = HashMap<String, String>;

/// `systemctl show -p Id,...` for several units: blocks separated by blank
/// lines, keyed here by their Id.
pub fn parse_show(text: &str) -> HashMap<String, UnitProps> {
    let mut all = HashMap::new();
    let mut cur: UnitProps = HashMap::new();
    let mut flush = |cur: &mut UnitProps| {
        if let Some(id) = cur.get("Id").cloned() {
            all.insert(id, std::mem::take(cur));
        } else {
            cur.clear();
        }
    };
    for line in text.lines() {
        if line.trim().is_empty() {
            flush(&mut cur);
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            cur.insert(k.to_string(), v.to_string());
        }
    }
    flush(&mut cur);
    all
}

// ----------------------------------------------------------------- fuser

#[derive(Debug, Clone, PartialEq)]
pub enum Busy {
    /// Processes with files open (PIDs).
    InUse(Vec<u32>),
    /// fuser listed the mount and found nobody.
    Free,
    /// Could not tell (not a mount point, fuser missing, timed out).
    Unknown,
}

/// fuser -v -M -m: PIDs (and the `kernel` token for the mount itself) go to
/// stdout, the rest of the table to stderr. With no -v access letters would
/// follow the PIDs; they are stripped anyway.
pub fn parse_fuser(code: Option<i32>, stdout: &str) -> Busy {
    let mut pids = Vec::new();
    let mut kernel = false;
    for tok in stdout.split_whitespace() {
        let tok = tok.rsplit(':').next().unwrap_or(tok);
        if tok == "kernel" {
            kernel = true;
            continue;
        }
        let digits: String = tok.chars().take_while(char::is_ascii_digit).collect();
        if let Ok(p) = digits.parse::<u32>()
            && !pids.contains(&p)
        {
            pids.push(p);
        }
    }
    if !pids.is_empty() {
        Busy::InUse(pids)
    } else if kernel && code == Some(0) {
        Busy::Free
    } else {
        Busy::Unknown
    }
}

/// "1234 (nvim)" for each PID, from /proc.
pub fn describe_pids(pids: &[u32]) -> Vec<String> {
    pids.iter()
        .take(12)
        .map(|p| {
            let comm = fs::read_to_string(format!("/proc/{p}/comm")).unwrap_or_default();
            let comm: String = comm
                .trim()
                .chars()
                .filter(|c| !c.is_control())
                .take(32)
                .collect();
            if comm.is_empty() {
                format!("{p}")
            } else {
                format!("{p} ({comm})")
            }
        })
        .collect()
}

// ------------------------------------------------------------ state files

#[derive(Debug, Clone, Default, PartialEq)]
pub struct State {
    pub time: Option<i64>,
    pub exit: Option<i32>,
    pub conflicts: Vec<String>,
    pub ok: Option<u32>,
    pub failed: Option<u32>,
}

pub fn parse_state(text: &str) -> State {
    let mut s = State::default();
    for line in text.lines() {
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let v = v.trim();
        match k {
            "time" => s.time = v.parse().ok(),
            "exit" => s.exit = v.parse().ok(),
            "ok" => s.ok = v.parse().ok(),
            "failed" => s.failed = v.parse().ok(),
            "conflict" if !v.is_empty() => {
                s.conflicts
                    .push(v.chars().filter(|c| !c.is_control()).collect());
            }
            _ => {}
        }
    }
    s
}

pub fn read_state(path: &Path) -> Option<State> {
    read_small(path).map(|t| parse_state(&t))
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// "just now", "5m ago", "3h ago", "2d ago".
pub fn ago(then: i64, now: i64) -> String {
    let d = now - then;
    if d < 0 {
        "in the future".into()
    } else if d < 60 {
        "just now".into()
    } else if d < 3600 {
        format!("{}m ago", d / 60)
    } else if d < 86400 {
        format!("{}h ago", d / 3600)
    } else {
        format!("{}d ago", d / 86400)
    }
}

// ------------------------------------------------------ files on disk

/// Reads a config-sized file (up to 1 MiB); None when missing or too big.
pub fn read_small(path: &Path) -> Option<String> {
    let f = fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    f.take(1024 * 1024 + 1).read_to_end(&mut buf).ok()?;
    if buf.len() > 1024 * 1024 {
        return None;
    }
    String::from_utf8(buf).ok()
}

/// The first `max` bytes of a regular file (symlinks followed); None when
/// it is missing or not a regular file (a FIFO would block the read).
pub fn read_bounded(path: &Path, max: usize) -> Option<Vec<u8>> {
    if !fs::metadata(path).ok()?.is_file() {
        return None;
    }
    let mut buf = Vec::new();
    fs::File::open(path)
        .ok()?
        .take(max as u64)
        .read_to_end(&mut buf)
        .ok()?;
    Some(buf)
}

/// The mount-root setting from cloud.env (`envfile::parse_root`); Absent
/// when the file is missing or unreadable.
pub fn read_root(paths: &crate::cmd::Paths) -> crate::envfile::RootSetting {
    match read_bounded(&paths.cloud_env(), crate::envfile::ROOT_FILE_MAX) {
        Some(b) => crate::envfile::parse_root(&b, &paths.home),
        None => crate::envfile::RootSetting::Absent,
    }
}

/// Why `dir` cannot hold mount points: missing, not a directory, or not
/// writable and searchable by this user (`access(W_OK|X_OK)`). None: usable.
pub fn dir_problem(dir: &Path) -> Option<&'static str> {
    use std::os::unix::ffi::OsStrExt;
    match fs::metadata(dir) {
        Err(_) => return Some("does not exist"),
        Ok(m) if !m.is_dir() => return Some("is not a directory"),
        Ok(_) => {}
    }
    let Ok(c) = std::ffi::CString::new(dir.as_os_str().as_bytes()) else {
        return Some("is not a usable path");
    };
    // SAFETY: `c` is a valid NUL-terminated string that outlives the call.
    let r = unsafe { libc::access(c.as_ptr(), libc::W_OK | libc::X_OK) };
    (r != 0).then_some("is not writable by you")
}

/// The valid instance names of `<dir>/<name>.conf`, sorted.
pub fn list_confs(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let n = e.file_name().into_string().ok()?;
            let stem = n.strip_suffix(".conf")?;
            is_valid_name(stem).then(|| stem.to_string())
        })
        .collect();
    v.sort();
    v
}

/// Creates a config directory (mode 700) when missing.
pub fn ensure_dir(dir: &Path) -> Result<(), String> {
    if dir.is_dir() {
        return Ok(());
    }
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("{}: {e}", dir.display()))
}

/// Writes a file atomically (temp file in the same directory, fsync, rename,
/// fsync of the directory), mode 600. Refuses when `path` is a symlink: the
/// link is neither replaced nor written through.
pub fn write_atomic(path: &Path, content: &str) -> Result<(), String> {
    static SEQ: AtomicU32 = AtomicU32::new(0);
    let dir = path.parent().ok_or("no parent directory")?;
    ensure_dir(dir)?;
    if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(format!(
            "{} is a symlink; refusing to write",
            path.display()
        ));
    }
    let name = path.file_name().ok_or("no file name")?.to_string_lossy();
    let tmp = dir.join(format!(
        ".{name}.tmp{}.{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let res = (|| -> std::io::Result<()> {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(content.as_bytes())?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        fs::File::open(dir)?.sync_all()
    })();
    if let Err(e) = res {
        let _ = fs::remove_file(&tmp);
        return Err(format!("{}: {e}", path.display()));
    }
    Ok(())
}

/// Removes a file if it exists.
pub fn remove_if_exists(path: &Path) -> Result<bool, String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// ~/Cloud/<r> → <root>/<r>, only when nothing exists at the link path.
pub fn create_cloud_link(link: &Path, target: &Path) -> Result<bool, String> {
    if fs::symlink_metadata(link).is_ok() {
        return Ok(false);
    }
    if let Some(dir) = link.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::os::unix::fs::symlink(target, link).map_err(|e| format!("{}: {e}", link.display()))?;
    Ok(true)
}

/// Removes ~/Cloud/<r> only if it is a symlink pointing at `target`
/// (<root>/<r>).
pub fn remove_cloud_link(link: &Path, target: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(link) {
        Ok(m) if m.file_type().is_symlink() => {
            if fs::read_link(link).map(|t| t == target).unwrap_or(false) {
                fs::remove_file(link).map_err(|e| format!("{}: {e}", link.display()))?;
                Ok(true)
            } else {
                Ok(false)
            }
        }
        _ => Ok(false),
    }
}

/// True only when the directory can be read and has no entries (missing or
/// unreadable counts as not empty, so nothing is copied into it blindly).
pub fn dir_is_empty(dir: &Path) -> bool {
    match fs::read_dir(dir) {
        Ok(mut it) => it.next().is_none(),
        Err(_) => false,
    }
}

/// What one vfsMeta file says about its upload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetaState {
    /// `"Dirty": true`: an upload is pending.
    Dirty,
    /// `"Dirty": false`.
    Clean,
    /// Empty, truncated, not JSON, not an object, or no boolean `Dirty`
    /// (rclone always writes the field, so its absence is not "clean").
    Unknown,
}

/// The verdict of one vfsMeta file: Dirty or Clean only when the whole text
/// is one valid JSON object whose top-level `"Dirty"` is a boolean. Pure.
pub fn meta_state(json: &str) -> MetaState {
    let mut p = Json {
        b: json.as_bytes(),
        i: 0,
        dirty: None,
        conflict: false,
    };
    p.ws();
    if p.peek() != Some(b'{') || p.value(0).is_none() {
        return MetaState::Unknown;
    }
    p.ws();
    if p.i != p.b.len() || p.conflict {
        return MetaState::Unknown;
    }
    match p.dirty {
        Some(true) => MetaState::Dirty,
        Some(false) => MetaState::Clean,
        None => MetaState::Unknown,
    }
}

/// A strict, minimal JSON reader: validates the text and records the
/// top-level `"Dirty"` boolean (a non-boolean or contradicting duplicate
/// marks `conflict`).
struct Json<'a> {
    b: &'a [u8],
    i: usize,
    dirty: Option<bool>,
    conflict: bool,
}

impl<'a> Json<'a> {
    const MAX_DEPTH: usize = 64;

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }
    fn eat(&mut self, c: u8) -> Option<()> {
        (self.peek()? == c).then(|| self.i += 1)
    }
    fn lit(&mut self, s: &[u8]) -> Option<()> {
        self.b[self.i..].starts_with(s).then(|| self.i += s.len())
    }
    /// A string; returns its raw (still escaped) bytes.
    fn string(&mut self) -> Option<&'a [u8]> {
        self.eat(b'"')?;
        let start = self.i;
        loop {
            match self.peek()? {
                b'"' => break,
                b'\\' => {
                    self.i += 1;
                    match self.peek()? {
                        b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => self.i += 1,
                        b'u' => {
                            let hex = self.b.get(self.i + 1..self.i + 5)?;
                            if !hex.iter().all(u8::is_ascii_hexdigit) {
                                return None;
                            }
                            self.i += 5;
                        }
                        _ => return None,
                    }
                }
                c if c < 0x20 => return None,
                _ => self.i += 1,
            }
        }
        let s: &'a [u8] = &self.b[start..self.i];
        self.i += 1;
        Some(s)
    }
    fn digits(&mut self) -> Option<()> {
        let start = self.i;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        (self.i > start).then_some(())
    }
    fn number(&mut self) -> Option<()> {
        let _ = self.eat(b'-');
        if self.eat(b'0').is_none() {
            self.digits()?;
        }
        if self.eat(b'.').is_some() {
            self.digits()?;
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            self.digits()?;
        }
        Some(())
    }
    fn value(&mut self, depth: usize) -> Option<()> {
        if depth > Self::MAX_DEPTH {
            return None;
        }
        self.ws();
        match self.peek()? {
            b'{' => {
                self.i += 1;
                self.ws();
                if self.eat(b'}').is_some() {
                    return Some(());
                }
                loop {
                    self.ws();
                    let key = self.string()?;
                    let top_dirty = depth == 0 && key == b"Dirty";
                    self.ws();
                    self.eat(b':')?;
                    self.ws();
                    if top_dirty {
                        let v = if self.lit(b"true").is_some() {
                            true
                        } else if self.lit(b"false").is_some() {
                            false
                        } else {
                            self.conflict = true;
                            self.value(depth + 1)?;
                            false
                        };
                        if self.dirty.is_some_and(|d| d != v) {
                            self.conflict = true;
                        }
                        self.dirty = Some(v);
                    } else {
                        self.value(depth + 1)?;
                    }
                    self.ws();
                    if self.eat(b'}').is_some() {
                        return Some(());
                    }
                    self.eat(b',')?;
                }
            }
            b'[' => {
                self.i += 1;
                self.ws();
                if self.eat(b']').is_some() {
                    return Some(());
                }
                loop {
                    self.value(depth + 1)?;
                    self.ws();
                    if self.eat(b']').is_some() {
                        return Some(());
                    }
                    self.eat(b',')?;
                }
            }
            b'"' => self.string().map(|_| ()),
            b't' => self.lit(b"true"),
            b'f' => self.lit(b"false"),
            b'n' => self.lit(b"null"),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }
}

/// Entries `count_dirty` looks at before it gives up (and answers unknown).
pub const DIRTY_MAX_ENTRIES: usize = 200_000;

/// Counts pending uploads under vfsMeta/<r> (bounded walk, no symlinks
/// followed). Conservative: None ("unknown") when the walk was cut at
/// `max_entries` or anything could not be read (a directory, an entry, its
/// type, a metadata file), when a metadata file is not valid rclone JSON
/// (`meta_state` Unknown: empty, truncated, garbage) or an entry is neither a
/// directory nor a regular file; only a missing vfsMeta/<r> is a sure 0.
pub fn count_dirty_bounded(meta_dir: &Path, max_entries: usize) -> Option<usize> {
    let mut count = 0;
    let mut stack: Vec<PathBuf> = vec![meta_dir.to_path_buf()];
    let mut seen = 0usize;
    while let Some(d) = stack.pop() {
        let rd = match fs::read_dir(&d) {
            Ok(rd) => rd,
            Err(e) if d == meta_dir && e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return None,
        };
        for e in rd {
            let e = e.ok()?;
            seen += 1;
            if seen > max_entries {
                return None;
            }
            let ft = e.file_type().ok()?;
            if ft.is_dir() {
                stack.push(e.path());
            } else if !ft.is_file() {
                // A symlink, fifo or socket is not something rclone writes.
                return None;
            } else {
                match meta_state(&read_small(&e.path())?) {
                    MetaState::Dirty => count += 1,
                    MetaState::Clean => {}
                    MetaState::Unknown => return None,
                }
            }
        }
    }
    Some(count)
}

/// `count_dirty_bounded` at DIRTY_MAX_ENTRIES.
pub fn count_dirty(meta_dir: &Path) -> Option<usize> {
    count_dirty_bounded(meta_dir, DIRTY_MAX_ENTRIES)
}

/// rename(2) that never replaces an existing target (RENAME_NOREPLACE).
/// Through the raw syscall: Rust's bundled musl has no `renameat2` symbol.
fn rename_noreplace(from: &Path, to: &Path) -> std::io::Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = |p: &Path| {
        CString::new(p.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))
    };
    let (f, t) = (c(from)?, c(to)?);
    // SAFETY: two valid NUL-terminated paths, resolved against the cwd;
    // renameat2(2) takes (int, const char *, int, const char *, unsigned).
    let r = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            f.as_ptr(),
            libc::AT_FDCWD,
            t.as_ptr(),
            libc::RENAME_NOREPLACE as libc::c_uint,
        )
    };
    if r == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// Clears a remote's VFS cache (vfsMeta/<r>, then vfs/<r>) under the cache
/// root without a check-then-delete window. Each existing directory is first
/// renamed to `.<r>.clearing-<pid>` in its own parent, so a mount that starts
/// meanwhile gets a fresh cache and nothing can be added to what is about to
/// go; then `recheck` runs on the renamed vfsMeta (a missing path when there
/// was none) and must confirm the mount is still stopped and exactly 0
/// uploads pending. On any doubt (a recheck Err, a rename failing) both are
/// renamed back and it refuses; only then is the trash deleted. Refuses a
/// symlink (the root, vfs, vfsMeta or the directory itself), a non-directory
/// and a leftover trash name. Returns what was cleared ("vfsMeta/<r>", ...).
pub fn clear_cache_dirs(
    root: &Path,
    remote: &str,
    recheck: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<Vec<String>, String> {
    if !is_valid_name(remote) {
        return Err("invalid cache name".into());
    }
    let trash_name = format!(".{remote}.clearing-{}", std::process::id());
    let is_link = |p: &Path| {
        fs::symlink_metadata(p)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(true)
    };
    // (kind, dir, trash) of each directory there is to clear.
    let mut todo: Vec<(&str, PathBuf, PathBuf)> = Vec::new();
    for kind in ["vfsMeta", "vfs"] {
        let parent = root.join(kind);
        let dir = parent.join(remote);
        match fs::symlink_metadata(&dir) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("{}: {e}", dir.display())),
            Ok(m) if m.file_type().is_symlink() => {
                return Err(format!("{} is a symlink; refusing", dir.display()));
            }
            Ok(m) if !m.is_dir() => {
                return Err(format!("{} is not a directory; refusing", dir.display()));
            }
            Ok(_) => {}
        }
        for p in [root, parent.as_path()] {
            if is_link(p) {
                return Err(format!("{} is a symlink; refusing", p.display()));
            }
        }
        let trash = parent.join(&trash_name);
        if fs::symlink_metadata(&trash).is_ok() {
            return Err(format!(
                "{} is left over from an earlier clear; remove it first",
                trash.display()
            ));
        }
        todo.push((kind, dir, trash));
    }
    let undo = |moved: &[(&str, PathBuf, PathBuf)]| -> Vec<String> {
        moved
            .iter()
            .filter_map(|(_, dir, trash)| {
                rename_noreplace(trash, dir).err().map(|e| {
                    format!(
                        "could not move {} back to {} ({e}); move it back by hand",
                        trash.display(),
                        dir.display()
                    )
                })
            })
            .collect()
    };
    let refuse = |why: String, moved: &[(&str, PathBuf, PathBuf)]| -> String {
        let stuck = undo(moved);
        if stuck.is_empty() {
            why
        } else {
            format!("{why}; {}", stuck.join("; "))
        }
    };
    for (i, (_, dir, trash)) in todo.iter().enumerate() {
        if let Err(e) = rename_noreplace(dir, trash) {
            let why = format!("{}: {e}", dir.display());
            return Err(refuse(why, &todo[..i]));
        }
    }
    let meta = root.join("vfsMeta").join(&trash_name);
    if let Err(e) = recheck(&meta) {
        return Err(refuse(e, &todo));
    }
    let mut done = Vec::new();
    for (kind, _, trash) in &todo {
        fs::remove_dir_all(trash).map_err(|e| format!("{}: {e}", trash.display()))?;
        done.push(format!("{kind}/{remote}"));
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn time_limits() {
        let h = "/home/u/.local/bin/rclone-bisync";
        assert_eq!(timeout_for(&argv(&[h, "resync", "p"])), T_LONG);
        assert_eq!(timeout_for(&argv(&[h, "setup", "p"])), T_MEDIUM);
        assert_eq!(timeout_for(&argv(&["rclone", "copy", "a:", "/b"])), T_LONG);
        assert_eq!(timeout_for(&argv(&["rclone", "listremotes"])), T_QUICK);
        assert_eq!(
            timeout_for(&argv(&["systemctl", "--user", "start", "--no-block", "u"])),
            T_QUICK
        );
        assert_eq!(
            timeout_for(&argv(&["systemctl", "--user", "stop", "u"])),
            T_SLOW
        );
        assert_eq!(
            timeout_for(&argv(&["systemctl", "--user", "enable", "--now", "u"])),
            T_SLOW
        );
        assert_eq!(
            timeout_for(&argv(&["systemctl", "--user", "show", "u"])),
            T_QUICK
        );
        assert_eq!(timeout_for(&argv(&["nvim"])), T_MEDIUM);
    }

    #[test]
    fn run_is_bounded() {
        let t0 = std::time::Instant::now();
        let o = run_for(
            &argv(&["sh", "-c", "echo before; sleep 30 & sleep 30"]),
            Duration::from_millis(300),
        );
        assert!(t0.elapsed() < Duration::from_secs(10), "{:?}", t0.elapsed());
        assert_eq!(o.code, None);
        assert!(o.stderr.contains("timed out"), "{}", o.stderr);
        assert_eq!(o.stdout.trim(), "before");
        let ok = run(&argv(&["sh", "-c", "echo out; echo err >&2; exit 3"]));
        assert_eq!(
            (ok.code, ok.stdout.as_str(), ok.stderr.as_str()),
            (Some(3), "out\n", "err\n")
        );
        assert_eq!(run(&argv(&["/nonexistent/x"])).code, None);
        assert_eq!(run(&[]).code, None);
    }

    #[test]
    fn term_graces() {
        let h = "/home/u/.local/bin/rclone-bisync";
        for sub in ["run", "resync", "dry-run"] {
            assert_eq!(term_grace(&argv(&[h, sub, "p"])), SYNC_GRACE, "{sub}");
        }
        assert_eq!(
            term_grace(&argv(&["rclone", "bisync", "a", "b"])),
            SYNC_GRACE
        );
        assert!(
            SYNC_GRACE >= Duration::from_secs(120),
            "bisync's own shutdown takes up to 30s + 60s"
        );
        assert_eq!(term_grace(&argv(&[h, "check", "p"])), KILL_GRACE);
        assert_eq!(
            term_grace(&argv(&["rclone", "copy", "a:", "/b"])),
            KILL_GRACE
        );
        assert_eq!(
            term_grace(&argv(&["systemctl", "--user", "stop", "u"])),
            KILL_GRACE
        );
        assert_eq!(term_grace(&[]), KILL_GRACE);
    }

    #[test]
    fn mounts_table() {
        let t = "proc /proc proc rw 0 0\nrclone:x /mnt/cloud/gdrive fuse.rclone rw 0 0\nx /mnt/a\\040b fuse rw 0 0\n";
        assert!(mounts_contain(t, Path::new("/mnt/cloud/gdrive")));
        assert!(!mounts_contain(t, Path::new("/mnt/cloud/gd")));
        assert!(!mounts_contain(t, Path::new("/mnt/cloud")));
        assert!(mounts_contain(t, Path::new("/mnt/a b")));
        assert_eq!(is_mounted(Path::new("/proc")), Some(true));
        let t2 = format!(
            "{t}fusectl /sys/fs/fuse/connections fusectl rw 0 0\nportal /run/user/1000/doc fuse.portal rw 0 0\n/dev/sda1 /home ext4 rw 0 0\nx /mnt/fusey fuseblk rw 0 0\n"
        );
        assert_eq!(
            parse_fuse_mounts(&t2),
            [
                PathBuf::from("/mnt/cloud/gdrive"),
                PathBuf::from("/mnt/a b"),
                PathBuf::from("/run/user/1000/doc")
            ]
        );
        assert!(parse_fuse_mounts("garbage\n\n").is_empty());
    }

    /// A stopped command's group is waited for (pipes kept open), so a
    /// child that cleans up after SIGTERM is not cut off.
    #[test]
    fn stop_waits_for_the_group() {
        let t0 = std::time::Instant::now();
        // The leader dies at once on SIGTERM; its child traps it, cleans up
        // for 2.5s (longer than the pipe wait) and reports on stderr.
        let o = run_for(
            &argv(&[
                "sh",
                "-c",
                "sh -c 'trap \"sleep 2.5; echo drained >&2; exit 0\" TERM; sleep 30 & wait' & wait",
            ]),
            Duration::from_millis(300),
        );
        assert!(o.stderr.contains("drained"), "{:?}", o.stderr);
        assert!(o.stderr.contains("timed out"), "{}", o.stderr);
        assert!(t0.elapsed() < Duration::from_secs(10), "{:?}", t0.elapsed());
        // A group that outlives the limit is reported (not waited forever).
        let mut c = Command::new("sh")
            .args(["-c", "sleep 30 & exit 0"])
            .stdout(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let g = c.id() as i32;
        c.wait().unwrap();
        assert!(!wait_group_gone(g, Duration::from_millis(200)));
        kill_group(g, libc::SIGKILL);
        assert!(wait_group_gone(g, Duration::from_secs(5)));
    }

    #[test]
    fn listremotes() {
        let t = "work_drive: s3\ngdrive:      drive\nbad name:  x\nonedrive:    onedrive\n\n";
        assert_eq!(
            parse_listremotes(t),
            vec![
                ("work_drive".to_string(), "s3".to_string()),
                ("gdrive".to_string(), "drive".to_string()),
                ("onedrive".to_string(), "onedrive".to_string())
            ]
        );
    }

    #[test]
    fn show_blocks() {
        let t = "Id=rclone-mount@a.service\nActiveState=active\nSubState=running\nUnitFileState=enabled\n\nId=rclone-bisync@p.timer\nActiveState=inactive\nUnitFileState=\n";
        let m = parse_show(t);
        assert_eq!(m["rclone-mount@a.service"]["SubState"], "running");
        assert_eq!(m["rclone-bisync@p.timer"]["UnitFileState"], "");
        assert_eq!(m.len(), 2);
    }

    #[test]
    fn fuser_parse() {
        assert_eq!(
            parse_fuser(Some(0), " kernel  1234  5678 1234"),
            Busy::InUse(vec![1234, 5678])
        );
        assert_eq!(parse_fuser(Some(0), "kernel"), Busy::Free);
        assert_eq!(parse_fuser(Some(1), ""), Busy::Unknown);
        assert_eq!(parse_fuser(Some(124), "kernel"), Busy::Unknown);
        assert_eq!(parse_fuser(None, ""), Busy::Unknown);
        assert_eq!(
            parse_fuser(Some(0), "/mnt/cloud/a: 42c"),
            Busy::InUse(vec![42])
        );
    }

    #[test]
    fn state_parse() {
        let s = parse_state(
            "time=1700000000\nexit=0\nconflict=a.kdbx.conflict1\nconflict=b/c.conflict2\n",
        );
        assert_eq!(s.time, Some(1_700_000_000));
        assert_eq!(s.exit, Some(0));
        assert_eq!(s.conflicts, ["a.kdbx.conflict1", "b/c.conflict2"]);
        let b = parse_state("time=1\nexit=1\nok=3\nfailed=1\n");
        assert_eq!((b.ok, b.failed), (Some(3), Some(1)));
        assert_eq!(ago(100, 130), "just now");
        assert_eq!(ago(0, 300), "5m ago");
        assert_eq!(ago(0, 7200), "2h ago");
        assert_eq!(ago(0, 200_000), "2d ago");
    }

    #[test]
    fn dirty_meta() {
        use MetaState::*;
        // The shape rclone writes (tab-indented, every field present).
        let real = "{\n\t\"ModTime\": \"2026-01-02T03:04:05.6+01:00\",\n\t\"ATime\": \"2026-01-02T03:04:05Z\",\n\t\"Size\": 12,\n\t\"Rs\": [{\"Pos\": 0, \"Size\": 12}],\n\t\"Fingerprint\": \"12,2026-01-02 03:04:05 +0000 UTC\",\n\t\"Dirty\": DIRTY\n}\n";
        assert_eq!(meta_state(&real.replace("DIRTY", "true")), Dirty);
        assert_eq!(meta_state(&real.replace("DIRTY", "false")), Clean);
        assert_eq!(
            meta_state(r#"{"ModTime":"x","Dirty": true,"Size":1}"#),
            Dirty
        );
        assert_eq!(meta_state(r#"{"Dirty":true}"#), Dirty);
        assert_eq!(meta_state(r#"{"Dirty": false}"#), Clean);
        assert_eq!(meta_state(r#"{"a":{"Dirty":true},"Dirty":false}"#), Clean);
        // Anything else is not a verdict.
        for bad in [
            "",
            "   \n",
            "garbage",
            "\0\0\0\0",
            r#"{"Name":"Dirty"}"#,
            r#"{"Dirty": true"#,
            r#"{"ModTime":"x","Dir"#,
            r#"{"Dirty": "true"}"#,
            r#"{"Dirty": 1}"#,
            r#"{"Dirty": null}"#,
            r#"{"Dirty": true, "Dirty": false}"#,
            r#"{"Dirty": false} x"#,
            r#"{"Dirty": false,}"#,
            r#"[{"Dirty": true}]"#,
            r#"{"Dirty": truex}"#,
            r#"{"Size": 01, "Dirty": false}"#,
        ] {
            assert_eq!(meta_state(bad), Unknown, "{bad:?}");
        }
        let deep = format!(
            "{{\"a\":{}1{}, \"Dirty\": false}}",
            "[".repeat(100),
            "]".repeat(100)
        );
        assert_eq!(meta_state(&deep), Unknown);
    }

    fn scratch(tag: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("omarchy-cloud-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn rename_never_replaces() {
        let d = scratch("noreplace");
        let (a, b, c) = (d.join("a"), d.join("b"), d.join("c"));
        fs::write(&a, "A").unwrap();
        fs::write(&b, "B").unwrap();
        let e = rename_noreplace(&a, &b).unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::AlreadyExists, "{e}");
        assert_eq!(fs::read_to_string(&b).unwrap(), "B");
        rename_noreplace(&a, &c).unwrap();
        assert!(!a.exists());
        assert_eq!(fs::read_to_string(&c).unwrap(), "A");
        let e = rename_noreplace(&a, &d.join("x")).unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::NotFound, "{e}");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn fs_helpers() {
        let d = scratch("fs");
        let f = d.join("sub/x.conf");
        write_atomic(&f, "A=1\n").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "A=1\n");
        assert_eq!(
            fs::metadata(&f).unwrap().permissions().mode() & 0o777,
            0o600
        );
        write_atomic(&d.join("sub/y.conf"), "").unwrap();
        write_atomic(&d.join("sub/bad name.conf"), "").unwrap();
        assert_eq!(list_confs(&d.join("sub")), ["x", "y"]);
        // A symlink is neither replaced nor written through.
        let target = d.join("target");
        fs::write(&target, "keep").unwrap();
        let ln = d.join("sub/ln.conf");
        std::os::unix::fs::symlink(&target, &ln).unwrap();
        assert!(write_atomic(&ln, "X=1\n").is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "keep");
        assert!(fs::symlink_metadata(&ln).unwrap().file_type().is_symlink());
        fs::remove_file(&ln).unwrap();
        write_atomic(&f, "A=2\n").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "A=2\n");
        assert_eq!(
            canonical_lenient(&d.join("sub/../sub/missing/x")),
            fs::canonicalize(d.join("sub")).unwrap().join("missing/x")
        );
        assert!(remove_if_exists(&f).unwrap());
        assert!(!remove_if_exists(&f).unwrap());

        let link = d.join("Cloud/r");
        let target = Path::new("/mnt/cloud/r");
        assert!(create_cloud_link(&link, target).unwrap());
        assert!(!create_cloud_link(&link, target).unwrap());
        assert!(!remove_cloud_link(&link, Path::new("/mnt/cloud/other")).unwrap());
        assert!(remove_cloud_link(&link, target).unwrap());
        fs::create_dir_all(&link).unwrap();
        assert!(!remove_cloud_link(&link, target).unwrap());
        assert!(link.is_dir());
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn dirty_count_is_conservative() {
        let d = scratch("dirty");
        let meta = d.join("vfsMeta/od");
        // Missing: nothing was ever cached, a sure 0.
        assert_eq!(count_dirty(&meta), Some(0));
        fs::create_dir_all(meta.join("a/b")).unwrap();
        fs::write(meta.join("x"), r#"{"Dirty": true}"#).unwrap();
        fs::write(meta.join("a/y"), r#"{"Dirty": false}"#).unwrap();
        fs::write(meta.join("a/b/z"), r#"{"Dirty": true}"#).unwrap();
        assert_eq!(count_dirty(&meta), Some(2));
        // Cut short by the bound: unknown, never a partial count.
        assert_eq!(count_dirty_bounded(&meta, 5), Some(2));
        assert_eq!(count_dirty_bounded(&meta, 4), None);
        assert_eq!(count_dirty_bounded(&meta, 1), None);
        // A metadata file that cannot be read (too big here): unknown.
        fs::write(meta.join("a/big"), vec![b' '; 1024 * 1024 + 10]).unwrap();
        assert_eq!(count_dirty(&meta), None);
        fs::remove_file(meta.join("a/big")).unwrap();
        // The root is a file, not a directory: unknown.
        fs::write(d.join("vfsMeta/file"), "").unwrap();
        assert_eq!(count_dirty(&d.join("vfsMeta/file")), None);
        // An unreadable subdirectory (as a normal user; root reads anything).
        let locked = meta.join("a/b");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read_dir(&locked).is_err() {
            assert_eq!(count_dirty(&meta), None);
        }
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(count_dirty(&meta), Some(2));
        // An empty, truncated or non-JSON metadata file: unknown, never clean.
        for bad in ["", "{\"Dirty\": fal", "garbage"] {
            fs::write(meta.join("a/bad"), bad).unwrap();
            assert_eq!(count_dirty(&meta), None, "{bad:?}");
        }
        fs::remove_file(meta.join("a/bad")).unwrap();
        // A symlink entry: unknown.
        std::os::unix::fs::symlink("/nonexistent", meta.join("a/ln")).unwrap();
        assert_eq!(count_dirty(&meta), None);
        fs::remove_file(meta.join("a/ln")).unwrap();
        assert_eq!(count_dirty(&meta), Some(2));
        // Valid clean only: 0; one valid dirty: 1.
        let one = d.join("vfsMeta/one");
        fs::create_dir_all(&one).unwrap();
        fs::write(one.join("f"), r#"{"Dirty": false}"#).unwrap();
        assert_eq!(count_dirty(&one), Some(0));
        fs::write(one.join("g"), r#"{"Dirty": true}"#).unwrap();
        assert_eq!(count_dirty(&one), Some(1));
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn cache_removal() {
        let d = scratch("cache");
        let meta = d.join("vfsMeta/od/sub");
        fs::create_dir_all(&meta).unwrap();
        fs::write(meta.join("b"), r#"{"Dirty": false}"#).unwrap();
        fs::create_dir_all(d.join("vfs/od")).unwrap();
        fs::write(d.join("vfs/od/data"), "x").unwrap();
        fs::create_dir_all(d.join("vfs/other")).unwrap();
        let trash = format!(".od.clearing-{}", std::process::id());
        // The recheck sees the renamed vfsMeta, the original names are gone.
        let mut seen = None;
        let done = clear_cache_dirs(&d, "od", |m| {
            seen = Some(m.to_path_buf());
            assert!(!d.join("vfsMeta/od").exists() && !d.join("vfs/od").exists());
            assert!(d.join("vfs").join(&trash).join("data").exists());
            count_dirty(m)
                .filter(|&n| n == 0)
                .map(|_| ())
                .ok_or("dirty".into())
        })
        .unwrap();
        assert_eq!(done, ["vfsMeta/od", "vfs/od"]);
        assert_eq!(seen.unwrap(), d.join("vfsMeta").join(&trash));
        assert!(!d.join("vfsMeta").join(&trash).exists() && !d.join("vfs").join(&trash).exists());
        assert!(d.join("vfs/other").exists(), "other remotes are kept");
        // Nothing there: nothing cleared, the recheck still runs.
        assert_eq!(
            clear_cache_dirs(&d, "od", |_| Ok(())).unwrap(),
            Vec::<String>::new()
        );
        assert!(clear_cache_dirs(&d, "od", |_| Err("busy".into())).is_err());

        // A recheck that finds a pending upload (or a started mount): both are
        // renamed back, untouched, and it refuses.
        fs::create_dir_all(&meta).unwrap();
        fs::write(meta.join("a"), r#"{"Dirty": true}"#).unwrap();
        fs::create_dir_all(d.join("vfs/od")).unwrap();
        fs::write(d.join("vfs/od/data"), "x").unwrap();
        let e = clear_cache_dirs(&d, "od", |m| match count_dirty(m) {
            Some(0) => Ok(()),
            _ => Err("uploads pending".into()),
        })
        .unwrap_err();
        assert_eq!(e, "uploads pending");
        assert!(meta.join("a").exists() && d.join("vfs/od/data").exists());
        assert!(!d.join("vfsMeta").join(&trash).exists() && !d.join("vfs").join(&trash).exists());
        // Unknown counts refuse the same way (an empty metadata file).
        fs::write(meta.join("a"), "").unwrap();
        assert!(
            clear_cache_dirs(&d, "od", |m| count_dirty(m)
                .map(|_| ())
                .ok_or("unknown".into()))
            .is_err()
        );
        assert!(meta.join("a").exists());
        // A mount that recreated vfs/<r> meanwhile: the trash is kept, named.
        let e = clear_cache_dirs(&d, "od", |_| {
            fs::create_dir_all(d.join("vfs/od")).unwrap();
            fs::write(d.join("vfs/od/new"), "y").unwrap();
            Err("the mount is active".into())
        })
        .unwrap_err();
        assert!(e.starts_with("the mount is active; could not move"), "{e}");
        assert!(e.contains(&trash) && e.contains("by hand"), "{e}");
        assert!(meta.join("a").exists(), "vfsMeta was moved back");
        assert!(d.join("vfs").join(&trash).join("data").exists());
        // A leftover trash name: refused before anything moves.
        let e = clear_cache_dirs(&d, "od", |_| Ok(())).unwrap_err();
        assert!(e.contains("left over"), "{e}");
        assert!(meta.join("a").exists() && d.join("vfs/od/new").exists());
        fs::remove_dir_all(d.join("vfs").join(&trash)).unwrap();

        // Names and symlinks.
        assert!(clear_cache_dirs(&d, "../x", |_| Ok(())).is_err());
        let keep = d.join("precious");
        fs::create_dir_all(&keep).unwrap();
        std::os::unix::fs::symlink(&keep, d.join("vfs/ln")).unwrap();
        assert!(clear_cache_dirs(&d, "ln", |_| Ok(())).is_err());
        assert!(keep.exists());
        let root_ln = d.join("rootln");
        std::os::unix::fs::symlink(&d, &root_ln).unwrap();
        assert!(clear_cache_dirs(&root_ln, "od", |_| Ok(())).is_err());
        assert!(meta.join("a").exists());
        fs::write(d.join("vfs/file"), "").unwrap();
        assert!(clear_cache_dirs(&d, "file", |_| Ok(())).is_err());
        assert!(dir_is_empty(&keep));
        assert!(!dir_is_empty(&d.join("missing")));
        assert!(!dir_is_empty(&d));
        fs::remove_dir_all(&d).unwrap();
    }
}
