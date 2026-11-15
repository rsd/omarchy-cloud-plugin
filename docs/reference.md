# Reference: config files, commands, exit codes, state

For people who edit files or run the helper scripts by hand. The app
([tui.md](tui.md)) writes all of this for you. Terms: [glossary.md](glossary.md).

## Requirements

Every external dependency, by what needs it (on Omarchy, the ones marked *Omarchy*
are already there).

| Needed | Package (Arch) | What for |
|---|---|---|
| The Omarchy shell (Quickshell) and its `omarchy` command, `omarchy-launch-tui` | *Omarchy* | The bar icon; **Configure…** opens the app with `omarchy-launch-tui` |
| A systemd **user** session (`systemctl --user`, `journalctl --user`) | `systemd` | Every unit, the panel's state and logs |
| `rclone` | `rclone` | Mounts, offline folders, backups, adding remotes |
| FUSE 3 (`fusermount3`) | `fuse3` | `rclone mount` |
| `fuser` | `psmisc` | The panel's check "which programs have files open" before unmounting |
| `notify-send` | `libnotify` | Notifications for conflict copies and failures (skipped when absent) |
| `flock` | `util-linux` | One sync or backup at a time per offline folder or backup |
| `realpath`, `sha256sum`, `du`, `timeout`, `mktemp`, `stat`, `date` | `coreutils` | The scripts, the panel, `install.sh` |
| `grep`, `sed`, `find`, `cmp` | `grep`, `sed`, `findutils`, `diffutils` | The scripts and `install.sh` |
| `uwsm-app`, `nautilus` | *Omarchy* | The panel's open-folder button (Omarchy's own file manager) |
| `systemd-analyze` (optional) | `systemd` | Checks a backup's schedule when you set it up; skipped when absent |
| `cargo` (only for a build from source) | `rust` or rustup | `install.sh` on a machine other than x86_64, with `--from-source`, or in a checkout without a matching `dist/` |

## Names

Offline folders ("pairs"), backups ("jobs") and remotes are each named by one
strict pattern: `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`, with no `..`. Anything else is
dropped, never repaired. Mount folder: a separate, stricter rule
([mount-folder.md](mount-folder.md)).

## Config syntax

The `.conf` files are `KEY=VALUE` lines with `#` comments and no quoting. They are
parsed, never run as scripts. An unknown or repeated key is an error. A leading
`~/` is the only expansion.

## Offline folder config file

`~/.config/rclone-bisync/<name>.conf`:

```
LOCAL=~/Vaults
REMOTE=onedrive:Backup/Vaults
FILTER=~/.config/rclone-bisync/vault-A.filter
INTERVAL=2min
```

| Key | |
|---|---|
| `LOCAL` | Required. Absolute or `~/`; an existing directory; must not overlap another offline folder's `LOCAL` or a backup's `DEST`, nor overlap a cloud location |
| `REMOTE` | Required. `<remote>:<path>`, the remote part matching the name pattern |
| `FILTER` | Optional. An rclone filter file. Absent: `<name>.filter` next to the conf if it exists, else no filter. `FILTER=` (empty): no filter |
| `INTERVAL` | Optional. `<n>s`, `<n>min`, `<n>h` or `<n>d`, at least 30s; default `2min` |

The app writes the filter from the include patterns you give: for each pattern
`P`, `+ P` and `+ P.conflict*`, then a final `- **`. A pattern ending in `/` is a
folder: `dir/` becomes `+ dir/**` (its whole contents, no conflict line).

## Backup config file

`~/.config/rclone-backup/<name>.conf`:

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
| `REMOTE` | Required. `<remote>:` or `<remote>:<prefix>` (no trailing `/`) |
| `FILES` | Optional. Default `~/.config/rclone-backup/<name>.files`; one path per line relative to `REMOTE`, `#` comments, no `..` segment, no leading `/` |
| `DEST` | Required. Created with mode 700; must not overlap the `LOCAL` of any offline folder nor the `DEST` of another backup, nor overlap a cloud location |
| `KEEP` | Optional. 1 to 365, default 14 |
| `SCHEDULE` | Optional. An `OnCalendar` value (`^[A-Za-z0-9*:,./ -]{1,64}$`), default `daily` |
| `STRIP_PREFIX` | Optional. Removed from the front of each path when naming copies |

A "cloud location" is the mount folder, `/mnt/cloud`, `~/Cloud` or any mounted
(FUSE) drive.

## Mount settings

`~/.config/rclone-mount/<remote>.env` is a systemd `EnvironmentFile`, which wins over the unit's `Environment=` defaults.

| Key | Unit default | Value |
|---|---|---|
| `RCLONE_VFS_CACHE_MAX_SIZE` | `10G` | a size: `^[0-9]+(\.[0-9]+)?[KMGT]?$` |
| `RCLONE_VFS_CACHE_MAX_AGE` | `72h` | a duration |
| `RCLONE_VFS_WRITE_BACK` | `1s` | a duration |
| `RCLONE_DIR_CACHE_TIME` | `5m` | a duration, e.g. `5m`, `1000h` |
| `RCLONE_POLL_INTERVAL` | `1m` | a duration; `0` = off |

Durations are rclone style (`1h30m`, `500ms`, `0`; units ms, s, m, h, d, w, M, y).

## Mount folder setting

`~/.config/omarchy-cloud/cloud.env` holds one plain line, `OMARCHY_CLOUD_ROOT=/mnt/cloud`, at the start of a line (no quotes, indentation or surrounding spaces: a line written differently makes the mount fail). Written only by `install.sh`. See
[mount-folder.md](mount-folder.md).

## Helper commands

Installed in `~/.local/bin`.

```
rclone-bisync run|check|resync|dry-run|conflicts|setup|teardown|validate <name>
rclone-backup run|setup|teardown|list|validate <name>
rclone-mount check|start <remote> <root> <home> [-- <command…>]
```

`rclone-mount` is run by the mount unit, not by you: it checks the mount folder
before and while a mount starts. `check` exits 0 (go on) or 1 (skip: the folder is
valid but not set up yet); `start` exits 78 when the folder or the remote name is
refused (the unit then fails and is not restarted), else it creates
`<root>/<remote>` and runs the command; 64 is a usage error. See
[how-it-works.md](how-it-works.md#the-mount-unit-and-the-mount-folder).

`setup` writes the systemd drop-ins an offline folder or backup needs (the
app does this). `teardown` removes them and never touches the local folder, the
remote, the destination or the copies. `validate <name>` (both scripts) is
read-only: it loads the conf (for a backup, also the files list) and runs every
setup-time guard, writes nothing and runs no `rclone` or `systemctl`; exit 0 valid,
64 not. `rclone-backup list` prints the validated files list.

### Exit codes: `rclone-bisync`

| Exit | Meaning |
|---|---|
| 0 | ok; for `check`: identical; for `run`: also when another run of the same folder is active |
| 1 | `check`: the sides differ |
| 2 | `check`: an error (`resync` also returns 2 when its check errors) |
| 3 | `resync` refused: local and remote differ |
| 4 | `check` or `resync`: identical, but nothing to sync (no file on either side after the filter); `resync` refuses |
| 75 | `resync` or `dry-run`: the folder's lock is busy, nothing was done |
| 64 | Usage error, invalid name or invalid conf (and, for `setup` and `validate` only, a guard hit: `LOCAL` overlapping another folder's `LOCAL` or a backup `DEST`, or a cloud location) |

`run` otherwise exits with `rclone bisync`'s own code.

### Exit codes: `rclone-backup`

0 ok; 1 when any file failed (the others are still copied); 64 as above (a guard
hit, such as `DEST` overlapping an offline folder's `LOCAL` or another backup's
`DEST`: 64 for `setup` and `validate` only, a warning for `run`).

## State files

Written atomically after each run.

- `~/.local/state/rclone-bisync/<name>.state`: `time=` (unix seconds), `exit=`, one
  `conflict=<relative path>` per conflict copy and one `notified=<relative path>`
  per copy a notification was sent for (a failed or missing `notify-send` leaves it
  out, so it is retried; a failed listing keeps the previous lines).
- `~/.local/state/rclone-backup/<name>.state`: `time=`, `exit=`, `ok=`, `failed=`.
- `~/.local/state/omarchy-cloud/installed-files`: the install record
  ([install.md](install.md)).

## Where everything lives

All under your home folder; the `XDG_*` variables are ignored (see
[how-it-works.md](how-it-works.md#why-all-paths-are-fixed-to-your-home-folder)).

| What | Where |
|---|---|
| Units | `~/.config/systemd/user/` |
| Helper scripts, app | `~/.local/bin/` |
| Offline folders, backups | `~/.config/rclone-bisync/`, `~/.config/rclone-backup/` |
| Mount settings | `~/.config/rclone-mount/<remote>.env` |
| Mount folder setting | `~/.config/omarchy-cloud/cloud.env` |
| State | `~/.local/state/rclone-bisync/`, `rclone-backup/`, `omarchy-cloud/` |
| Cache | `~/.cache/rclone/` (VFS cache in `vfs/<remote>`, upload metadata in `vfsMeta/<remote>`, bisync work files in `bisync/`); build cache `~/.cache/omarchy-cloud/target` |
| Run locks | `$XDG_RUNTIME_DIR` (else `/tmp`): `rclone-bisync-<name>.lock`, `rclone-backup-<name>.lock` |
| rclone's own config | wherever rclone keeps it (`rclone config file` prints the path); not managed by this plugin, except the Google client edit in [remotes.md](remotes.md#your-own-google-drive-client-usually-not-needed) |
