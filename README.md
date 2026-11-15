# Omarchy cloud

Everything for rclone cloud storage on an [Omarchy](https://omarchy.org)
desktop, kept in one repository:

- **The bar plugin** (Cloud Mounts, 0.3.3, id `io.github.rsd.cloud-mounts`): a
  shell bar widget that shows rclone remotes mounted by systemd user units, the
  offline folders kept in sync with a remote, and the scheduled backups, and has
  a **Configure...** button (a right-click on the bar icon opens it too).
- **`omarchy-cloud`**, a terminal UI (Rust, `app/`) that sets all of it up:
  remotes and their mount settings, offline folders, backups.
- **systemd user units** (`systemd/`): `rclone-mount@`,
  `rclone-bisync@<pair>.{service,path,timer}` and
  `rclone-backup@<job>.{service,timer}`.
- **Helper scripts** (`bin/`): `rclone-bisync` and `rclone-backup`, the only
  place the sync and backup logic lives (the units, the TUI and the panel all
  call them).
- **`install.sh`**, which copies the units and scripts into place and installs
  the TUI (a prebuilt static binary on x86_64, else built from source).

Three ideas, in three kinds of instance, each named by one strict pattern
(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`): a **remote** is mounted at
`/mnt/cloud/<remote>` (linked at `~/Cloud/<remote>`); an **offline folder**
(a "pair") is a local directory kept in two-way sync with a path on a remote;
a **backup** (a "job") keeps dated local copies of chosen files on a remote.
Nothing is enabled by installing: the TUI does it, step by step.

Example used below: the pair `vault-A` (`~/Vaults` kept in sync with
`onedrive:Backup/Vaults`, only `Personal.kdbx` and its conflict copies) and the job
`archive-vaults` (`work_drive:`, dated copies of one file kept in
`~/Backups/vaults`). Nothing in the design is specific to them.

## Install

```bash
omarchy plugin add <git-url> --enable     # adds the plugin folder under ~/.config/omarchy/plugins
cd ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts
./install.sh                              # the units, the scripts, the TUI
omarchy-cloud                             # or the panel's Configure... button
```

`omarchy plugin add` only clones the plugin (the bar widget); the units,
scripts and TUI it needs are installed by `./install.sh`, which you run
yourself. It refuses to run as root and is idempotent:

```
./install.sh [--no-build | --from-source]
./install.sh --uninstall [--force]
```

What it installs, and where (all of it copies, never links, so updating,
moving or removing the plugin folder changes nothing that systemd runs):

| From the plugin folder | To | Mode |
|---|---|---|
| `systemd/*` (the six unit templates) | `~/.config/systemd/user/` | 644 |
| `bin/rclone-bisync`, `bin/rclone-backup` | `~/.local/bin/` | 755 |
| the `omarchy-cloud` TUI | `~/.local/bin/omarchy-cloud` | 755 |
| (a record of the above, with the version) | `~/.local/state/omarchy-cloud/installed-files` | 644 |

It also creates `~/.config/rclone-bisync` and `~/.config/rclone-backup`
(mode 700), runs `systemctl --user daemon-reload`, and enables and starts
nothing. Each file is copied atomically (a temporary file in the target
directory, then `mv`). The record starts with two header lines,
`#version=<the plugin's version>` and `#repo=<the checkout install.sh ran
from>`, then lists one `<sha256>  <path>` line per installed file, sorted by
path. It is rewritten on every run, so a rerun after an update records the new
version even when no file changed. The widget and the TUI compare that version
with the plugin's (see "After an update").

**Running syncs and backups.** Before changing anything, `install.sh` (and
`--uninstall`) looks at the locks of the offline-folder syncs and backups
(`$XDG_RUNTIME_DIR/rclone-{bisync,backup}-*.lock`, read from `/proc/locks`, never
taken, so a scheduled run is not made to skip). While one is held it names it
and waits up to `OMARCHY_CLOUD_INSTALL_WAIT_S` seconds (default 60, 0-9999;
`0` does not wait). If it is still running then, it exits 75 with nothing
changed; rerun it when the sync or backup has finished.

**The TUI binary.** On x86_64, a release commit carries a prebuilt static
(musl) binary in `dist/`: `omarchy-cloud-x86_64-linux-musl`, its `.sha256`, and
`BUILD-INFO` (`version=`, `commit=`, `src_sha256=`, `rustc=`, `target=`).
`src_sha256` is a digest of the sources it was built from: in the repository
root, the `sha256sum` lines of `app/Cargo.toml`, `app/Cargo.lock` and every
`app/src/**/*.rs`, by relative path in C-locale sorted order, hashed again with
`sha256sum`. `install.sh` installs the prebuilt when its sha256 matches
(`sha256sum -c`), its version is `app/Cargo.toml`'s and the digest it
recomputes from the checkout (no git needed) is `src_sha256`, so a checkout
whose `app/` changed after the release never gets a stale TUI next to newer
scripts. A sha256 mismatch is an error that stops the install (it never falls
back silently). Otherwise (another architecture, no `dist/`, another version,
other sources) it says why and builds from source with
`cargo build --release --locked` into `~/.cache/omarchy-cloud/target` (never
inside the plugin folder); `--from-source` always builds; `--no-build` installs
everything but the TUI (an installed `omarchy-cloud` is kept). With neither a
fitting prebuilt nor `cargo`, it stops with nothing changed and says what to
install (Rust), or to rerun with `--no-build`.

**What it never overwrites.** Before changing anything it decides for every
target: it is replaced only when it is absent, identical to what it would
become, listed in the record with the sha256 it still has, or a symlink into
the plugin folder (an install by an older `install.sh`, which linked).
Anything else (a hand-written unit of the same name, another program called
`omarchy-cloud`, or one of the installed files edited since) stops the install
with nothing changed, naming the file (and, for a unit, a `diff` command).

**Upgrading from a linked install (0.3.1 and earlier).** Rerunning
`./install.sh` replaces each link with a copy, and re-points the links that
enabling an instance created (`rclone-bisync@<pair>.path` and its
`*.wants/` link, and so on) at the installed copy of the template. The
instance drop-ins (`*.d/`) are not touched, nothing is restarted, and the
running timers and path units read the new unit files at the daemon-reload. The
old `installed-binary.sha256` marker is moved into the record.

**After an update.** The plugin (the bar widget) runs from its folder, but the
units, scripts and TUI are copies, so `omarchy plugin update` (or `git pull` in
a checkout) does not change them. Run `./install.sh` again, or press **Update
installed parts** in the panel: it opens `install.sh` in a floating terminal,
which waits for Enter at the end so the result stays readable. The panel
re-checks the next time it opens.

**Version check.** The bar widget compares the version in the record's header
with its own. It shows a small badge on the bar icon (quieter than the error
colour, which wins) and a notice in the panel, with the **Update installed
parts** button, when the installed parts are of another version, have no
recorded version (installed by 0.3.2 or older, whose record has no header), or
are not installed. It reads the record at shell start and on each panel open,
never on a timer, so the badge updates when a panel is opened. The TUI shows a
one-line notice on a mismatch.

A pair or a job works only after `rclone-bisync setup <pair>` /
`rclone-backup setup <job>` has written its systemd drop-ins; the TUI does that.

### Uninstall

```bash
./install.sh --uninstall [--force]
omarchy plugin remove io.github.rsd.cloud-mounts      # asks to confirm; --yes skips
```

`--uninstall` removes the files in the record whose sha256 still matches (an
edited one is left, and named), the links of an older linked install, and the
record, then reloads systemd. It refuses while `rclone-bisync@` or
`rclone-backup@` instances are enabled and prints the `systemctl --user
disable --now` commands; it refuses while `rclone-mount@` instances are enabled
unless `--force` (they then stop mounting at the next login). It keeps
configuration (`~/.config/rclone-bisync`, `~/.config/rclone-backup`, rclone's
own config), the instances' drop-ins and enablement links, state
(`~/.local/state/rclone-*`), the build cache and every synced, mounted or
backed-up file.

`omarchy plugin remove` then disables the plugin and removes its folder (for a
symlinked development install, only the link; the checkout stays). The plugin
itself writes no files.

### Install from a local checkout (development)

The folder name of the checkout does not matter; the link must be named by the
id:

```bash
ln -s ~/src/omarchy-cloud-plugin ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts

omarchy plugin validate ~/src/omarchy-cloud-plugin   # the real path, not the link
omarchy-shell shell rescanPlugins      # a symlinked folder is not watched; rescan after adding or renaming files
omarchy restart shell                  # the shell caches QML: an edit only loads after a restart
omarchy plugin enable io.github.rsd.cloud-mounts right
```

Move it with `omarchy bar move io.github.rsd.cloud-mounts --section right`
(see `omarchy bar --help`).

## Requirements

Every external dependency, by what needs it (on Omarchy, the ones marked
*Omarchy* are already there):

| Dependency | Package (Arch) | Needed by |
|---|---|---|
| The Omarchy shell (Quickshell) and its `omarchy` CLI, `omarchy-launch-tui` | *Omarchy* | the bar widget; Configure... opens the TUI with `omarchy-launch-tui` |
| A systemd **user** session (`systemctl --user`, `journalctl --user`) | `systemd` | every unit, the panel's state and logs |
| `rclone` | `rclone` | mounts, offline folders, backups, adding remotes |
| FUSE 3 (`fusermount3`) | `fuse3` | `rclone mount` |
| `fuser` | `psmisc` | the panel's "folder busy" check before unmounting |
| `notify-send` | `libnotify` | sync conflict and failure notifications (skipped when absent) |
| `flock` | `util-linux` | one sync or backup at a time per pair / job |
| `realpath`, `sha256sum`, `du`, `timeout`, `mktemp`, `stat`, `date` | `coreutils` | the scripts, the panel, `install.sh` |
| `grep`, `sed`, `find`, `cmp` | `grep`, `sed`, `findutils`, `diffutils` | the scripts and `install.sh` |
| `uwsm-app`, `nautilus` | *Omarchy* | the panel's Open folder action (Omarchy's own file-manager binding) |
| `systemd-analyze` (optional) | `systemd` | checks a backup's `SCHEDULE` at setup; skipped when absent |
| `cargo` (only for a source build) | `rust` or rustup | `install.sh` on a machine other than x86_64, `--from-source`, or a checkout without a matching `dist/` |

No network access at install time, except what `cargo` fetches for a source
build (pinned by `app/Cargo.lock`, built with `--locked`). Nothing needs root.

## Marketplace

The id `io.github.rsd.cloud-mounts` is permanent. Suggested listing:
category **System** (it installs and drives systemd user units, mounts and
scheduled jobs; it is plumbing for the machine rather than a productivity
tool), tags `bar`, `quickshell`, `system`. Expect the marketplace's automated
scan to report review capabilities, not failures: `installer` (`install.sh`),
`service-management` (the unit files and `systemctl --user` calls),
`bundled-executable-binary` (`dist/`) and `remote-build` (the cargo fallback).
There is no symlink in the repository (checked by `tests/install-test.sh` and
`tests/manifest-test.js`), and nothing in `dist/` is named `install*` or
`setup*`.

## Releasing

1. Bump the version in `app/Cargo.toml` (and `app/Cargo.lock`),
   `manifest.json`, `tests/manifest-test.js` and this README; commit to `main`.
2. `git tag v0.3.3 && git push origin main v0.3.3`.
3. `.github/workflows/release.yml` runs two jobs. **build** (token
   `contents: read`, not kept in the checkout) checks that the tag equals both
   versions, digests the tagged `app/` sources (`src_sha256`, the same pipeline
   as `install.sh`), builds `x86_64-unknown-linux-musl` with the pinned Rust
   toolchain (`cargo build --release --locked`), checks the binary is static,
   and uploads the binary, its `.sha256` and `BUILD-INFO` as an artifact; the
   dependencies' build scripts thus never run with a token that can write.
   **publish** (`contents: write`, no cargo, no repository code) downloads the
   artifact, checks out `main`, checks that the tag still names the built
   commit and is on `main`, that `main` has not changed `app/` since the tag,
   and that the artifact is consistent (`sha256sum -c`, and `BUILD-INFO`'s
   version, commit and `src_sha256` recomputed from `main`), then commits
   `dist/` to `main` as `github-actions[bot]`. Any check failing stops it
   without pushing. Every action is pinned by commit SHA.
4. The marketplace listing is bound to a commit: submit the commit that carries
   `dist/` (the "Plugin verification" form, with its full 40-character SHA).

## The panel

Plugin id `io.github.rsd.cloud-mounts`, click the widget. A left-click opens
the panel; a right-click opens the TUI (Configure...), or the panel until the
TUI is installed.

- **Bar.** A cloud glyph from the bar's icon font: a cloud with a check when
  every remote is mounted, a plain cloud when some are, a crossed-out cloud
  (dimmed) when none are, and a cloud with an alert, in the theme's urgent
  colour, when any `rclone-mount@` unit has failed (or is failing and retrying),
  a sync or a backup has failed, or a conflict copy exists. The tooltip says how
  many are mounted and names what failed (lines such as "Mount failed:",
  "Sync failed:", "Backup failed:", "<pair>: N conflict copies").
- **Hero line.** Counts what is wrong, e.g. "3 of 3 mounted - 1 sync failed - 2
  conflict copies".
- **Remotes.** One row per remote: its name, its state (mounted, stopped,
  failed, starting, stopping, from the unit's `ActiveState`/`SubState`), the
  disk space its VFS cache takes, a mount switch, a button (while mounted) that
  opens `~/Cloud/<remote>` in the file manager, and, for a failed unit, a button
  that shows its last 20 journal lines in the panel.
- **Offline folders.** Discovered, one row per pair: the last sync (time and
  result) and a **Sync now** button, which works while the pair's timer or path
  unit is enabled (otherwise the row says "Sync not enabled" in the urgent
  colour and the button is disabled); a "show log" button after a failed run;
  "Folder watch stopped (<reason>)" or "Timer stopped (<reason>)" in the
  urgent colour, with the commands that restart it, when the pair's `.path` or
  `.timer` is enabled but not active (failed, for instance on
  `trigger-limit-hit` or `unit-start-limit-hit`; the bar alerts too); the
  conflict copies from the pair's state file (at most 5 named, then a count).
- **Backups.** Discovered, one row per job: the last run and the timer's next
  run; a "show log" button after a failed run.
- Sections with nothing to show are hidden; with nothing at all a hint points to
  Configure.... Rows are capped at 16 per section ("Showing 16 of N") and
  remotes at 32 ("Showing 32 of N remotes.").
- **Configure...** (footer). Opens the TUI in a floating terminal with
  `omarchy-launch-tui --app-id=TUI.float <absolute path>/omarchy-cloud`. The
  app id `TUI.float` matches Omarchy's rule that floats such windows;
  `omarchy-launch-or-focus-tui` is not used because it would focus any
  `TUI.float` window, an unrelated one included, instead of opening ours (so a
  second click opens a second window). When the binary is missing the footer
  shows a dim hint: "Run install.sh from the plugin folder to install
  omarchy-cloud."
- **Installed parts.** When they differ from the plugin, are unversioned or
  missing (see "Version check"), a line says so, with an **Update installed
  parts** button that runs `install.sh` in a floating terminal and closes the
  panel.
- The panel is capped in height and scrolls past it.
- **Keyboard.** Opened from a keybinding, the first arrow key shows a cursor;
  Up/Down step between rows (a remote, the confirm box, Sync now, a log), Left/
  Right between a row's controls (log, folder, switch; Force, Cancel), Enter or
  Space activates the one under the cursor, Esc closes. The mouse moves the same
  cursor, so one control is highlighted at a time.
- **Unmounting a busy remote.** Switching a remote off first checks, at that
  moment only, which processes have files open on `/mnt/cloud/<remote>` and how
  many uploads are still pending in its VFS cache. With nothing open and
  nothing pending it stops at once. Otherwise the row lists the processes
  (name, PID, user; at most 8, then a count) and the pending uploads ("N pending
  uploads will resume on the next mount"), and offers **Force unmount** (or
  **Unmount** when only uploads are pending) and **Cancel**. When the check
  could not answer (fuser missing or timed out) it says so and offers **Stop
  anyway** and **Cancel**.

## The TUI

`omarchy-cloud`, four sections: **Remotes**, **Offline folders**, **Backups**,
**Maintenance**.

Global keys: Tab, Left/Right or `h`/`l`, or `1`-`4` switch section; Up/Down or
`j`/`k` move; `r` refreshes; `?` shows help; `q` or Esc quits (`q` waits for a
running task; Ctrl-C quits and stops it, see Maintenance below). Forms: Up/Down choose the field, Enter
saves, Esc cancels, Ctrl-U clears the field; a paste never submits. Dialogs
start on Cancel. Long commands run in a worker with a spinner.

**Remotes**

| Key | Does |
|---|---|
| `a` | add: hands the terminal to `rclone config`, then creates the `.env`, enables the mount and the `~/Cloud/<remote>` link |
| Enter / `s` | mount settings (see below); a restart is offered |
| `m` | mount / unmount (an unmount asks first when files are open or uploads are pending, naming the count; a count that cannot be made counts as pending) |
| `c` | reconnect |
| `g` | Google client id and secret (Google Drive only; the secret is masked and never shown) |
| `d` | remove: refuses while files are open, asks when uploads are pending (or cannot be counted); `rclone config delete` needs a separate typed-name confirmation and is refused while an offline folder or a backup uses the remote |

**Offline folders**

| Key | Does |
|---|---|
| `a` | add: remote, path, local directory, include patterns, then a **check** |
| Enter | sync now (a paused pair: resume = enable, plus one normal run when bisync's listings and the pair's own state file exist, else check, then resync) |
| `p` | pause / resume |
| `n` | dry-run |
| `c` | conflicts |
| `w` | restart a stopped folder watch / timer (`systemctl --user reset-failed`, then `start`, of the pair's `.path` and `.timer`); the row shows "stopped" in red when one is enabled but not active |
| `d` | remove (never deletes files) |

Adding checks first. Identical: syncing starts (resync, then enable). Different:
refused, with the differences listed. Identical but with no file on either side
after the filter: refused ("put a file on one side first"), because bisync's
next normal run fails on an empty baseline. An empty local folder: optionally,
after a confirmation, "copy remote -> local first". A local directory inside
`/mnt/cloud`, `~/Cloud` or any FUSE mount is refused, and so is one that
overlaps another pair's `LOCAL` or a backup job's `DEST` (see "Safety" and
"Backups"). Resume (the paused pair's one normal run) is offered only when the
pair has its own state file next to bisync's listings: listings left by a
removed pair with the same folders would make bisync diff against a stale
baseline. Removing a pair deletes its state file, its filter's `.md5` and its
listings. The settings form's restart asks the same way as an unmount when
files are open or uploads are pending.

**Backups**

| Key | Does |
|---|---|
| `a` / `e` | add / edit |
| `f` | the files list, opened in `$VISUAL` / `$EDITOR` |
| Enter | run now |
| `p` | schedule on / off |
| `d` | remove (keeps `DEST` and the `.files` list) |

**Maintenance.** The journal of a unit; clear a remote's VFS cache (the mount
must be stopped, re-checked right before deleting; refused outright while any
upload is pending, naming the count, and when they cannot be counted: a cache
directory or metadata file that cannot be read, or more than 200,000 entries;
mount the remote and let rclone upload them first. Only a count of 0 is
offered, behind a confirm);
a folder dry-run.

Ctrl-C during a sync run (a first sync's `resync`, a dry-run) sends it SIGTERM
and waits up to 120 s (rclone lets transfers drain for 30 s, then cancels them
and may take up to 60 s more), so that it can finish or cancel its transfers
and remove its lock file; other tasks get 4 s. Then they are killed.

## Offline folders

A pair is `~/.config/rclone-bisync/<pair>.conf` (`KEY=VALUE` lines, `#`
comments, no quoting; parsed, never sourced; an unknown or repeated key is an
error; a leading `~/` is the only expansion):

```
LOCAL=~/Vaults
REMOTE=onedrive:Backup/Vaults
FILTER=~/.config/rclone-bisync/vault-A.filter
INTERVAL=2min
```

| Key | |
|---|---|
| `LOCAL` | required; absolute or `~/`; an existing directory; must not overlap another pair's `LOCAL` or a backup job's `DEST`, nor be inside a cloud location |
| `REMOTE` | required; `<remote>:<path>`, the remote part matching the name pattern |
| `FILTER` | optional; an rclone filter file. Absent: `<pair>.filter` next to the conf if it exists, else no filter. `FILTER=` (empty): no filter |
| `INTERVAL` | optional; `<n>s`, `<n>min`, `<n>h` or `<n>d`, at least 30s; default `2min` |

The TUI writes the filter from the include patterns you give: for each pattern
`P`, `+ P` and `+ P.conflict*`, then a final `- **`. A pattern ending in `/`
is a folder: `dir/` becomes `+ dir/**` (its whole contents, no conflict line).
Patterns are separated by commas only: spaces inside a pattern are kept
(`My Vault.kdbx` is one pattern), empty ones and repeats are dropped, and a
comma inside `{a,b}` braces does not split.

**What triggers a sync.** `rclone-bisync@<pair>.path` watches `LOCAL`
(`PathChanged=`, written by `setup` into
`rclone-bisync@<pair>.path.d/10-local.conf`), `rclone-bisync@<pair>.timer` runs
it a minute after login and then `INTERVAL` after each run (a drop-in
`rclone-bisync@<pair>.timer.d/10-interval.conf` resets the timer triggers and
sets `OnStartupSec=1min` and `OnUnitInactiveSec=<INTERVAL>`). A change is
debounced (the service sleeps 3 s first, so an editor's temp-file-and-rename
save settles); triggers that arrive while a run is active merge into it, so a
save made during a run may wait for the next timer tick. A failing run is
retried by the timer.

A path unit that hits its trigger limit fails and stops watching until it is
restarted, and a service start-limit failure is passed on to it. So the path
unit's limit is 200 triggers in 2 s (only a program rewriting the folder in a
loop reaches it), and the service has no start limit (every start sleeps 3 s
first, and the timer waits at least 30 s after each run). If the watch stops
anyway, the timer keeps syncing every `INTERVAL`, the panel and the TUI show
the pair as stopped, and `w` in the TUI restarts it. "Enabled" for a pair means
both the timer and the path unit are enabled.

**Safety.**

- A conflict never picks a winner: `--conflict-resolve none --conflict-loser
  num` keeps both versions. A file `X` changed on both sides is kept as
  numbered copies, `X.conflictN` (the numbers depend on the copies already
  there, so which one is local and which remote is not fixed), and `X` itself
  is renamed (a program that has `X` open, such as KeePassXC, then saves to a
  path that no longer exists). Nothing is ever merged automatically: merge
  them into one file, rename it back to `X`, and delete the other copies.
- Conflict copies are detected under `LOCAL` ignoring the filter (so a copy the
  filter would not sync is still reported), and `setup` warns when the filter
  would not sync the conflict copies of an included file.
- Each new conflict copy (one not in the previous state file) is announced by
  one critical desktop notification ("<pair>: conflict - New conflict copies:
  <names>. ... Merge them into one file, rename it back to X, delete the other
  copy."); every run still logs all of them, writes them to the state file, and
  the panel and the bar show them until they are gone.
- One run of a pair at a time (a `flock` on
  `${XDG_RUNTIME_DIR:-/tmp}/rclone-bisync-<pair>.lock`). bisync's own lock
  file expires (`--max-lock 2m`, rclone's minimum; a running bisync keeps
  renewing it), so a run that was killed (SIGKILL, power loss) does not block
  every later run until its `.lck` is deleted by hand. A run that hangs is
  stopped after `TimeoutStartSec=1h` (SIGTERM: rclone cancels and removes its
  lock).
- `LOCAL` must not overlap the `DEST` of any backup job (equal, inside it, or
  containing it; compared by path components, as written and with symlinks
  resolved). Otherwise the dated copies would be synced to the pair's
  remote, and so would their pruning. It is refused when the config is
  written (`setup`, and the TUI's save), exit 64; at run time (`run`,
  `check`, `resync`, `dry-run`) it is only a warning on stderr
  (`warning: ...; continuing`) and the command goes on with its normal exit
  code: a sync is never stopped for it.
- The same refuse-at-setup, warn-at-run rule covers `LOCAL` overlapping
  another pair's `LOCAL` (two pairs would share or nest bisync's listings and
  baseline) and `LOCAL` inside `/mnt/cloud`, `~/Cloud` or any FUSE mount point
  (a pair would sync a remote with itself through the mount).
- Every bisync call uses the work dir `~/.cache/rclone/bisync`, pinned: the
  service and a terminal may have different `XDG_CACHE_HOME`, and the TUI looks
  for the listings there.
- The first sync of a pair (`resync`) builds the baseline and is allowed only
  when local and remote are **identical** under the filter (`rclone check
  --download`); otherwise it refuses (exit 3) and prints both listings. There is
  no override. The TUI's "copy remote -> local first" for an empty folder is the
  way to make them identical. Identical but empty (no file on either side
  after the filter) is refused too (exit 4): bisync's next normal run would
  fail on an empty baseline.
- `setup` and `teardown` touch only the drop-ins named above; `teardown` never
  touches `LOCAL` or the remote; removing a pair in the TUI never deletes files.

## Backups

A job is `~/.config/rclone-backup/<job>.conf`, same syntax as above:

```
REMOTE=work_drive:
FILES=~/.config/rclone-backup/archive-vaults.files
DEST=~/Backups/vaults
KEEP=14
SCHEDULE=daily
STRIP_PREFIX=acme/
```

| Key | |
|---|---|
| `REMOTE` | required; `<remote>:` or `<remote>:<prefix>` (no trailing `/`) |
| `FILES` | optional; default `~/.config/rclone-backup/<job>.files`; one path per line relative to `REMOTE`, `#` comments, no `..` segment, no leading `/` |
| `DEST` | required; created with mode 700; must not overlap the `LOCAL` of any offline folder nor the `DEST` of another job, nor be inside a cloud location |
| `KEEP` | optional; 1 to 365, default 14 |
| `SCHEDULE` | optional; an `OnCalendar` value (`^[A-Za-z0-9*:,./ -]{1,64}$`), default `daily` |
| `STRIP_PREFIX` | optional; removed from the front of each path when naming copies |

**Keep `DEST` out of offline folders.** A backup destination must never be
inside an offline folder's `LOCAL` (nor equal to it, nor contain it), and an
offline folder must never be inside a backup destination: the dated copies
(and their deletion by pruning) would be synced to that folder's remote. The
paths are compared by components, as written and with symlinks resolved.
Refused at setup, warned at run: the TUI refuses to save such a job or pair,
and `rclone-backup setup` and `rclone-bisync setup` refuse with exit 64 and
write nothing; `rclone-backup run` and `rclone-bisync run|check|resync|dry-run`
print a warning on stderr (`warning: ...; continuing`) and go on with their
normal exit code, so a backup or a sync is never stopped for it.

Two more guards work the same way: a `DEST` must not overlap another job's
`DEST` (the jobs' copies and pruning would collide), and must not be inside
`/mnt/cloud`, `~/Cloud` or any FUSE mount point (a backup would write, and
prune, on a remote, or into a bare mount point the next mount hides).

**Naming.** `<job>@`, then the path minus `STRIP_PREFIX` with `/` replaced by
`__`, then the date before the extension: for the job `team-vaults`,
`acme/A/B/C.kdbx` with `STRIP_PREFIX=acme/` becomes
`team-vaults@A__B__C.2026-11-14.kdbx`; a name without an extension gets the date
at the end. The newest `KEEP` copies per file are kept, older ones pruned.
Pruning and the cleanup of stale `.part` files touch only the job's own
`<job>@` copies (a job name has no `@`), so jobs that share a `DEST` no longer
overwrite or prune each other's copies (before 0.3.2 they did; overlapping
`DEST`s are now refused, see above). Copies written by 0.3.1 and earlier
(`<stem>.<date><ext>`, no prefix) are left alone, never pruned, renamed or
deleted: delete them by hand once the new copies exist.

**Read-only toward the remote.** The only rclone verb used is
`rclone copyto <remote path> <local>`; nothing that writes to a remote is ever
run. Copies are downloaded to a `.part` file and then renamed, with umask 077
(files 600, `DEST` 700). One failed file does not stop the others: the run
exits 1 and sends a desktop notification, a failed rename counts as failed and
its older copies are not pruned. One run per job at a time (a lock); a run
that hangs is stopped after `TimeoutStartSec=1h`. The
schedule is `rclone-backup@<job>.timer`, with the drop-in
`rclone-backup@<job>.timer.d/10-schedule.conf` that `setup` writes
(`Persistent=true`, up to 10 min random delay). "Enabled" for a job means its
timer is enabled. `teardown` and removing a job never delete `DEST` or the
copies.

## Mount settings

Remotes are mounted by `rclone-mount@<remote>.service`
(`/mnt/cloud/<remote>`, `--cache-dir ~/.cache/rclone`, `--vfs-cache-mode full`,
and `ExecStop=/usr/bin/fusermount3 -uz /mnt/cloud/%i`: a lazy unmount, which the
force-unmount design depends on, see below). The tunables are environment
variables, set in the unit as `Environment=` defaults and overridden per remote
in `~/.config/rclone-mount/<remote>.env` (a systemd `EnvironmentFile`, which
wins over `Environment=`):

| Key | Unit default | Value |
|---|---|---|
| `RCLONE_VFS_CACHE_MAX_SIZE` | `10G` | a size: `^[0-9]+(\.[0-9]+)?[KMGT]?$` |
| `RCLONE_VFS_CACHE_MAX_AGE` | `72h` | a duration |
| `RCLONE_VFS_WRITE_BACK` | `1s` | a duration |
| `RCLONE_DIR_CACHE_TIME` | `5m` | a duration, e.g. `5m`, `1000h` |
| `RCLONE_POLL_INTERVAL` | `1m` | a duration; `0` = off |

The defaults suit remotes without change polling (S3); Drive and OneDrive, which
have it, are given a long `RCLONE_DIR_CACHE_TIME` in their `.env`.

**Without network.** The user manager has no `network-online.target`, so the
units do not order on it. A mount whose start fails (or takes longer than
`TimeoutStartSec=2min`) is restarted every 15 s (`Restart=on-failure`), with no
start limit, so it comes up once the network does. A sync that fails offline is
retried by its timer; a backup that fails offline (say, the catch-up run at
login) notifies, and the next scheduled run tries again.

**Environment, not flags.** An rclone command-line flag beats its environment
variable, so a tunable given as a flag in the unit would shadow the `.env` file.
That is why the unit sets them as `Environment=` and the TUI writes only the
`.env`; it preserves the comments and any key it does not manage. Durations are
rclone style (`1h30m`, `500ms`, `0`; units ms, s, m, h, d, w, M, y).

The TUI's "start at login" is the mount instance being enabled; stopping a mount
leaves it unchanged.

## Helper commands, exit codes, state

`rclone-bisync run|check|resync|dry-run|conflicts|setup|teardown|validate <pair>`

| Exit | Meaning |
|---|---|
| 0 | ok; for `check`: identical; for `run`: also when another run of the pair is active |
| 1 | `check`: the sides differ |
| 2 | `check`: an error (`resync` also returns 2 when its check errors) |
| 3 | `resync` refused: local and remote differ |
| 4 | `check` or `resync`: identical, but nothing to sync (no file on either side after the filter); `resync` refuses |
| 75 | `resync` or `dry-run`: the pair's lock is busy, nothing was done |
| 64 | usage error, invalid name or invalid conf (and, for `setup` and `validate` only, a guard hit: `LOCAL` overlapping another pair's `LOCAL` or a backup `DEST`, or inside a cloud location) |

`run` otherwise exits with `rclone bisync`'s own code.

`rclone-backup run|setup|teardown|list|validate <job>`: 0 ok, 1 when any file
failed (the others are still copied), 64 as above (a guard hit, such as `DEST`
overlapping an offline folder's `LOCAL` or another job's `DEST`: 64 for `setup`
and `validate` only, a warning for `run`). `list` prints the validated files
list.

`validate <name>` (both scripts) is read-only: it loads the conf (for a job,
also the files list) and runs every setup-time guard, writes nothing and runs
no `rclone` or `systemctl`; exit 0 valid, 64 not.

State files, written atomically after each run:

- `~/.local/state/rclone-bisync/<pair>.state`: `time=` (unix seconds), `exit=`,
  one `conflict=<relative path>` per conflict copy and one
  `notified=<relative path>` per copy a notification was sent for (a failed
  or missing `notify-send` leaves it out, so it is retried; a failed listing
  keeps the previous lines);
- `~/.local/state/rclone-backup/<job>.state`: `time=`, `exit=`, `ok=`, `failed=`.

`XDG_CONFIG_HOME` and `XDG_STATE_HOME` are honoured by the scripts (and
`XDG_CONFIG_HOME` by the TUI) for the `rclone-bisync` and `rclone-backup`
configuration; the mount `.env` and the VFS cache stay under `~/.config` and
`~/.cache` because the unit addresses them with `%h`.

## How the panel relates to the units

**Instances** are discovered, never listed in the plugin.

- *Remotes*: every `rclone-mount@*.service` systemd has loaded (matched by
  systemctl itself), every `~/.config/rclone-mount/*.env` file name, and every
  remote seen earlier in the session.
- *Offline folders and backups*: a 5-second batched poll with the globs
  `rclone-bisync@*` and `rclone-backup@*`. The poll never names an instance, so
  a pair that has not been set up causes no systemd error. Alongside, a bounded
  scan (token-marked output, at most a fixed number of files and bytes; symlinks
  to regular files are read, FIFOs, directories and dangling links skipped) reads
  the `.conf` and `.state` files; it runs on the first poll, when a run ends and
  when the panel opens.

Each name must match `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` and contain no `..`;
anything else is dropped, never repaired. A stopped, disabled remote with no env
file is unloaded by systemd and only shows while it was seen since the shell
started. A directory that does not exist when the shell starts (the env
directory) is not watched until the next restart.

**Reads**

| What | How | When |
|---|---|---|
| state of every unit | one batched `systemctl --user show --timestamp=unix -p <props> -- 'rclone-mount@*.service' 'rclone-bisync@*' 'rclone-backup@*' <named remotes>` | every 5 s while a bar shows the widget, once for all monitors; again on opening the panel and 1.2 s after an action |
| `~/.config/rclone-mount/` | file names only (a watched directory listing, no process) | on change |
| pair and job `.conf` / `.state` | the bounded scan described above | first poll, end of a run, panel open |
| `~/.cache/rclone/vfs/<remote>` | one `du -s -B1 -- <dirs>` for all remotes: allocated bytes, since rclone's cache files are sparse and their apparent size (`du -b`) overstates the cache | only while the panel is open, at most once a minute |
| who uses a mount | `timeout -k 2 10 sh -c 'fuser -v -M -m "$1" 2>&1; echo "cloud-mounts-fuser-exit $?"' cloud-mounts-busy /mnt/cloud/<remote>`: psmisc fuser puts the PIDs on stdout and the rest of its table on stderr, so the two are merged; output without the exit line (timed out) reads as "could not check" | only when switching a mounted remote off |
| pending uploads | `timeout -k 2 10 bash -c '<constant script>' cloud-mounts-pending ~/.cache/rclone/vfsMeta/<remote>`: counts the metadata files whose `"Dirty"` is true (rclone's write-back flag); only the count is output | only when switching a mounted remote off |
| a unit's log | `journalctl --user -u <unit> -n 20 --no-pager -o short`, shown as plain text, lines and total capped | on demand, for a failed unit |

**Runs** (argv arrays, no shell): `systemctl --user start|stop rclone-mount@<remote>.service`,
`systemctl --user start --no-block rclone-bisync@<pair>.service` (Sync now, only
while the pair's timer or path unit is enabled),
`uwsm-app -- nautilus --new-window ~/Cloud/<remote>`, and
`omarchy-launch-tui --app-id=TUI.float <omarchy-cloud>` (Configure...).

**Force unmount.** The unit's `ExecStop` is already `fusermount3 -uz`, a lazy
unmount, so a stop never fails on a busy mount. Force therefore sends the same
`systemctl --user stop`; it only differs from a plain stop in having shown you
what is open first. Running `fusermount3` from the plugin as well would detach
the mount before the unit's own `ExecStop` and make that fail. The processes
listed are not touched; once rclone has exited, their open files on the mount
return errors. Uploads still pending stay in the VFS cache and are resumed by
rclone on the next mount. When the check itself fails (fuser missing, the mount
not answering within 10 s, the count unreadable) the row asks instead of
stopping. A check that outlives even its timeout (a task stuck on a hung FUSE
mount) is given up on after 14 s and never blocks a later stop: that stop's
check reads as "could not check" and asks.

## What it never does

- This section is about the panel, not the TUI. No `rclone` invocation and no
  network access of its own (no
  `XMLHttpRequest`, `WebSocket`, `Qt.openUrlExternally`); `tests/model-test.js`
  checks the sources.
- Never reads `~/.config/rclone/` (the rclone configuration and credentials),
  and never reads the mount env files' contents (it reads only the pair and job
  `.conf` and `.state` files, which hold no secrets).
- Never deletes a cache file or anything else, and writes no files.
- Never kills a process: the busy check only lists them.
- Never enables, disables or edits a unit, and never writes a configuration or
  drop-in file (that is the TUI's and the scripts' job); Sync now is refused
  while the pair's units are not enabled.
- No remote name reaches a shell string: every command is an argv array, and
  the two scripts are constants whose only value is their positional `"$1"`.
- Every text that shows command output or file names is plain text
  (`Text.PlainText`), never rich text.

## Dev workflow

Work in the checkout and link it in under the id (see Install from a local
checkout). The bar widget loads from the checkout, but the units, scripts and
TUI are copies: rerun `./install.sh` after editing `bin/`, `systemd/` or `app/`. No symlink may
exist inside the plugin folder. `Model.js` holds every parse, validation,
argv, aggregation and format; `CloudState.qml` is the singleton that polls
(declared in `qmldir`); `BarWidget.qml` lays it out and runs the actions. The TUI is the crate in `app/`
(`main.rs`, `app.rs`, `ui.rs`, `cmd.rs`, `conf.rs`, `envfile.rs`, `validate.rs`,
`sys.rs`, `secret.rs`); it calls `rclone-bisync` and `rclone-backup` rather than
reimplementing them, and parses configuration the same way (never sourcing it).

## Tests

```bash
bash tests/run.sh
```

Needs `node`, `bash` and the `omarchy` CLI. Besides the plugin suites below it
runs `tests/scripts-test.sh` (the helper scripts, with stand-ins for `rclone`,
`systemctl` and `notify-send`), `tests/install-test.sh` (`install.sh` in a
scratch `HOME`, with stand-ins for `systemctl`, `cargo` and `uname`: copies, the
record, identical-or-stop, the migration from a linked install, the prebuilt
binary's checks, `--uninstall`, and that the repository holds no symlink) and the app's `cargo test` and `cargo clippy` (warnings fatal),
built under `CARGO_TARGET_DIR=~/.cache/omarchy-cloud/target`, never inside the
repo; they are skipped when `cargo` or `app/Cargo.lock` is missing. Plugin suites (a suite that cannot run here
is reported as **skipped**, not passed):

- `omarchy plugin validate` (it does not check the folder name).
- `qmllint` from Qt 6 against the shell's own `qs.Ui` and `qs.Commons`
  (`/usr/share/omarchy/shell`, override with `OMARCHY_SHELL_DIR`), judged from
  its `--json` output by `tests/qmllint-check.js`, and a self-test that injects
  an unknown type into `BarWidget.qml` and `CloudState.qml`.
- A scratch Quickshell (`qs -p` on a temporary config) that loads
  `BarWidget.qml` by file URL, with a self-test (a duplicate property, a syntax
  error in the singleton); and one that creates the widget for real (its panel
  is never opened, so no window appears), which runs one read-only poll
  (`systemctl --user show`) and, through a stand-in panel hold, one `du`, and
  fails on any binding error. Skipped without `qs`, a Wayland session or a user
  manager. The scratch instance is stopped by its PID.
- `tests/model-test.js`: the model under node, including crafted remote names
  (`a;rm -rf ~`, `$(x)`, `-x`, `../x`, a newline, unicode, ...) that are rejected
  and appear in no argv, the parsers against output captured from the real
  tools in the layout the widget receives (fuser's merged stdout from a live
  rclone mount, busy and idle), the keyboard cursor model, and source checks
  on the QML.
- `tests/process-pattern-test.sh`: the pending-upload script run through a real
  bash with printf stand-ins for `grep`, `head` and `wc`, asserting the argv
  each receives for crafted `$HOME` values, then with the real `grep` on a
  fixture metadata tree; and the fuser script with a stand-in that splits its
  table across stdout and stderr as psmisc does, and one that hangs (cut by
  `timeout`).
- `tests/fuser-live-test.js`: the busy check against the real `fuser`, read
  from stdout as the widget reads it, with a `sleep` the test starts holding
  its cwd on `/dev/shm` (busy) and on a non-mount temporary directory (could
  not check). Only that `sleep` is stopped, by its handle. Skipped without
  `fuser`, `timeout` or a `/dev/shm` mount point.
- `tests/manifest-test.js`: manifest, entry points, imports, no symlinks, and
  the folder name: passes when the checkout is named by the id; otherwise
  checks that `~/.config/omarchy/plugins/<id>` leads to this checkout, and is
  skipped when that path does not exist.

## Known residuals

- The Google client secret (set with `g` in the Remotes section) is briefly
  visible in `/proc/<pid>/cmdline` while `rclone config update` runs: rclone
  offers no stdin or environment alternative. The TUI never shows it.

## License

MIT, see [LICENSE](LICENSE).
