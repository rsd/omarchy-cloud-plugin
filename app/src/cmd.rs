//! Paths and command construction. Every external command is an argument
//! vector built here by a pure function from already validated names — no
//! shell is ever involved.

use crate::envfile::{DEFAULT_ROOT, RootSetting};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// fuser runs under `timeout -k 2 10`, like the plugin's stop check.
pub const CHECK_TIMEOUT_S: &str = "10";
pub const CHECK_KILL_S: &str = "2";

/// Where everything lives. HOME-fixed: `~/.config`, `~/.local/state` and
/// `~/.cache`, whatever XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_CACHE_HOME
/// say, like the helper scripts, the bar and the units (the user manager's
/// environment usually lacks the shell's XDG variables, so following them
/// would split the parts).
#[derive(Clone, Debug)]
pub struct Paths {
    pub home: PathBuf,
    /// `~/.config`.
    pub config_home: PathBuf,
    /// `~/.local/state`.
    pub state_home: PathBuf,
    /// The mount-root setting (cloud.env) as last read (`sys::read_root`);
    /// Absent until then.
    pub root_setting: RootSetting,
}

/// `~/…` when `p` is under `home`, else `p` as is.
pub fn tilde_of(home: &Path, p: &Path) -> String {
    match p.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~/".to_string(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

impl Paths {
    pub fn new(home: PathBuf) -> Paths {
        Paths {
            config_home: home.join(".config"),
            state_home: home.join(".local/state"),
            home,
            root_setting: RootSetting::Absent,
        }
    }

    /// From the environment `get` reads: only HOME, which must be an
    /// absolute path without control characters or `.`/`..` segments.
    /// XDG_* variables are never read.
    pub fn from_env(get: impl Fn(&str) -> Option<OsString>) -> Option<Paths> {
        let h = PathBuf::from(get("HOME")?);
        (h.is_absolute() && crate::validate::expand_local(&h.to_string_lossy(), &h).is_ok())
            .then(|| Paths::new(h))
    }

    /// The mount-root setting, `~/.config/omarchy-cloud/cloud.env`.
    pub fn cloud_env(&self) -> PathBuf {
        self.home.join(".config/omarchy-cloud/cloud.env")
    }
    /// The configured root when the setting is valid.
    pub fn configured_root(&self) -> Option<&Path> {
        match &self.root_setting {
            RootSetting::Valid(p) => Some(p),
            _ => None,
        }
    }
    /// The root mounts live under: the configured one, else the unit's
    /// default /mnt/cloud.
    pub fn root(&self) -> &Path {
        self.configured_root()
            .unwrap_or_else(|| Path::new(DEFAULT_ROOT))
    }
    /// The mount env files: the unit reads `%h/.config/rclone-mount/%i.env`.
    pub fn mount_env_dir(&self) -> PathBuf {
        self.home.join(".config/rclone-mount")
    }
    pub fn mount_env(&self, remote: &str) -> PathBuf {
        self.mount_env_dir().join(format!("{remote}.env"))
    }
    /// `<root>/<remote>`, where the unit mounts it.
    pub fn mount_point(&self, remote: &str) -> PathBuf {
        self.root().join(remote)
    }
    pub fn cloud_dir(&self) -> PathBuf {
        self.home.join("Cloud")
    }
    pub fn cloud_link(&self, remote: &str) -> PathBuf {
        self.cloud_dir().join(remote)
    }
    pub fn bisync_dir(&self) -> PathBuf {
        self.config_home.join("rclone-bisync")
    }
    pub fn pair_conf(&self, pair: &str) -> PathBuf {
        self.bisync_dir().join(format!("{pair}.conf"))
    }
    pub fn pair_filter(&self, pair: &str) -> PathBuf {
        self.bisync_dir().join(format!("{pair}.filter"))
    }
    pub fn pair_state(&self, pair: &str) -> PathBuf {
        self.state_home
            .join("rclone-bisync")
            .join(format!("{pair}.state"))
    }
    pub fn backup_dir(&self) -> PathBuf {
        self.config_home.join("rclone-backup")
    }
    pub fn job_conf(&self, job: &str) -> PathBuf {
        self.backup_dir().join(format!("{job}.conf"))
    }
    pub fn job_files(&self, job: &str) -> PathBuf {
        self.backup_dir().join(format!("{job}.files"))
    }
    pub fn job_state(&self, job: &str) -> PathBuf {
        self.state_home
            .join("rclone-backup")
            .join(format!("{job}.state"))
    }
    /// The mount units' cache dir (`--cache-dir %h/.cache/rclone`).
    pub fn rclone_cache(&self) -> PathBuf {
        self.home.join(".cache/rclone")
    }
    pub fn vfs_dir(&self, remote: &str) -> PathBuf {
        self.rclone_cache().join("vfs").join(remote)
    }
    pub fn vfs_meta_dir(&self, remote: &str) -> PathBuf {
        self.rclone_cache().join("vfsMeta").join(remote)
    }
    pub fn bisync_bin(&self) -> PathBuf {
        self.home.join(".local/bin/rclone-bisync")
    }
    pub fn backup_bin(&self) -> PathBuf {
        self.home.join(".local/bin/rclone-backup")
    }
    /// The bisync work dir: the helper passes `--workdir
    /// "$HOME/.cache/rclone/bisync"` to every bisync call, so the service and
    /// a run from a terminal share the listings. The only dir that decides
    /// whether a pair has synced, and the one a pair's listings are deleted
    /// from.
    pub fn bisync_workdir(&self) -> PathBuf {
        self.home.join(".cache/rclone/bisync")
    }
    /// The drop-in `rclone-backup setup` writes (the job's SCHEDULE): a job
    /// without it was never set up.
    pub fn job_timer_dropin(&self, job: &str) -> PathBuf {
        self.config_home
            .join("systemd/user")
            .join(format!("rclone-backup@{job}.timer.d/10-schedule.conf"))
    }
    /// The drop-in `rclone-bisync setup` writes for the pair's folder watch
    /// (PathChanged=); without it the .path unit cannot load.
    pub fn pair_path_dropin(&self, pair: &str) -> PathBuf {
        self.config_home
            .join("systemd/user")
            .join(format!("rclone-bisync@{pair}.path.d/10-local.conf"))
    }
    /// A config-file path as stored (`~/…` when under home).
    pub fn tilde(&self, p: &Path) -> String {
        tilde_of(&self.home, p)
    }
}

/// rclone's `bilib.CanonicalPath`: trim `/` and `\` at both ends, then each
/// of whitespace `\ / : ? *` becomes `_`.
fn rclone_canonical(s: &str) -> String {
    s.trim_matches(|c| c == '/' || c == '\\')
        .chars()
        .map(|c| match c {
            '\t' | '\n' | '\x0c' | '\r' | ' ' | '\\' | '/' | ':' | '?' | '*' => '_',
            c => c,
        })
        .collect()
}

/// The files rclone bisync keeps for a session in one work dir: both
/// listings with their `-old`, `-err` and `-new` variants, and the lock.
pub fn bisync_session_files(workdir: &Path, session: &str) -> Vec<PathBuf> {
    let mut v = Vec::new();
    for k in ["path1", "path2"] {
        for suffix in ["", "-old", "-err", "-new"] {
            v.push(workdir.join(format!("{session}.{k}.lst{suffix}")));
        }
    }
    v.push(workdir.join(format!("{session}.lck")));
    v
}

/// The base name rclone bisync gives a pair's listings
/// (`<session>.path1.lst`, `<session>.path2.lst`) for `rclone bisync LOCAL
/// REMOTE`, as rclone's `bilib.SessionName` builds it. Valid for a named
/// cloud remote (its backend drops the slashes around the root); an alias, a
/// `local`-type remote or one with inline options gets another name, and the
/// caller then finds no listing and takes the safe (check → resync) path.
pub fn bisync_session(local: &Path, remote_spec: &str) -> String {
    let (name, path) = remote_spec.split_once(':').unwrap_or((remote_spec, ""));
    let local = format!("{}/", local.display());
    let remote = format!("{name}:{}/", path.trim_matches('/'));
    format!(
        "{}..{}",
        rclone_canonical(&local),
        rclone_canonical(&remote)
    )
}

fn v(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

// ------------------------------------------------------------ unit names

pub fn mount_unit(remote: &str) -> String {
    format!("rclone-mount@{remote}.service")
}
pub fn pair_timer(pair: &str) -> String {
    format!("rclone-bisync@{pair}.timer")
}
pub fn pair_path(pair: &str) -> String {
    format!("rclone-bisync@{pair}.path")
}
pub fn pair_service(pair: &str) -> String {
    format!("rclone-bisync@{pair}.service")
}
pub fn job_timer(job: &str) -> String {
    format!("rclone-backup@{job}.timer")
}
pub fn job_service(job: &str) -> String {
    format!("rclone-backup@{job}.service")
}

// ------------------------------------------------------------- systemctl

pub const SHOW_PROPS: &str = "Id,ActiveState,SubState,UnitFileState,Result,ExecMainExitTimestamp,InactiveEnterTimestamp,ExecMainStatus";

/// Timestamps as `@<unix seconds>`, so they compare with the state files.
pub fn systemctl_show_cmd(units: &[String]) -> Vec<String> {
    let mut a = v(&[
        "systemctl",
        "--user",
        "show",
        "--timestamp=unix",
        "-p",
        SHOW_PROPS,
    ]);
    a.extend(units.iter().cloned());
    a
}

fn systemctl(verb: &[&str], units: &[String]) -> Vec<String> {
    let mut a = v(&["systemctl", "--user"]);
    a.extend(verb.iter().map(|s| s.to_string()));
    a.extend(units.iter().cloned());
    a
}

pub fn enable_now_cmd(units: &[String]) -> Vec<String> {
    systemctl(&["enable", "--now"], units)
}
pub fn disable_now_cmd(units: &[String]) -> Vec<String> {
    systemctl(&["disable", "--now"], units)
}
pub fn enable_cmd(units: &[String]) -> Vec<String> {
    systemctl(&["enable"], units)
}
pub fn disable_cmd(units: &[String]) -> Vec<String> {
    systemctl(&["disable"], units)
}
pub fn start_cmd(unit: &str) -> Vec<String> {
    systemctl(&["start"], &[unit.to_string()])
}
pub fn start_no_block_cmd(unit: &str) -> Vec<String> {
    systemctl(&["start", "--no-block"], &[unit.to_string()])
}
pub fn is_active_cmd(unit: &str) -> Vec<String> {
    systemctl(&["is-active"], &[unit.to_string()])
}
pub fn stop_cmd(unit: &str) -> Vec<String> {
    systemctl(&["stop"], &[unit.to_string()])
}
pub fn restart_cmd(unit: &str) -> Vec<String> {
    systemctl(&["restart"], &[unit.to_string()])
}

pub fn mount_enable_cmd(remote: &str) -> Vec<String> {
    enable_now_cmd(&[mount_unit(remote)])
}
pub fn mount_disable_cmd(remote: &str) -> Vec<String> {
    disable_now_cmd(&[mount_unit(remote)])
}
pub fn pair_enable_cmd(pair: &str) -> Vec<String> {
    enable_now_cmd(&[pair_timer(pair), pair_path(pair)])
}
pub fn pair_disable_cmd(pair: &str) -> Vec<String> {
    disable_now_cmd(&[pair_timer(pair), pair_path(pair)])
}
pub fn pair_sync_now_cmd(pair: &str) -> Vec<String> {
    start_no_block_cmd(&pair_service(pair))
}
/// Resume a paused pair: the timer and the folder watch, then one run.
pub fn pair_resume_cmds(pair: &str) -> [Vec<String>; 2] {
    [pair_enable_cmd(pair), pair_sync_now_cmd(pair)]
}
/// Restart a pair's folder watch and timer after they failed (a trigger or
/// start limit): clear the failed state of the service and both triggers (a
/// failed service would otherwise keep its start-limit counter), then start
/// the triggers (starting an active unit is a no-op).
pub fn pair_recover_cmds(pair: &str) -> [Vec<String>; 2] {
    [
        systemctl(
            &["reset-failed"],
            &[pair_service(pair), pair_path(pair), pair_timer(pair)],
        ),
        systemctl(&["start"], &[pair_path(pair), pair_timer(pair)]),
    ]
}
pub fn job_enable_cmd(job: &str) -> Vec<String> {
    enable_now_cmd(&[job_timer(job)])
}
pub fn job_disable_cmd(job: &str) -> Vec<String> {
    disable_now_cmd(&[job_timer(job)])
}
pub fn job_run_now_cmd(job: &str) -> Vec<String> {
    start_no_block_cmd(&job_service(job))
}

pub fn journal_cmd(unit: &str) -> Vec<String> {
    v(&[
        "journalctl",
        "--user",
        "-u",
        unit,
        "-n",
        "30",
        "--no-pager",
        "-o",
        "short-iso",
    ])
}

// ---------------------------------------------------------------- rclone

pub fn listremotes_cmd() -> Vec<String> {
    v(&["rclone", "listremotes", "--long"])
}
pub fn rclone_config_cmd() -> Vec<String> {
    v(&["rclone", "config"])
}
pub fn reconnect_cmd(remote: &str) -> Vec<String> {
    v(&["rclone", "config", "reconnect", &format!("{remote}:")])
}
pub fn config_delete_cmd(remote: &str) -> Vec<String> {
    v(&["rclone", "config", "delete", remote])
}

/// Prints the path of rclone.conf (the OAuth client is written there
/// in-process, never on an argument vector: `app::set_client`).
pub fn config_file_cmd() -> Vec<String> {
    v(&["rclone", "config", "file"])
}

/// Copy remote → local, used only to seed an empty local folder before the
/// first resync. Never sync, never --delete, never toward the remote.
pub fn copy_first_cmd(remote_spec: &str, local: &Path, filter: Option<&Path>) -> Vec<String> {
    let mut a = v(&["rclone", "copy", remote_spec, &path_str(local)]);
    if let Some(f) = filter {
        a.push("--filter-from".into());
        a.push(path_str(f));
    }
    a
}

// --------------------------------------------------------------- helpers

pub fn bisync_cmd(paths: &Paths, sub: &str, pair: &str) -> Vec<String> {
    vec![
        path_str(&paths.bisync_bin()),
        sub.to_string(),
        pair.to_string(),
    ]
}
pub fn backup_cmd(paths: &Paths, sub: &str, job: &str) -> Vec<String> {
    vec![
        path_str(&paths.backup_bin()),
        sub.to_string(),
        job.to_string(),
    ]
}

/// Who has files open on a mount: `timeout -k 2 10 fuser -v -M -m <mnt>`.
pub fn fuser_cmd(mount: &Path) -> Vec<String> {
    v(&[
        "timeout",
        "-k",
        CHECK_KILL_S,
        CHECK_TIMEOUT_S,
        "fuser",
        "-v",
        "-M",
        "-m",
        &path_str(mount),
    ])
}

/// The editor for a files list: $VISUAL, else $EDITOR (split on whitespace,
/// no shell), else nvim if present, else vi.
pub fn editor_cmd(
    visual: Option<&str>,
    editor: Option<&str>,
    have_nvim: bool,
    file: &Path,
) -> Vec<String> {
    let chosen = [visual, editor]
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|s| !s.is_empty() && !crate::validate::has_control(s));
    let mut a: Vec<String> = match chosen {
        Some(s) => s.split_whitespace().map(String::from).collect(),
        None if have_nvim => vec!["nvim".into()],
        None => vec!["vi".into()],
    };
    a.push("--".into());
    a.push(path_str(file));
    a
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths() -> Paths {
        Paths::new(PathBuf::from("/home/u"))
    }

    #[test]
    fn path_layout() {
        let p = paths();
        assert_eq!(
            p.mount_env("gdrive"),
            PathBuf::from("/home/u/.config/rclone-mount/gdrive.env")
        );
        assert_eq!(p.mount_point("gdrive"), PathBuf::from("/mnt/cloud/gdrive"));
        assert_eq!(
            p.cloud_link("gdrive"),
            PathBuf::from("/home/u/Cloud/gdrive")
        );
        assert_eq!(
            p.pair_conf("vault-A"),
            PathBuf::from("/home/u/.config/rclone-bisync/vault-A.conf")
        );
        assert_eq!(
            p.pair_filter("vault-A"),
            PathBuf::from("/home/u/.config/rclone-bisync/vault-A.filter")
        );
        assert_eq!(
            p.pair_state("vault-A"),
            PathBuf::from("/home/u/.local/state/rclone-bisync/vault-A.state")
        );
        assert_eq!(
            p.job_state("j"),
            PathBuf::from("/home/u/.local/state/rclone-backup/j.state")
        );
        assert_eq!(
            p.job_files("j"),
            PathBuf::from("/home/u/.config/rclone-backup/j.files")
        );
        assert_eq!(
            p.vfs_dir("od"),
            PathBuf::from("/home/u/.cache/rclone/vfs/od")
        );
        assert_eq!(
            p.vfs_meta_dir("od"),
            PathBuf::from("/home/u/.cache/rclone/vfsMeta/od")
        );
        assert_eq!(p.tilde(Path::new("/home/u/Docs")), "~/Docs");
        assert_eq!(p.tilde(Path::new("/srv/x")), "/srv/x");
        assert_eq!(p.tilde(Path::new("/home/u")), "~/");
        assert_eq!(
            p.bisync_workdir(),
            PathBuf::from("/home/u/.cache/rclone/bisync")
        );
        assert_eq!(
            p.pair_path_dropin("p"),
            PathBuf::from("/home/u/.config/systemd/user/rclone-bisync@p.path.d/10-local.conf")
        );
        assert_eq!(
            p.job_timer_dropin("j"),
            PathBuf::from("/home/u/.config/systemd/user/rclone-backup@j.timer.d/10-schedule.conf")
        );
        assert_eq!(
            p.cloud_env(),
            PathBuf::from("/home/u/.config/omarchy-cloud/cloud.env")
        );
    }

    /// D6: XDG variables set elsewhere change nothing; only HOME is read.
    #[test]
    fn paths_are_home_fixed() {
        let env = |k: &str| -> Option<OsString> {
            match k {
                "HOME" => Some("/home/u".into()),
                "XDG_CONFIG_HOME" => Some("/elsewhere/config".into()),
                "XDG_STATE_HOME" => Some("/elsewhere/state".into()),
                "XDG_CACHE_HOME" => Some("/elsewhere/cache".into()),
                "XDG_DATA_HOME" => Some("/elsewhere/data".into()),
                _ => None,
            }
        };
        let x = Paths::from_env(env).unwrap();
        assert_eq!(x.config_home, PathBuf::from("/home/u/.config"));
        assert_eq!(x.state_home, PathBuf::from("/home/u/.local/state"));
        assert_eq!(
            x.pair_conf("p"),
            PathBuf::from("/home/u/.config/rclone-bisync/p.conf")
        );
        assert_eq!(
            x.job_files("j"),
            PathBuf::from("/home/u/.config/rclone-backup/j.files")
        );
        assert_eq!(
            x.pair_state("p"),
            PathBuf::from("/home/u/.local/state/rclone-bisync/p.state")
        );
        assert_eq!(
            x.job_state("j"),
            PathBuf::from("/home/u/.local/state/rclone-backup/j.state")
        );
        assert_eq!(
            x.mount_env("r"),
            PathBuf::from("/home/u/.config/rclone-mount/r.env")
        );
        assert_eq!(
            x.cloud_env(),
            PathBuf::from("/home/u/.config/omarchy-cloud/cloud.env")
        );
        assert_eq!(
            x.bisync_workdir(),
            PathBuf::from("/home/u/.cache/rclone/bisync")
        );
        assert_eq!(x.vfs_dir("r"), PathBuf::from("/home/u/.cache/rclone/vfs/r"));
        assert_eq!(
            x.pair_path_dropin("p"),
            PathBuf::from("/home/u/.config/systemd/user/rclone-bisync@p.path.d/10-local.conf")
        );
        let all = format!("{x:?}");
        assert!(!all.contains("elsewhere"), "{all}");
        // HOME must be usable.
        for bad in ["", "rel", "/a/../b", "/a\nb"] {
            assert!(
                Paths::from_env(|k| (k == "HOME").then(|| bad.into())).is_none(),
                "{bad:?}"
            );
        }
        assert!(Paths::from_env(|_| None).is_none());
    }

    #[test]
    fn mount_points_follow_the_root() {
        let mut p = paths();
        assert_eq!(p.root(), Path::new("/mnt/cloud"));
        assert_eq!(p.configured_root(), None);
        p.root_setting = RootSetting::Valid(PathBuf::from("/srv/cloud"));
        assert_eq!(p.mount_point("od"), PathBuf::from("/srv/cloud/od"));
        assert_eq!(p.configured_root(), Some(Path::new("/srv/cloud")));
        assert_eq!(
            fuser_cmd(&p.mount_point("od")).last().unwrap(),
            "/srv/cloud/od"
        );
        // An invalid setting is never used as a path.
        p.root_setting = RootSetting::Invalid("/home/u/x".into());
        assert_eq!(p.mount_point("od"), PathBuf::from("/mnt/cloud/od"));
        assert_eq!(p.configured_root(), None);
    }

    #[test]
    fn bisync_session_names() {
        // Checked against rclone v1.75 (local path, named remote).
        assert_eq!(
            bisync_session(Path::new("/home/alice/Vaults"), "onedrive:Backup/Vaults"),
            "home_alice_Vaults..onedrive_Backup_Vaults"
        );
        // Cloud backends drop the slashes around their root.
        assert_eq!(
            bisync_session(Path::new("/tmp/a b"), "od:/Backup/K/"),
            "tmp_a_b..od_Backup_K"
        );
        assert_eq!(bisync_session(Path::new("/x"), "od:"), "x..od_");
        // A live session (its listings exist under that name).
        assert_eq!(
            bisync_session(Path::new("/home/user/Vaults"), "personal-drive:Vaults"),
            "home_user_Vaults..personal-drive_Vaults"
        );
        let wd = Path::new("/w");
        let files: Vec<String> = bisync_session_files(wd, "s")
            .iter()
            .map(|f| f.display().to_string())
            .collect();
        assert_eq!(
            files,
            [
                "/w/s.path1.lst",
                "/w/s.path1.lst-old",
                "/w/s.path1.lst-err",
                "/w/s.path1.lst-new",
                "/w/s.path2.lst",
                "/w/s.path2.lst-old",
                "/w/s.path2.lst-err",
                "/w/s.path2.lst-new",
                "/w/s.lck"
            ]
        );
        assert_eq!(
            pair_resume_cmds("p"),
            [pair_enable_cmd("p"), pair_sync_now_cmd("p")]
        );
        assert_eq!(
            is_active_cmd("rclone-mount@a.service"),
            ["systemctl", "--user", "is-active", "rclone-mount@a.service"]
        );
    }

    #[test]
    fn pair_recover_argv() {
        let [reset, start] = pair_recover_cmds("vault-A");
        assert_eq!(
            reset,
            [
                "systemctl",
                "--user",
                "reset-failed",
                "rclone-bisync@vault-A.service",
                "rclone-bisync@vault-A.path",
                "rclone-bisync@vault-A.timer"
            ]
        );
        assert_eq!(
            start,
            [
                "systemctl",
                "--user",
                "start",
                "rclone-bisync@vault-A.path",
                "rclone-bisync@vault-A.timer"
            ]
        );
    }

    #[test]
    fn systemctl_argv() {
        assert_eq!(
            mount_enable_cmd("gdrive"),
            [
                "systemctl",
                "--user",
                "enable",
                "--now",
                "rclone-mount@gdrive.service"
            ]
        );
        assert_eq!(
            mount_disable_cmd("gdrive"),
            [
                "systemctl",
                "--user",
                "disable",
                "--now",
                "rclone-mount@gdrive.service"
            ]
        );
        assert_eq!(
            enable_cmd(&[mount_unit("a")]),
            ["systemctl", "--user", "enable", "rclone-mount@a.service"]
        );
        assert_eq!(
            disable_cmd(&[mount_unit("a")]),
            ["systemctl", "--user", "disable", "rclone-mount@a.service"]
        );
        assert_eq!(
            restart_cmd(&mount_unit("a")),
            ["systemctl", "--user", "restart", "rclone-mount@a.service"]
        );
        assert_eq!(
            start_cmd(&mount_unit("a")),
            ["systemctl", "--user", "start", "rclone-mount@a.service"]
        );
        assert_eq!(
            stop_cmd(&mount_unit("a")),
            ["systemctl", "--user", "stop", "rclone-mount@a.service"]
        );
        assert_eq!(
            pair_enable_cmd("p"),
            [
                "systemctl",
                "--user",
                "enable",
                "--now",
                "rclone-bisync@p.timer",
                "rclone-bisync@p.path"
            ]
        );
        assert_eq!(
            pair_disable_cmd("p"),
            [
                "systemctl",
                "--user",
                "disable",
                "--now",
                "rclone-bisync@p.timer",
                "rclone-bisync@p.path"
            ]
        );
        assert_eq!(
            pair_sync_now_cmd("p"),
            [
                "systemctl",
                "--user",
                "start",
                "--no-block",
                "rclone-bisync@p.service"
            ]
        );
        assert_eq!(
            job_enable_cmd("j"),
            [
                "systemctl",
                "--user",
                "enable",
                "--now",
                "rclone-backup@j.timer"
            ]
        );
        assert_eq!(
            job_disable_cmd("j"),
            [
                "systemctl",
                "--user",
                "disable",
                "--now",
                "rclone-backup@j.timer"
            ]
        );
        assert_eq!(
            job_run_now_cmd("j"),
            [
                "systemctl",
                "--user",
                "start",
                "--no-block",
                "rclone-backup@j.service"
            ]
        );
        assert_eq!(
            systemctl_show_cmd(&[mount_unit("a"), pair_timer("p")]),
            [
                "systemctl",
                "--user",
                "show",
                "--timestamp=unix",
                "-p",
                SHOW_PROPS,
                "rclone-mount@a.service",
                "rclone-bisync@p.timer"
            ]
        );
        assert_eq!(
            journal_cmd("rclone-mount@a.service"),
            [
                "journalctl",
                "--user",
                "-u",
                "rclone-mount@a.service",
                "-n",
                "30",
                "--no-pager",
                "-o",
                "short-iso"
            ]
        );
    }

    #[test]
    fn rclone_argv() {
        assert_eq!(listremotes_cmd(), ["rclone", "listremotes", "--long"]);
        assert_eq!(rclone_config_cmd(), ["rclone", "config"]);
        assert_eq!(
            reconnect_cmd("gdrive"),
            ["rclone", "config", "reconnect", "gdrive:"]
        );
        assert_eq!(
            config_delete_cmd("gdrive"),
            ["rclone", "config", "delete", "gdrive"]
        );
        assert_eq!(
            copy_first_cmd(
                "od:Backup/K",
                Path::new("/home/u/K"),
                Some(Path::new("/home/u/.config/rclone-bisync/k.filter"))
            ),
            [
                "rclone",
                "copy",
                "od:Backup/K",
                "/home/u/K",
                "--filter-from",
                "/home/u/.config/rclone-bisync/k.filter"
            ]
        );
        assert_eq!(
            copy_first_cmd("od:", Path::new("/l"), None),
            ["rclone", "copy", "od:", "/l"]
        );
    }

    #[test]
    fn config_file_argv() {
        assert_eq!(config_file_cmd(), ["rclone", "config", "file"]);
    }

    #[test]
    fn helper_argv() {
        let p = paths();
        assert_eq!(
            bisync_cmd(&p, "check", "vault-A"),
            ["/home/u/.local/bin/rclone-bisync", "check", "vault-A"]
        );
        assert_eq!(
            bisync_cmd(&p, "setup", "x"),
            ["/home/u/.local/bin/rclone-bisync", "setup", "x"]
        );
        assert_eq!(
            backup_cmd(&p, "list", "j"),
            ["/home/u/.local/bin/rclone-backup", "list", "j"]
        );
        assert_eq!(
            fuser_cmd(&p.mount_point("gdrive")),
            [
                "timeout",
                "-k",
                "2",
                "10",
                "fuser",
                "-v",
                "-M",
                "-m",
                "/mnt/cloud/gdrive"
            ]
        );
    }

    #[test]
    fn editor_argv() {
        let f = Path::new("/home/u/.config/rclone-backup/j.files");
        let fs = "/home/u/.config/rclone-backup/j.files";
        assert_eq!(
            editor_cmd(Some("code -w"), Some("vim"), true, f),
            ["code", "-w", "--", fs]
        );
        assert_eq!(editor_cmd(None, Some("vim"), true, f), ["vim", "--", fs]);
        assert_eq!(editor_cmd(Some(" "), None, true, f), ["nvim", "--", fs]);
        assert_eq!(editor_cmd(None, None, false, f), ["vi", "--", fs]);
    }
}
