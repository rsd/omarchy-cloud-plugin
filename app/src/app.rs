//! Application state, key handling and the action flows. Anything slow runs
//! in a worker thread (one at a time) that reports back an `Outcome`;
//! anything interactive (rclone config, reconnect, the editor) is requested
//! through `App::interactive` and run by the main loop with the TUI suspended.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::cmd::{self, Paths};
use crate::conf::{self, JobConf, PairConf};
use crate::envfile::{self, DEFAULT_ROOT, EnvFile, MANAGED, RootSetting};
use crate::rclone_conf;
use crate::secret::{self, Secret};
use crate::sys::{self, Busy, Output, State, UnitProps};
use crate::validate;

/// How long a status message stays on screen.
pub const STATUS_TTL: Duration = Duration::from_secs(5);
/// Time limit of the refresh commands (`rclone listremotes`, `systemctl show`).
const REFRESH_LIMIT: Duration = Duration::from_secs(10);
/// The helpers' exit status when the pair's lock is held by another run.
pub const EXIT_BUSY: i32 = 75;
/// `rclone-bisync check` / `resync`: nothing to sync, no file on either side.
pub const EXIT_EMPTY: i32 = 4;
/// What the TUI says when a pair has no file on either side.
pub const NOTHING_TO_SYNC: &str =
    "nothing to sync: no file on either side (after the filter); put a file on one side first";

// ------------------------------------------------------------------ data

pub struct Remote {
    pub name: String,
    pub kind: String,
    pub active: String,
    pub sub: String,
    pub file_state: String,
}

pub struct Pair {
    pub name: String,
    pub conf: Result<PairConf, String>,
    pub timer_file: String,
    pub path_file: String,
    pub timer_active: String,
    pub timer_result: String,
    pub path_active: String,
    pub path_result: String,
    pub svc_active: String,
    pub svc_result: String,
    pub exit_ts: String,
    pub exit_status: String,
    pub state: Option<State>,
    /// The include patterns of the pair's generated filter, as the form
    /// field writes them (`a.kdbx, Docs/`); None: no filter, or not ours.
    pub include: Option<String>,
}

fn enabled_state(file_state: &str) -> bool {
    matches!(file_state, "enabled" | "enabled-runtime")
}

impl Pair {
    /// Syncing: the timer or the folder watch enabled (the bar's rule). A
    /// pause disables both.
    pub fn enabled(&self) -> bool {
        enabled_state(&self.timer_file) || enabled_state(&self.path_file)
    }
    /// What stopped of the folder watch and the timer ("folder watch stopped
    /// (trigger-limit-hit)"), or None while both do their job.
    pub fn watch_problem(&self) -> Option<String> {
        let parts: Vec<String> = [
            (
                "folder watch",
                &self.path_file,
                &self.path_active,
                &self.path_result,
            ),
            (
                "timer",
                &self.timer_file,
                &self.timer_active,
                &self.timer_result,
            ),
        ]
        .iter()
        .filter_map(|(what, f, a, r)| {
            trigger_stopped(f, a, r).map(|why| format!("{what} stopped ({why})"))
        })
        .collect();
        (!parts.is_empty()).then(|| parts.join(", "))
    }
}

/// Why an enabled .path or .timer starts no syncs, or None. Enabled but not
/// active: a path unit that hit its trigger limit (or whose service hit its
/// start limit) fails and stops watching until it is restarted. The reason
/// is systemd's Result, else the ActiveState. An unknown state ("", no
/// answer yet) is not a problem. Pure.
pub fn trigger_stopped(file_state: &str, active: &str, result: &str) -> Option<String> {
    if !matches!(file_state, "enabled" | "enabled-runtime")
        || matches!(active, "" | "active" | "activating" | "reloading")
    {
        return None;
    }
    Some(if result.is_empty() || result == "success" {
        active.to_string()
    } else {
        result.to_string()
    })
}

pub struct Job {
    pub name: String,
    pub conf: Result<JobConf, String>,
    pub timer_file: String,
    pub svc_active: String,
    pub svc_result: String,
    pub exit_ts: String,
    pub exit_status: String,
    pub state: Option<State>,
}

impl Job {
    pub fn enabled(&self) -> bool {
        self.timer_file == "enabled"
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Remotes,
    Offline,
    Backups,
    Maint,
}

impl Tab {
    pub const ALL: [Tab; 4] = [Tab::Remotes, Tab::Offline, Tab::Backups, Tab::Maint];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Remotes => "Remotes",
            Tab::Offline => "Offline folders",
            Tab::Backups => "Backups",
            Tab::Maint => "Maintenance",
        }
    }
    pub fn index(self) -> usize {
        Tab::ALL.iter().position(|t| *t == self).unwrap_or(0)
    }
}

pub const MAINT_ITEMS: [&str; 3] = [
    "Show the journal of a unit…",
    "Clear the VFS cache of a remote…",
    "Dry-run sync of an offline folder…",
];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Info,
    Ok,
    Warn,
    Error,
}

// ---------------------------------------------------------------- dialogs

pub enum Action {
    RemoveMount(String),
    RemoveMountForce(String),
    DeleteRemote(String),
    StopMount(String),
    StopMountForce(String),
    RestartMount(String),
    RestartMountForce(String),
    AddPair(Box<NewPair>),
    StartSync(String),
    CopyFirst(String),
    ResumePair(String),
    RemovePair(String),
    RemoveJob(String),
    /// Offered only for a cache with no pending upload (counted: 0).
    ClearCache(String),
}

pub struct Confirm {
    pub title: String,
    pub body: Vec<String>,
    pub yes: String,
    pub focus_yes: bool,
    pub action: Action,
}

pub struct TypeConfirm {
    pub title: String,
    pub body: Vec<String>,
    pub expect: String,
    pub input: String,
    pub action: Action,
}

pub struct View {
    pub title: String,
    pub lines: Vec<String>,
    pub scroll: usize,
}

#[derive(Clone, Copy)]
pub enum PickKind {
    Journal,
    ClearCache,
    DryRun,
}

pub struct Pick {
    pub title: String,
    pub items: Vec<String>,
    pub sel: usize,
    pub kind: PickKind,
}

pub enum Input {
    Text(String),
    Secret(Secret),
    Choice(Vec<String>, usize),
    Toggle(bool),
}

pub struct Field {
    pub key: &'static str,
    pub label: String,
    pub hint: String,
    /// Shown (dimmed) while the field is empty: what empty means.
    pub placeholder: String,
    pub input: Input,
}

impl Field {
    fn text(key: &'static str, label: &str, value: &str, hint: &str) -> Field {
        Field {
            key,
            label: label.into(),
            hint: hint.into(),
            placeholder: String::new(),
            input: Input::Text(value.into()),
        }
    }

    fn other(key: &'static str, label: &str, hint: &str, input: Input) -> Field {
        Field {
            key,
            label: label.into(),
            hint: hint.into(),
            placeholder: String::new(),
            input,
        }
    }

    fn ph(mut self, placeholder: &str) -> Field {
        self.placeholder = placeholder.into();
        self
    }
}

pub enum FormKind {
    Settings(String),
    Client(String),
    Pair,
    Job(Option<String>),
}

pub struct Form {
    pub title: String,
    pub kind: FormKind,
    pub fields: Vec<Field>,
    pub focus: usize,
    pub error: Option<String>,
}

impl Form {
    pub fn has_choice(&self) -> bool {
        self.fields
            .iter()
            .any(|f| matches!(f.input, Input::Choice(..)))
    }

    fn get(&self, key: &str) -> String {
        self.fields
            .iter()
            .find(|f| f.key == key)
            .map(|f| match &f.input {
                Input::Text(s) => s.trim().to_string(),
                Input::Choice(o, i) => o.get(*i).cloned().unwrap_or_default(),
                Input::Toggle(b) => b.to_string(),
                Input::Secret(_) => String::new(),
            })
            .unwrap_or_default()
    }

    fn toggle(&self, key: &str) -> bool {
        self.fields
            .iter()
            .any(|f| f.key == key && matches!(f.input, Input::Toggle(true)))
    }

    fn take_secret(&mut self, key: &str) -> Secret {
        for f in &mut self.fields {
            if f.key == key
                && let Input::Secret(s) = &mut f.input
            {
                return std::mem::take(s);
            }
        }
        Secret::new()
    }
}

pub enum Mode {
    Normal,
    Help,
    Confirm(Confirm),
    TypeConfirm(TypeConfirm),
    Form(Form),
    View(View),
    Pick(Pick),
}

/// Work that needs the real terminal; run by the main loop.
pub enum Interactive {
    RcloneConfig {
        before: Vec<String>,
    },
    Reconnect(String),
    EditFiles {
        job: String,
        file: PathBuf,
        setup: bool,
        enable: bool,
    },
}

#[derive(Clone, Copy)]
pub enum BusyFor {
    Remove,
    Stop,
    Restart,
}

pub struct NewPair {
    pub name: String,
    pub conf: PairConf,
    pub filter: Option<String>,
    pub local_abs: PathBuf,
    pub create_local: bool,
}

/// What a worker reports back.
pub enum Outcome {
    Msg(Level, String),
    View {
        title: String,
        text: String,
        level: Level,
        msg: String,
    },
    /// Files open on the mount, or uploads pending (or either unknown):
    /// ask before going ahead.
    Busy {
        what: BusyFor,
        remote: String,
        busy: Busy,
        /// Pending uploads in the cache; None: could not be counted.
        dirty: Option<usize>,
    },
    MountRemoved {
        remote: String,
        log: Vec<String>,
        /// Pending uploads left in the cache after the mount stopped (None:
        /// could not be counted).
        dirty: Option<usize>,
    },
    SettingsSaved {
        remote: String,
        active: bool,
        log: Vec<String>,
    },
    PairChecked {
        pair: String,
        out: Output,
        local_empty: bool,
        note: Vec<String>,
    },
    CacheChecked {
        remote: String,
        /// Err: the mount is (or may be) running.
        stopped: Result<(), String>,
        /// None: the pending uploads could not be counted.
        dirty: Option<usize>,
    },
    /// A paused pair with bisync listings: offer a normal run.
    CanResume(String),
    Reconnect(String),
}

// ------------------------------------------------------------------- app

pub struct App {
    pub paths: Paths,
    pub tab: Tab,
    pub sel: [usize; 4],
    pub mode: Mode,
    pub remotes: Vec<Remote>,
    /// The last `rclone listremotes` succeeded (so `remotes` is the truth).
    pub remotes_ok: bool,
    pub pairs: Vec<Pair>,
    pub jobs: Vec<Job>,
    pub status: Option<(Level, String, Instant)>,
    pub running: Option<(String, Instant)>,
    /// Persistent one-line notice (installed parts vs. plugin), set at startup.
    pub notice: Option<String>,
    pub interactive: Option<Interactive>,
    pub quit: bool,
    tx: Sender<Outcome>,
    pub rx: Receiver<Outcome>,
    /// Unit polls run off the UI thread; results carry the generation they
    /// were started in, and one older than the last refresh is dropped.
    units_tx: Sender<(u64, Option<HashMap<String, UnitProps>>)>,
    pub units_rx: Receiver<(u64, Option<HashMap<String, UnitProps>>)>,
    polling: bool,
    generation: u64,
}

fn is_active(s: &str) -> bool {
    matches!(s, "active" | "activating" | "deactivating" | "reloading")
}

fn one_line(s: &str) -> String {
    let l: String = s
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .chars()
        .take(200)
        .collect();
    l.trim().to_string()
}

impl App {
    pub fn new(paths: Paths) -> App {
        let (tx, rx) = channel();
        let (units_tx, units_rx) = channel();
        App {
            paths,
            tab: Tab::Remotes,
            sel: [0; 4],
            mode: Mode::Normal,
            remotes: Vec::new(),
            remotes_ok: false,
            pairs: Vec::new(),
            jobs: Vec::new(),
            status: None,
            running: None,
            notice: None,
            interactive: None,
            quit: false,
            tx,
            rx,
            units_tx,
            units_rx,
            polling: false,
            generation: 0,
        }
    }

    pub fn msg(&mut self, level: Level, text: impl Into<String>) {
        self.status = Some((level, one_line(&text.into()), Instant::now()));
    }

    /// Clears a status message once it is STATUS_TTL old.
    pub fn tick(&mut self) {
        if self
            .status
            .as_ref()
            .is_some_and(|(_, _, t)| t.elapsed() >= STATUS_TTL)
        {
            self.status = None;
        }
    }

    fn view(&mut self, title: impl Into<String>, text: &str) {
        let mut lines: Vec<String> = text.lines().map(|l| l.replace('\t', "    ")).collect();
        if lines.is_empty() {
            lines.push("(no output)".into());
        }
        self.mode = Mode::View(View {
            title: title.into(),
            lines,
            scroll: 0,
        });
    }

    /// Re-reads cloud.env (install.sh may have just run) and checks the
    /// mount root (`root_ready`); when it is not usable, shows why and what
    /// to run. True when a mount may be enabled.
    fn root_ok_or_explain(&mut self) -> bool {
        self.paths.root_setting = sys::read_root(&self.paths);
        match root_ready(&self.paths) {
            Ok(()) => true,
            Err(why) => {
                self.view("Mount root not set up", &why);
                self.msg(Level::Warn, "Not mounted: the mount root is not set up");
                false
            }
        }
    }

    fn confirm(&mut self, title: &str, body: Vec<String>, yes: &str, action: Action) {
        self.mode = Mode::Confirm(Confirm {
            title: title.into(),
            body,
            yes: yes.into(),
            focus_yes: false,
            action,
        });
    }

    /// Runs `f` in a worker thread; its Outcome arrives on `rx`.
    fn spawn<F>(&mut self, label: &str, f: F)
    where
        F: FnOnce(&Paths) -> Outcome + Send + 'static,
    {
        if let Some((l, _)) = &self.running {
            let l = l.clone();
            self.msg(Level::Warn, format!("Busy: {l} — wait for it to finish"));
            return;
        }
        self.running = Some((label.to_string(), Instant::now()));
        let tx = self.tx.clone();
        let paths = self.paths.clone();
        let what = label.to_string();
        let spawned = std::thread::Builder::new()
            .name("worker".into())
            .spawn(move || {
                // A panic must not leave the app busy forever: report it.
                let o = catch_unwind(AssertUnwindSafe(|| f(&paths))).unwrap_or_else(|p| {
                    let why = p
                        .downcast_ref::<&str>()
                        .map(|s| s.to_string())
                        .or_else(|| p.downcast_ref::<String>().cloned())
                        .unwrap_or_default();
                    Outcome::Msg(Level::Error, format!("{what}: internal error {why}"))
                });
                let _ = tx.send(o);
            });
        if let Err(e) = spawned {
            self.running = None;
            self.msg(Level::Error, format!("cannot start a task: {e}"));
        }
    }

    // ------------------------------------------------------------ refresh

    pub fn refresh(&mut self) {
        // install.sh may have set the mount root since the last refresh.
        self.paths.root_setting = sys::read_root(&self.paths);
        let out = sys::run_for(&cmd::listremotes_cmd(), REFRESH_LIMIT);
        self.remotes_ok = out.ok();
        if out.ok() {
            let list = sys::parse_listremotes(&out.stdout);
            self.remotes = list
                .into_iter()
                .map(|(name, kind)| Remote {
                    name,
                    kind,
                    active: String::new(),
                    sub: String::new(),
                    file_state: String::new(),
                })
                .collect();
        } else {
            self.msg(
                Level::Error,
                format!("rclone listremotes failed: {}", out.last_line()),
            );
        }
        let home = self.paths.home.clone();
        self.pairs = sys::list_confs(&self.paths.bisync_dir())
            .into_iter()
            .map(|name| {
                let conf = sys::read_small(&self.paths.pair_conf(&name))
                    .ok_or_else(|| "cannot read the conf".to_string())
                    .and_then(|t| PairConf::parse(&t, &home));
                let state = sys::read_state(&self.paths.pair_state(&name));
                let include = conf
                    .as_ref()
                    .ok()
                    .and_then(|c| {
                        c.filter_file(&home, &self.paths.pair_filter(&name))
                            .ok()
                            .flatten()
                    })
                    .and_then(|f| sys::read_small(&f))
                    .and_then(|t| conf::patterns_of_filter(&t))
                    .map(|p| conf::patterns_field(&p));
                Pair {
                    name,
                    conf,
                    include,
                    timer_file: String::new(),
                    path_file: String::new(),
                    timer_active: String::new(),
                    timer_result: String::new(),
                    path_active: String::new(),
                    path_result: String::new(),
                    svc_active: String::new(),
                    svc_result: String::new(),
                    exit_ts: String::new(),
                    exit_status: String::new(),
                    state,
                }
            })
            .collect();
        self.jobs = sys::list_confs(&self.paths.backup_dir())
            .into_iter()
            .map(|name| {
                let conf = sys::read_small(&self.paths.job_conf(&name))
                    .ok_or_else(|| "cannot read the conf".to_string())
                    .and_then(|t| JobConf::parse(&t, &home));
                let state = sys::read_state(&self.paths.job_state(&name));
                Job {
                    name,
                    conf,
                    timer_file: String::new(),
                    svc_active: String::new(),
                    svc_result: String::new(),
                    exit_ts: String::new(),
                    exit_status: String::new(),
                    state,
                }
            })
            .collect();
        self.refresh_units();
        self.clamp();
    }

    fn unit_names(&self) -> Vec<String> {
        let mut units = Vec::new();
        units.extend(self.remotes.iter().map(|r| cmd::mount_unit(&r.name)));
        for p in &self.pairs {
            let watch = self.paths.pair_path_dropin(&p.name).is_file();
            units.extend(pair_units(&p.name, watch));
        }
        for j in &self.jobs {
            units.extend([cmd::job_timer(&j.name), cmd::job_service(&j.name)]);
        }
        units
    }

    /// One `systemctl show` for every unit on screen, waited for (bounded).
    pub fn refresh_units(&mut self) {
        self.generation += 1;
        let units = self.unit_names();
        if units.is_empty() {
            return;
        }
        if let Some(props) = show_units(&units) {
            self.apply_units(&props);
        }
    }

    /// The periodic poll: the same `systemctl show`, in a thread; the
    /// result arrives on `units_rx` (see `on_units`).
    pub fn poll_units(&mut self) {
        if self.polling {
            return;
        }
        let units = self.unit_names();
        if units.is_empty() {
            return;
        }
        self.polling = true;
        let tx = self.units_tx.clone();
        let generation = self.generation;
        let spawned = std::thread::Builder::new()
            .name("poll".into())
            .spawn(move || {
                let props = catch_unwind(|| show_units(&units)).unwrap_or(None);
                let _ = tx.send((generation, props));
            });
        if spawned.is_err() {
            self.polling = false;
        }
    }

    pub fn on_units(&mut self, generation: u64, props: Option<HashMap<String, UnitProps>>) {
        self.polling = false;
        if generation == self.generation
            && let Some(p) = props
        {
            self.apply_units(&p);
        }
    }

    fn apply_units(&mut self, props: &HashMap<String, UnitProps>) {
        let get = |unit: &str, key: &str| -> String {
            let v = props
                .get(unit)
                .and_then(|m| m.get(key))
                .cloned()
                .unwrap_or_default();
            if v.is_empty() && key == "UnitFileState" {
                "not installed".into()
            } else {
                v
            }
        };
        for r in &mut self.remotes {
            let u = cmd::mount_unit(&r.name);
            r.active = get(&u, "ActiveState");
            r.sub = get(&u, "SubState");
            r.file_state = get(&u, "UnitFileState");
        }
        for p in &mut self.pairs {
            let (t, u) = (cmd::pair_timer(&p.name), cmd::pair_path(&p.name));
            p.timer_file = get(&t, "UnitFileState");
            p.timer_active = get(&t, "ActiveState");
            p.timer_result = get(&t, "Result");
            p.path_file = get(&u, "UnitFileState");
            p.path_active = get(&u, "ActiveState");
            p.path_result = get(&u, "Result");
            let s = cmd::pair_service(&p.name);
            p.svc_active = get(&s, "ActiveState");
            p.svc_result = get(&s, "Result");
            p.exit_ts = crate::ui::run_ts(
                &get(&s, "ExecMainExitTimestamp"),
                &get(&s, "InactiveEnterTimestamp"),
            );
            p.exit_status = get(&s, "ExecMainStatus");
        }
        for j in &mut self.jobs {
            j.timer_file = get(&cmd::job_timer(&j.name), "UnitFileState");
            let s = cmd::job_service(&j.name);
            j.svc_active = get(&s, "ActiveState");
            j.svc_result = get(&s, "Result");
            j.exit_ts = crate::ui::run_ts(
                &get(&s, "ExecMainExitTimestamp"),
                &get(&s, "InactiveEnterTimestamp"),
            );
            j.exit_status = get(&s, "ExecMainStatus");
        }
        for p in &mut self.pairs {
            p.state = sys::read_state(&self.paths.pair_state(&p.name));
        }
        for j in &mut self.jobs {
            j.state = sys::read_state(&self.paths.job_state(&j.name));
        }
    }

    pub fn tab_len(&self, t: Tab) -> usize {
        match t {
            Tab::Remotes => self.remotes.len(),
            Tab::Offline => self.pairs.len(),
            Tab::Backups => self.jobs.len(),
            Tab::Maint => MAINT_ITEMS.len(),
        }
    }

    fn clamp(&mut self) {
        for t in Tab::ALL {
            let n = self.tab_len(t);
            let s = &mut self.sel[t.index()];
            if *s >= n {
                *s = n.saturating_sub(1);
            }
        }
    }

    fn cur(&self) -> usize {
        self.sel[self.tab.index()]
    }

    fn cur_remote(&self) -> Option<&Remote> {
        self.remotes.get(self.sel[Tab::Remotes.index()])
    }
    pub fn cur_pair(&self) -> Option<&Pair> {
        self.pairs.get(self.sel[Tab::Offline.index()])
    }
    fn cur_job(&self) -> Option<&Job> {
        self.jobs.get(self.sel[Tab::Backups.index()])
    }

    fn remote_active(&self, name: &str) -> bool {
        self.remotes
            .iter()
            .any(|r| r.name == name && is_active(&r.active))
    }

    // --------------------------------------------------------------- keys

    pub fn on_key(&mut self, k: KeyEvent) {
        if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        let mode = std::mem::replace(&mut self.mode, Mode::Normal);
        match mode {
            Mode::Normal => self.key_normal(k),
            Mode::Help => {}
            Mode::View(mut v) => {
                let page = 10;
                match k.code {
                    KeyCode::Esc | KeyCode::Char('q') | KeyCode::Enter => return,
                    KeyCode::Down | KeyCode::Char('j') => {
                        v.scroll = (v.scroll + 1).min(v.lines.len().saturating_sub(1))
                    }
                    KeyCode::Up | KeyCode::Char('k') => v.scroll = v.scroll.saturating_sub(1),
                    KeyCode::PageDown | KeyCode::Char(' ') => {
                        v.scroll = (v.scroll + page).min(v.lines.len().saturating_sub(1))
                    }
                    KeyCode::PageUp => v.scroll = v.scroll.saturating_sub(page),
                    KeyCode::Home | KeyCode::Char('g') => v.scroll = 0,
                    KeyCode::End | KeyCode::Char('G') => v.scroll = v.lines.len().saturating_sub(1),
                    _ => {}
                }
                self.mode = Mode::View(v);
            }
            Mode::Pick(mut p) => match k.code {
                KeyCode::Esc | KeyCode::Char('q') => {}
                KeyCode::Down | KeyCode::Char('j') => {
                    p.sel = (p.sel + 1).min(p.items.len().saturating_sub(1));
                    self.mode = Mode::Pick(p);
                }
                KeyCode::Up | KeyCode::Char('k') => {
                    p.sel = p.sel.saturating_sub(1);
                    self.mode = Mode::Pick(p);
                }
                KeyCode::Enter => {
                    if let Some(item) = p.items.get(p.sel).cloned() {
                        self.picked(p.kind, item);
                    }
                }
                _ => self.mode = Mode::Pick(p),
            },
            Mode::Confirm(mut c) => match k.code {
                KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('q') => {
                    self.msg(Level::Info, "Cancelled")
                }
                KeyCode::Left
                | KeyCode::Right
                | KeyCode::Tab
                | KeyCode::BackTab
                | KeyCode::Char('h')
                | KeyCode::Char('l') => {
                    c.focus_yes = !c.focus_yes;
                    self.mode = Mode::Confirm(c);
                }
                KeyCode::Enter => {
                    if c.focus_yes {
                        self.act(c.action);
                    } else {
                        self.msg(Level::Info, "Cancelled");
                    }
                }
                _ => self.mode = Mode::Confirm(c),
            },
            Mode::TypeConfirm(mut t) => match k.code {
                KeyCode::Esc => self.msg(Level::Info, "Cancelled — nothing deleted"),
                KeyCode::Enter => {
                    if t.input == t.expect {
                        self.act(t.action);
                    } else {
                        self.msg(Level::Info, "Name not typed — nothing deleted");
                    }
                }
                KeyCode::Backspace => {
                    t.input.pop();
                    self.mode = Mode::TypeConfirm(t);
                }
                KeyCode::Char(c)
                    if !c.is_control()
                        && t.input.len() < 80
                        && !k
                            .modifiers
                            .intersects(KeyModifiers::ALT | KeyModifiers::CONTROL) =>
                {
                    t.input.push(c);
                    self.mode = Mode::TypeConfirm(t);
                }
                _ => self.mode = Mode::TypeConfirm(t),
            },
            Mode::Form(f) => self.key_form(f, k),
        }
    }

    /// Pasted text (bracketed paste) goes into the focused text, secret or
    /// type-to-confirm field, without CR/LF and control characters; a paste
    /// never submits anything.
    pub fn on_paste(&mut self, text: &str) {
        let clean = text.chars().filter(|c| !c.is_control());
        match &mut self.mode {
            Mode::Form(f) => {
                let i = f.focus;
                match &mut f.fields[i].input {
                    Input::Text(s) => {
                        for c in clean {
                            if s.len() + c.len_utf8() > validate::MAX_TEXT {
                                break;
                            }
                            s.push(c);
                        }
                    }
                    Input::Secret(s) => clean.for_each(|c| s.push(c)),
                    _ => {}
                }
                f.error = None;
            }
            Mode::TypeConfirm(t) => {
                for c in clean {
                    if t.input.len() >= 80 {
                        break;
                    }
                    t.input.push(c);
                }
            }
            _ => {}
        }
    }

    fn key_normal(&mut self, k: KeyEvent) {
        if k.modifiers.contains(KeyModifiers::CONTROL) {
            return; // Ctrl+letter never triggers an action
        }
        let n = self.tab_len(self.tab);
        let i = self.tab.index();
        match k.code {
            KeyCode::Char('q') | KeyCode::Esc => {
                if let Some((l, _)) = &self.running {
                    let l = l.clone();
                    self.msg(
                        Level::Warn,
                        format!("Still running: {l} — wait, or Ctrl-C to quit anyway"),
                    );
                } else {
                    self.quit = true;
                }
            }
            KeyCode::Char('?') => self.mode = Mode::Help,
            KeyCode::Tab | KeyCode::Right | KeyCode::Char('l') => self.tab = Tab::ALL[(i + 1) % 4],
            KeyCode::BackTab | KeyCode::Left | KeyCode::Char('h') => {
                self.tab = Tab::ALL[(i + 3) % 4]
            }
            KeyCode::Char(c @ '1'..='4') => self.tab = Tab::ALL[(c as usize) - ('1' as usize)],
            KeyCode::Down | KeyCode::Char('j') => {
                if n > 0 {
                    self.sel[i] = (self.sel[i] + 1).min(n - 1);
                }
            }
            KeyCode::Up | KeyCode::Char('k') => self.sel[i] = self.sel[i].saturating_sub(1),
            KeyCode::Home => self.sel[i] = 0,
            KeyCode::End => self.sel[i] = n.saturating_sub(1),
            KeyCode::Char('r') => {
                self.refresh();
                self.msg(Level::Info, "Refreshed");
            }
            KeyCode::Char(c) => self.tab_key(Some(c)),
            KeyCode::Enter => self.tab_key(None),
            _ => {}
        }
    }

    /// Tab-specific keys; `None` is Enter.
    fn tab_key(&mut self, c: Option<char>) {
        if let Some((l, _)) = &self.running {
            let l = l.clone();
            self.msg(Level::Warn, format!("Busy: {l} — wait for it to finish"));
            return;
        }
        match self.tab {
            Tab::Remotes => self.remotes_key(c),
            Tab::Offline => self.offline_key(c),
            Tab::Backups => self.backups_key(c),
            Tab::Maint => {
                if c.is_none() {
                    self.maint_enter();
                }
            }
        }
    }

    // ------------------------------------------------------------ remotes

    fn remotes_key(&mut self, c: Option<char>) {
        if c == Some('a') {
            if !self.remotes_ok {
                self.msg(
                    Level::Error,
                    "rclone listremotes failed — cannot tell new remotes apart; fix rclone first",
                );
                return;
            }
            let before = self.remotes.iter().map(|r| r.name.clone()).collect();
            self.interactive = Some(Interactive::RcloneConfig { before });
            return;
        }
        let Some(r) = self.cur_remote() else {
            self.msg(Level::Info, "No remotes yet — press a to add one");
            return;
        };
        let name = r.name.clone();
        let kind = r.kind.clone();
        let active = is_active(&r.active);
        let enabled = r.file_state == "enabled";
        match c {
            None | Some('s') => self.settings_form(&name, enabled),
            Some('d') => {
                let users = self.users_of(&name);
                let mut body = vec![
                    format!(
                        "Stop and disable rclone-mount@{name}, remove ~/Cloud/{name} (if it is the mount link)"
                    ),
                    format!("and ~/.config/rclone-mount/{name}.env."),
                    "Open files on the mount are checked first.".into(),
                    "The remote itself stays in rclone.conf; deleting it is asked separately."
                        .into(),
                ];
                if !users.is_empty() {
                    body.push(String::new());
                    body.push(format!("Still used by: {}", users.join(", ")));
                }
                self.confirm(
                    &format!("Remove mount {name}?"),
                    body,
                    "Remove",
                    Action::RemoveMount(name),
                );
            }
            Some('m') => {
                if active {
                    self.confirm(
                        &format!("Unmount {name}?"),
                        vec![
                            format!("Stops rclone-mount@{name} now (start at login is unchanged)."),
                            "Open files are checked first.".into(),
                        ],
                        "Unmount",
                        Action::StopMount(name),
                    );
                } else if self.root_ok_or_explain() {
                    self.spawn(&format!("Mounting {name}"), move |_| {
                        let o = sys::run(&cmd::start_cmd(&cmd::mount_unit(&name)));
                        if o.ok() {
                            Outcome::Msg(Level::Ok, format!("Mounted {name}"))
                        } else {
                            Outcome::Msg(
                                Level::Error,
                                format!("Mount {name} failed: {}", o.last_line()),
                            )
                        }
                    });
                }
            }
            Some('c') => self.interactive = Some(Interactive::Reconnect(name)),
            Some('g') => {
                if kind != "drive" {
                    self.msg(
                        Level::Warn,
                        "Client id/secret applies to Google Drive remotes only",
                    );
                    return;
                }
                self.mode = Mode::Form(Form {
                    title: format!("Google OAuth client for {name}"),
                    kind: FormKind::Client(name),
                    fields: vec![
                        Field::text("id", "Client ID", "", "…apps.googleusercontent.com"),
                        Field::other(
                            "secret",
                            "Client secret",
                            "never shown, not stored by this app",
                            Input::Secret(Secret::new()),
                        ),
                    ],
                    focus: 0,
                    error: None,
                });
            }
            _ => {}
        }
    }

    /// Every backup job's destination (name, absolute DEST), from the confs
    /// that parse.
    fn job_dests(&self) -> Vec<(String, PathBuf)> {
        self.jobs
            .iter()
            .filter_map(|j| {
                let c = j.conf.as_ref().ok()?;
                let d = validate::expand_local(&c.dest, &self.paths.home).ok()?;
                Some((j.name.clone(), d))
            })
            .collect()
    }

    /// Every offline folder's local folder (name, absolute LOCAL).
    fn pair_locals(&self) -> Vec<(String, PathBuf)> {
        self.pairs
            .iter()
            .filter_map(|p| {
                let c = p.conf.as_ref().ok()?;
                let l = validate::expand_local(&c.local, &self.paths.home).ok()?;
                Some((p.name.clone(), l))
            })
            .collect()
    }

    /// Offline folders and backups that use `remote`. A conf that does not
    /// parse counts when its raw REMOTE= line names the remote.
    fn users_of(&self, remote: &str) -> Vec<String> {
        let raw_uses = |file: &Path| {
            sys::read_small(file).is_some_and(|t| {
                t.lines().any(|l| {
                    l.strip_prefix("REMOTE=")
                        .and_then(|v| v.split_once(':'))
                        .is_some_and(|(n, _)| n == remote)
                })
            })
        };
        let mut v: Vec<String> = self
            .pairs
            .iter()
            .filter(|p| match &p.conf {
                Ok(c) => c.remote_name() == remote,
                Err(_) => raw_uses(&self.paths.pair_conf(&p.name)),
            })
            .map(|p| format!("offline folder {}", p.name))
            .collect();
        v.extend(
            self.jobs
                .iter()
                .filter(|j| match &j.conf {
                    Ok(c) => c.remote_name() == remote,
                    Err(_) => raw_uses(&self.paths.job_conf(&j.name)),
                })
                .map(|j| format!("backup {}", j.name)),
        );
        v
    }

    fn settings_form(&mut self, remote: &str, enabled: bool) {
        let env = sys::read_small(&self.paths.mount_env(remote))
            .map(|t| EnvFile::parse(&t))
            .unwrap_or_default();
        let mut fields: Vec<Field> = MANAGED
            .iter()
            .map(|m| {
                Field::text(
                    m.key,
                    m.label,
                    &env.get(m.key).unwrap_or_default(),
                    &format!("empty = unit default {}", m.default),
                )
                .ph(&format!("{} (unit default)", m.default))
            })
            .collect();
        fields.push(Field::other(
            "login",
            "Start at login",
            "space toggles",
            Input::Toggle(enabled),
        ));
        self.mode = Mode::Form(Form {
            title: format!("Mount settings — {remote}"),
            kind: FormKind::Settings(remote.to_string()),
            fields,
            focus: 0,
            error: None,
        });
    }

    // ------------------------------------------------------------ offline

    fn offline_key(&mut self, c: Option<char>) {
        if c == Some('a') {
            if self.remotes.is_empty() {
                self.msg(Level::Warn, "Add a remote first");
                return;
            }
            let names: Vec<String> = self.remotes.iter().map(|r| r.name.clone()).collect();
            self.mode = Mode::Form(Form {
                title: "New offline folder".into(),
                kind: FormKind::Pair,
                fields: vec![
                    Field::text("name", "Name", "", "letters, digits, _ . -"),
                    Field::other("remote", "Remote", "←/→ choose", Input::Choice(names, 0)),
                    Field::text(
                        "path",
                        "Remote folder",
                        "",
                        "e.g. Backup/Vaults (empty = remote root)",
                    )
                    .ph("(remote root)"),
                    Field::text(
                        "local",
                        "Local folder",
                        "~/",
                        &format!(
                            "absolute or ~/…, not under ~/Cloud or {}",
                            self.paths.root().display()
                        ),
                    ),
                    Field::text(
                        "include",
                        "Include patterns",
                        "",
                        "comma separated; Docs/ = a whole subfolder; empty = whole folder",
                    )
                    .ph("(whole folder)"),
                    Field::text(
                        "interval",
                        "Sync interval",
                        "2min",
                        "at least 30s: 30s, 2min, 1h, 1d",
                    )
                    .ph("2min"),
                ],
                focus: 0,
                error: None,
            });
            return;
        }
        let Some(p) = self.cur_pair() else {
            self.msg(Level::Info, "No offline folders yet — press a to add one");
            return;
        };
        let name = p.name.clone();
        let enabled = p.enabled();
        let conf_ok = p.conf.is_ok();
        let watch = p.watch_problem();
        match c {
            Some('w') => match watch {
                Some(_) => self.spawn(&format!("Restarting the watch of {name}"), move |_| {
                    recover_pair(&name)
                }),
                None if enabled => self.msg(
                    Level::Info,
                    format!("{name}: the folder watch and the timer are running"),
                ),
                None => self.msg(Level::Info, "Not syncing — Enter starts (or resumes) it"),
            },
            None => {
                if !conf_ok {
                    self.msg(
                        Level::Error,
                        format!("{name}.conf is invalid — fix or remove it"),
                    );
                } else if enabled {
                    self.spawn(&format!("Syncing {name}"), move |_| {
                        let o = sys::run(&cmd::pair_sync_now_cmd(&name));
                        if o.ok() {
                            Outcome::Msg(Level::Ok, format!("Sync of {name} started"))
                        } else {
                            Outcome::Msg(Level::Error, format!("Sync {name}: {}", o.last_line()))
                        }
                    });
                } else {
                    self.spawn(&format!("Checking {name}"), move |paths| {
                        paused_enter(paths, &name)
                    });
                }
            }
            Some('p') => {
                if enabled {
                    self.spawn(&format!("Pausing {name}"), move |_| {
                        let o = sys::run(&cmd::pair_disable_cmd(&name));
                        if o.ok() {
                            Outcome::Msg(Level::Ok, format!("{name} paused (Enter resumes it)"))
                        } else {
                            Outcome::Msg(Level::Error, format!("Pause {name}: {}", o.last_line()))
                        }
                    });
                } else {
                    self.msg(Level::Info, "Not syncing — Enter starts (or resumes) it");
                }
            }
            Some('n') => self.dry_run(name),
            Some('c') => self.spawn(&format!("Listing conflicts of {name}"), move |paths| {
                let o = sys::run(&cmd::bisync_cmd(paths, "conflicts", &name));
                let text = o.text();
                let (level, msg) = if !o.ok() {
                    (Level::Error, format!("conflicts {name} failed"))
                } else if text.trim().is_empty() {
                    (Level::Ok, format!("{name}: no conflict copies"))
                } else {
                    (
                        Level::Warn,
                        format!("{name}: bisync kept both versions as X.conflictN copies (X itself is renamed); merge them into one file, rename it back to X, delete the other copies"),
                    )
                };
                let text = if text.trim().is_empty() {
                    "No conflict copies.".into()
                } else {
                    text
                };
                Outcome::View {
                    title: format!("Conflict copies — {name}"),
                    text,
                    level,
                    msg,
                }
            }),
            Some('d') => {
                let (local, remote) = match &p.conf {
                    Ok(c) => (c.local.clone(), c.remote.clone()),
                    Err(_) => ("?".into(), "?".into()),
                };
                self.confirm(
                    &format!("Remove offline folder {name}?"),
                    vec![
                        format!("Stops syncing (disables rclone-bisync@{name}.timer and .path),"),
                        format!("removes its systemd drop-ins, {name}.conf, {name}.filter, its state"),
                        "and bisync's listings, so adding it again starts with a fresh check.".into(),
                        String::new(),
                        format!("NOT touched: the local folder {local}"),
                        format!("            and the remote folder {remote}."),
                    ],
                    "Remove",
                    Action::RemovePair(name),
                );
            }
            _ => {}
        }
    }

    fn dry_run(&mut self, pair: String) {
        self.spawn(&format!("Dry-run of {pair}"), move |paths| {
            let o = sys::run(&cmd::bisync_cmd(paths, "dry-run", &pair));
            if o.code == Some(EXIT_BUSY) {
                return Outcome::Msg(
                    Level::Warn,
                    format!("{pair} is busy (another run holds its lock) — try again shortly"),
                );
            }
            let (level, msg) = if o.ok() {
                (
                    Level::Ok,
                    format!("Dry-run of {pair} finished (nothing was changed)"),
                )
            } else {
                (
                    Level::Error,
                    format!("Dry-run of {pair} exited {}", o.code.unwrap_or(-1)),
                )
            };
            Outcome::View {
                title: format!("Dry-run — {pair}"),
                text: o.text(),
                level,
                msg,
            }
        });
    }

    // ------------------------------------------------------------ backups

    fn backups_key(&mut self, c: Option<char>) {
        if c == Some('a') {
            if self.remotes.is_empty() {
                self.msg(Level::Warn, "Add a remote first");
                return;
            }
            self.job_form(None);
            return;
        }
        let Some(j) = self.cur_job() else {
            self.msg(Level::Info, "No backups yet — press a to add one");
            return;
        };
        let name = j.name.clone();
        let enabled = j.enabled();
        match c {
            None => self.spawn(&format!("Starting backup {name}"), move |_| {
                let o = sys::run(&cmd::job_run_now_cmd(&name));
                if o.ok() {
                    Outcome::Msg(Level::Ok, format!("Backup {name} started"))
                } else {
                    Outcome::Msg(Level::Error, format!("Backup {name}: {}", o.last_line()))
                }
            }),
            Some('e') => {
                if j.conf.is_err() {
                    self.msg(
                        Level::Error,
                        format!("{name}.conf is invalid — fix it by hand or remove it"),
                    );
                } else {
                    self.job_form(Some(name));
                }
            }
            Some('f') => {
                let file = self.job_files_path(&name);
                // A job whose setup was refused (an empty files list, say)
                // is set up and scheduled once the list is fixed.
                let setup = j.conf.is_ok() && !self.paths.job_timer_dropin(&name).is_file();
                self.interactive = Some(Interactive::EditFiles {
                    job: name,
                    file,
                    setup,
                    enable: setup,
                });
            }
            Some('p') => {
                let label = if enabled { "Disabling" } else { "Enabling" };
                self.spawn(&format!("{label} {name}"), move |_| {
                    let argv = if enabled {
                        cmd::job_disable_cmd(&name)
                    } else {
                        cmd::job_enable_cmd(&name)
                    };
                    let o = sys::run(&argv);
                    let what = if enabled { "disabled" } else { "enabled" };
                    if o.ok() {
                        Outcome::Msg(Level::Ok, format!("Backup {name} schedule {what}"))
                    } else {
                        Outcome::Msg(Level::Error, format!("{name}: {}", o.last_line()))
                    }
                });
            }
            Some('d') => {
                let dest = j
                    .conf
                    .as_ref()
                    .map(|c| c.dest.clone())
                    .unwrap_or_else(|_| "?".into());
                self.confirm(
                    &format!("Remove backup {name}?"),
                    vec![
                        format!("Disables rclone-backup@{name}.timer, removes its drop-in and {name}.conf."),
                        "The files list is kept.".into(),
                        String::new(),
                        format!("NOT touched: the backup copies in {dest}."),
                    ],
                    "Remove",
                    Action::RemoveJob(name),
                );
            }
            _ => {}
        }
    }

    fn job_files_path(&self, job: &str) -> PathBuf {
        self.jobs
            .iter()
            .find(|j| j.name == job)
            .and_then(|j| j.conf.as_ref().ok())
            .and_then(|c| c.files.as_ref())
            .and_then(|f| validate::expand_local(f, &self.paths.home).ok())
            .unwrap_or_else(|| self.paths.job_files(job))
    }

    fn job_form(&mut self, name: Option<String>) {
        let names: Vec<String> = self.remotes.iter().map(|r| r.name.clone()).collect();
        let existing = name
            .as_ref()
            .and_then(|n| self.jobs.iter().find(|j| &j.name == n))
            .and_then(|j| j.conf.as_ref().ok());
        let (rname, prefix) = existing
            .and_then(|c| c.remote.split_once(':'))
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .unwrap_or_default();
        let mut opts = names;
        if !rname.is_empty() && !opts.contains(&rname) {
            opts.push(rname.clone());
        }
        let ri = opts.iter().position(|o| *o == rname).unwrap_or(0);
        let mut fields = Vec::new();
        if name.is_none() {
            fields.push(Field::text("name", "Name", "", "letters, digits, _ . -"));
        }
        fields.push(Field::other(
            "remote",
            "Remote",
            "←/→ choose",
            Input::Choice(opts, ri),
        ));
        fields.push(
            Field::text(
                "prefix",
                "Remote prefix",
                &prefix,
                "optional folder, no trailing /",
            )
            .ph("(remote root)"),
        );
        fields.push(Field::text(
            "dest",
            "Destination",
            existing.map(|c| c.dest.as_str()).unwrap_or("~/"),
            "local folder for the copies",
        ));
        let keep = existing
            .and_then(|c| c.keep)
            .map(|k| k.to_string())
            .unwrap_or_else(|| "14".into());
        fields.push(Field::text("keep", "Keep copies", &keep, "1–365 per file").ph("14"));
        let sched = existing
            .and_then(|c| c.schedule.clone())
            .unwrap_or_else(|| "daily".into());
        fields.push(
            Field::text(
                "schedule",
                "Schedule",
                &sched,
                "OnCalendar, e.g. daily, *-*-* 03:00",
            )
            .ph("daily"),
        );
        let strip = existing
            .and_then(|c| c.strip_prefix.clone())
            .unwrap_or_default();
        fields.push(
            Field::text(
                "strip",
                "Strip prefix",
                &strip,
                "removed from names of copies (optional)",
            )
            .ph("(none)"),
        );
        let files = existing.and_then(|c| c.files.clone()).unwrap_or_default();
        let default_files = self
            .paths
            .tilde(&self.paths.backup_dir().join("<name>.files"));
        fields.push(
            Field::text(
                "files",
                "Files list",
                &files,
                &format!("empty = {default_files}"),
            )
            .ph(&default_files),
        );
        self.mode = Mode::Form(Form {
            title: match &name {
                Some(n) => format!("Edit backup {n}"),
                None => "New backup".into(),
            },
            kind: FormKind::Job(name),
            fields,
            focus: 0,
            error: None,
        });
    }

    // -------------------------------------------------------- maintenance

    fn maint_enter(&mut self) {
        let (title, items, kind) = match self.cur() {
            0 => {
                let mut u: Vec<String> = self
                    .remotes
                    .iter()
                    .map(|r| cmd::mount_unit(&r.name))
                    .collect();
                u.extend(self.pairs.iter().map(|p| cmd::pair_service(&p.name)));
                u.extend(self.jobs.iter().map(|j| cmd::job_service(&j.name)));
                ("Journal of which unit?", u, PickKind::Journal)
            }
            1 => (
                "Clear the cache of which remote?",
                self.remotes.iter().map(|r| r.name.clone()).collect(),
                PickKind::ClearCache,
            ),
            _ => (
                "Dry-run which offline folder?",
                self.pairs.iter().map(|p| p.name.clone()).collect(),
                PickKind::DryRun,
            ),
        };
        if items.is_empty() {
            self.msg(Level::Info, "Nothing to choose from");
            return;
        }
        self.mode = Mode::Pick(Pick {
            title: title.into(),
            items,
            sel: 0,
            kind,
        });
    }

    fn picked(&mut self, kind: PickKind, item: String) {
        match kind {
            PickKind::Journal => self.spawn(&format!("Reading the journal of {item}"), move |_| {
                let o = sys::run(&cmd::journal_cmd(&item));
                let (level, msg) = if o.ok() {
                    (Level::Info, String::new())
                } else {
                    (Level::Error, "journalctl failed".into())
                };
                Outcome::View {
                    title: format!("Journal — {item} (last 30 lines)"),
                    text: o.text(),
                    level,
                    msg,
                }
            }),
            PickKind::DryRun => self.dry_run(item),
            PickKind::ClearCache => {
                self.spawn(&format!("Inspecting the cache of {item}"), move |paths| {
                    let stopped = mount_stopped(
                        &sys::unit_active_state(&cmd::mount_unit(&item)),
                        sys::is_mounted(&paths.mount_point(&item)),
                    )
                    .map_err(|e| format!("{item}: {e}"));
                    let dirty = sys::count_dirty(&paths.vfs_meta_dir(&item));
                    Outcome::CacheChecked {
                        remote: item,
                        stopped,
                        dirty,
                    }
                });
            }
        }
    }

    // --------------------------------------------------------------- forms

    fn key_form(&mut self, mut f: Form, k: KeyEvent) {
        let n = f.fields.len();
        match k.code {
            KeyCode::Esc => {
                self.msg(Level::Info, "Cancelled");
                return; // the form (and any secret in it) is dropped and zeroed
            }
            KeyCode::Enter => {
                self.submit(f);
                return;
            }
            KeyCode::Down | KeyCode::Tab => f.focus = (f.focus + 1) % n,
            KeyCode::Up | KeyCode::BackTab => f.focus = (f.focus + n - 1) % n,
            _ if k.modifiers.contains(KeyModifiers::ALT) => {}
            _ => {
                let field = &mut f.fields[f.focus];
                match (&mut field.input, k.code) {
                    (Input::Text(s), KeyCode::Backspace) => {
                        s.pop();
                    }
                    (Input::Text(s), KeyCode::Char('u'))
                        if k.modifiers.contains(KeyModifiers::CONTROL) =>
                    {
                        s.clear()
                    }
                    (Input::Text(s), KeyCode::Char(c))
                        if !c.is_control()
                            && !k.modifiers.contains(KeyModifiers::CONTROL)
                            && s.len() < validate::MAX_TEXT =>
                    {
                        s.push(c)
                    }
                    (Input::Secret(s), KeyCode::Backspace) => s.pop(),
                    (Input::Secret(s), KeyCode::Char('u'))
                        if k.modifiers.contains(KeyModifiers::CONTROL) =>
                    {
                        s.clear()
                    }
                    (Input::Secret(s), KeyCode::Char(c))
                        if !c.is_control() && !k.modifiers.contains(KeyModifiers::CONTROL) =>
                    {
                        s.push(c)
                    }
                    (Input::Choice(o, i), KeyCode::Right | KeyCode::Char(' '))
                        if !o.is_empty() && !k.modifiers.contains(KeyModifiers::CONTROL) =>
                    {
                        *i = (*i + 1) % o.len()
                    }
                    (Input::Choice(o, i), KeyCode::Left) if !o.is_empty() => {
                        *i = (*i + o.len() - 1) % o.len()
                    }
                    (Input::Toggle(b), KeyCode::Char(' ') | KeyCode::Left | KeyCode::Right)
                        if !k.modifiers.contains(KeyModifiers::CONTROL) =>
                    {
                        *b = !*b
                    }
                    _ => {}
                }
            }
        }
        f.error = None;
        self.mode = Mode::Form(f);
    }

    fn submit(&mut self, mut f: Form) {
        let res = match &f.kind {
            FormKind::Settings(r) => self.submit_settings(r.clone(), &f),
            FormKind::Client(r) => {
                let r = r.clone();
                let id = f.get("id");
                let secret = f.take_secret("secret");
                self.submit_client(r, id, secret)
            }
            FormKind::Pair => self.submit_pair(&f),
            FormKind::Job(name) => self.submit_job(name.clone(), &f),
        };
        if let Err(e) = res {
            if let FormKind::Client(_) = f.kind {
                // The secret was taken out (and dropped); ask for it again.
                for fl in &mut f.fields {
                    if fl.key == "secret" {
                        fl.input = Input::Secret(Secret::new());
                    }
                }
            }
            f.error = Some(e);
            self.mode = Mode::Form(f);
        }
    }

    fn submit_settings(&mut self, remote: String, f: &Form) -> Result<(), String> {
        let values: Vec<String> = MANAGED.iter().map(|m| f.get(m.key)).collect();
        let changes = build_settings(&values)?;
        let login = f.toggle("login");
        let was_enabled = self
            .remotes
            .iter()
            .any(|r| r.name == remote && r.file_state == "enabled");
        let active = self.remote_active(&remote);
        if login && !was_enabled {
            self.paths.root_setting = sys::read_root(&self.paths);
            root_ready(&self.paths).map_err(|e| format!("Start at login: {e}"))?;
        }
        self.spawn(&format!("Saving settings of {remote}"), move |paths| {
            let file = paths.mount_env(&remote);
            let mut env = sys::read_small(&file)
                .map(|t| EnvFile::parse(&t))
                .unwrap_or_default();
            for (k, v) in &changes {
                env.set(k, v.as_deref());
            }
            if let Err(e) = sys::write_atomic(&file, &env.render()) {
                return Outcome::Msg(Level::Error, format!("Saving failed: {e}"));
            }
            let mut log = vec![format!("Saved {}", paths.tilde(&file))];
            if login != was_enabled {
                let u = [cmd::mount_unit(&remote)];
                let o = sys::run(&if login {
                    cmd::enable_cmd(&u)
                } else {
                    cmd::disable_cmd(&u)
                });
                log.push(if o.ok() {
                    format!(
                        "start at login {}",
                        if login { "enabled" } else { "disabled" }
                    )
                } else {
                    format!("start at login: {}", o.last_line())
                });
            }
            Outcome::SettingsSaved {
                remote,
                active,
                log,
            }
        });
        Ok(())
    }

    fn submit_client(&mut self, remote: String, id: String, secret: Secret) -> Result<(), String> {
        if !validate::is_valid_client_id(&id) {
            return Err("Client ID: letters, digits, . _ - only".into());
        }
        if !validate::is_valid_client_secret(secret.expose()) {
            return Err(CLIENT_SECRET_RULE.into());
        }
        self.spawn(
            &format!("Setting the OAuth client of {remote}"),
            move |_| {
                match set_client(&remote, &id, &secret, &mut |a: &[String]| sys::run(a)) {
                    Ok(()) => Outcome::Reconnect(remote),
                    Err(e) => {
                        let err = secret::scrub(&e, &secret);
                        Outcome::Msg(Level::Error, format!("Setting the client failed: {err}"))
                    }
                }
                // `secret` is dropped (zeroed) here
            },
        );
        Ok(())
    }

    fn submit_pair(&mut self, f: &Form) -> Result<(), String> {
        let mut np = build_pair(
            &self.paths,
            &sys::fuse_mounts(),
            &f.get("name"),
            &f.get("remote"),
            &f.get("path"),
            &f.get("local"),
            &f.get("include"),
            &f.get("interval"),
        )?;
        if self.paths.pair_conf(&np.name).exists() {
            return Err(format!(
                "An offline folder named {} already exists",
                np.name
            ));
        }
        if let Some((job, dest)) = overlap_with(&np.local_abs, &self.job_dests()) {
            return Err(format!(
                "Local folder: overlaps {}, the destination of backup {job}; a backup destination must not be inside an offline folder, nor contain one",
                self.paths.tilde(dest)
            ));
        }
        let others: Vec<(String, PathBuf)> = self
            .pair_locals()
            .into_iter()
            .filter(|(n, _)| *n != np.name)
            .collect();
        if let Some((pair, local)) = overlap_with(&np.local_abs, &others) {
            return Err(format!(
                "Local folder: overlaps {}, the local folder of offline folder {pair}; two offline folders must not share files",
                self.paths.tilde(local)
            ));
        }
        if np.filter.is_none() && self.paths.pair_filter(&np.name).exists() {
            return Err(format!(
                "A stale {}.filter exists; remove it or give include patterns",
                np.name
            ));
        }
        if !np.local_abs.exists() {
            np.create_local = true;
            let local = np.conf.local.clone();
            self.confirm(
                "Create the local folder?",
                vec![format!(
                    "{local} does not exist. Create it (empty) and continue?"
                )],
                "Create",
                Action::AddPair(Box::new(np)),
            );
            return Ok(());
        }
        if !np.local_abs.is_dir() {
            return Err("Local folder: exists but is not a directory".into());
        }
        self.act(Action::AddPair(Box::new(np)));
        Ok(())
    }

    fn submit_job(&mut self, name: Option<String>, f: &Form) -> Result<(), String> {
        let is_new = name.is_none();
        let job = name.unwrap_or_else(|| f.get("name"));
        let conf = build_job(
            &self.paths,
            &sys::fuse_mounts(),
            &job,
            &f.get("remote"),
            &f.get("prefix"),
            &f.get("dest"),
            &f.get("keep"),
            &f.get("schedule"),
            &f.get("strip"),
            &f.get("files"),
        )?;
        let conf_path = self.paths.job_conf(&job);
        if is_new && conf_path.exists() {
            return Err(format!("A backup named {job} already exists"));
        }
        let dest_abs = validate::expand_local(&conf.dest, &self.paths.home)?;
        if let Some((pair, local)) = overlap_with(&dest_abs, &self.pair_locals()) {
            return Err(format!(
                "Destination: overlaps {}, the local folder of offline folder {pair}; a backup destination must not be inside an offline folder, nor contain one",
                self.paths.tilde(local)
            ));
        }
        let others: Vec<(String, PathBuf)> = self
            .job_dests()
            .into_iter()
            .filter(|(n, _)| *n != job)
            .collect();
        if let Some((other, dest)) = overlap_with(&dest_abs, &others) {
            return Err(format!(
                "Destination: overlaps {}, the destination of backup {other}; two backups must not share a destination",
                self.paths.tilde(dest)
            ));
        }
        let files = match &conf.files {
            Some(fl) => validate::expand_local(fl, &self.paths.home)?,
            None => self.paths.job_files(&job),
        };
        sys::write_atomic(&conf_path, &conf.render())?;
        if !files.exists() {
            sys::write_atomic(&files, &conf::files_template(&job, &conf.remote))?;
        }
        let enable = is_new || self.jobs.iter().any(|j| j.name == job && j.enabled());
        self.interactive = Some(Interactive::EditFiles {
            job,
            file: files,
            setup: true,
            enable,
        });
        Ok(())
    }

    // ------------------------------------------------------------- actions

    fn act(&mut self, a: Action) {
        match a {
            Action::RemoveMount(r) => {
                self.spawn(&format!("Removing mount {r}"), move |paths| {
                    // Decided now, not from the (possibly paused) poll.
                    let live = mount_stopped(
                        &sys::unit_active_state(&cmd::mount_unit(&r)),
                        sys::is_mounted(&paths.mount_point(&r)),
                    );
                    let busy = if live.is_err() {
                        check_busy(paths, &r)
                    } else {
                        Busy::Free
                    };
                    let dirty = sys::count_dirty(&paths.vfs_meta_dir(&r));
                    if !clear_to_stop(&busy, dirty) {
                        return Outcome::Busy {
                            what: BusyFor::Remove,
                            remote: r,
                            busy,
                            dirty,
                        };
                    }
                    remove_mount(paths, &r)
                });
            }
            Action::RemoveMountForce(r) => self
                .spawn(&format!("Removing mount {r}"), move |paths| {
                    remove_mount(paths, &r)
                }),
            Action::DeleteRemote(r) => {
                let users = self.users_of(&r);
                if !users.is_empty() {
                    self.msg(
                        Level::Error,
                        format!(
                            "Remote {r} kept: still used by {} — remove those first",
                            users.join(", ")
                        ),
                    );
                    return;
                }
                self.spawn(&format!("Deleting remote {r}"), move |_| {
                    let o = sys::run(&cmd::config_delete_cmd(&r));
                    if o.ok() {
                        Outcome::Msg(Level::Ok, format!("Remote {r} deleted from rclone.conf"))
                    } else {
                        Outcome::Msg(
                            Level::Error,
                            format!("rclone config delete {r}: {}", o.last_line()),
                        )
                    }
                })
            }
            Action::StopMount(r) => self.spawn(&format!("Unmounting {r}"), move |paths| {
                let busy = check_busy(paths, &r);
                let dirty = sys::count_dirty(&paths.vfs_meta_dir(&r));
                if !clear_to_stop(&busy, dirty) {
                    return Outcome::Busy {
                        what: BusyFor::Stop,
                        remote: r,
                        busy,
                        dirty,
                    };
                }
                stop_mount(&r)
            }),
            Action::StopMountForce(r) => {
                self.spawn(&format!("Unmounting {r}"), move |_| stop_mount(&r))
            }
            Action::RestartMount(r) => self.spawn(&format!("Restarting {r}"), move |paths| {
                let busy = check_busy(paths, &r);
                let dirty = sys::count_dirty(&paths.vfs_meta_dir(&r));
                if !clear_to_stop(&busy, dirty) {
                    return Outcome::Busy {
                        what: BusyFor::Restart,
                        remote: r,
                        busy,
                        dirty,
                    };
                }
                restart_mount(&r)
            }),
            Action::RestartMountForce(r) => {
                self.spawn(&format!("Restarting {r}"), move |_| restart_mount(&r))
            }
            Action::AddPair(np) => {
                let label = format!("Setting up {}", np.name);
                self.spawn(&label, move |paths| add_pair(paths, *np));
            }
            Action::StartSync(p) => self.spawn(&format!("First sync of {p}"), move |paths| {
                start_sync(paths, &p)
            }),
            Action::CopyFirst(p) => self
                .spawn(&format!("Copying remote → local for {p}"), move |paths| {
                    copy_first(paths, &p)
                }),
            Action::ResumePair(p) => self.spawn(&format!("Resuming {p}"), move |_| resume_pair(&p)),
            Action::RemovePair(p) => self.spawn(&format!("Removing {p}"), move |paths| {
                remove_pair(paths, &p)
            }),
            Action::RemoveJob(j) => {
                self.spawn(&format!("Removing {j}"), move |paths| remove_job(paths, &j))
            }
            Action::ClearCache(r) => {
                self.spawn(&format!("Clearing the cache of {r}"), move |paths| {
                    // Checked before renaming, and again on the renamed
                    // (frozen) copy right before deleting.
                    let verdict = |meta: &Path| {
                        clear_cache_verdict(
                            &sys::unit_active_state(&cmd::mount_unit(&r)),
                            sys::is_mounted(&paths.mount_point(&r)),
                            sys::count_dirty(meta),
                        )
                    };
                    if let Err(e) = verdict(&paths.vfs_meta_dir(&r)) {
                        return Outcome::Msg(Level::Error, format!("{r}: {e} — nothing deleted"));
                    }
                    match sys::clear_cache_dirs(&paths.rclone_cache(), &r, verdict) {
                        Err(e) => Outcome::Msg(Level::Error, format!("{r}: {e} — nothing deleted")),
                        Ok(done) if done.is_empty() => {
                            Outcome::Msg(Level::Info, format!("{r}: no cache to clear"))
                        }
                        Ok(done) => {
                            Outcome::Msg(Level::Ok, format!("Cleared {}", done.join(" and ")))
                        }
                    }
                });
            }
        }
    }

    // ------------------------------------------------------------ outcomes

    pub fn on_outcome(&mut self, o: Outcome) {
        self.running = None;
        match o {
            Outcome::Msg(l, m) => self.msg(l, m),
            Outcome::View {
                title,
                text,
                level,
                msg,
            } => {
                self.view(title, &text);
                if !msg.is_empty() {
                    self.msg(level, msg);
                }
            }
            Outcome::Busy {
                what,
                remote,
                busy,
                dirty,
            } => {
                let mnt = self.paths.mount_point(&remote).display().to_string();
                let (title, body, yes, action) = busy_dialog(what, &remote, &mnt, &busy, dirty);
                match action {
                    Some(action) => self.confirm(&title, body, &yes, action),
                    None => {
                        self.view(title, &body.join("\n"));
                        self.msg(Level::Warn, format!("{remote} is in use — not removed"));
                    }
                }
            }
            Outcome::MountRemoved { remote, log, dirty } => {
                self.refresh();
                let users = self.users_of(&remote);
                match delete_remote_offer(&remote, &users, dirty) {
                    Ok(body) => {
                        self.msg(Level::Ok, log.join("; "));
                        self.mode = Mode::TypeConfirm(TypeConfirm {
                            title: format!("Delete the rclone remote {remote} too?"),
                            body,
                            expect: remote.clone(),
                            input: String::new(),
                            action: Action::DeleteRemote(remote),
                        });
                    }
                    Err(why) => self.msg(Level::Warn, format!("{}; {why}", log.join("; "))),
                }
                return;
            }
            Outcome::SettingsSaved {
                remote,
                active,
                log,
            } => {
                self.refresh();
                if active {
                    self.msg(Level::Ok, log.join("; "));
                    self.confirm(
                        &format!("Restart {remote} now?"),
                        vec![
                            "The new settings apply when the mount restarts.".into(),
                            "Open files are checked first.".into(),
                        ],
                        "Restart",
                        Action::RestartMount(remote),
                    );
                } else {
                    self.msg(
                        Level::Ok,
                        format!("{} — applies at the next mount", log.join("; ")),
                    );
                }
                return;
            }
            Outcome::PairChecked {
                pair,
                out,
                local_empty,
                note,
            } => self.pair_checked(pair, out, local_empty, note),
            Outcome::CacheChecked {
                remote,
                stopped,
                dirty,
            } => {
                if let Err(e) = stopped {
                    self.msg(Level::Error, e);
                } else if let Err(e) = clear_cache_pending(dirty) {
                    self.msg(Level::Error, format!("{remote}: {e} — not clearing"));
                } else {
                    let body = vec![
                        format!(
                            "Deletes {} and {}.",
                            self.paths.tilde(&self.paths.vfs_dir(&remote)),
                            self.paths.tilde(&self.paths.vfs_meta_dir(&remote))
                        ),
                        "No pending uploads found.".into(),
                    ];
                    self.confirm(
                        &format!("Clear the cache of {remote}?"),
                        body,
                        "Clear",
                        Action::ClearCache(remote),
                    );
                }
            }
            Outcome::CanResume(pair) => self.confirm(
                &format!("Resume syncing {pair}?"),
                vec![
                    format!(
                        "{pair} has synced before, so a normal bisync run reconciles both sides:"
                    ),
                    "changes made on either side meanwhile are synced, and a file changed on"
                        .into(),
                    "both sides keeps both versions (the loser becomes a conflict copy).".into(),
                    "DELETIONS made on one side since the last sync are applied to the other"
                        .into(),
                    "side too: a file deleted here since then is deleted on the remote, and".into(),
                    "the other way round.".into(),
                    String::new(),
                    format!("Enables rclone-bisync@{pair}.timer and .path and starts one run now."),
                ],
                "Resume",
                Action::ResumePair(pair),
            ),
            Outcome::Reconnect(r) => {
                self.msg(Level::Ok, format!("Client set for {r}; reconnecting"));
                self.interactive = Some(Interactive::Reconnect(r));
            }
        }
        self.refresh();
    }

    fn pair_checked(&mut self, pair: String, out: Output, local_empty: bool, note: Vec<String>) {
        let text = out.text();
        let mut head = note;
        match out.code {
            Some(EXIT_EMPTY) => {
                let mut v = head;
                v.push(format!("REFUSED: {pair}: {NOTHING_TO_SYNC}."));
                v.push(
                    "A sync started with both sides empty fails on every later run, so it was not"
                        .into(),
                );
                v.push("started. Then press Enter on the folder to check again.".into());
                let joined = format!("{}\n\n{text}", v.join("\n"));
                self.view(format!("{pair}: nothing to sync"), &joined);
                self.msg(Level::Warn, format!("{pair}: {NOTHING_TO_SYNC}"));
            }
            Some(0) => {
                head.push(format!("Local and remote are identical for {pair}."));
                head.push(String::new());
                head.push(
                    "Start syncing: establishes the bisync baseline (resync), then enables".into(),
                );
                head.push(format!(
                    "rclone-bisync@{pair}.timer and .path so changes sync automatically."
                ));
                self.confirm(
                    &format!("Start syncing {pair}?"),
                    head,
                    "Start syncing",
                    Action::StartSync(pair),
                );
            }
            Some(1) if local_empty => {
                head.push("The local folder is empty and the remote is not.".into());
                head.push("Copy remote → local first (rclone copy: never deletes, never writes to the remote),".into());
                head.push("then check again?".into());
                head.push(String::new());
                head.extend(text.lines().take(8).map(String::from));
                self.confirm(
                    &format!("Copy {pair} remote → local?"),
                    head,
                    "Copy",
                    Action::CopyFirst(pair),
                );
            }
            Some(1) => {
                let mut v = head;
                v.push(format!(
                    "REFUSED: local and remote differ for {pair}, so syncing was not started."
                ));
                v.push(
                    "A first sync between different trees can lose edits. Make them identical"
                        .into(),
                );
                v.push("(copy what is missing by hand), then press Enter on the folder to check again.".into());
                v.push(String::new());
                v.push("Differences (rclone check):".into());
                let joined = format!("{}\n{text}", v.join("\n"));
                self.view(format!("{pair}: local and remote differ"), &joined);
                self.msg(Level::Warn, format!("{pair}: not identical — not started"));
            }
            _ => {
                let joined = format!("{}\n{text}", head.join("\n"));
                self.view(format!("{pair}: check failed"), &joined);
                self.msg(
                    Level::Error,
                    format!("check {pair} failed (exit {})", out.code.unwrap_or(-1)),
                );
            }
        }
    }

    // ---------------------------------------------------------- interactive

    /// Called by the main loop after an interactive command returned.
    pub fn after_interactive(&mut self, what: Interactive, res: Result<i32, String>) {
        match what {
            Interactive::RcloneConfig { before } => {
                self.refresh();
                if !self.remotes_ok {
                    self.msg(
                        Level::Error,
                        "rclone listremotes failed after rclone config — nothing set up",
                    );
                    return;
                }
                if let Err(e) = res {
                    self.msg(Level::Error, e);
                    return;
                }
                let new: Vec<(String, String)> = self
                    .remotes
                    .iter()
                    .filter(|r| !before.contains(&r.name))
                    .map(|r| (r.name.clone(), r.kind.clone()))
                    .collect();
                if new.is_empty() {
                    self.msg(Level::Info, "No new remote");
                    return;
                }
                // refresh() just re-read cloud.env.
                let ready = root_ready(&self.paths);
                self.spawn("Setting up the new mount(s)", move |paths| {
                    let mut log = Vec::new();
                    let mut level = Level::Ok;
                    for (r, kind) in &new {
                        let env = paths.mount_env(r);
                        if !env.exists()
                            && let Err(e) = sys::write_atomic(&env, &envfile::initial_env(kind))
                        {
                            level = Level::Error;
                            log.push(format!("{r}: {e}"));
                            continue;
                        }
                        if ready.is_err() {
                            log.push(format!("{r}: settings saved, not mounted"));
                            continue;
                        }
                        let o = sys::run(&cmd::mount_enable_cmd(r));
                        if !o.ok() {
                            level = Level::Error;
                            log.push(format!("{r}: enable failed: {}", o.last_line()));
                            continue;
                        }
                        match sys::create_cloud_link(&paths.cloud_link(r), &paths.mount_point(r)) {
                            Ok(true) => log.push(format!("{r} mounted, ~/Cloud/{r} linked")),
                            Ok(false) => {
                                log.push(format!("{r} mounted (~/Cloud/{r} already exists)"))
                            }
                            Err(e) => {
                                level = Level::Warn;
                                log.push(format!("{r} mounted; link: {e}"));
                            }
                        }
                    }
                    if let Err(why) = ready {
                        return Outcome::View {
                            title: "Mount root not set up".into(),
                            text: format!("{why}\n\n{}", log.join("\n")),
                            level: Level::Warn,
                            msg: "New remote(s) not mounted: the mount root is not set up — press m to mount once it is".into(),
                        };
                    }
                    Outcome::Msg(level, log.join("; "))
                });
            }
            Interactive::Reconnect(r) => {
                self.refresh();
                match res {
                    Ok(0) => self.msg(Level::Ok, format!("{r} reconnected")),
                    Ok(c) => self.msg(Level::Error, format!("reconnect {r} exited {c}")),
                    Err(e) => self.msg(Level::Error, e),
                }
            }
            Interactive::EditFiles {
                job,
                file,
                setup,
                enable,
            } => {
                if let Err(e) = res {
                    self.msg(Level::Error, format!("editor: {e}"));
                }
                self.spawn(&format!("Checking backup {job}"), move |paths| {
                    finish_job(paths, &job, &file, setup, enable)
                });
            }
        }
    }
}

// ------------------------------------------------- pure form → config

/// The settings form's values (in MANAGED order) → env changes; empty
/// removes the key so the unit default applies.
pub fn build_settings(values: &[String]) -> Result<Vec<(&'static str, Option<String>)>, String> {
    let mut out = Vec::new();
    for (m, v) in MANAGED.iter().zip(values) {
        let v = v.trim();
        if v.is_empty() {
            out.push((m.key, None));
        } else {
            envfile::validate_value(m, v)?;
            out.push((m.key, Some(v.to_string())));
        }
    }
    Ok(out)
}

#[allow(clippy::too_many_arguments)]
pub fn build_pair(
    paths: &Paths,
    fuse: &[PathBuf],
    name: &str,
    remote: &str,
    path: &str,
    local: &str,
    include: &str,
    interval: &str,
) -> Result<NewPair, String> {
    if !validate::is_valid_name(name) {
        return Err(
            "Name: letters, digits, _ . - (starting with a letter or digit), up to 64".into(),
        );
    }
    if !validate::is_valid_name(remote) {
        return Err("Remote: choose a remote".into());
    }
    let path = path.trim_matches('/');
    if !path.is_empty() && !validate::is_valid_rel(path) {
        return Err("Remote folder: a relative path, without //, . or .. segments".into());
    }
    let local_abs =
        validate::expand_local(local, &paths.home).map_err(|e| format!("Local folder: {e}"))?;
    if local_abs == paths.home || local_abs == Path::new("/") {
        return Err("Local folder: choose a folder, not your home or /".into());
    }
    cloud_loop(paths, &local_abs, fuse).map_err(|e| format!("Local folder: {e}"))?;
    let patterns =
        validate::parse_patterns(include).map_err(|e| format!("Include patterns: {e}"))?;
    let interval = if interval.is_empty() {
        None
    } else {
        Some(interval.to_string())
    };
    let filter = conf::filter_text(&patterns);
    let conf = PairConf {
        local: paths.tilde(&local_abs),
        remote: format!("{remote}:{path}"),
        filter: filter
            .as_ref()
            .map(|_| paths.tilde(&paths.pair_filter(name))),
        interval,
    };
    conf.validate(&paths.home)?;
    Ok(NewPair {
        name: name.to_string(),
        conf,
        filter,
        local_abs,
        create_local: false,
    })
}

#[allow(clippy::too_many_arguments)]
pub fn build_job(
    paths: &Paths,
    fuse: &[PathBuf],
    name: &str,
    remote: &str,
    prefix: &str,
    dest: &str,
    keep: &str,
    schedule: &str,
    strip: &str,
    files: &str,
) -> Result<JobConf, String> {
    let home = paths.home.as_path();
    if !validate::is_valid_name(name) {
        return Err(
            "Name: letters, digits, _ . - (starting with a letter or digit), up to 64".into(),
        );
    }
    if !validate::is_valid_name(remote) {
        return Err("Remote: choose a remote".into());
    }
    let prefix = prefix.trim_matches('/');
    let dest_abs = validate::expand_local(dest, home).map_err(|e| format!("Destination: {e}"))?;
    if dest_abs == home || dest_abs == Path::new("/") {
        return Err("Destination: choose a folder, not your home or /".into());
    }
    cloud_loop(paths, &dest_abs, fuse).map_err(|e| format!("Destination: {e}"))?;
    let keep = if keep.is_empty() {
        None
    } else {
        Some(validate::parse_keep(keep).ok_or("Keep copies: a number from 1 to 365")?)
    };
    let files = if files.is_empty() {
        None
    } else {
        let f = validate::expand_local(files, home).map_err(|e| format!("Files list: {e}"))?;
        Some(cmd::tilde_of(home, &f))
    };
    let c = JobConf {
        remote: format!("{remote}:{prefix}"),
        files,
        dest: cmd::tilde_of(home, &dest_abs),
        keep,
        schedule: (!schedule.is_empty()).then(|| schedule.to_string()),
        strip_prefix: (!strip.is_empty()).then(|| strip.to_string()),
    };
    c.validate(home)?;
    Ok(c)
}

// ------------------------------------------------------ pure flow logic

/// Whether a mount is clearly stopped: the unit inactive or failed, and the
/// mount point absent from the mounts table. Anything else (running,
/// starting, unknown, table unreadable) is an Err saying why.
pub fn mount_stopped(active_state: &str, mounted: Option<bool>) -> Result<(), String> {
    match (active_state, mounted) {
        ("inactive" | "failed", Some(false)) => Ok(()),
        ("inactive" | "failed", Some(true)) => {
            Err("still mounted (stale mount) — unmount it first".into())
        }
        (_, None) => Err("cannot read the mounts table".into()),
        ("", _) => Err("cannot tell whether the mount is running".into()),
        (s, _) => Err(format!(
            "the mount is {s} — unmount it first (m on Remotes)"
        )),
    }
}

/// Clearing a VFS cache goes ahead only when the mount is still stopped and
/// no upload is pending (see `clear_cache_pending`). Pure.
pub fn clear_cache_verdict(
    active_state: &str,
    mounted: Option<bool>,
    dirty_now: Option<usize>,
) -> Result<(), String> {
    mount_stopped(active_state, mounted)?;
    clear_cache_pending(dirty_now)
}

/// A VFS cache is cleared only when its pending uploads are counted and 0:
/// any pending upload, or a count that could not be made, refuses (there is
/// no override; clearing would lose those files). Pure.
pub fn clear_cache_pending(dirty: Option<usize>) -> Result<(), String> {
    const HOW: &str = "mount the remote and wait for rclone to upload them, then try again";
    match dirty {
        Some(0) => Ok(()),
        Some(n) => Err(format!("{n} file(s) have uploads still pending — {HOW}")),
        None => Err(format!(
            "pending uploads could not be counted (the cache could not be fully read) — {HOW}"
        )),
    }
}

/// A mount can be stopped (restarted, removed) without asking only when
/// nothing has files open on it and no upload is pending, both known. Pure.
pub fn clear_to_stop(busy: &Busy, dirty: Option<usize>) -> bool {
    *busy == Busy::Free && dirty == Some(0)
}

/// The confirm-dialog line about pending uploads, as the bar plugin words
/// it; None when there are none. `remove`: the mount is going away, so they
/// upload only if it is mounted again. Pure.
pub fn pending_line(dirty: Option<usize>, remove: bool) -> Option<String> {
    match dirty {
        Some(0) => None,
        None => Some(
            "Pending uploads could not be counted (the cache could not be fully read): files may not be uploaded yet."
                .into(),
        ),
        Some(n) if remove => Some(format!(
            "{n} pending upload(s) in the cache: they upload only if the remote is mounted again."
        )),
        Some(n) => Some(format!(
            "{n} pending upload(s) will resume on the next mount (the cache is kept)."
        )),
    }
}

/// The dialog after a stop, restart or remove found files open or uploads
/// pending: (title, body, yes label, action to go ahead anyway). No action:
/// a removal with files open is refused (shown as a view). Pure.
pub fn busy_dialog(
    what: BusyFor,
    remote: &str,
    mnt: &str,
    busy: &Busy,
    dirty: Option<usize>,
) -> (String, Vec<String>, String, Option<Action>) {
    let pending = pending_line(dirty, matches!(what, BusyFor::Remove));
    let who = match busy {
        Busy::InUse(p) => Some(sys::describe_pids(p).join(", ")),
        _ => None,
    };
    if let BusyFor::Remove = what {
        if let Some(who) = who {
            return (
                format!("Not removed — files open on {mnt}"),
                vec![
                    "Processes with files open on the mount:".into(),
                    format!("  {who}"),
                    String::new(),
                    "Close them (or let pending uploads finish), then remove again.".into(),
                ],
                String::new(),
                None,
            );
        }
        let mut body = Vec::new();
        if *busy == Busy::Unknown {
            body.push("fuser could not tell whether files are open (timed out or failed).".into());
        }
        body.extend(pending);
        body.push("Remove the mount anyway?".into());
        let title = if *busy == Busy::Unknown {
            format!("Could not check {mnt}")
        } else {
            format!("Uploads pending for {remote}")
        };
        return (
            title,
            body,
            "Remove anyway".into(),
            Some(Action::RemoveMountForce(remote.to_string())),
        );
    }
    let (verb, action) = if matches!(what, BusyFor::Stop) {
        ("Unmount", Action::StopMountForce(remote.to_string()))
    } else {
        ("Restart", Action::RestartMountForce(remote.to_string()))
    };
    let mut body = Vec::new();
    match (busy, &who) {
        (_, Some(who)) => body.push(format!("Files are open on {mnt} by: {who}")),
        (Busy::Unknown, _) => {
            body.push(format!("Could not check whether files are open on {mnt}."))
        }
        _ => {}
    }
    body.extend(pending);
    if *busy != Busy::Free {
        body.push("Programs using those files may lose unsaved work.".into());
    }
    (
        format!("{verb} {remote} anyway?"),
        body,
        format!("{verb} anyway"),
        Some(action),
    )
}

/// The first of `others` (name, directory) that `dir` overlaps (equal,
/// inside or containing, see `validate::overlaps`), checked as given and
/// with symlinks resolved; None when there is none.
pub fn overlap_with<'a>(
    dir: &Path,
    others: &'a [(String, PathBuf)],
) -> Option<&'a (String, PathBuf)> {
    let canon = sys::canonical_lenient(dir);
    others.iter().find(|(_, o)| {
        validate::overlaps(dir, o) || validate::overlaps(&canon, &sys::canonical_lenient(o))
    })
}

/// The body of the "delete the remote too?" dialog, or why it is not
/// offered (offline folders or backups still use the remote).
pub fn delete_remote_offer(
    remote: &str,
    users: &[String],
    dirty: Option<usize>,
) -> Result<Vec<String>, String> {
    if !users.is_empty() {
        return Err(format!(
            "remote {remote} kept in rclone.conf: still used by {}",
            users.join(", ")
        ));
    }
    let mut body = vec![
        format!("This runs `rclone config delete {remote}`: its credentials leave rclone.conf"),
        "and you would have to log in again to add it back.".into(),
    ];
    match dirty {
        Some(0) => {}
        Some(n) => {
            body.push(String::new());
            body.push(format!(
                "WARNING: {n} file(s) in its cache were never uploaded; deleting the remote"
            ));
            body.push("strands them (they upload only when the remote is mounted again).".into());
        }
        None => {
            body.push(String::new());
            body.push(
                "WARNING: its cache could not be fully read, so files in it may never have been"
                    .into(),
            );
            body.push(
                "uploaded; deleting the remote strands them (they upload only when it is mounted again)."
                    .into(),
            );
        }
    }
    body.push(String::new());
    body.push(format!(
        "Type {remote} and press Enter to delete it; Esc keeps it."
    ));
    Ok(body)
}

/// What follows `rclone-bisync resync`.
#[derive(Debug, PartialEq, Eq)]
pub enum ResyncNext {
    /// Baseline done: enable the timer and the folder watch.
    Enable,
    /// The pair's lock is held by another run: nothing done, try again.
    Busy,
    /// Local and remote differ: refused, nothing done.
    Refused,
    /// No file on either side: refused, nothing done (NOTHING_TO_SYNC).
    Empty,
    /// Any other failure.
    Failed,
}

pub fn resync_next(code: Option<i32>) -> ResyncNext {
    match code {
        Some(0) => ResyncNext::Enable,
        Some(EXIT_BUSY) => ResyncNext::Busy,
        Some(3) => ResyncNext::Refused,
        Some(EXIT_EMPTY) => ResyncNext::Empty,
        _ => ResyncNext::Failed,
    }
}

/// True when rclone bisync has prior listings for LOCAL ⇄ REMOTE (both
/// `.path1.lst` and `.path2.lst`) in the pinned work dir (the only one the
/// helper's runs read).
pub fn listings_exist(paths: &Paths, local: &Path, remote: &str) -> bool {
    let session = cmd::bisync_session(local, remote);
    let d = paths.bisync_workdir();
    ["path1", "path2"]
        .iter()
        .all(|k| d.join(format!("{session}.{k}.lst")).is_file())
}

/// A paused pair may resume with a normal run only when bisync has its
/// listings AND the pair has its own state file (written by its own resync
/// or run, deleted with the pair). Listings alone may be stale: left by a
/// removed pair with the same folders, they would make bisync diff against
/// an old baseline and propagate deletions instead of the first-sync check.
pub fn can_resume(paths: &Paths, pair: &str, local: &Path, remote: &str) -> bool {
    listings_exist(paths, local, remote) && paths.pair_state(pair).is_file()
}

/// Refuses a folder that overlaps a cloud location (is it, is inside it,
/// or contains it): the configured mount root, /mnt/cloud (an old mount
/// may still live there), ~/Cloud, or any FUSE mount point (`fuse`, from
/// `sys::fuse_mounts`). A pair would sync a remote with itself through the
/// mount (and a folder *containing* a mount, like /mnt or the root's
/// parent, still crosses into it); a backup would write (and prune) on a
/// remote, or into a bare mount point the next mount hides. Checked on the
/// path as given and with symlinks resolved; the error names the location.
/// The FUSE mount points come from /proc, already canonical, and are never
/// resolved: that would stat through a possibly hung mount.
pub fn cloud_loop(paths: &Paths, dir: &Path, fuse: &[PathBuf]) -> Result<(), String> {
    let mut targets: Vec<(PathBuf, String)> = Vec::new();
    let mut fixed: Vec<(PathBuf, String)> = Vec::new();
    if let Some(root) = paths.configured_root() {
        fixed.push((root.to_path_buf(), root.display().to_string()));
    }
    fixed.push((PathBuf::from(DEFAULT_ROOT), DEFAULT_ROOT.to_string()));
    fixed.push((paths.cloud_dir(), "~/Cloud".into()));
    for (r, label) in fixed {
        let canon = sys::canonical_lenient(&r);
        targets.push((r, label.clone()));
        targets.push((canon, label));
    }
    targets.extend(fuse.iter().map(|m| (m.clone(), m.display().to_string())));
    let canon = sys::canonical_lenient(dir);
    for p in [dir, canon.as_path()] {
        if let Some((_, label)) = targets.iter().find(|(t, _)| validate::overlaps(p, t)) {
            return Err(format!(
                "{} overlaps a cloud location ({label}); choose a local folder that is not inside one and contains none",
                p.display()
            ));
        }
    }
    Ok(())
}

/// C3: the one command that creates the mount root, the path single-quoted
/// (`'` becomes `'\''`). `"$USER"` is literal: the user's shell expands it.
/// Shown, never run.
pub fn root_setup_command(root: &Path) -> String {
    let q = root.to_string_lossy().replace('\'', r"'\''");
    format!("sudo install -d -o \"$USER\" -m 755 '{q}'")
}

/// Whether a mount may be enabled now: the mount root is set in cloud.env,
/// valid, and an existing directory this user can write to (the unit only
/// creates `<root>/<remote>` inside it, never the root). Err: what to do, on
/// several lines.
pub fn root_ready(paths: &Paths) -> Result<(), String> {
    let file = paths.tilde(&paths.cloud_env());
    let setup = "Run install.sh from the plugin folder (the bar panel's Set up… button runs it) to choose it, or install.sh --mount-root PATH.";
    match &paths.root_setting {
        RootSetting::Absent => Err(format!(
            "The mount root is not set up: {file} sets no OMARCHY_CLOUD_ROOT.\n{setup}"
        )),
        RootSetting::Invalid(v) => {
            let v: String = v.chars().take(120).collect();
            Err(format!(
                "The mount root is not set up: OMARCHY_CLOUD_ROOT={v} in {file} is not valid\n\
                 (it must be an absolute path outside your home, without spaces, quotes, $, % or \\).\n{setup}"
            ))
        }
        RootSetting::Valid(r) => match sys::dir_problem(r) {
            None => Ok(()),
            Some(why) => Err(format!(
                "The mount root is not set up: {} {why}.\n\
                 Create it once, in a terminal (nothing here runs sudo for you):\n  {}\n\
                 then try again.",
                r.display(),
                root_setup_command(r)
            )),
        },
    }
}

/// The units the poll names for a pair. The .path only once its drop-in
/// exists (`rclone-bisync setup` wrote it): naming one without makes systemd
/// log "Path unit lacks path setting" on every poll (the bar never names
/// it either). Its state then reads "not installed". Pure.
pub fn pair_units(pair: &str, watch_set_up: bool) -> Vec<String> {
    let mut v = vec![cmd::pair_timer(pair)];
    if watch_set_up {
        v.push(cmd::pair_path(pair));
    }
    v.push(cmd::pair_service(pair));
    v
}

/// A backup's files list must name at least one file: an empty list is an
/// invalid conf for the helper (every run would exit 64). Returns the count.
pub fn files_list_verdict(text: &str) -> Result<usize, String> {
    match conf::check_files_list(text)? {
        0 => Err("the files list names no file; add at least one path".into()),
        n => Ok(n),
    }
}

// ------------------------------------------------------- worker bodies

/// Sets a Drive remote's OAuth client in rclone.conf without putting the
/// secret on any argument vector: `run` gets only `rclone config file` (to
/// find the file); the file is edited in-process (`write_client`). The
/// reconnect that follows (`Outcome::Reconnect`) gets a new token.
pub fn set_client(
    remote: &str,
    id: &str,
    secret: &Secret,
    run: &mut dyn FnMut(&[String]) -> Output,
) -> Result<(), String> {
    let o = run(&cmd::config_file_cmd());
    if !o.ok() {
        return Err(format!("rclone config file failed: {}", o.last_line()));
    }
    let path =
        rclone_conf::config_path(&o.stdout).ok_or("rclone config file printed no absolute path")?;
    write_client(&path, remote, id, secret)
}

/// Writes `client_id` / `client_secret` into the `[remote]` section of the
/// rclone.conf at `path` (`rclone_conf::set_client`: nothing else changes).
/// Refuses an encrypted config (rclone would have to decrypt it) and a
/// symlink (`sys::write_atomic`, mode 600). The file is read again right
/// before the write, since rclone rewrites it on every token refresh; when
/// it changed in between, the edit is redone on the new text. Every copy of
/// the new text is zeroed.
pub fn write_client(path: &Path, remote: &str, id: &str, secret: &Secret) -> Result<(), String> {
    use zeroize::Zeroize;
    let shown = path.display();
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(format!(
            "{shown} is a symlink; refusing to write it — set the client in rclone config instead"
        ));
    }
    for _ in 0..3 {
        let mut before = sys::read_small(path).ok_or_else(|| format!("cannot read {shown}"))?;
        if rclone_conf::is_encrypted(&before) {
            before.zeroize();
            return Err(format!(
                "{shown} is encrypted; set the client in rclone config (edit the remote {remote})"
            ));
        }
        let mut new = match rclone_conf::set_client(&before, remote, id, secret.expose()) {
            Ok(t) => t,
            Err(e) => {
                before.zeroize();
                return Err(e);
            }
        };
        let mut again = sys::read_small(path).unwrap_or_default();
        let same = again == before;
        before.zeroize();
        again.zeroize();
        if same {
            let res = sys::write_atomic(path, &new);
            new.zeroize();
            return res;
        }
        new.zeroize();
    }
    Err(format!(
        "{shown} kept changing while it was edited; try again"
    ))
}

fn show_units(units: &[String]) -> Option<HashMap<String, UnitProps>> {
    let out = sys::run_for(&cmd::systemctl_show_cmd(units), REFRESH_LIMIT);
    let props = sys::parse_show(&out.stdout);
    (out.ok() || !props.is_empty()).then_some(props)
}

fn check_busy(paths: &Paths, remote: &str) -> Busy {
    let o = sys::run(&cmd::fuser_cmd(&paths.mount_point(remote)));
    sys::parse_fuser(o.code, &o.stdout)
}

fn stop_mount(r: &str) -> Outcome {
    let o = sys::run(&cmd::stop_cmd(&cmd::mount_unit(r)));
    if o.ok() {
        Outcome::Msg(Level::Ok, format!("Unmounted {r}"))
    } else {
        Outcome::Msg(Level::Error, format!("Unmount {r}: {}", o.last_line()))
    }
}

fn restart_mount(r: &str) -> Outcome {
    let o = sys::run(&cmd::restart_cmd(&cmd::mount_unit(r)));
    if o.ok() {
        Outcome::Msg(Level::Ok, format!("Restarted {r} with the new settings"))
    } else {
        Outcome::Msg(Level::Error, format!("Restart {r}: {}", o.last_line()))
    }
}

fn remove_mount(paths: &Paths, r: &str) -> Outcome {
    let o = sys::run(&cmd::mount_disable_cmd(r));
    if !o.ok() {
        return Outcome::Msg(Level::Error, format!("disable {r}: {}", o.last_line()));
    }
    let mut log = vec![format!("{r} stopped and disabled")];
    match sys::remove_cloud_link(&paths.cloud_link(r), &paths.mount_point(r)) {
        Ok(true) => log.push(format!("~/Cloud/{r} removed")),
        Ok(false) => {}
        Err(e) => log.push(e),
    }
    match sys::remove_if_exists(&paths.mount_env(r)) {
        Ok(true) => log.push(format!("{r}.env removed")),
        Ok(false) => {}
        Err(e) => log.push(e),
    }
    // Counted once the mount is stopped: what is left stays in the cache.
    let dirty = sys::count_dirty(&paths.vfs_meta_dir(r));
    match dirty {
        Some(0) => {}
        Some(n) => log.push(format!("{n} upload(s) still pending in the cache")),
        None => log.push("pending uploads could not be counted".into()),
    }
    Outcome::MountRemoved {
        remote: r.to_string(),
        log,
        dirty,
    }
}

fn pair_local(paths: &Paths, pair: &str) -> Result<(PairConf, PathBuf), String> {
    let text = sys::read_small(&paths.pair_conf(pair))
        .ok_or_else(|| format!("cannot read {pair}.conf"))?;
    let c = PairConf::parse(&text, &paths.home)?;
    let local = validate::expand_local(&c.local, &paths.home)?;
    cloud_loop(paths, &local, &sys::fuse_mounts()).map_err(|e| format!("{pair}: LOCAL {e}"))?;
    Ok((c, local))
}

/// Enter on a paused (or never started) pair: when it has synced before
/// (`can_resume`), offer a normal run; else the check → resync flow.
fn paused_enter(paths: &Paths, pair: &str) -> Outcome {
    let (c, local) = match pair_local(paths, pair) {
        Ok(x) => x,
        Err(e) => return Outcome::Msg(Level::Error, e),
    };
    if can_resume(paths, pair, &local, &c.remote) {
        if !local.is_dir() {
            return Outcome::Msg(
                Level::Error,
                format!("{}: the local folder is missing — not resuming", c.local),
            );
        }
        return Outcome::CanResume(pair.to_string());
    }
    check_pair(paths, pair, Vec::new())
}

fn resume_pair(pair: &str) -> Outcome {
    let [enable, run] = cmd::pair_resume_cmds(pair);
    let e = sys::run(&enable);
    if !e.ok() {
        return Outcome::Msg(Level::Error, format!("resume {pair}: {}", e.last_line()));
    }
    let r = sys::run(&run);
    if r.ok() {
        Outcome::Msg(Level::Ok, format!("{pair} resumed; a sync run started"))
    } else {
        Outcome::Msg(
            Level::Warn,
            format!(
                "{pair} resumed, but the first run did not start: {}",
                r.last_line()
            ),
        )
    }
}

/// `w` on a pair whose folder watch or timer stopped: reset-failed, start.
fn recover_pair(pair: &str) -> Outcome {
    let [reset, start] = cmd::pair_recover_cmds(pair);
    let r = sys::run(&reset);
    if !r.ok() {
        return Outcome::Msg(
            Level::Error,
            format!("reset-failed {pair}: {}", r.last_line()),
        );
    }
    let s = sys::run(&start);
    if s.ok() {
        Outcome::Msg(
            Level::Ok,
            format!("{pair}: folder watch and timer restarted"),
        )
    } else {
        Outcome::Msg(Level::Error, format!("start {pair}: {}", s.last_line()))
    }
}

fn check_pair(paths: &Paths, pair: &str, note: Vec<String>) -> Outcome {
    let local_empty = match pair_local(paths, pair) {
        Ok((_, l)) => sys::dir_is_empty(&l),
        Err(e) => return Outcome::Msg(Level::Error, e),
    };
    let out = sys::run(&cmd::bisync_cmd(paths, "check", pair));
    Outcome::PairChecked {
        pair: pair.to_string(),
        out,
        local_empty,
        note,
    }
}

fn add_pair(paths: &Paths, np: NewPair) -> Outcome {
    let mut note = Vec::new();
    if np.create_local {
        if let Err(e) = std::fs::create_dir_all(&np.local_abs) {
            return Outcome::Msg(Level::Error, format!("{}: {e}", np.local_abs.display()));
        }
        note.push(format!("Created {}.", np.conf.local));
    }
    if let Some(f) = &np.filter
        && let Err(e) = sys::write_atomic(&paths.pair_filter(&np.name), f)
    {
        return Outcome::Msg(Level::Error, e);
    }
    if let Err(e) = sys::write_atomic(&paths.pair_conf(&np.name), &np.conf.render()) {
        return Outcome::Msg(Level::Error, e);
    }
    let o = sys::run(&cmd::bisync_cmd(paths, "setup", &np.name));
    if !o.ok() {
        return Outcome::View {
            title: format!("setup {} failed", np.name),
            text: o.text(),
            level: Level::Error,
            msg: format!(
                "setup {} failed — the conf was kept; remove it with d",
                np.name
            ),
        };
    }
    check_pair(paths, &np.name, note)
}

fn start_sync(paths: &Paths, pair: &str) -> Outcome {
    let o = sys::run(&cmd::bisync_cmd(paths, "resync", pair));
    match resync_next(o.code) {
        ResyncNext::Enable => {}
        ResyncNext::Busy => {
            return Outcome::Msg(
                Level::Warn,
                format!("{pair} is busy (another run holds its lock) — try again shortly"),
            );
        }
        ResyncNext::Refused => {
            return Outcome::View {
                title: format!("{pair}: resync refused — local and remote differ"),
                text: o.text(),
                level: Level::Warn,
                msg: format!("{pair}: changed since the check — not started"),
            };
        }
        ResyncNext::Empty => {
            return Outcome::View {
                title: format!("{pair}: nothing to sync"),
                text: o.text(),
                level: Level::Warn,
                msg: format!("{pair}: {NOTHING_TO_SYNC}"),
            };
        }
        ResyncNext::Failed => {
            return Outcome::View {
                title: format!("{pair}: resync failed"),
                text: o.text(),
                level: Level::Error,
                msg: format!("resync {pair} exited {}", o.code.unwrap_or(-1)),
            };
        }
    }
    let e = sys::run(&cmd::pair_enable_cmd(pair));
    if e.ok() {
        Outcome::Msg(
            Level::Ok,
            format!("{pair} is syncing (timer and folder watch enabled)"),
        )
    } else {
        Outcome::Msg(
            Level::Error,
            format!("baseline done, but enabling failed: {}", e.last_line()),
        )
    }
}

fn copy_first(paths: &Paths, pair: &str) -> Outcome {
    let (c, local) = match pair_local(paths, pair) {
        Ok(x) => x,
        Err(e) => return Outcome::Msg(Level::Error, e),
    };
    if !sys::dir_is_empty(&local) {
        return Outcome::Msg(
            Level::Error,
            format!("{} is no longer empty — not copying", c.local),
        );
    }
    let filter = match c.filter_file(&paths.home, &paths.pair_filter(pair)) {
        Ok(f) => f,
        Err(e) => return Outcome::Msg(Level::Error, e),
    };
    let o = sys::run(&cmd::copy_first_cmd(&c.remote, &local, filter.as_deref()));
    if !o.ok() {
        return Outcome::View {
            title: format!("{pair}: copy failed"),
            text: o.text(),
            level: Level::Error,
            msg: format!("rclone copy exited {}", o.code.unwrap_or(-1)),
        };
    }
    check_pair(
        paths,
        pair,
        vec![format!("Copied {} → {}.", c.remote, c.local)],
    )
}

/// Whether a unit state (`systemctl is-active`) means a run is in progress:
/// a sync still running rewrites its state file and listings after removal
/// deleted them, and a pair added again would then offer Resume. Pure.
pub fn run_in_progress(active: &str) -> bool {
    matches!(
        active,
        "active" | "activating" | "deactivating" | "reloading"
    )
}

fn remove_pair(paths: &Paths, pair: &str) -> Outcome {
    let mut log = Vec::new();
    let busy = || run_in_progress(&sys::unit_active_state(&cmd::pair_service(pair)));
    if busy() {
        return Outcome::Msg(
            Level::Error,
            format!(
                "{pair} is syncing now; wait for the run to finish (or pause {pair} first), \
                 then remove it — nothing removed"
            ),
        );
    }
    let o = sys::run(&cmd::pair_disable_cmd(pair));
    if !o.ok() {
        return Outcome::Msg(
            Level::Error,
            format!("disable {pair}: {} — nothing removed", o.last_line()),
        );
    }
    // A run the timer or the watch started meanwhile: the triggers are
    // stopped now, so none can start after this check.
    if busy() {
        return Outcome::Msg(
            Level::Error,
            format!(
                "{pair} paused, but a run started meanwhile; wait for it to finish, \
                 then remove it — nothing removed"
            ),
        );
    }
    let t = sys::run(&cmd::bisync_cmd(paths, "teardown", pair));
    if !t.ok() {
        return Outcome::Msg(
            Level::Error,
            format!("teardown {pair}: {} — conf kept", t.last_line()),
        );
    }
    let conf = sys::read_small(&paths.pair_conf(pair)).map(|t| PairConf::parse(&t, &paths.home));
    let (filter_is_own, leftovers) = pair_leftovers(paths, pair, conf.as_ref());
    if let Err(e) = sys::remove_if_exists(&paths.pair_conf(pair)) {
        return Outcome::Msg(Level::Error, e);
    }
    log.push(format!("{pair} removed (local and remote files untouched)"));
    if filter_is_own && let Err(e) = sys::remove_if_exists(&paths.pair_filter(pair)) {
        log.push(e);
    }
    for f in leftovers {
        if let Err(e) = sys::remove_if_exists(&f) {
            log.push(e);
        }
    }
    Outcome::Msg(Level::Ok, log.join("; "))
}

/// What removing a pair deletes besides its conf: whether its default filter
/// file goes (only when the pair uses it, or the conf cannot be read), and
/// the other files: the state file, the filter's `.md5` (rclone's hash of
/// it) when the filter goes, and the session's listings and lock in every
/// bisync work dir. Without them a pair added again with the same folders
/// would resume from a stale baseline. Pure.
pub fn pair_leftovers(
    paths: &Paths,
    pair: &str,
    conf: Option<&Result<PairConf, String>>,
) -> (bool, Vec<PathBuf>) {
    let own_filter = paths.pair_filter(pair);
    let filter_is_own = match conf {
        Some(Ok(c)) => c.filter.as_deref().is_none_or(|f| {
            validate::expand_local(f, &paths.home).ok().as_deref() == Some(own_filter.as_path())
        }),
        _ => true,
    };
    let mut v = vec![paths.pair_state(pair)];
    if filter_is_own {
        let mut md5 = own_filter.into_os_string();
        md5.push(".md5");
        v.push(PathBuf::from(md5));
    }
    if let Some(Ok(c)) = conf
        && let Ok(local) = validate::expand_local(&c.local, &paths.home)
    {
        let session = cmd::bisync_session(&local, &c.remote);
        v.extend(cmd::bisync_session_files(&paths.bisync_workdir(), &session));
    }
    (filter_is_own, v)
}

fn remove_job(paths: &Paths, job: &str) -> Outcome {
    let o = sys::run(&cmd::job_disable_cmd(job));
    if !o.ok() {
        return Outcome::Msg(
            Level::Error,
            format!("disable {job}: {} — nothing removed", o.last_line()),
        );
    }
    let t = sys::run(&cmd::backup_cmd(paths, "teardown", job));
    if !t.ok() {
        return Outcome::Msg(
            Level::Error,
            format!("teardown {job}: {} — conf kept", t.last_line()),
        );
    }
    match sys::remove_if_exists(&paths.job_conf(job)) {
        Ok(_) => Outcome::Msg(
            Level::Ok,
            format!("Backup {job} removed (copies and files list kept)"),
        ),
        Err(e) => Outcome::Msg(Level::Error, e),
    }
}

fn finish_job(paths: &Paths, job: &str, file: &Path, setup: bool, enable: bool) -> Outcome {
    let text = sys::read_small(file).unwrap_or_default();
    if let Err(e) = files_list_verdict(&text) {
        let what = if setup { " — not set up" } else { "" };
        return Outcome::Msg(
            Level::Error,
            format!("{}: {e}{what}; fix it with f", paths.tilde(file)),
        );
    }
    let l = sys::run(&cmd::backup_cmd(paths, "list", job));
    if !l.ok() {
        return Outcome::View {
            title: format!("{job}: invalid configuration"),
            text: l.text(),
            level: Level::Error,
            msg: format!("rclone-backup list {job} failed — fix with e / f"),
        };
    }
    if !setup {
        let n = l.stdout.lines().filter(|x| !x.trim().is_empty()).count();
        return Outcome::View {
            title: format!("Files backed up by {job}"),
            text: l.text(),
            level: Level::Ok,
            msg: format!("{job}: {n} file(s) in the list"),
        };
    }
    let s = sys::run(&cmd::backup_cmd(paths, "setup", job));
    if !s.ok() {
        return Outcome::Msg(Level::Error, format!("setup {job}: {}", s.last_line()));
    }
    if enable {
        let e = sys::run(&cmd::job_enable_cmd(job));
        if !e.ok() {
            return Outcome::Msg(Level::Error, format!("enable {job}: {}", e.last_line()));
        }
        return Outcome::Msg(
            Level::Ok,
            format!("Backup {job} saved and scheduled (Enter runs it now)"),
        );
    }
    Outcome::Msg(
        Level::Ok,
        format!("Backup {job} saved (schedule disabled — p enables it)"),
    )
}

/// The client-secret refusal: names exactly what `is_valid_client_secret`
/// refuses, never the value.
const CLIENT_SECRET_RULE: &str =
    "Client secret: 1-256 printable ASCII characters, none of space = \" ' or `";

#[cfg(test)]
mod tests {
    use super::*;

    fn paths() -> Paths {
        Paths::new(PathBuf::from("/home/u"))
    }

    fn scratch(tag: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("omarchy-cloud-app-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(&d).unwrap()
    }

    fn key(c: char, m: KeyModifiers) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), m)
    }

    fn form_app() -> App {
        let mut a = App::new(paths());
        a.mode = Mode::Form(Form {
            title: "t".into(),
            kind: FormKind::Pair,
            fields: vec![
                Field::text("name", "Name", "", ""),
                Field::other("secret", "S", "", Input::Secret(Secret::new())),
            ],
            focus: 0,
            error: None,
        });
        a
    }

    #[test]
    fn client_secret_refusal_names_the_refused_set_not_the_value() {
        let mut a = App::new(paths());
        for bad in ["a b", "a=b", "a\"b", "a'b", "a`b"] {
            let mut sec = Secret::new();
            bad.chars().for_each(|c| sec.push(c));
            let e = a.submit_client("r".into(), "id".into(), sec).unwrap_err();
            assert_eq!(e, CLIENT_SECRET_RULE);
            assert!(!e.contains(bad), "{e}");
        }
        // The message names every refused character, matching the validator.
        for c in ["space", "=", "\"", "'", "`"] {
            assert!(CLIENT_SECRET_RULE.contains(c), "{c}");
        }
        assert!(!CLIENT_SECRET_RULE.contains("without spaces or ="));
    }

    fn form_text(a: &App, key: &str) -> String {
        match &a.mode {
            Mode::Form(f) => f.get(key),
            _ => panic!("not a form"),
        }
    }

    #[test]
    fn ctrl_letters_do_not_type() {
        let mut a = form_app();
        a.on_key(key('a', KeyModifiers::NONE));
        a.on_key(key('b', KeyModifiers::CONTROL));
        a.on_key(key('x', KeyModifiers::ALT));
        a.on_key(key('C', KeyModifiers::SHIFT));
        assert_eq!(form_text(&a, "name"), "aC");
        a.on_key(key('u', KeyModifiers::CONTROL));
        assert_eq!(form_text(&a, "name"), "");
        // In the secret field too.
        a.on_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE));
        a.on_key(key('s', KeyModifiers::NONE));
        a.on_key(key('k', KeyModifiers::CONTROL));
        if let Mode::Form(f) = &mut a.mode {
            assert_eq!(f.take_secret("secret").expose(), "s");
        }
        // Normal mode: Ctrl+d does not ask to remove anything.
        let mut n = App::new(paths());
        n.on_key(key('d', KeyModifiers::CONTROL));
        assert!(matches!(n.mode, Mode::Normal));
        assert!(!n.quit);
        n.on_key(key('c', KeyModifiers::CONTROL));
        assert!(n.quit);
    }

    #[test]
    fn paste_goes_into_the_field() {
        let mut a = form_app();
        a.on_paste("my\r\nname\n");
        assert_eq!(form_text(&a, "name"), "myname");
        assert!(matches!(a.mode, Mode::Form(_)), "a paste never submits");
        a.on_paste(&"x".repeat(validate::MAX_TEXT + 10));
        assert_eq!(form_text(&a, "name").len(), validate::MAX_TEXT);
        a.on_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE));
        a.on_paste("GOCSPX-abc\n");
        if let Mode::Form(f) = &mut a.mode {
            assert_eq!(f.take_secret("secret").expose(), "GOCSPX-abc");
        }
        let mut t = App::new(paths());
        t.mode = Mode::TypeConfirm(TypeConfirm {
            title: String::new(),
            body: Vec::new(),
            expect: "gdrive".into(),
            input: String::new(),
            action: Action::DeleteRemote("gdrive".into()),
        });
        t.on_paste("gdrive\r\n");
        match &t.mode {
            Mode::TypeConfirm(c) => assert_eq!(c.input, "gdrive"),
            _ => panic!("the paste must not confirm"),
        }
        let mut n = App::new(paths());
        n.on_paste("dq");
        assert!(matches!(n.mode, Mode::Normal) && !n.quit);
    }

    #[test]
    fn status_expires() {
        let mut a = App::new(paths());
        a.msg(Level::Ok, "done\nsecond line");
        a.tick();
        assert_eq!(a.status.as_ref().map(|s| s.1.as_str()), Some("done"));
        if let Some(s) = &mut a.status {
            s.2 = Instant::now() - STATUS_TTL;
        }
        a.tick();
        assert!(a.status.is_none());
    }

    #[test]
    fn worker_panic_clears_busy() {
        let mut a = App::new(paths());
        a.spawn("boom", |_| panic!("kaput"));
        assert!(a.running.is_some());
        let o = a.rx.recv_timeout(Duration::from_secs(5)).unwrap();
        a.on_outcome(o);
        assert!(a.running.is_none());
        let (l, m, _) = a.status.clone().unwrap();
        assert!(l == Level::Error && m.contains("kaput"), "{m}");
    }

    #[test]
    fn mount_must_be_stopped() {
        assert!(mount_stopped("inactive", Some(false)).is_ok());
        assert!(mount_stopped("failed", Some(false)).is_ok());
        for (st, m) in [
            ("active", Some(false)),
            ("activating", Some(false)),
            ("deactivating", Some(false)),
            ("inactive", Some(true)),
            ("inactive", None),
            ("", Some(false)),
        ] {
            assert!(mount_stopped(st, m).is_err(), "{st} {m:?}");
        }
        assert!(clear_cache_verdict("inactive", Some(false), Some(0)).is_ok());
        assert!(clear_cache_verdict("active", Some(true), Some(0)).is_err());
        assert!(clear_cache_verdict("inactive", None, Some(0)).is_err());
        // Pending uploads, or an uncounted cache, are never cleared.
        let e = clear_cache_verdict("inactive", Some(false), Some(2)).unwrap_err();
        assert!(e.contains("2 file(s)") && e.contains("upload"), "{e}");
        let e = clear_cache_verdict("inactive", Some(false), None).unwrap_err();
        assert!(e.contains("could not be counted"), "{e}");
    }

    #[test]
    fn clear_cache_pending_allows_only_a_count_of_zero() {
        assert_eq!(clear_cache_pending(Some(0)), Ok(()));
        for n in [1, 3, 200_000] {
            let e = clear_cache_pending(Some(n)).unwrap_err();
            assert!(
                e.contains(&format!("{n} file(s)")) && e.contains("mount the remote"),
                "{e}"
            );
        }
        let e = clear_cache_pending(None).unwrap_err();
        assert!(
            e.contains("could not be counted") && e.contains("mount the remote"),
            "{e}"
        );
    }

    #[test]
    fn clear_cache_refuses_pending_or_uncounted_uploads() {
        let mut a = App::new(paths());
        a.on_outcome(Outcome::CacheChecked {
            remote: "od".into(),
            stopped: Ok(()),
            dirty: None,
        });
        assert!(matches!(a.mode, Mode::Normal), "no confirm dialog");
        let (level, text, _) = a.status.as_ref().unwrap();
        assert!(
            *level == Level::Error
                && text.contains("not clearing")
                && text.contains("could not be counted"),
            "{text}"
        );
        // A known count above 0 is refused too: no confirm to override it.
        a.on_outcome(Outcome::CacheChecked {
            remote: "od".into(),
            stopped: Ok(()),
            dirty: Some(3),
        });
        assert!(matches!(a.mode, Mode::Normal), "no confirm dialog");
        let (level, text, _) = a.status.as_ref().unwrap();
        assert!(
            *level == Level::Error
                && text.contains("not clearing")
                && text.contains("3 file(s)")
                && text.contains("mount the remote"),
            "{text}"
        );
        a.on_outcome(Outcome::CacheChecked {
            remote: "od".into(),
            stopped: Ok(()),
            dirty: Some(0),
        });
        match &a.mode {
            Mode::Confirm(c) => {
                assert!(matches!(&c.action, Action::ClearCache(r) if r == "od"));
                assert!(c.body.iter().any(|l| l == "No pending uploads found."));
            }
            _ => panic!("a counted, clean cache is offered"),
        }
    }

    #[test]
    fn stop_checks_pending_uploads() {
        assert!(clear_to_stop(&Busy::Free, Some(0)));
        assert!(
            !clear_to_stop(&Busy::Free, Some(2)),
            "pending uploads are asked about"
        );
        assert!(
            !clear_to_stop(&Busy::Free, None),
            "an uncounted cache counts as pending"
        );
        assert!(!clear_to_stop(&Busy::Unknown, Some(0)));
        assert!(!clear_to_stop(&Busy::InUse(vec![1]), Some(0)));
        assert_eq!(pending_line(Some(0), false), None);
        assert_eq!(
            pending_line(Some(3), false).unwrap(),
            "3 pending upload(s) will resume on the next mount (the cache is kept)."
        );
        assert!(
            pending_line(Some(3), true)
                .unwrap()
                .contains("only if the remote is mounted again")
        );
        assert!(
            pending_line(None, false)
                .unwrap()
                .starts_with("Pending uploads could not be counted")
        );

        let mnt = "/mnt/cloud/od";
        // Stop with only uploads pending: the count is named, Unmount anyway.
        let (title, body, yes, action) =
            busy_dialog(BusyFor::Stop, "od", mnt, &Busy::Free, Some(3));
        assert_eq!(title, "Unmount od anyway?");
        assert_eq!(yes, "Unmount anyway");
        assert_eq!(
            body,
            ["3 pending upload(s) will resume on the next mount (the cache is kept)."]
        );
        assert!(matches!(action, Some(Action::StopMountForce(ref r)) if r == "od"));
        // Restart with an unknown count and fuser unknown.
        let (_, body, yes, action) = busy_dialog(BusyFor::Restart, "od", mnt, &Busy::Unknown, None);
        assert_eq!(yes, "Restart anyway");
        assert!(body[0].starts_with("Could not check whether files are open"));
        assert!(body[1].starts_with("Pending uploads could not be counted"));
        assert!(matches!(action, Some(Action::RestartMountForce(_))));
        // Remove with uploads pending: asked, the count named.
        let (title, body, yes, action) =
            busy_dialog(BusyFor::Remove, "od", mnt, &Busy::Free, Some(2));
        assert_eq!(title, "Uploads pending for od");
        assert_eq!(yes, "Remove anyway");
        assert!(body[0].starts_with("2 pending upload(s)"), "{body:?}");
        assert!(matches!(action, Some(Action::RemoveMountForce(_))));
        // Remove with files open: refused, no action.
        let (title, _, _, action) = busy_dialog(
            BusyFor::Remove,
            "od",
            mnt,
            &Busy::InUse(vec![u32::MAX]),
            Some(0),
        );
        assert!(title.starts_with("Not removed"));
        assert!(action.is_none());
    }

    #[test]
    fn stopped_watch() {
        assert_eq!(trigger_stopped("enabled", "active", ""), None);
        assert_eq!(trigger_stopped("enabled", "", ""), None, "no answer yet");
        assert_eq!(
            trigger_stopped("disabled", "failed", "trigger-limit-hit"),
            None
        );
        assert_eq!(
            trigger_stopped("enabled", "failed", "trigger-limit-hit").as_deref(),
            Some("trigger-limit-hit")
        );
        assert_eq!(
            trigger_stopped("enabled", "failed", "unit-start-limit-hit").as_deref(),
            Some("unit-start-limit-hit")
        );
        assert_eq!(
            trigger_stopped("enabled", "inactive", "success").as_deref(),
            Some("inactive")
        );
        let mut p = Pair {
            name: "vault-A".into(),
            conf: Err("x".into()),
            timer_file: "enabled".into(),
            path_file: "enabled".into(),
            timer_active: "active".into(),
            timer_result: "success".into(),
            path_active: "active".into(),
            path_result: "success".into(),
            svc_active: "inactive".into(),
            svc_result: "success".into(),
            exit_ts: String::new(),
            exit_status: String::new(),
            state: None,
            include: None,
        };
        assert_eq!(p.watch_problem(), None);
        p.path_active = "failed".into();
        p.path_result = "trigger-limit-hit".into();
        assert_eq!(
            p.watch_problem().as_deref(),
            Some("folder watch stopped (trigger-limit-hit)")
        );
        p.timer_active = "failed".into();
        p.timer_result = "unit-start-limit-hit".into();
        assert_eq!(
            p.watch_problem().as_deref(),
            Some("folder watch stopped (trigger-limit-hit), timer stopped (unit-start-limit-hit)")
        );
        // The poll fills them from systemctl show.
        let mut a = App::new(paths());
        p.path_active.clear();
        a.pairs.push(p);
        let mut props = HashMap::new();
        let mut path = UnitProps::new();
        path.insert("UnitFileState".into(), "enabled".into());
        path.insert("ActiveState".into(), "failed".into());
        path.insert("Result".into(), "trigger-limit-hit".into());
        props.insert(cmd::pair_path("vault-A"), path);
        a.on_units(a.generation, Some(props));
        assert_eq!(a.pairs[0].path_active, "failed");
        assert_eq!(a.pairs[0].path_result, "trigger-limit-hit");
        assert!(
            a.pairs[0]
                .watch_problem()
                .unwrap()
                .starts_with("folder watch stopped (trigger-limit-hit)")
        );
    }

    fn pair_form(local: &str) -> Form {
        Form {
            title: "t".into(),
            kind: FormKind::Pair,
            fields: vec![
                Field::text("name", "", "vault-B", ""),
                Field::other("remote", "", "", Input::Choice(vec!["onedrive".into()], 0)),
                Field::text("path", "", "Vaults", ""),
                Field::text("local", "", local, ""),
                Field::text("include", "", "", ""),
                Field::text("interval", "", "", ""),
            ],
            focus: 0,
            error: None,
        }
    }

    #[test]
    fn backup_dest_and_offline_folder_never_overlap() {
        let d = scratch("overlap");
        let others = vec![
            ("archive-vaults".to_string(), d.join("Backups/vaults")),
            ("other".to_string(), d.join("Elsewhere")),
        ];
        for inside in ["Backups/vaults", "Backups/vaults/x", "Backups", ""] {
            let got = overlap_with(&d.join(inside), &others).map(|(n, _)| n.as_str());
            assert_eq!(got, Some("archive-vaults"), "{inside:?}");
        }
        for apart in ["Backups/vaults2", "Backups/vault", "Vaults"] {
            assert!(overlap_with(&d.join(apart), &others).is_none(), "{apart:?}");
        }
        // Through a symlink: ~/Vaults/old is really ~/Backups/vaults/old.
        std::fs::create_dir_all(d.join("Backups/vaults")).unwrap();
        std::os::unix::fs::symlink(d.join("Backups/vaults"), d.join("Vaults")).unwrap();
        assert!(overlap_with(&d.join("Vaults/old"), &others).is_some());
        std::fs::remove_dir_all(&d).unwrap();

        // The forms refuse it, naming the other side.
        let mut a = App::new(paths());
        a.jobs.push(Job {
            name: "archive-vaults".into(),
            conf: Ok(JobConf {
                remote: "work_drive:".into(),
                files: None,
                dest: "~/Vaults/backups".into(),
                keep: None,
                schedule: None,
                strip_prefix: None,
            }),
            timer_file: String::new(),
            svc_active: String::new(),
            svc_result: String::new(),
            exit_ts: String::new(),
            exit_status: String::new(),
            state: None,
        });
        let e = a.submit_pair(&pair_form("~/Vaults")).unwrap_err();
        assert!(
            e.contains("overlaps ~/Vaults/backups") && e.contains("archive-vaults"),
            "{e}"
        );
        assert!(a.submit_pair(&pair_form("~/")).is_err());
        // A folder next to it is fine (it then asks to create the folder).
        assert!(a.submit_pair(&pair_form("~/Vaults2")).is_ok());
        assert!(matches!(a.mode, Mode::Confirm(_)));

        let mut a = App::new(paths());
        a.pairs.push(Pair {
            name: "vault-A".into(),
            conf: PairConf::parse(
                "LOCAL=~/Vaults\nREMOTE=onedrive:Vaults\n",
                Path::new("/home/u"),
            ),
            timer_file: String::new(),
            path_file: String::new(),
            timer_active: String::new(),
            timer_result: String::new(),
            path_active: String::new(),
            path_result: String::new(),
            svc_active: String::new(),
            svc_result: String::new(),
            exit_ts: String::new(),
            exit_status: String::new(),
            state: None,
            include: None,
        });
        assert!(a.pairs[0].conf.is_ok());
        let job = Form {
            title: "t".into(),
            kind: FormKind::Job(None),
            fields: vec![
                Field::text("name", "", "archive-vaults", ""),
                Field::other(
                    "remote",
                    "",
                    "",
                    Input::Choice(vec!["work_drive".into()], 0),
                ),
                Field::text("prefix", "", "", ""),
                Field::text("dest", "", "~/Vaults/backups", ""),
                Field::text("keep", "", "", ""),
                Field::text("schedule", "", "", ""),
                Field::text("strip", "", "", ""),
                Field::text("files", "", "", ""),
            ],
            focus: 0,
            error: None,
        };
        let e = a.submit_job(None, &job).unwrap_err();
        assert!(
            e.contains("overlaps ~/Vaults") && e.contains("vault-A"),
            "{e}"
        );
    }

    #[test]
    fn delete_remote_guard() {
        let users = vec!["offline folder kp".to_string(), "backup j".to_string()];
        let e = delete_remote_offer("od", &users, Some(0)).unwrap_err();
        assert!(
            e.contains("offline folder kp") && e.contains("backup j"),
            "{e}"
        );
        let b = delete_remote_offer("od", &[], Some(0)).unwrap();
        assert!(!b.iter().any(|l| l.contains("WARNING")));
        assert!(b.last().unwrap().contains("Type od"));
        let w = delete_remote_offer("od", &[], Some(3)).unwrap();
        assert!(w.iter().any(|l| l.contains("3 file(s)")));
        let u = delete_remote_offer("od", &[], None).unwrap();
        assert!(
            u.iter()
                .any(|l| l.contains("WARNING") && l.contains("could not be fully read"))
        );
    }

    #[test]
    fn resync_exit_codes() {
        assert_eq!(resync_next(Some(0)), ResyncNext::Enable);
        assert_eq!(resync_next(Some(75)), ResyncNext::Busy);
        assert_eq!(resync_next(Some(3)), ResyncNext::Refused);
        for c in [Some(1), Some(2), Some(64), None] {
            assert_eq!(resync_next(c), ResyncNext::Failed, "{c:?}");
        }
    }

    #[test]
    fn listings_decide_resume() {
        let d = scratch("listings");
        let p = Paths::new(d.join("home"));
        let local = Path::new("/home/u/K");
        assert!(!listings_exist(&p, local, "od:Backup/K"));
        let wd = d.join("home/.cache/rclone/bisync");
        std::fs::create_dir_all(&wd).unwrap();
        let s = cmd::bisync_session(local, "od:Backup/K");
        std::fs::write(wd.join(format!("{s}.path1.lst")), "").unwrap();
        assert!(!listings_exist(&p, local, "od:Backup/K"), "both are needed");
        std::fs::write(wd.join(format!("{s}.path2.lst")), "").unwrap();
        assert!(listings_exist(&p, local, "od:Backup/K"));
        assert!(!listings_exist(&p, local, "od:Backup/Other"));
        // Listings alone (stale: a removed pair, the same folders) never
        // resume: the pair's own state file is needed too.
        assert!(!can_resume(&p, "kp", local, "od:Backup/K"));
        std::fs::create_dir_all(d.join("home/.local/state/rclone-bisync")).unwrap();
        std::fs::write(p.pair_state("other"), "exit=0\n").unwrap();
        assert!(
            !can_resume(&p, "kp", local, "od:Backup/K"),
            "another pair's state"
        );
        std::fs::write(p.pair_state("kp"), "exit=0\n").unwrap();
        assert!(can_resume(&p, "kp", local, "od:Backup/K"));
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn removing_a_pair_forgets_its_sync_history() {
        let p = Paths::new(PathBuf::from("/home/user"));
        let home = Path::new("/home/user");
        let conf = PairConf::parse(
            "LOCAL=~/Vaults\nREMOTE=personal-drive:Vaults\nFILTER=~/.config/rclone-bisync/personal.filter\n",
            home,
        );
        let (own, files) = pair_leftovers(&p, "personal", Some(&conf));
        assert!(own);
        let files: Vec<String> = files.iter().map(|f| f.display().to_string()).collect();
        let s = "home_user_Vaults..personal-drive_Vaults";
        for want in [
            "/home/user/.local/state/rclone-bisync/personal.state".to_string(),
            "/home/user/.config/rclone-bisync/personal.filter.md5".to_string(),
            format!("/home/user/.cache/rclone/bisync/{s}.path1.lst"),
            format!("/home/user/.cache/rclone/bisync/{s}.path2.lst-old"),
            format!("/home/user/.cache/rclone/bisync/{s}.lck"),
        ] {
            assert!(files.contains(&want), "{want} not in {files:?}");
        }
        assert!(!files.iter().any(|f| f.ends_with(".conf")));
        // A filter that is not the pair's own stays, and so does its hash.
        let shared = PairConf::parse("LOCAL=/a\nREMOTE=x:y\nFILTER=~/shared.filter\n", home);
        let (own, files) = pair_leftovers(&p, "personal", Some(&shared));
        assert!(!own);
        assert!(!files.iter().any(|f| f.to_string_lossy().ends_with(".md5")));
        assert!(
            files
                .iter()
                .any(|f| f.to_string_lossy().ends_with("a..x_y.path1.lst"))
        );
    }

    #[test]
    fn empty_pair_is_refused() {
        assert_eq!(resync_next(Some(4)), ResyncNext::Empty);
        let mut a = App::new(paths());
        let out = Output {
            code: Some(EXIT_EMPTY),
            stdout: String::new(),
            stderr: "rclone-bisync: kp: nothing to sync".into(),
        };
        a.pair_checked("kp".into(), out, true, Vec::new());
        match &a.mode {
            Mode::View(v) => assert!(
                v.lines.iter().any(|l| l.contains(NOTHING_TO_SYNC)),
                "{:?}",
                v.lines
            ),
            _ => panic!("exit 4 must be a refusal, never Start syncing"),
        }
        assert!(a.status.as_ref().unwrap().1.contains("nothing to sync"));
        // Identical with files: still offers to start.
        let mut a = App::new(paths());
        a.pair_checked(
            "kp".into(),
            Output {
                code: Some(0),
                ..Output::default()
            },
            false,
            Vec::new(),
        );
        assert!(matches!(&a.mode, Mode::Confirm(c) if c.yes == "Start syncing"));
    }

    #[test]
    fn resume_warns_that_deletions_propagate() {
        let mut a = App::new(paths());
        a.on_outcome(Outcome::CanResume("kp".into()));
        match &a.mode {
            Mode::Confirm(c) => {
                let body = c.body.join(" ");
                assert!(body.contains("DELETIONS"), "{body}");
                assert!(body.contains("applied to the other"), "{body}");
            }
            _ => panic!("not a confirm"),
        }
    }

    fn job_entry(name: &str, dest: &str) -> Job {
        Job {
            name: name.into(),
            conf: Ok(JobConf {
                remote: "work_drive:".into(),
                files: None,
                dest: dest.into(),
                keep: None,
                schedule: None,
                strip_prefix: None,
            }),
            timer_file: String::new(),
            svc_active: String::new(),
            svc_result: String::new(),
            exit_ts: String::new(),
            exit_status: String::new(),
            state: None,
        }
    }

    fn job_form(name: Option<&str>, dest: &str) -> Form {
        let mut fields = Vec::new();
        if name.is_none() {
            fields.push(Field::text("name", "", "new-job", ""));
        }
        fields.extend([
            Field::other(
                "remote",
                "",
                "",
                Input::Choice(vec!["work_drive".into()], 0),
            ),
            Field::text("prefix", "", "", ""),
            Field::text("dest", "", dest, ""),
            Field::text("keep", "", "", ""),
            Field::text("schedule", "", "", ""),
            Field::text("strip", "", "", ""),
            Field::text("files", "", "", ""),
        ]);
        Form {
            title: "t".into(),
            kind: FormKind::Job(name.map(String::from)),
            fields,
            focus: 0,
            error: None,
        }
    }

    #[test]
    fn backups_never_share_a_destination() {
        let mut a = App::new(paths());
        a.jobs.push(job_entry("team-vaults", "~/Backups/vaults"));
        for dest in ["~/Backups/vaults", "~/Backups/vaults/sub", "~/Backups"] {
            let e = a.submit_job(None, &job_form(None, dest)).unwrap_err();
            assert!(
                e.contains("team-vaults") && e.contains("share a destination"),
                "{dest}: {e}"
            );
        }
        // Editing a job: its own DEST is not an overlap.
        let d = scratch("dests");
        let mut b = App::new(Paths::new(d.clone()));
        b.jobs.push(job_entry("other", "~/Elsewhere"));
        b.jobs.push(job_entry("team-vaults", "~/Backups/vaults"));
        let own = job_form(Some("team-vaults"), "~/Backups/vaults");
        assert_eq!(b.submit_job(Some("team-vaults".into()), &own), Ok(()));
        let next = job_form(Some("other"), "~/Backups/vaults2");
        assert_eq!(b.submit_job(Some("other".into()), &next), Ok(()));
        let e = b
            .submit_job(Some("other".into()), &job_form(Some("other"), "~/Backups"))
            .unwrap_err();
        assert!(e.contains("team-vaults"), "{e}");
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn offline_folders_never_share_files() {
        let mut a = App::new(paths());
        a.pairs.push(Pair {
            name: "personal".into(),
            conf: PairConf::parse(
                "LOCAL=~/Sync/Vaults\nREMOTE=personal-drive:Vaults\n",
                Path::new("/home/u"),
            ),
            timer_file: String::new(),
            path_file: String::new(),
            timer_active: String::new(),
            timer_result: String::new(),
            path_active: String::new(),
            path_result: String::new(),
            svc_active: String::new(),
            svc_result: String::new(),
            exit_ts: String::new(),
            exit_status: String::new(),
            state: None,
            include: None,
        });
        for local in ["~/Sync/Vaults", "~/Sync/Vaults/x", "~/Sync"] {
            let e = a.submit_pair(&pair_form(local)).unwrap_err();
            assert!(
                e.contains("personal") && e.contains("share files"),
                "{local}: {e}"
            );
        }
        assert!(a.submit_pair(&pair_form("~/Sync/Vaults2")).is_ok());
    }

    #[test]
    fn destination_not_in_a_cloud_location() {
        let h = &paths();
        let fuse = vec![
            PathBuf::from("/run/user/1000/gvfs"),
            PathBuf::from("/srv/sshfs"),
        ];
        for dest in [
            "/mnt/cloud/od/bk",
            "~/Cloud/od/bk",
            "/srv/sshfs/bk",
            "/srv/sshfs",
        ] {
            let e = build_job(h, &fuse, "j", "r", "", dest, "", "", "", "").unwrap_err();
            assert!(
                e.starts_with("Destination:") && e.contains("cloud location"),
                "{dest}: {e}"
            );
        }
        let e = build_job(h, &fuse, "j", "r", "", "/srv/sshfs/bk", "", "", "", "").unwrap_err();
        assert!(e.contains("(/srv/sshfs)"), "names the mount: {e}");
        assert!(build_job(h, &fuse, "j", "r", "", "/srv/sshfs2", "", "", "", "").is_ok());
        assert!(build_job(h, &fuse, "j", "r", "", "~/Backups", "", "", "", "").is_ok());
        // A pair's LOCAL too, with any FUSE mount.
        let p = paths();
        let e = build_pair(&p, &fuse, "w", "od", "", "/srv/sshfs/x", "", "")
            .err()
            .unwrap();
        assert!(e.contains("(/srv/sshfs)"), "{e}");
    }

    #[test]
    fn half_enabled_pair_is_syncing_and_pauses_fully() {
        let mut p = Pair {
            name: "kp".into(),
            conf: Err("x".into()),
            timer_file: "enabled".into(),
            path_file: "disabled".into(),
            timer_active: String::new(),
            timer_result: String::new(),
            path_active: String::new(),
            path_result: String::new(),
            svc_active: String::new(),
            svc_result: String::new(),
            exit_ts: String::new(),
            exit_status: String::new(),
            state: None,
            include: None,
        };
        assert!(p.enabled(), "timer alone");
        p.timer_file = "disabled".into();
        p.path_file = "enabled-runtime".into();
        assert!(p.enabled(), "path alone");
        p.path_file = "not installed".into();
        assert!(!p.enabled());
        // Pausing disables both units, whichever was enabled.
        let d = cmd::pair_disable_cmd("kp");
        assert!(d.contains(&cmd::pair_timer("kp")) && d.contains(&cmd::pair_path("kp")));
    }

    #[test]
    fn poll_names_the_path_unit_only_once_set_up() {
        assert_eq!(
            pair_units("kp", false),
            ["rclone-bisync@kp.timer", "rclone-bisync@kp.service"]
        );
        assert_eq!(
            pair_units("kp", true),
            [
                "rclone-bisync@kp.timer",
                "rclone-bisync@kp.path",
                "rclone-bisync@kp.service"
            ]
        );
        let d = scratch("units");
        let mut a = App::new(Paths::new(d.clone()));
        for n in ["set-up", "half"] {
            a.pairs.push(Pair {
                name: n.into(),
                conf: Err("x".into()),
                timer_file: String::new(),
                path_file: String::new(),
                timer_active: String::new(),
                timer_result: String::new(),
                path_active: String::new(),
                path_result: String::new(),
                svc_active: String::new(),
                svc_result: String::new(),
                exit_ts: String::new(),
                exit_status: String::new(),
                state: None,
                include: None,
            });
        }
        let dropin = a.paths.pair_path_dropin("set-up");
        std::fs::create_dir_all(dropin.parent().unwrap()).unwrap();
        std::fs::write(&dropin, "[Path]\nPathChanged=/x\n").unwrap();
        let u = a.unit_names();
        assert!(u.contains(&cmd::pair_path("set-up")));
        assert!(!u.contains(&cmd::pair_path("half")), "{u:?}");
        assert!(u.contains(&cmd::pair_timer("half")));
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn backup_needs_a_file() {
        assert!(files_list_verdict(&conf::files_template("j", "r:")).is_err());
        assert!(files_list_verdict("# only a comment\n\n").is_err());
        assert_eq!(files_list_verdict("a.kdbx\n").unwrap(), 1);
        assert!(files_list_verdict("/abs\n").is_err());
    }

    #[test]
    fn removal_waits_for_a_run() {
        for s in ["active", "activating", "deactivating", "reloading"] {
            assert!(run_in_progress(s), "{s}");
        }
        for s in ["inactive", "failed", "unknown", ""] {
            assert!(!run_in_progress(s), "{s}");
        }
    }

    /// D4: the guard checks both directions (equal, inside, containing),
    /// against the configured root, /mnt/cloud, ~/Cloud and FUSE mounts.
    #[test]
    fn cloud_guard_refuses_overlaps_both_ways() {
        let d = scratch("cloudguard");
        let home = d.join("home");
        std::fs::create_dir_all(home.join("Cloud")).unwrap();
        std::fs::create_dir_all(home.join("sub/inner")).unwrap();
        let mut p = Paths::new(home.clone());
        p.root_setting = RootSetting::Valid(PathBuf::from("/srv/cloudroot"));
        let refused = |dir: &Path, fuse: &[PathBuf]| cloud_loop(&p, dir, fuse).unwrap_err();
        // Containing /mnt/cloud, the configured root, ~/Cloud, a FUSE mount.
        let e = refused(Path::new("/mnt"), &[]);
        assert!(e.contains("overlaps a cloud location (/mnt/cloud)"), "{e}");
        let e = refused(Path::new("/srv"), &[]);
        assert!(e.contains("(/srv/cloudroot)"), "root's parent: {e}");
        refused(Path::new("/srv/cloudroot"), &[]);
        refused(Path::new("/srv/cloudroot/od/x"), &[]);
        let e = refused(&home, &[]);
        assert!(e.contains("(~/Cloud)"), "$HOME contains ~/Cloud: {e}");
        let fuse = [home.join("sub/inner/sshfs")];
        let e = refused(&home.join("sub"), &fuse);
        assert!(e.contains("sub/inner/sshfs"), "contains a FUSE mount: {e}");
        refused(Path::new("/"), &[]);
        // Siblings that only share a prefix are fine.
        for ok in [
            "/mnt/cloudy",
            "/mnt/cloud-other/x",
            "/srv/cloudroot2",
            "/srv/other",
        ] {
            assert!(cloud_loop(&p, Path::new(ok), &[]).is_ok(), "{ok}");
        }
        assert!(cloud_loop(&p, &home.join("sub"), &[]).is_ok());
        assert!(cloud_loop(&p, &home.join("sub2"), &fuse).is_ok());
        // An invalid setting is not a target, /mnt/cloud still is.
        p.root_setting = RootSetting::Invalid("/srv/cloudroot".into());
        assert!(cloud_loop(&p, Path::new("/srv"), &[]).is_ok());
        assert!(cloud_loop(&p, Path::new("/mnt"), &[]).is_err());
        // Through a symlink: ~/up → /mnt contains /mnt/cloud.
        std::os::unix::fs::symlink("/mnt", home.join("up")).unwrap();
        assert!(cloud_loop(&p, &home.join("up"), &[]).is_err());
        // The forms refuse them too.
        let p2 = Paths::new(home.clone());
        assert!(build_pair(&p2, &[], "w", "od", "", "/mnt", "", "").is_err());
        assert!(build_job(&p2, &[], "j", "r", "", "/mnt", "", "", "", "").is_err());
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn root_setup_command_is_quoted() {
        assert_eq!(
            root_setup_command(Path::new("/mnt/cloud")),
            r#"sudo install -d -o "$USER" -m 755 '/mnt/cloud'"#
        );
        assert_eq!(
            root_setup_command(Path::new("/mnt/it's")),
            r#"sudo install -d -o "$USER" -m 755 '/mnt/it'\''s'"#
        );
    }

    /// D1: a mount is enabled only under a set, valid, existing, writable
    /// root; otherwise the instructions (C3) are shown.
    #[test]
    fn mount_root_must_be_ready() {
        let d = scratch("rootready");
        let home = d.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let mut p = Paths::new(home.clone());
        // Absent.
        let e = root_ready(&p).unwrap_err();
        assert!(e.contains("not set up") && e.contains("install.sh"), "{e}");
        assert!(e.contains("~/.config/omarchy-cloud/cloud.env"), "{e}");
        // Invalid (inside home).
        p.root_setting = RootSetting::Invalid(home.join("Cloud").display().to_string());
        let e = root_ready(&p).unwrap_err();
        assert!(
            e.contains("is not valid") && e.contains("install.sh"),
            "{e}"
        );
        // Valid but missing: the exact command.
        let root = d.join("root");
        p.root_setting = RootSetting::Valid(root.clone());
        let e = root_ready(&p).unwrap_err();
        let cmd = format!("sudo install -d -o \"$USER\" -m 755 '{}'", root.display());
        assert!(e.contains("does not exist") && e.contains(&cmd), "{e}");
        // A file, not a directory.
        std::fs::write(&root, "").unwrap();
        let e = root_ready(&p).unwrap_err();
        assert!(e.contains("is not a directory") && e.contains(&cmd), "{e}");
        std::fs::remove_file(&root).unwrap();
        // Ready.
        std::fs::create_dir(&root).unwrap();
        assert!(root_ready(&p).is_ok());
        // Not writable (root bypasses the mode, so only checked as a user).
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o555)).unwrap();
        if unsafe { libc::geteuid() } != 0 {
            let e = root_ready(&p).unwrap_err();
            assert!(e.contains("is not writable") && e.contains(&cmd), "{e}");
        }
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();

        // The app re-reads cloud.env and refuses with the text in a view.
        let mut a = App::new(Paths::new(home.clone()));
        assert!(!a.root_ok_or_explain(), "absent");
        match &a.mode {
            Mode::View(v) => {
                assert_eq!(v.title, "Mount root not set up");
                assert!(
                    v.lines.iter().any(|l| l.contains("install.sh")),
                    "{:?}",
                    v.lines
                );
            }
            _ => panic!("no view"),
        }
        let env = home.join(".config/omarchy-cloud/cloud.env");
        let missing = d.join("missing");
        std::fs::create_dir_all(env.parent().unwrap()).unwrap();
        std::fs::write(&env, format!("OMARCHY_CLOUD_ROOT={}\n", missing.display())).unwrap();
        a.mode = Mode::Normal;
        assert!(!a.root_ok_or_explain(), "missing");
        let want = format!(
            "  sudo install -d -o \"$USER\" -m 755 '{}'",
            missing.display()
        );
        match &a.mode {
            Mode::View(v) => assert!(v.lines.contains(&want), "{:?}", v.lines),
            _ => panic!("no view"),
        }
        assert_eq!(a.paths.mount_point("od"), missing.join("od"));
        std::fs::write(&env, format!("OMARCHY_CLOUD_ROOT={}\n", root.display())).unwrap();
        a.mode = Mode::Normal;
        assert!(a.root_ok_or_explain(), "ready");
        assert!(matches!(a.mode, Mode::Normal));
        assert_eq!(a.paths.mount_point("od"), root.join("od"));
        std::fs::write(&env, format!("OMARCHY_CLOUD_ROOT={}/x\n", home.display())).unwrap();
        assert!(!a.root_ok_or_explain(), "inside home");
        std::fs::remove_dir_all(&d).unwrap();
    }

    const RCLONE_CONF: &str = "# hand-written note\n\
[work]\n\
type = drive\n\
token = {\"access_token\":\"ya29.w\",\"expiry\":\"2026-01-01T00:00:00Z\"}\n\
\n\
[gdrive]\n\
type = drive\n\
client_id = old.apps.googleusercontent.com\n\
client_secret = OLD-secret\n\
scope = drive\n\
token = {\"access_token\":\"ya29.g\",\"refresh_token\":\"1//r\"}\n\
\n\
; media below\n\
[media]\n\
type = s3\n";

    fn secret_of(s: &str) -> Secret {
        let mut x = Secret::new();
        for c in s.chars() {
            x.push(c);
        }
        x
    }

    /// D7: the secret goes into rclone.conf in-process; the only commands
    /// of the flow (rclone config file, then the reconnect) never carry it.
    #[test]
    fn client_secret_never_on_argv() {
        let d = scratch("client");
        let conf = d.join("rclone/rclone.conf");
        std::fs::create_dir_all(conf.parent().unwrap()).unwrap();
        std::fs::write(&conf, RCLONE_CONF).unwrap();
        let secret = secret_of("GOCSPX-t0pS3cret");
        let mut seen: Vec<Vec<String>> = Vec::new();
        let stdout = format!("Configuration file is stored at:\n{}\n", conf.display());
        let mut run = |a: &[String]| {
            seen.push(a.to_vec());
            Output {
                code: Some(0),
                stdout: stdout.clone(),
                stderr: String::new(),
            }
        };
        set_client(
            "gdrive",
            "new.apps.googleusercontent.com",
            &secret,
            &mut run,
        )
        .unwrap();
        seen.push(cmd::reconnect_cmd("gdrive"));
        assert_eq!(seen[0], ["rclone", "config", "file"]);
        assert_eq!(seen.len(), 2);
        for a in &seen {
            assert!(
                a.iter().all(|x| !x.contains("t0pS3cret")),
                "secret on argv: {a:?}"
            );
        }
        let text = std::fs::read_to_string(&conf).unwrap();
        assert_eq!(
            text,
            RCLONE_CONF
                .replace(
                    "client_id = old.apps.googleusercontent.com\n",
                    "client_id = new.apps.googleusercontent.com\n"
                )
                .replace(
                    "client_secret = OLD-secret\n",
                    "client_secret = GOCSPX-t0pS3cret\n"
                )
        );
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&conf).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        // Keys absent from the section are added; nothing else moves.
        write_client(&conf, "media", "m.apps.googleusercontent.com", &secret).unwrap();
        let text2 = std::fs::read_to_string(&conf).unwrap();
        assert_eq!(
            text2,
            format!(
                "{text}client_id = m.apps.googleusercontent.com\nclient_secret = GOCSPX-t0pS3cret\n"
            )
        );
        // A failing `rclone config file` writes nothing.
        let mut fail = |_: &[String]| Output {
            code: Some(1),
            stdout: String::new(),
            stderr: "boom".into(),
        };
        let e = set_client("gdrive", "x", &secret, &mut fail).unwrap_err();
        assert!(e.contains("rclone config file failed"), "{e}");
        assert_eq!(std::fs::read_to_string(&conf).unwrap(), text2);
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn client_write_refuses_encrypted_and_symlinked_configs() {
        let d = scratch("clientref");
        let secret = secret_of("GOCSPX-zz9");
        let enc = d.join("enc.conf");
        let enc_text = "# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nAAAA\n";
        std::fs::write(&enc, enc_text).unwrap();
        let e = write_client(&enc, "gdrive", "i", &secret).unwrap_err();
        assert!(
            e.contains("encrypted") && e.contains("rclone config"),
            "{e}"
        );
        assert_eq!(std::fs::read_to_string(&enc).unwrap(), enc_text);
        let real = d.join("real.conf");
        std::fs::write(&real, RCLONE_CONF).unwrap();
        let link = d.join("link.conf");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let e = write_client(&link, "gdrive", "i", &secret).unwrap_err();
        assert!(e.contains("symlink"), "{e}");
        assert_eq!(std::fs::read_to_string(&real).unwrap(), RCLONE_CONF);
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let e = write_client(&real, "nope", "i", &secret).unwrap_err();
        assert!(e.contains("no [nope] section") && !e.contains("zz9"), "{e}");
        assert_eq!(std::fs::read_to_string(&real).unwrap(), RCLONE_CONF);
        assert!(write_client(&d.join("absent.conf"), "gdrive", "i", &secret).is_err());
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn local_not_in_a_mount() {
        let d = scratch("cloud");
        let home = d.join("home");
        std::fs::create_dir_all(home.join("Cloud")).unwrap();
        std::fs::create_dir_all(home.join("real")).unwrap();
        // ~/link → ~/Cloud: a folder under it is inside the mount dir.
        std::os::unix::fs::symlink(home.join("Cloud"), home.join("link")).unwrap();
        let p = Paths::new(home.clone());
        assert!(cloud_loop(&p, &home.join("real/x"), &[]).is_ok());
        assert!(cloud_loop(&p, &home.join("Cloud/od/K"), &[]).is_err());
        assert!(cloud_loop(&p, &home.join("link/od"), &[]).is_err());
        assert!(cloud_loop(&p, Path::new("/mnt/cloud/od/K"), &[]).is_err());
        assert!(cloud_loop(&p, Path::new("/mnt/cloudy"), &[]).is_ok());
        // A FUSE mount point is used as /proc lists it, never resolved (that
        // would stat through the mount): here a symlink standing in for one
        // is not followed, while the folder itself still is.
        std::os::unix::fs::symlink(home.join("real"), home.join("fuse")).unwrap();
        let fuse = [home.join("fuse")];
        assert!(cloud_loop(&p, &home.join("real/x"), &fuse).is_ok());
        let e = cloud_loop(&p, &home.join("fuse/x"), &fuse).unwrap_err();
        assert!(
            e.contains(&format!("({})", home.join("fuse").display())),
            "{e}"
        );
        assert!(build_pair(&p, &[], "w", "od", "", "~/link/od", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "od", "", "~/real", "", "").is_ok());
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn settings_from_form() {
        let v: Vec<String> = ["20G", "", "5s", "1000h", "0"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let c = build_settings(&v).unwrap();
        assert_eq!(c[0], ("RCLONE_VFS_CACHE_MAX_SIZE", Some("20G".into())));
        assert_eq!(c[1], ("RCLONE_VFS_CACHE_MAX_AGE", None));
        assert_eq!(c[4], ("RCLONE_POLL_INTERVAL", Some("0".into())));
        let bad: Vec<String> = ["20GB", "", "", "", ""]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert!(build_settings(&bad).is_err());
    }

    #[test]
    fn pair_from_form() {
        let p = paths();
        let np = build_pair(
            &p,
            &[],
            "kp",
            "onedrive",
            "/Backup/Vaults/",
            "~/Vaults",
            "a.kdbx, b.key",
            "2min",
        )
        .unwrap();
        assert_eq!(np.conf.remote, "onedrive:Backup/Vaults");
        assert_eq!(np.conf.local, "~/Vaults");
        assert_eq!(
            np.conf.filter.as_deref(),
            Some("~/.config/rclone-bisync/kp.filter")
        );
        assert_eq!(np.local_abs, PathBuf::from("/home/u/Vaults"));
        assert!(np.filter.unwrap().contains("+ b.key.conflict*\n- **\n"));
        let whole = build_pair(&p, &[], "w", "gdrive", "", "/srv/w", "", "").unwrap();
        assert_eq!(whole.conf.filter, None);
        assert_eq!(whole.filter, None);
        assert_eq!(whole.conf.remote, "gdrive:");
        assert!(build_pair(&p, &[], "bad name", "gdrive", "", "/srv/w", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "", "", "/srv/w", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "", "relative", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "", "~", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "", "/srv/w", "", "2m").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "a\nb", "/srv/w", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "a//b", "/srv/w", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "a/../b", "/srv/w", "", "").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "", "/srv/w", "", "500ms").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "", "/srv/w", "", "10s").is_err());
        assert!(build_pair(&p, &[], "w", "gdrive", "", "/srv/a\\b", "", "").is_err());
        let dbl = build_pair(&p, &[], "w", "gdrive", "", "~//Docs/x/", "", "30s").unwrap();
        assert_eq!(dbl.conf.local, "~/Docs/x");
        assert_eq!(dbl.local_abs, PathBuf::from("/home/u/Docs/x"));
    }

    #[test]
    fn job_from_form() {
        let h = &paths();
        let c = build_job(
            h,
            &[],
            "archive-vaults",
            "work_drive",
            "",
            "~/Backups/vaults/",
            "14",
            "daily",
            "acme/",
            "",
        )
        .unwrap();
        assert_eq!(c.remote, "work_drive:");
        assert_eq!(c.dest, "~/Backups/vaults");
        assert_eq!(c.files, None);
        assert_eq!(c.strip_prefix.as_deref(), Some("acme/"));
        let c2 = build_job(h, &[], "j", "r", "/pre/fix/", "/b", "", "", "", "~/x.files").unwrap();
        assert_eq!(c2.remote, "r:pre/fix");
        assert_eq!(c2.keep, None);
        assert_eq!(c2.files.as_deref(), Some("~/x.files"));
        assert_eq!(c2.dest, "/b");
        // DEST and FILES are stored normalised.
        let c3 = build_job(
            h,
            &[],
            "j",
            "r",
            "",
            "~//Backups//x/",
            "",
            "",
            "",
            "/home/u//l.files",
        )
        .unwrap();
        assert_eq!(c3.dest, "~/Backups/x");
        assert_eq!(c3.files.as_deref(), Some("~/l.files"));
        assert!(build_job(h, &[], "j", "r", "a//b", "/b", "", "", "", "").is_err());
        assert!(build_job(h, &[], "j", "r", "./a", "/b", "", "", "", "").is_err());
        assert!(build_job(h, &[], "j", "r", "", "/b", "", "", "", "rel.files").is_err());
        assert!(build_job(h, &[], "j", "r", "", "/b", "0", "", "", "").is_err());
        assert!(build_job(h, &[], "j", "r", "", "~", "", "", "", "").is_err());
        assert!(build_job(h, &[], "j", "r", "", "/b", "", "x;y", "", "").is_err());
        assert!(build_job(h, &[], "..", "r", "", "/b", "", "", "", "").is_err());
    }
}
