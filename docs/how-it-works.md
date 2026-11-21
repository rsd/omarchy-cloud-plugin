# How it works

The technical background: what runs, what is written where, and what the safety
choices are. You do not need any of this to use the plugin. Terms are explained
in the [glossary](glossary.md).

## The pieces

| Piece | Where | What it is |
|---|---|---|
| The bar plugin | the plugin folder (`BarWidget.qml`, `CloudState.qml`, `Model.js`) | The icon and panel. `Model.js` holds every parse, validation, command line, aggregation and format; `CloudState.qml` is the singleton that polls; `BarWidget.qml` lays it out and runs the actions |
| The Omarchy Cloud app | `app/` (Rust), installed to `~/.local/bin/omarchy-cloud` | The terminal app that sets everything up. It calls `rclone-bisync` and `rclone-backup` instead of reimplementing them, and reads configuration the same way (never running it) |
| Helper scripts | `bin/`, installed to `~/.local/bin/` | `rclone-bisync` and `rclone-backup`: the only place the sync and backup logic lives. The units, the app and the panel all call them. `rclone-mount` is the guard the mount unit runs before and while it starts a mount (below) |
| systemd user units | `systemd/`, installed to `~/.config/systemd/user/` | Six templates (below) |
| `install.sh` | the plugin folder | Copies the units, scripts and app into place and sets up the mount folder |

Nothing is enabled by installing: the app does it, step by step.

## The systemd units

systemd is the part of Linux that starts and supervises services. A "user" unit
runs as you, in your login session, with no `sudo`. Each unit below is a
**template**: `@` is followed by the name of a remote, offline folder or backup
(the "instance"), and `%i` in the file stands for that name.

| Unit | Does |
|---|---|
| `rclone-mount@<remote>.service` | Mounts the remote at `<mount folder>/<remote>` (through the `rclone-mount` guard, below) with `rclone mount`, `--cache-dir ~/.cache/rclone`, `--vfs-cache-mode full` (plus small read-chunk and buffer sizes). Its `ExecStop` is `/usr/bin/fusermount3 -uz`, a "lazy" unmount, which the force-unmount design depends on |
| `rclone-bisync@<name>.service` | One sync run of an offline folder (`rclone-bisync run <name>`), after a 3-second pause. Stopped after one hour; two minutes are allowed for stopping |
| `rclone-bisync@<name>.path` | Watches the local folder for changes and starts the service. Its `PathChanged=` is written by `setup` into `rclone-bisync@<name>.path.d/10-local.conf` |
| `rclone-bisync@<name>.timer` | Starts the service a minute after login and then the interval after each run. A drop-in `rclone-bisync@<name>.timer.d/10-interval.conf` sets `OnStartupSec=1min` and `OnUnitInactiveSec=<INTERVAL>` |
| `rclone-backup@<name>.service` | One backup run (`rclone-backup run <name>`). Stopped after one hour |
| `rclone-backup@<name>.timer` | The schedule, with a drop-in `rclone-backup@<name>.timer.d/10-schedule.conf` written by `setup` (`Persistent=true`, up to 10 minutes of random delay) |

A **drop-in** (`*.d/` folder) is a small file that changes one setting of a unit
for one instance. An offline folder or a backup works only after
`rclone-bisync setup <name>` / `rclone-backup setup <name>` has written its
drop-ins; the app does that. `setup` and `teardown` touch only the drop-ins named
above; `teardown` never touches the local folder or the remote.

**Mounts that start at login** are mount units that are enabled. The app's "start
at login" is the mount instance being enabled; stopping a mount leaves it
unchanged.

### The mount unit and the mount folder

The mount folder is read by the unit as `OMARCHY_CLOUD_ROOT`: the unit sets
`/mnt/cloud` as a default, then reads `~/.config/omarchy-cloud/cloud.env`, which
wins. The unit does not trust that value by itself: `ExecCondition=` runs
`~/.local/bin/rclone-mount check <remote> ${OMARCHY_CLOUD_ROOT} %h` and `ExecStart=`
runs `rclone-mount start <remote> ${OMARCHY_CLOUD_ROOT} %h -- rclone mount …`, which
creates `<folder>/<remote>` (never the folder itself) and then `exec`s rclone (the
same process, so `Type=notify` keeps working).

`rclone-mount` reads `cloud.env` itself, the way the installer, the app, the panel and
the other scripts do (parsed, never run as a script: at most 4096 bytes, empty and `#`
lines skipped, the value of the last `OMARCHY_CLOUD_ROOT=` line taken verbatim; no file
or no such line means `/mnt/cloud`), and holds the root to their one rule
(`tests/fixtures/roots.tsv`): absolute; not `/`; no empty, `.` or `..` component; no
whitespace, control character (NUL included), `$ % \ " '` or backquote; not the home
folder nor inside it (the home is compared the same way by every reader,
`tests/fixtures/homes.tsv`: a doubled `/`, `/./` and a trailing `/` are ignored; a home
of only `/` means no home rule), and not resolving into it either: the unit runs
`realpath -m` on the root and on `%h` (each bounded to 5 s) and refuses a root that
resolves to the home or inside it, so that a symbolic link into the home cannot put the
mount where file search and backup tools walk; at most 255 bytes; valid UTF-8 without U+FFFD. The root systemd passed must also be
the same one: systemd parses an environment file its own way (strips quotes and
surrounding whitespace, processes backslashes, accepts indented lines, skips a line that
is not valid UTF-8 so that the default wins), and a root the other readers do not see is
never mounted.

- **A refused root (or remote name, or mount point):** `ExecStart=` exits **78** with one line in the
  journal, `rclone-mount: <remote>: refusing to mount: <reason>. Fix: edit
  ~/.config/omarchy-cloud/cloud.env (one OMARCHY_CLOUD_ROOT=<path> line) or run
  install.sh --mount-root PATH.`, and `RestartPreventExitStatus=78` keeps the unit from
  restarting until the setting is fixed. Reasons: the root is not valid; the unit was
  given a root that differs from what the other readers see (three variants: no
  `cloud.env`, a `cloud.env` without the line, or a line that says something else; the
  message names the likely causes: quotes or whitespace in the line, a line that is not
  valid UTF-8, an `OMARCHY_CLOUD_ROOT=` line in `~/.config/rclone-mount/<remote>.env`, or
  an `Environment=OMARCHY_CLOUD_ROOT=` line in a drop-in,
  `~/.config/systemd/user/rclone-mount@.service.d/*.conf` or
  `rclone-mount@<remote>.service.d/*.conf`; the message names both places);
  the root resolves to the home or inside it (the message says what it resolves to,
  and why: programs that crawl the home would follow the link into the cloud drive);
  `cloud.env` is not a readable regular file; `%h` is not absolute; an invalid remote
  name; or the mount point `<root>/<remote>` is a file, or a symbolic link (to a
  folder anywhere, or dangling): rclone would mount wherever the link points.
- **A temporary problem:** `ExecStart=` exits **75** with `rclone-mount: <remote>:
  cannot mount yet, will retry: <why>.`, and `Restart=on-failure` retries it as
  for any failing start (`RestartPreventExitStatus=78` is the only exit status that
  stops the retries). Reasons: the root or `%h` could not be resolved (`realpath`
  missing, failing or silent for 5 s); the mount point did not answer `stat` within
  5 s; `mkdir` failed with nothing in the way; or the mount point is a **stale FUSE
  mount** (see next).
- **A stale mount:** when rclone dies hard (`kill -9`, out of memory) the mount is
  left behind and `stat` on the mount point says "Transport endpoint is not
  connected". `ExecStart=` detects it from that (never from a live mount: it does not
  unmount anything that answers), clears it silently with `fusermount3 -uz -- <mount
  point>` and checks again, then mounts as normal, so the unit recovers by itself on
  the restart after the crash. If `fusermount3` is missing, fails or the mount point is
  still stale, it exits 75 and the journal line ends with `Fix: run fusermount3 -uz
  <mount point>.`; the unit keeps retrying.
- **A valid root that is not set up** (not an existing directory you can write to and
  search): `ExecCondition=` exits 1, which **skips** the start: the unit is neither
  failed nor restarted, so a machine without the folder does not retry every 15 seconds.
  The journal line is `rclone-mount: <remote>: not started: the mount root <root> is not
  an existing directory you can write to and search; create it once with: sudo install -d
  -o "$USER" -m 755 '<root>' (or choose another root: install.sh --mount-root PATH)`.

`ExecStop` must unmount the path `ExecStart` mounted, which is why the folder is only
changed while no mount runs.

### Without a network

The user manager has no `network-online.target`, so the units do not order on it.
A mount whose start fails (or takes longer than `TimeoutStartSec=2min`) is
restarted every 15 seconds (`Restart=on-failure`), with no start limit, so it
comes up once the network does. (The one exception is a refused mount folder or mount
point, exit 78 above, which is not restarted; a failure that only needs time exits 75
and is retried.)

### Why settings are environment variables, not flags

An rclone command-line flag beats its environment variable, so a tunable given as
a flag in the unit would shadow the `.env` file. That is why the unit sets the
tunables as `Environment=` and the app writes only the `.env` (it keeps comments
and any key it does not manage).

### Why the sync units look the way they do

A path unit that hits its trigger limit fails and stops watching until it is
restarted, and a service start-limit failure is passed on to it. So the path
unit's limit is 200 triggers in 2 seconds (only a program rewriting the folder in
a loop reaches it), and the service has no start limit: every start sleeps 3
seconds first, the timer waits at least 30 seconds after each run, triggers during
a run merge into it, and a lock serializes the rest. If the watch stops anyway,
the timer keeps syncing, the panel and the app show the folder as stopped, and
`w` in the app restarts it. A failing run is retried by the timer.

## Why all paths are fixed to your home folder

Everything the plugin reads or writes lives under your home folder, and the
`XDG_*` variables (`XDG_CONFIG_HOME` and friends) are ignored: configuration in
`~/.config/{rclone-bisync,rclone-backup,omarchy-cloud,rclone-mount}`, state in
`~/.local/state`, cache in `~/.cache`, the units in `~/.config/systemd/user`. The
services and timers run under the systemd user manager, whose environment usually
lacks the `XDG_*` variables of your shell, so following them would let the panel,
the app, the scripts and a timer run disagree about where an offline folder or a
backup lives. The units address the mount settings and the cache with `%h` (your
home). The run locks follow the same rule: always `~/.local/state/omarchy-cloud/locks`,
whatever `XDG_RUNTIME_DIR` is, so a timer run and a run from an ssh, su or cron shell
lock the same file; never `/tmp`, where another account could plant a symlink at the
predictable name. That folder and `~/.local/state/omarchy-cloud` are created with mode
700 and must be real folders (not symlinks) that you own and that group and others
cannot write. Otherwise a run stops before doing anything (exit 1), names the reason,
sends a notification and records `exit=1`. Every bisync call uses the work folder `~/.cache/rclone/bisync`,
pinned, because the app looks for the listings there.

## How the panel reads and acts

Instances are discovered, never listed in the plugin:

- **Remotes:** every `rclone-mount@*.service` systemd has loaded, every
  `~/.config/rclone-mount/*.env` file name, and every remote seen earlier in the
  session.
- **Offline folders and backups:** a 5-second batched poll with the patterns
  `rclone-bisync@*` and `rclone-backup@*`. The poll never names an instance, so an
  offline folder that has not been set up causes no systemd error. Alongside, a
  bounded scan (token-marked output, at most a fixed number of files and bytes;
  symlinks to regular files are read; FIFOs, directories and dangling links are
  skipped) reads the `.conf` and `.state` files and the mount-folder setting. It
  runs on the first poll, when a run ends and when the panel opens.

A stopped, disabled remote with no settings file is unloaded by systemd and only
shows while it was seen since the shell started. A folder that does not exist when
the shell starts (the settings folder) is not watched until the next restart.

### Reads

| What | How | When |
|---|---|---|
| State of every unit | One batched `systemctl --user show --timestamp=unix -p <props> -- 'rclone-mount@*.service' 'rclone-bisync@*' 'rclone-backup@*' <named remotes>` | Every 5 s while a bar shows the widget, once for all monitors; again on opening the panel and 1.2 s after an action |
| `~/.config/rclone-mount/` | File names only (a watched directory listing, no process) | On change |
| `.conf` / `.state` files and `cloud.env` | The bounded scan above | First poll, end of a run, panel open |
| `~/.cache/rclone/vfs/<remote>` | One `du -s -B1 -- <dirs>` for all remotes: allocated bytes, since rclone's cache files are sparse and their apparent size (`du -b`) overstates the cache | Only while the panel is open, at most once a minute |
| Who uses a mount | `timeout -k 2 10 sh -c 'fuser -v -M -m "$1" 2>&1; echo "cloud-mounts-fuser-exit $?"' cloud-mounts-busy <folder>/<remote>`: psmisc `fuser` puts the process numbers on stdout and the rest of its table on stderr, so the two are merged; output without the exit line (timed out) reads as "could not check" | Only when switching a mounted remote off |
| Pending uploads | `timeout -k 2 10 bash -c '<constant script>' cloud-mounts-pending ~/.cache/rclone/vfsMeta/<remote>`: counts the metadata files whose `"Dirty"` is true (rclone's write-back flag); only the count is output | Only when switching a mounted remote off |
| A unit's log | `journalctl --user -u <unit> -n 20 --no-pager -o short`, shown as plain text, lines and total capped | On demand, for a failed unit |

The state poll, the cache-size read and the log read each run under a timeout with
an output cap. On a timeout the poll keeps the last good state and the log view
shows "Log timed out".

### Actions

All are argument lists, never shell strings: `systemctl --user start|stop
rclone-mount@<remote>.service`, `systemctl --user start --no-block
rclone-bisync@<name>.service` (Sync now, only while the folder's timer or watch is
enabled), `uwsm-app -- nautilus --new-window ~/Cloud/<remote>`, and
`omarchy-launch-tui --app-id=TUI.float <omarchy-cloud>` (Configure…).

**Why Configure… uses `omarchy-launch-tui` and not `omarchy-launch-or-focus-tui`.**
The app id `TUI.float` matches Omarchy's rule that floats such windows, but
`omarchy-launch-or-focus-tui` would focus any `TUI.float` window, an unrelated one
included, instead of opening ours (so a second click opens a second window).

### Force unmount

The unit's `ExecStop` is already `fusermount3 -uz`, a lazy unmount, so a stop never
fails on a busy mount. "Force" therefore sends the same `systemctl --user stop`;
it only differs from a plain stop in having shown you what is open first. Running
`fusermount3` from the plugin as well would detach the mount before the unit's own
`ExecStop` and make that fail. The programs listed are not touched; once rclone has
exited, their open files on the mount return errors. Uploads still pending stay in
the cache and are resumed by rclone on the next mount. When the check itself fails
(`fuser` missing, the mount not answering within 10 s, the count unreadable) the
row asks instead of stopping. A check that outlives even its timeout (a task stuck
on a hung mount) is given up on after 14 s and never blocks a later stop: that
stop's check reads as "could not check" and asks.

## Safety and security notes

**The panel.** It runs no `rclone` and makes no network connection of its own
(`tests/model-test.js` checks the sources for `XMLHttpRequest`, `WebSocket` and
`Qt.openUrlExternally`). It never reads rclone's configuration or credentials or the per-remote mount settings files (it reads only the offline-folder and backup `.conf` and `.state` files and the mount-folder setting `cloud.env`, none of which hold secrets),
never writes a file, never kills a program, never enables, disables or edits a unit.
No remote name reaches a shell string: every command is an argument list, and the
two small scripts it runs are constants whose only value is their `"$1"`. Everything
that shows command output or file names is plain text, never rich text. See also
[panel.md](panel.md#what-the-panel-never-does).

**Names.** Every name is held to the strict pattern in
[reference.md](reference.md#names) before it reaches a command or a path; crafted
names (`a;rm -rf ~`, `$(x)`, `-x`, `../x`, a newline, unicode) are rejected and
appear in no command (pinned by `tests/fixtures/names.tsv`).

**Notifications.** Desktop notifications cannot be trusted to show text safely: the
notification server renders a small set of markup (links included) and decodes
entities first, so a file named like a link in a synced remote could otherwise show
a clickable link in a critical notification. The scripts remove `<`, `>` and `&`
from every name and message put in a notification (conflict names, the offline
folder or backup name, a backup's failure message); the log keeps the real names.

**The mount folder.** The mount is outside your home on purpose (see
[mount-folder.md](mount-folder.md)), and the installer never runs `sudo`.

**Google client secret.** The app never puts the secret on a command line (any local
user can read command lines through `/proc` while they run). rclone offers no way to
set a config value without one, so the app edits the remote's section of
`rclone.conf` itself, re-reading the file right before writing because rclone
rewrites it when a token refreshes, and writing atomically with owner-only
permissions. It is plain text in that file, as rclone keeps it for Drive (in rclone 1.75.2 the Drive `client_secret` option is not marked as a password); the file
must not be encrypted nor a symlink, and rclone then reconnects the remote for a new
login. The app never shows the secret.

**Offline folder and backup guards.** See [Offline folders: the details](#offline-folders-the-details) and [Backups: the details](#backups-the-details).

**Locks.** One run of an offline folder at a time: a `flock` on
`~/.local/state/omarchy-cloud/locks/rclone-bisync-<name>.lock` (see above), opened
without truncation; a lock file that is a symlink is refused. bisync's own lock file expires
(`--max-lock 2m`, rclone's minimum; a running bisync keeps renewing it), so a run
that was killed does not block every later run until its `.lck` is deleted by hand.
A run that hangs is stopped after one hour (SIGTERM: rclone cancels and removes its
lock). Backups use a lock per backup in the same place.

**The prebuilt app.** See [install.md](how-it-works.md#installer-details).

## Installer details

For the user steps see [install.md](install.md).

**The record.** The record file `~/.local/state/omarchy-cloud/installed-files`
starts with two header lines, `#version=<the plugin's version>` and
`#repo=<the checkout install.sh ran from>`, then (once the mount-folder setting
exists) `#config=<its path>`, which marks it as user configuration. After that it
lists one `<sha256>  <path>` line per installed file, sorted by path. It is
rewritten on every run, so running the installer after an update records the new
version even when no file changed. The panel and the app compare that version with
the plugin's. Each file is copied atomically (a temporary file in the target folder,
then a rename), mode 644 for units and 755 for programs; the config folders are mode
700. A version in `manifest.json` that is not `N.N.N` stops the install before any
change.

**Which app binary.** On x86_64, a release commit carries a prebuilt static (musl)
binary in `dist/`: `omarchy-cloud-x86_64-linux-musl`, its `.sha256`, and `BUILD-INFO`
(`version=`, `commit=`, `src_sha256=`, `rustc=`, `target=`). `src_sha256` is a digest
of the sources it was built from: in the repository root, the `sha256sum` lines of
`app/Cargo.toml`, `app/Cargo.lock` and every `app/src/**/*.rs`, by relative path in
C-locale sorted order, hashed again with `sha256sum`. `install.sh` installs the
prebuilt when its sha256 matches (`sha256sum -c`), its version is `app/Cargo.toml`'s,
and the digest it recomputes from the checkout (no git needed) is `src_sha256`, so a
checkout whose `app/` changed after the release never gets a stale app next to newer
scripts. A sha256 mismatch is an error that stops the install (it never falls back
silently). Otherwise (another architecture, no `dist/`, another version, other
sources) it says why and builds from source with `cargo build --release --locked`
into `~/.cache/omarchy-cloud/target` (never inside the plugin folder). `--from-source`
always builds; `--no-build` installs everything but the app. With neither a fitting
prebuilt nor `cargo`, it stops with nothing changed and says what to install (Rust),
or to rerun with `--no-build`.

*What the prebuilt check proves.* The `.sha256` and `BUILD-INFO`'s `src_sha256` show
that the binary is the file the release published and that it was built from the
sources of this very commit: it is consistent with the commit. They do not show that
the build itself was honest: that trust rests on the CI publish job (`release.yml`,
see [development.md](development.md#releasing)), which is the only thing that writes
`dist/`. If you would rather not rely on it, run `./install.sh --from-source`.

**What it never overwrites.** Before changing anything it decides for every target:
it is replaced only when it is absent, identical to what it would become, listed in
the record with the sha256 it still has, or a symlink into the plugin folder (an
install by an older `install.sh`, which linked). Anything else (a hand-written unit
of the same name, another program called `omarchy-cloud`, or one of the installed
files edited since) stops the install with nothing changed, naming the file (and,
for a unit, a `diff` command).

**Running syncs and backups.** Before changing anything, `install.sh` (and
`--uninstall`) looks at the locks of the offline-folder syncs and backups
(`~/.local/state/omarchy-cloud/locks/rclone-{bisync,backup}-*.lock`, read from `/proc/locks`, never
taken, so a scheduled run is not made to skip). While one is held it names it and
waits up to `OMARCHY_CLOUD_INSTALL_WAIT_S` seconds (default 60, 0-9999; `0` does not
wait). If it is still running then, it exits 75 with nothing changed. A run started
by an older version, whose lock is still in `$XDG_RUNTIME_DIR` or `/tmp`, is not seen.

**Uninstall.** `--uninstall` removes the files in the record whose sha256 still
matches (an edited one is left, and named), the links of an older linked install, and
the record, then reloads systemd. It keeps configuration, the instances' drop-ins and
enablement links, state, the build cache and every synced, mounted or backed-up file.
`omarchy plugin remove` removes the plugin folder (for a symlinked development
install, only the link). The plugin itself writes no files.

**Upgrading from a linked install (0.3.1 and earlier).** Rerunning `./install.sh`
replaces each link with a copy, and re-points the links that enabling an instance
created (`rclone-bisync@<name>.path` and its `*.wants/` link, and so on) at the
installed copy of the template. The instance drop-ins (`*.d/`) are not touched,
nothing is restarted, and the running timers and path units read the new unit files at
the daemon-reload. The old `installed-binary.sha256` marker is moved into the record.

**Version check.** The panel reads the record at shell start and on each panel open,
never on a timer. It shows a badge (quieter than the error colour, which wins) when
the installed version differs from the plugin's, has no recorded version (installed by
0.3.2 or older, whose record has no header), or is missing.

**Upgrading to 0.3.5 with a non-default `XDG_CONFIG_HOME`.** Before 0.3.5 the scripts
and the app (but not the panel) followed it, so offline folders and backups may sit
under `$XDG_CONFIG_HOME/rclone-bisync` and `rclone-backup`, and their state under
`$XDG_STATE_HOME`. Nothing reads them there any more: move them to
`~/.config/rclone-bisync`, `~/.config/rclone-backup` and `~/.local/state/rclone-*`,
then rerun `rclone-bisync setup <name>` / `rclone-backup setup <name>`. There is no
automatic migration. Likewise, bisync listings an older version left under
`$XDG_CACHE_HOME/rclone/bisync` are no longer cleaned when an offline folder is
removed (only `~/.cache/rclone/bisync` is); delete them by hand.

## Offline folders: the details

**Include patterns.** The app writes the filter from the patterns you give: for each
pattern `P`, `+ P` and `+ P.conflict*`, then a final `- **`. A pattern ending in `/`
is a folder: `dir/` becomes `+ dir/**` (its whole contents, no conflict line).
Patterns are separated by commas only: spaces inside a pattern are kept
(`My Vault.kdbx` is one pattern), empty ones and repeats are dropped, and a comma
inside `{a,b}` braces does not split.

**Adding.** The app checks first. Identical: syncing starts (resync, then enable).
Different: refused, with the differences listed. Identical but with no file on either
side after the filter: refused ("put a file on one side first"), because bisync's next
normal run fails on an empty baseline. An empty local folder: optionally, after a
confirmation, "copy remote -> local first". Removing an offline folder deletes its
state file, its filter and the filter's `.md5`, and its listings.

**Pause and resume.** Resume (the paused folder's one normal run) is offered only when
the folder has its own state file next to bisync's listings: listings left by a removed
folder with the same folders would make bisync diff against a stale baseline.
Otherwise a check and a resync come first. A paused folder is one whose timer and path
unit are not enabled ("enabled" means both are).

**What triggers a sync.** `rclone-bisync@<name>.path` watches `LOCAL` (`PathChanged=`,
written by `setup` into `rclone-bisync@<name>.path.d/10-local.conf`),
`rclone-bisync@<name>.timer` runs it a minute after login and then `INTERVAL` after
each run. A change is debounced (the service sleeps 3 s first, so an editor's
temp-file-and-rename save settles); triggers that arrive while a run is active merge
into it, so a save made during a run may wait for the next timer tick. A failing run
is retried by the timer. `w` in the app runs `systemctl --user reset-failed`, then
`start`, on the folder's `.path` and `.timer`.

**Safety.**

- A conflict never picks a winner: `--conflict-resolve none --conflict-loser num`
  keeps both versions. A file `X` changed on both sides is kept as numbered copies,
  `X.conflictN` (the numbers depend on the copies already there, so which one is
  local and which remote is not fixed), and `X` itself is renamed. Nothing is ever
  merged automatically.
- Conflict copies are detected under `LOCAL` ignoring the filter (so a copy the filter
  would not sync is still reported), and `setup` warns when the filter would not sync
  the conflict copies of an included file.
- Each new conflict copy (one not in the previous state file) is announced by one
  critical desktop notification; every run still logs all of them, writes them to the
  state file, and the panel and the bar show them until they are gone.
- `LOCAL` must not overlap the `DEST` of any backup (equal, inside it, or containing
  it; compared by path components, as written and with symlinks resolved). Otherwise
  the dated copies would be synced to the offline folder's remote, and so would their
  pruning. It is refused when the config is written (`setup`, and the app's save),
  exit 64; at run time (`run`, `check`, `resync`, `dry-run`) it is only a warning on
  stderr (`warning: ...; continuing`) and the command goes on with its normal exit
  code: a sync is never stopped for it.
- The same refuse-at-setup, warn-at-run rule covers `LOCAL` overlapping another
  folder's `LOCAL` (two would share or nest bisync's listings and baseline) and
  `LOCAL` overlapping the mount folder, `/mnt/cloud`, `~/Cloud` or any FUSE mount
  point, in either direction: inside one, equal to one, or containing one (a folder
  would sync a remote with itself through the mount, or walk it: `LOCAL=/mnt`, or a
  home folder that holds an sshfs mount, is refused).
- One run at a time (see Locks, in the safety notes above).
- The first sync (`resync`) builds the baseline and is allowed only when local and
  remote are **identical** under the filter (`rclone check --download`); otherwise it
  refuses (exit 3) and prints both listings. There is no override. Identical but empty
  is refused too (exit 4).
- `setup` and `teardown` touch only the drop-ins named above; `teardown` never
  touches `LOCAL` or the remote; removing a folder in the app never deletes files.

## Backups: the details

- Copies are made with the only rclone command used, `rclone copyto <remote path>
  <local>`; nothing that writes to a remote is ever run. This copies one file per list
  line; a list line that is a folder is not expanded into its files, which is why
  backups are for single files only.
- The app's files-list screen and `rclone-backup list`/`validate` judge a list by one
  rule, pinned by `tests/fixtures/files-lines.tsv` (run under the C and C.UTF-8
  locales): a relative path (no leading or trailing `/`, no `//`, `.` or `..` part), no
  control character, and no two entries that would make the same
  copy name. The screen is stricter than bash only in a few exotic cases (such as a line over 1024
  bytes; never the other way round), and it writes the list atomically; a list that is a symlink, is not
  UTF-8 or is over 1 MiB is not opened on the screen but in `$VISUAL` / `$EDITOR`.
- Each run downloads into a private staging folder inside `DEST`,
  `.rclone-backup@<name>@XXXXXX` (created with `mktemp -d`, so 700), sets each copy to
  600 there and then renames it into place (`mv -fT`: the rename replaces whatever has
  that name and never follows a link). The staging folder is removed when the run
  ends, also on an interrupt (INT or TERM); one left by a killed run is removed at the
  next run of the same backup (only if it is a real folder you own). A missing `DEST`
  is created 700, and so are the missing folders above it. One failed file does not
  stop the others: the run exits 1 and sends a desktop notification; a failed rename
  counts as failed and its older copies are not pruned.
- `DEST` must be safe from other local accounts (`check_dest_safe`). Why: an account
  that can write in a folder on the path could plant a symlink at a name the run
  writes (a copy, or rclone's own temporary name) or swap `DEST` itself, and the run,
  working as you, would overwrite a file of yours through it. `DEST` is resolved once
  (symlinks followed) and every write uses the resolved folder. Refused when: `DEST`
  exists but is not a folder, is not owned by you, or is writable by group or others
  (mode & 022); any folder above it is owned by another account (not root, not you),
  or is group- or other-writable without the sticky bit (a `/tmp`-style 1777 folder is
  fine, since others cannot rename or delete what is yours there); or a component
  cannot be checked (`stat` fails or takes over 5 s, as on a hung mount; a path
  `realpath` cannot resolve, such as inside a FUSE mount, is refused if a component is a
  symlink). A missing `DEST` is judged by its nearest existing ancestor, created, then
  judged again right before the first copy, even if it appeared meanwhile (another
  account may have made it while the run waited for the lock). `setup`, `validate`
  and `run` all refuse with exit 64; the message says how to fix it (`chmod go-w
  <folder>`, or a private folder). Existing setups can be hit: a folder shared with a
  group (mode 775 or 770 from a umask of 002) and a USB drive mounted with
  `umask=000` are refused; a drive mounted normally (owned by you, 755) is fine.
- Pruning and the cleanup of leftovers (stale staging folders, and `.part` files
  left by 0.3.6 and earlier, which are still cleaned) touch only the backup's own
  `<name>@` copies (a name has no `@`), so backups that share a destination do not
  overwrite or prune each other's copies (before 0.3.2 they did; overlapping
  destinations are now refused).
- One run per backup at a time (a lock); a run that hangs is stopped after
  `TimeoutStartSec=1h`.
- The schedule is `rclone-backup@<name>.timer` with the drop-in `10-schedule.conf` that
  `setup` writes (`Persistent=true`, up to 10 min random delay). "Enabled" means its
  timer is enabled. `teardown` and removing a backup never delete `DEST` or the copies.
- Guards (refuse at setup, warn at run, like the offline-folder ones above): a `DEST`
  must not be inside an offline folder's `LOCAL`, equal to it or contain it (the dated
  copies and their pruning would be synced); must not overlap another backup's `DEST`;
  and must not be inside the mount folder, `/mnt/cloud`, `~/Cloud` or any FUSE mount
  point, or contain one (a backup would write, and prune, on a remote, or into a bare
  mount point the next mount hides). The app refuses to save such a backup or offline
  folder; the helper scripts' `setup` refuse with exit 64 and write nothing.
- A backup that fails offline (say, the catch-up run at login) notifies, and the next
  scheduled run tries again.

## Stopping a task with Ctrl-C

In the app, Ctrl-C during a sync run (a first sync's resync, a dry-run) sends it
SIGTERM and waits up to 120 s (rclone lets transfers drain for 30 s, then cancels them
and may take up to 60 s more), so that it can finish or cancel its transfers and remove
its lock file; other tasks get 4 s. Then they are killed.

**Clearing a VFS cache.** The mount must be stopped (re-checked right before deleting).
It is refused outright while any upload is pending, naming the count, and also when
they cannot be counted: a cache folder or metadata file that cannot be read, or more
than 200,000 entries. Only a count of 0 is offered, behind a confirm.

## Known limits

- The mount folder is not changed from the app, only through
  `install.sh --mount-root`, and re-pointing the `~/Cloud/<remote>` links after a
  change is left to you.
- Setting a Google client edits `rclone.conf` in the app (above): plain text, and
  refused for an encrypted or symlinked config.
