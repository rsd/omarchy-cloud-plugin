//! Drawing. Colours are the terminal's own ANSI palette (named colours,
//! `Color::Reset` backgrounds) so the Omarchy terminal theme applies.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, BorderType, Clear, List, ListItem, ListState, Paragraph, Tabs, Wrap,
};

use crate::app::{App, Input, Level, MAINT_ITEMS, Mode, Tab};
use crate::sys;

const ACCENT: Color = Color::Blue;
const SPINNER: [&str; 4] = ["◐", "◓", "◑", "◒"];
/// A secret shows as this many dots once non-empty, whatever its length.
const SECRET_MASK: usize = 8;

/// `s` in a column of `w` cells: cut with "…" so at least one cell of gap
/// is left, then padded to `w`. Pure.
pub fn fit(s: &str, w: usize) -> String {
    use ratatui::text::Span;
    let width = |t: &str| Span::raw(t).width();
    let mut out = String::new();
    if width(s) < w {
        out.push_str(s);
    } else {
        let room = w.saturating_sub(2); // the "…" and the gap
        for c in s.chars() {
            let mut next = out.clone();
            next.push(c);
            if width(&next) > room {
                break;
            }
            out = next;
        }
        if w >= 2 {
            out.push('…');
        }
    }
    let pad = w.saturating_sub(width(&out));
    out.push_str(&" ".repeat(pad));
    out
}

fn block(title: &str) -> Block<'_> {
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(ACCENT))
        .title(Span::styled(
            format!(" {title} "),
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ))
}

fn dim() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

fn level_style(l: Level) -> Style {
    match l {
        Level::Info => Style::default(),
        Level::Ok => Style::default().fg(Color::Green),
        Level::Warn => Style::default().fg(Color::Yellow),
        Level::Error => Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
    }
}

fn dot(on: bool, failed: bool) -> Span<'static> {
    if failed {
        Span::styled("● ", Style::default().fg(Color::Red))
    } else if on {
        Span::styled("● ", Style::default().fg(Color::Green))
    } else {
        Span::styled("○ ", dim())
    }
}

pub fn draw(f: &mut Frame, app: &App) {
    let [top, body, notice, status, hints] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(5),
        Constraint::Length(app.notice.is_some() as u16),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(f.area());

    let titles: Vec<Line> = Tab::ALL
        .iter()
        .enumerate()
        .map(|(i, t)| Line::from(format!(" {} {} ", i + 1, t.title())))
        .collect();
    let tabs = Tabs::new(titles)
        .block(block("Omarchy Cloud"))
        .select(app.tab.index())
        .style(Style::default())
        .highlight_style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD | Modifier::REVERSED),
        )
        .divider(Span::styled("│", Style::default().fg(ACCENT)));
    f.render_widget(tabs, top);

    let details = detail_lines(app);
    // Sized to its content (plus borders), leaving the list at least 3 rows.
    let dh = (details.len() as u16 + 2).clamp(3, body.height.saturating_sub(3).max(3));
    let [list_area, detail_area] =
        Layout::vertical([Constraint::Min(3), Constraint::Length(dh)]).areas(body);
    draw_list(f, app, list_area);
    f.render_widget(
        Paragraph::new(details)
            .wrap(Wrap { trim: false })
            .block(block("Details")),
        detail_area,
    );

    if let Some(n) = &app.notice {
        f.render_widget(
            Paragraph::new(Span::styled(
                format!(" {n}"),
                Style::default().fg(Color::Yellow),
            )),
            notice,
        );
    }

    let st = match (&app.running, &app.status) {
        (Some((label, t0)), _) => {
            let i = (t0.elapsed().as_millis() / 150) as usize % SPINNER.len();
            Line::from(vec![
                Span::styled(
                    format!(" {} ", SPINNER[i]),
                    Style::default().fg(Color::Cyan),
                ),
                Span::raw(format!("{label}… ({}s)", t0.elapsed().as_secs())),
            ])
        }
        (None, Some((l, m, _))) => Line::from(Span::styled(format!(" {m}"), level_style(*l))),
        (None, None) => Line::from(Span::styled(" Ready", dim())),
    };
    f.render_widget(Paragraph::new(st), status);
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!(" {}", hint_line(app)),
            dim(),
        ))),
        hints,
    );

    match &app.mode {
        Mode::Normal => {}
        Mode::Help => draw_help(f),
        Mode::Confirm(c) => {
            let mut lines: Vec<Line> = c.body.iter().map(|l| Line::from(l.as_str())).collect();
            lines.push(Line::from(""));
            let sel = Style::default().add_modifier(Modifier::REVERSED | Modifier::BOLD);
            let (cs, ys) = if c.focus_yes {
                (Style::default(), sel.fg(Color::Red))
            } else {
                (sel, Style::default())
            };
            lines.push(Line::from(vec![
                Span::raw("   "),
                Span::styled(" Cancel ", cs),
                Span::raw("   "),
                Span::styled(format!(" {} ", c.yes), ys),
            ]));
            lines.push(Line::from(Span::styled(
                "   ←/→ choose · Enter confirm · Esc cancel",
                dim(),
            )));
            popup(f, &c.title, lines, 76);
        }
        Mode::TypeConfirm(t) => {
            let mut lines: Vec<Line> = t.body.iter().map(|l| Line::from(l.as_str())).collect();
            lines.push(Line::from(""));
            lines.push(Line::from(vec![
                Span::styled(" Name: ", Style::default().fg(Color::Yellow)),
                Span::styled(
                    format!("{}▏", t.input),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
            ]));
            lines.push(Line::from(Span::styled(
                " type the name · Enter delete · Esc keep",
                dim(),
            )));
            popup(f, &t.title, lines, 80);
        }
        Mode::Form(form) => {
            let mut lines = Vec::new();
            for (i, fl) in form.fields.iter().enumerate() {
                let focused = i == form.focus;
                let empty = match &fl.input {
                    Input::Text(s) => s.is_empty(),
                    Input::Secret(s) => s.is_empty(),
                    _ => false,
                };
                let value = match &fl.input {
                    Input::Text(s) => s.clone(),
                    Input::Secret(s) if s.is_empty() => String::new(),
                    Input::Secret(_) => "•".repeat(SECRET_MASK),
                    Input::Choice(o, i) => {
                        format!("‹ {} ›", o.get(*i).map(String::as_str).unwrap_or("(none)"))
                    }
                    Input::Toggle(b) => (if *b { "[x] yes" } else { "[ ] no" }).to_string(),
                };
                let label_style = if focused {
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };
                let cursor = if focused && matches!(fl.input, Input::Text(_) | Input::Secret(_)) {
                    "▏"
                } else {
                    ""
                };
                let vstyle = if focused {
                    Style::default().add_modifier(Modifier::REVERSED)
                } else {
                    Style::default()
                };
                let mut row = vec![
                    Span::styled(
                        format!("{} {:<17}", if focused { "›" } else { " " }, fl.label),
                        label_style,
                    ),
                    Span::styled(format!("{value}{cursor}"), vstyle),
                ];
                if empty && !fl.placeholder.is_empty() {
                    row.push(Span::styled(format!(" {}", fl.placeholder), dim()));
                }
                lines.push(Line::from(row));
                if focused {
                    lines.push(Line::from(Span::styled(
                        format!("{:19}{}", "", fl.hint),
                        dim(),
                    )));
                }
            }
            lines.push(Line::from(""));
            if let Some(e) = &form.error {
                // An error may carry instructions on several lines (the
                // mount-root setup command).
                for l in e.lines() {
                    lines.push(Line::from(Span::styled(
                        format!(" {l}"),
                        level_style(Level::Error),
                    )));
                }
            }
            lines.push(Line::from(Span::styled(
                form_footer(form.has_choice()),
                dim(),
            )));
            popup(f, &form.title, lines, 84);
        }
        Mode::View(v) => {
            let area = centered(
                f.area(),
                f.area().width.saturating_sub(4),
                f.area().height.saturating_sub(2),
            );
            f.render_widget(Clear, area);
            let inner_h = area.height.saturating_sub(2) as usize;
            let lines: Vec<Line> = v
                .lines
                .iter()
                .skip(v.scroll)
                .take(inner_h)
                .map(|l| Line::from(l.as_str()))
                .collect();
            let title = format!(
                "{} — {}/{} — ↑/↓ PgUp/PgDn · Esc close",
                v.title,
                (v.scroll + 1).min(v.lines.len()),
                v.lines.len()
            );
            f.render_widget(
                Paragraph::new(lines)
                    .wrap(Wrap { trim: false })
                    .block(block(&title)),
                area,
            );
        }
        Mode::Pick(p) => {
            let items: Vec<ListItem> = p.items.iter().map(|s| ListItem::new(s.as_str())).collect();
            let h = (p.items.len() as u16 + 2)
                .min(f.area().height.saturating_sub(4))
                .max(3);
            let area = centered(f.area(), 64, h);
            f.render_widget(Clear, area);
            let mut st = ListState::default().with_selected(Some(p.sel));
            let list = List::new(items)
                .block(block(&p.title).title_bottom(Line::from(Span::styled(
                    " ↑/↓ move · Enter choose · Esc cancel ",
                    dim(),
                ))))
                .highlight_style(Style::default().add_modifier(Modifier::REVERSED | Modifier::BOLD))
                .highlight_symbol("› ");
            f.render_stateful_widget(list, area, &mut st);
        }
    }
}

/// The form's key line; "←/→ choose" only when it has a choice field.
pub fn form_footer(has_choice: bool) -> &'static str {
    if has_choice {
        " ↑/↓ field · ←/→ choose · Enter save · Esc cancel · Ctrl-U clear"
    } else {
        " ↑/↓ field · Enter save · Esc cancel · Ctrl-U clear"
    }
}

/// The bottom key line of a section (at most MAX_HINT cells; the rest of
/// the keys are in the help). `watch_stopped`: the selected offline folder's
/// watch or timer stopped, so its line leads with `w`.
pub fn hint_for(mode_normal: bool, help: bool, tab: Tab, watch_stopped: bool) -> &'static str {
    if help {
        return "any key closes help";
    }
    if !mode_normal {
        return "";
    }
    match tab {
        Tab::Remotes => {
            "a add · Enter settings · m mount/unmount · c reconnect · g Google client · d remove · ? help"
        }
        Tab::Offline if watch_stopped => {
            "w restart watch · Enter sync · c conflicts · d remove · ? help · q quit"
        }
        Tab::Offline => {
            "a add · Enter sync/resume · p pause · n dry-run · c conflicts · d remove · ? help · q quit"
        }
        Tab::Backups => {
            "a add · Enter run · e edit · f files · p schedule on/off · d remove · ? help · q quit"
        }
        Tab::Maint => "Enter choose · ↑/↓ move · Tab next section · ? help · q quit",
    }
}

fn hint_line(app: &App) -> &'static str {
    hint_for(
        matches!(app.mode, Mode::Normal),
        matches!(app.mode, Mode::Help),
        app.tab,
        app.tab == Tab::Offline && app.cur_pair().is_some_and(|p| p.watch_problem().is_some()),
    )
}

/// The row badge of an offline folder whose watch or timer stopped: names
/// what stopped (`Pair::watch_problem`). Pure.
pub fn watch_badge(problem: &str) -> String {
    format!("  ⚠ {problem} (w restarts)")
}

fn draw_list(f: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = match app.tab {
        Tab::Remotes => app
            .remotes
            .iter()
            .map(|r| {
                let on = r.active == "active";
                let state = match (r.active.as_str(), r.sub.as_str()) {
                    ("active", _) => "mounted".to_string(),
                    ("failed", _) => "failed".to_string(),
                    ("activating", _) => "mounting…".to_string(),
                    ("", _) => "unknown".to_string(),
                    _ => "not mounted".to_string(),
                };
                let login = if r.file_state == "enabled" {
                    "starts at login"
                } else {
                    "manual"
                };
                ListItem::new(Line::from(vec![
                    dot(on, r.active == "failed"),
                    Span::styled(
                        fit(&r.name, 22),
                        Style::default().add_modifier(Modifier::BOLD),
                    ),
                    Span::raw(fit(&r.kind, 12)),
                    Span::raw(format!("{state:<13}")),
                    Span::styled(login, dim()),
                ]))
            })
            .collect(),
        Tab::Offline => app
            .pairs
            .iter()
            .map(|p| {
                let watch = p.watch_problem();
                let failed = pair_run(p).failed || p.conf.is_err() || watch.is_some();
                let what = match &p.conf {
                    Ok(c) => format!("{} ⇄ {}", c.local, c.remote),
                    Err(e) => format!("invalid conf: {e}"),
                };
                let state = match (&watch, p.enabled()) {
                    (Some(_), _) => "stopped",
                    (None, true) => "syncing",
                    (None, false) => "paused",
                };
                let mut spans = vec![
                    dot(p.enabled(), failed),
                    Span::styled(
                        fit(&p.name, 18),
                        Style::default().add_modifier(Modifier::BOLD),
                    ),
                    if watch.is_some() {
                        Span::styled(format!("{state:<9}"), Style::default().fg(Color::Red))
                    } else {
                        Span::raw(format!("{state:<9}"))
                    },
                    Span::raw(what),
                ];
                if let Some(w) = &watch {
                    spans.push(Span::styled(
                        watch_badge(w),
                        Style::default().fg(Color::Red),
                    ));
                }
                if let Some(s) = &p.state
                    && !s.conflicts.is_empty()
                {
                    spans.push(Span::styled(
                        format!("  ⚠ {} conflict(s)", s.conflicts.len()),
                        Style::default().fg(Color::Yellow),
                    ));
                }
                ListItem::new(Line::from(spans))
            })
            .collect(),
        Tab::Backups => app
            .jobs
            .iter()
            .map(|j| {
                let failed = job_run(j).failed || j.conf.is_err();
                let what = match &j.conf {
                    Ok(c) => format!(
                        "{} → {}  ({})",
                        c.remote,
                        c.dest,
                        c.schedule.as_deref().unwrap_or("daily")
                    ),
                    Err(e) => format!("invalid conf: {e}"),
                };
                ListItem::new(Line::from(vec![
                    dot(j.enabled(), failed),
                    Span::styled(
                        fit(&j.name, 18),
                        Style::default().add_modifier(Modifier::BOLD),
                    ),
                    Span::raw(format!(
                        "{:<11}",
                        if j.enabled() { "scheduled" } else { "off" }
                    )),
                    Span::raw(what),
                ]))
            })
            .collect(),
        Tab::Maint => MAINT_ITEMS
            .iter()
            .map(|s| ListItem::new(format!("  {s}")))
            .collect(),
    };
    let empty = items.is_empty();
    let mut st = ListState::default().with_selected(if empty {
        None
    } else {
        Some(app.sel[app.tab.index()])
    });
    let list = List::new(items)
        .block(block(app.tab.title()))
        .highlight_style(Style::default().add_modifier(Modifier::REVERSED))
        .highlight_symbol("› ");
    f.render_stateful_widget(list, area, &mut st);
    if empty {
        let inner = Rect {
            x: area.x + 2,
            y: area.y + 1,
            width: area.width.saturating_sub(4),
            height: 1,
        };
        f.render_widget(
            Paragraph::new(Span::styled("Nothing here yet — press a to add", dim())),
            inner,
        );
    }
}

/// A service's last run as shown: the text and whether it failed.
#[derive(Debug, PartialEq, Eq)]
pub struct LastRun {
    pub text: String,
    pub failed: bool,
}

/// What systemd says of a service (`systemctl show --timestamp=unix`).
pub struct SvcView<'a> {
    pub active: &'a str,
    pub result: &'a str,
    /// When the last run ended (`run_ts`): `@<unix seconds>`, empty when none.
    pub exit_ts: &'a str,
    pub exit_status: &'a str,
}

/// How far the state file's time may precede systemd's exit timestamp and
/// still describe the same run (the helper writes it just before exiting).
const STATE_SKEW_S: i64 = 5;

fn unix_ts(s: &str) -> Option<i64> {
    s.strip_prefix('@')
        .unwrap_or(s)
        .parse::<i64>()
        .ok()
        .filter(|t| *t > 0)
}

/// When the last run ended, as the bar's lastRun: ExecMainExitTimestamp,
/// or InactiveEnterTimestamp when that is unset (a run that failed before
/// its main process exited: resources, start-limit-hit). Empty when
/// neither is a valid `@<unix seconds>`. Pure.
pub fn run_ts(exec_exit: &str, inactive_enter: &str) -> String {
    [exec_exit, inactive_enter]
        .into_iter()
        .find(|t| unix_ts(t).is_some())
        .unwrap_or("")
        .to_string()
}

/// The last run, from both sources, as the bar's runOf: the state file
/// (written by the helper just before it exits, kept across reboots)
/// unless systemd saw a later run (one that failed before the state was
/// written: an invalid conf, a timeout), then systemd's view. Pure.
pub fn last_run(state: Option<&sys::State>, svc: &SvcView, now: i64) -> LastRun {
    let running = matches!(svc.active, "activating" | "deactivating");
    let prefix = if running { "running now · last " } else { "" };
    let at = unix_ts(svc.exit_ts);
    let st = state.filter(|s| s.time.is_some());
    if let Some(s) = st
        && at.is_none_or(|a| s.time.unwrap_or(0) >= a - STATE_SKEW_S)
    {
        let when = sys::ago(s.time.unwrap_or(0), now);
        let res = match s.exit {
            Some(0) => "ok".to_string(),
            Some(c) => format!("exit {c}"),
            None => "?".into(),
        };
        let counts = match (s.ok, s.failed) {
            (Some(o), Some(fl)) => format!(", {o} copied, {fl} failed"),
            _ => String::new(),
        };
        return LastRun {
            text: format!("{prefix}{when} — {res}{counts}"),
            failed: s.exit.is_some_and(|c| c != 0),
        };
    }
    let failed = svc.active == "failed"
        || !matches!(svc.result, "" | "success")
        || !matches!(svc.exit_status, "" | "0");
    if at.is_none() && !failed {
        let text = if running {
            "running now".into()
        } else if state.is_some() {
            "? (the state file has no time)".into()
        } else {
            "never".into()
        };
        return LastRun {
            text,
            failed: false,
        };
    }
    let when = at.map_or_else(|| "time unknown".into(), |a| sys::ago(a, now));
    let res = if failed {
        let why = if matches!(svc.result, "" | "success") {
            "error"
        } else {
            svc.result
        };
        match svc.exit_status {
            "" | "0" => format!("failed ({why})"),
            c => format!("failed ({why}, exit {c})"),
        }
    } else {
        "ok".into()
    };
    LastRun {
        text: format!("{prefix}{when} — {res} (systemd; no newer state file)"),
        failed,
    }
}

fn pair_run(p: &crate::app::Pair) -> LastRun {
    let svc = SvcView {
        active: &p.svc_active,
        result: &p.svc_result,
        exit_ts: &p.exit_ts,
        exit_status: &p.exit_status,
    };
    last_run(p.state.as_ref(), &svc, sys::now())
}

fn job_run(j: &crate::app::Job) -> LastRun {
    let svc = SvcView {
        active: &j.svc_active,
        result: &j.svc_result,
        exit_ts: &j.exit_ts,
        exit_status: &j.exit_status,
    };
    last_run(j.state.as_ref(), &svc, sys::now())
}

fn detail_lines(app: &App) -> Vec<Line<'static>> {
    let kv = |k: &str, v: String| {
        Line::from(vec![
            Span::styled(format!("{k:<14}"), Style::default().fg(Color::Cyan)),
            Span::raw(v),
        ])
    };
    let i = app.sel[app.tab.index()];
    match app.tab {
        Tab::Remotes => app.remotes.get(i).map_or_else(Vec::new, |r| {
            vec![
                kv(
                    "Mount",
                    format!(
                        "{}  (~/Cloud/{})",
                        app.paths.mount_point(&r.name).display(),
                        r.name
                    ),
                ),
                kv(
                    "Unit",
                    format!(
                        "rclone-mount@{}.service: {} ({}), {}",
                        r.name, r.active, r.sub, r.file_state
                    ),
                ),
                kv("Settings", format!("~/.config/rclone-mount/{}.env", r.name)),
            ]
        }),
        Tab::Offline => app.pairs.get(i).map_or_else(Vec::new, |p| {
            let mut v = Vec::new();
            match &p.conf {
                Ok(c) => {
                    v.push(kv("Remote", c.remote.clone()));
                    v.push(kv("Local", c.local.clone()));
                }
                Err(e) => v.push(kv("Conf", format!("invalid: {e}"))),
            }
            v.push(kv("Last sync", pair_run(p).text));
            v.push(kv(
                "Units",
                format!(
                    "timer {} · path {} · service {} ({})",
                    p.timer_file, p.path_file, p.svc_active, p.svc_result
                ),
            ));
            if let Some(w) = p.watch_problem() {
                v.push(Line::from(Span::styled(
                    format!("Problem       {w} — press w to restart"),
                    Style::default().fg(Color::Red),
                )));
            }
            if let Some(s) = &p.state
                && !s.conflicts.is_empty()
            {
                v.push(Line::from(Span::styled(
                    format!("Conflicts     {}", s.conflicts.join(", ")),
                    Style::default().fg(Color::Yellow),
                )));
            }
            if let Ok(c) = &p.conf {
                v.push(kv(
                    "Every",
                    c.interval.clone().unwrap_or_else(|| "2min".into()),
                ));
                v.push(kv(
                    "Filter",
                    match c.filter.as_deref() {
                        Some("") => "none (FILTER= empty): whole folder".into(),
                        Some(f) => f.to_string(),
                        None => "whole folder (or the pair's default .filter)".into(),
                    },
                ));
                if let Some(inc) = &p.include {
                    v.push(kv("Include", inc.clone()));
                }
            }
            v
        }),
        Tab::Backups => app.jobs.get(i).map_or_else(Vec::new, |j| {
            let mut v = Vec::new();
            match &j.conf {
                Ok(c) => {
                    v.push(kv("Remote", c.remote.clone()));
                    v.push(kv("Dest", c.dest.clone()));
                }
                Err(e) => v.push(kv("Conf", format!("invalid: {e}"))),
            }
            v.push(kv("Last run", job_run(j).text));
            v.push(kv(
                "Units",
                format!(
                    "timer {} · service {} ({})",
                    j.timer_file, j.svc_active, j.svc_result
                ),
            ));
            if let Ok(c) = &j.conf {
                v.push(kv(
                    "Keep",
                    format!("{} copies per file", c.keep.unwrap_or(14)),
                ));
                v.push(kv(
                    "Files list",
                    c.files
                        .clone()
                        .unwrap_or_else(|| app.paths.tilde(&app.paths.job_files(&j.name))),
                ));
            }
            v
        }),
        Tab::Maint => vec![Line::from(Span::styled(
            match i {
                0 => "The last 30 journal lines of a mount, offline-folder or backup unit.",
                1 => {
                    "Deletes a remote's VFS cache (only while it is unmounted; pending uploads are counted first)."
                }
                _ => "Shows what a bisync run would do, without changing anything.",
            },
            dim(),
        ))],
    }
}

fn draw_help(f: &mut Frame) {
    let h = |k: &str, d: &str| {
        Line::from(vec![
            Span::styled(format!("  {k:<16}"), Style::default().fg(Color::Cyan)),
            Span::raw(d.to_string()),
        ])
    };
    let s = |t: &str| {
        Line::from(Span::styled(
            t.to_string(),
            Style::default()
                .fg(Color::Blue)
                .add_modifier(Modifier::BOLD),
        ))
    };
    let lines = vec![
        s("Everywhere"),
        h("Tab / ←→ / 1-4", "switch section"),
        h("↑↓ / j k", "move"),
        h("r", "refresh"),
        h("?", "this help"),
        h(
            "q / Esc",
            "quit (Ctrl-C forces it, stopping a running task)",
        ),
        h(
            "in forms",
            "↑↓ field · ←→ choose · Ctrl-U clear · paste works",
        ),
        s("Remotes"),
        h("a", "add a remote (runs rclone config), then mount it"),
        h(
            "Enter / s",
            "mount settings (cache, polling, start at login)",
        ),
        h("m", "mount / unmount"),
        h("c", "reconnect (renew the login)"),
        h("g", "Google Drive: set your own OAuth client id/secret"),
        h(
            "d",
            "remove the mount (asks again before deleting the remote)",
        ),
        s("Offline folders"),
        h(
            "a",
            "add: remote folder ⇄ local folder, optional include patterns",
        ),
        h(
            "Enter",
            "sync now; paused: resume (or check and start, the first time)",
        ),
        h("p / n / c", "pause · dry-run · conflict copies"),
        h(
            "w",
            "restart a stopped folder watch / timer (reset-failed + start)",
        ),
        h("d", "remove (local and remote files are never deleted)"),
        s("Backups"),
        h("a / e / f", "add · edit · edit the files list"),
        h(
            "Enter / p / d",
            "run now · schedule on/off · remove (copies kept)",
        ),
        s("Maintenance"),
        h(
            "Enter",
            "journal of a unit · clear a VFS cache · dry-run a folder",
        ),
    ];
    popup(f, "Help", lines, 86);
}

fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width);
    let h = h.min(area.height);
    Rect {
        x: area.x + (area.width - w) / 2,
        y: area.y + (area.height - h) / 2,
        width: w,
        height: h,
    }
}

fn popup(f: &mut Frame, title: &str, lines: Vec<Line>, width: u16) {
    let inner_w = width.saturating_sub(2).max(1) as usize;
    let rows: usize = lines
        .iter()
        .map(|l| l.width().max(1).div_ceil(inner_w))
        .sum();
    let area = centered(f.area(), width, rows as u16 + 2);
    f.render_widget(Clear, area);
    f.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .block(block(title)),
        area,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cells(s: &str) -> usize {
        Span::raw(s).width()
    }

    #[test]
    fn hints_fit_100_columns() {
        for t in Tab::ALL {
            for (normal, help) in [(true, false), (false, true), (false, false)] {
                for watch in [false, true] {
                    let h = hint_for(normal, help, t, watch);
                    // drawn with one leading space
                    assert!(cells(h) < 100, "{} cells: {h}", cells(h));
                }
            }
        }
        // A stopped watch on the selected folder: the line leads with `w`.
        let h = hint_for(true, false, Tab::Offline, true);
        assert!(h.starts_with("w restart watch"), "{h}");
        assert!(!hint_for(true, false, Tab::Offline, false).contains("w restart"));
        // Only on the Offline tab, and only in normal mode.
        assert!(!hint_for(true, false, Tab::Remotes, true).contains("w restart"));
        assert_eq!(
            hint_for(false, true, Tab::Offline, true),
            "any key closes help"
        );
        assert!(form_footer(true).contains("←/→"));
        assert!(!form_footer(false).contains("←/→"));
        assert!(cells(form_footer(true)) <= 82);
    }

    #[test]
    fn last_run_takes_the_newer_source() {
        let now = 1_000_000;
        let st = |time: i64, exit: i32| sys::State {
            time: Some(time),
            exit: Some(exit),
            ..sys::State::default()
        };
        let svc = |result: &'static str, ts: &'static str, status: &'static str| SvcView {
            active: "inactive",
            result,
            exit_ts: ts,
            exit_status: status,
        };
        // The state file describes systemd's last run (written just before).
        let r = last_run(
            Some(&st(now - 120, 0)),
            &svc("success", "@999882", "0"),
            now,
        );
        assert_eq!(
            r,
            LastRun {
                text: "2m ago — ok".into(),
                failed: false
            }
        );
        // systemd saw a later run that failed before writing the state.
        let r = last_run(
            Some(&st(now - 7200, 0)),
            &svc("exit-code", "@999940", "64"),
            now,
        );
        assert!(r.failed, "{r:?}");
        assert!(
            r.text.starts_with("1m ago — failed (exit-code, exit 64)"),
            "{}",
            r.text
        );
        // A timeout: no exit status, Result says why.
        let r = last_run(
            Some(&st(now - 7200, 0)),
            &svc("timeout", "@999940", ""),
            now,
        );
        assert!(r.failed && r.text.contains("failed (timeout)"), "{r:?}");
        // After a reboot systemd knows nothing: a failed state still fails.
        let r = last_run(Some(&st(now - 60, 2)), &svc("success", "", ""), now);
        assert_eq!(
            r,
            LastRun {
                text: "1m ago — exit 2".into(),
                failed: true
            }
        );
        // A newer ok state wins over an older systemd failure.
        let r = last_run(
            Some(&st(now - 10, 0)),
            &svc("exit-code", "@999000", "1"),
            now,
        );
        assert!(!r.failed, "{r:?}");
        // No state file at all.
        assert_eq!(last_run(None, &svc("", "", ""), now).text, "never");
        let r = last_run(None, &svc("success", "@999700", "0"), now);
        assert!(!r.failed && r.text.starts_with("5m ago — ok"), "{r:?}");
        // A run that failed without an exit timestamp (resources,
        // start-limit-hit): InactiveEnterTimestamp dates it, so it is not
        // hidden behind an older ok state file.
        let ts = run_ts("", "@999940");
        assert_eq!(ts, "@999940");
        let r = last_run(
            Some(&st(now - 7200, 0)),
            &SvcView {
                active: "failed",
                result: "resources",
                exit_ts: &ts,
                exit_status: "",
            },
            now,
        );
        assert!(
            r.failed && r.text.contains("1m ago — failed (resources)"),
            "{r:?}"
        );
        let running = SvcView {
            active: "activating",
            result: "success",
            exit_ts: "",
            exit_status: "",
        };
        assert!(
            last_run(Some(&st(now - 60, 0)), &running, now)
                .text
                .starts_with("running now · last 1m ago")
        );
    }

    #[test]
    fn run_ts_falls_back_to_inactive_enter() {
        assert_eq!(run_ts("@100", "@200"), "@100");
        assert_eq!(run_ts("", "@200"), "@200");
        assert_eq!(run_ts("n/a", "@200"), "@200");
        assert_eq!(run_ts("", ""), "");
        assert_eq!(run_ts("", "@0"), "");
    }

    #[test]
    fn watch_badge_names_what_stopped() {
        let b = watch_badge("timer stopped (unit-start-limit-hit)");
        assert_eq!(b, "  ⚠ timer stopped (unit-start-limit-hit) (w restarts)");
        assert!(!b.contains("watch"));
        assert!(
            watch_badge("folder watch stopped (trigger-limit-hit)")
                .contains("folder watch stopped")
        );
    }

    #[test]
    fn names_are_cut_to_their_column() {
        assert_eq!(fit("gdrive", 10), "gdrive    ");
        assert_eq!(fit("abcdefghij", 10), "abcdefgh… ");
        assert_eq!(fit("abcdefghi", 10), "abcdefghi ");
        assert_eq!(cells(&fit(&"x".repeat(64), 18)), 18);
        assert!(fit(&"x".repeat(64), 18).ends_with("… "));
        // wide characters count as two cells
        assert_eq!(cells(&fit("日本語日本語日本語", 10)), 10);
        assert_eq!(fit("", 3), "   ");
    }
}
