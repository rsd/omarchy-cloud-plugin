//! omarchy-cloud: a keyboard-driven TUI for rclone mounts, offline folders
//! (bisync pairs) and backups, built on the rclone-bisync / rclone-backup
//! helpers and the systemd user templates of the Cloud Mounts plugin.

mod app;
mod cmd;
mod conf;
mod envfile;
mod rclone_conf;
mod secret;
mod sys;
mod ui;
mod validate;
mod version;

use std::io::{BufRead, Write};
use std::time::{Duration, Instant};

use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyEventKind,
};
use ratatui::crossterm::{execute, terminal};
use zeroize::Zeroize;

use app::{App, Interactive};

fn main() {
    if let Some(a) = std::env::args().nth(1) {
        match a.as_str() {
            "-h" | "--help" => {
                println!(
                    "omarchy-cloud — manage rclone mounts, offline folders and backups.\nRun without arguments; press ? inside for the keys."
                );
                return;
            }
            "-V" | "--version" => {
                println!("omarchy-cloud {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            _ => {
                eprintln!("omarchy-cloud: unknown argument (try --help)");
                std::process::exit(64);
            }
        }
    }
    // HOME-fixed: only HOME is read, never XDG_* (see cmd::Paths).
    let Some(paths) = cmd::Paths::from_env(|k| std::env::var_os(k)) else {
        eprintln!("omarchy-cloud: HOME is not set to an absolute path");
        std::process::exit(1);
    };
    let mut app = App::new(paths);
    app.notice = version::check(&app.paths);
    app.refresh();

    let mut terminal = ratatui::init();
    // ratatui's hook restores the terminal on a panic. A panic in a worker
    // thread is caught there and reported in the app, so the terminal must
    // stay as it is: only the main thread's panics go to the hook.
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if std::thread::current().name() == Some("main") {
            hook(info);
        }
    }));
    let _ = execute!(std::io::stdout(), EnableBracketedPaste);
    let res = run(&mut terminal, &mut app);
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    finish_tasks(&mut app);
    if let Err(e) = res {
        eprintln!("omarchy-cloud: {e}");
        std::process::exit(1);
    }
}

fn run(terminal: &mut DefaultTerminal, app: &mut App) -> std::io::Result<()> {
    let mut last_poll = Instant::now();
    while !app.quit {
        app.tick();
        terminal.draw(|f| ui::draw(f, app))?;
        if event::poll(Duration::from_millis(150))? {
            match event::read()? {
                Event::Key(k) if k.kind != KeyEventKind::Release => app.on_key(k),
                Event::Paste(mut text) => {
                    app.on_paste(&text);
                    text.zeroize(); // it may have been a secret
                }
                _ => {}
            }
        }
        while let Ok(o) = app.rx.try_recv() {
            app.on_outcome(o);
        }
        while let Ok((generation, props)) = app.units_rx.try_recv() {
            app.on_units(generation, props);
        }
        if let Some(what) = app.interactive.take() {
            let res = suspended(terminal, || run_interactive(&what))?;
            app.after_interactive(what, res);
        }
        // Unit states change under us (timers, the bar plugin): poll them,
        // off the UI thread.
        if last_poll.elapsed() > Duration::from_secs(3)
            && app.running.is_none()
            && matches!(app.mode, app::Mode::Normal)
        {
            app.poll_units();
            last_poll = Instant::now();
        }
    }
    Ok(())
}

/// Quitting (Ctrl-C) while a task runs: stop its command (SIGTERM to its
/// process group, SIGKILL if it lingers) and wait for the worker to report.
/// A bisync run gets sys::SYNC_GRACE after SIGTERM: rclone then drains or
/// cancels its transfers and removes its lock file, which a SIGKILL would
/// leave behind. The worker reports only once the whole group is gone (not
/// just the helper's bash, which dies at once), with its output pipes still
/// read, so this process stays alive while rclone cleans up; both waits are
/// bounded by the grace, then the SIGKILL. Runs on the restored terminal,
/// so the wait is visible.
fn finish_tasks(app: &mut App) {
    let Some((label, _)) = &app.running else {
        return;
    };
    let grace = sys::stop_children(false).max(Duration::from_secs(4));
    if grace > Duration::from_secs(4) {
        eprintln!(
            "omarchy-cloud: stopping \"{label}\" (up to {}s, so that rclone can clean up)…",
            grace.as_secs()
        );
    }
    if app.rx.recv_timeout(grace).is_err() {
        sys::stop_children(true);
        let _ = app.rx.recv_timeout(Duration::from_secs(2));
    }
}

fn run_interactive(what: &Interactive) -> Result<i32, String> {
    let argv = match what {
        Interactive::RcloneConfig { .. } => cmd::rclone_config_cmd(),
        Interactive::Reconnect(r) => cmd::reconnect_cmd(r),
        Interactive::EditFiles { file, .. } => {
            let visual = std::env::var("VISUAL").ok();
            let editor = std::env::var("EDITOR").ok();
            let have_nvim = std::path::Path::new("/usr/bin/nvim").exists();
            cmd::editor_cmd(visual.as_deref(), editor.as_deref(), have_nvim, file)
        }
    };
    println!("\n── omarchy-cloud: running {} ──\n", argv.join(" "));
    let res = sys::run_interactive(&argv);
    if !matches!(what, Interactive::EditFiles { .. }) {
        print!("\n── done; press Enter to return to omarchy-cloud ── ");
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        let _ = std::io::stdin().lock().read_line(&mut line);
    }
    res
}

/// Leaves the alternate screen and raw mode, runs `f` on the plain
/// terminal, then restores the TUI.
fn suspended<T>(terminal: &mut DefaultTerminal, f: impl FnOnce() -> T) -> std::io::Result<T> {
    terminal::disable_raw_mode()?;
    execute!(
        std::io::stdout(),
        DisableBracketedPaste,
        terminal::LeaveAlternateScreen,
        ratatui::crossterm::cursor::Show
    )?;
    let out = f();
    terminal::enable_raw_mode()?;
    execute!(
        std::io::stdout(),
        terminal::EnterAlternateScreen,
        EnableBracketedPaste
    )?;
    terminal.clear()?;
    Ok(out)
}
