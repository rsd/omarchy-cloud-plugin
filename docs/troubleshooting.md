# Troubleshooting

Find your symptom, then follow the steps. Words are explained in the
[README](../README.md#words-used-in-these-docs) and the [glossary](glossary.md). In
the commands, replace `gdrive` (a remote) and `notes` (an offline folder) with your
own names.

## How to read the log of something that failed

Everything the plugin runs is a background service, and systemd keeps a log (the
"journal") for each.

- **Easiest, in the Omarchy Cloud app:** press `4` (Maintenance), then choose
  **Show the journal of a unit…** and pick the one that failed.
- **In the panel:** a failed row has a "show log" button (the last 20 lines).

If you are asked for the log in a bug report, or prefer a terminal:

```bash
journalctl --user -u rclone-mount@gdrive.service -n 50 --no-pager
journalctl --user -u rclone-bisync@notes.service -n 50 --no-pager
journalctl --user -u rclone-backup@documents-backup.service -n 50 --no-pager
```

These print the last 50 lines for a mount, an offline folder and a backup. To see
whether a mount is running: `systemctl --user status rclone-mount@gdrive.service`
shows `active (running)` when it is.

## I do not see the cloud icon on the bar

1. Check that the plugin is added and on:

   ```bash
   omarchy plugin list | grep cloud
   ```

   You should see a line `io.github.rsd.cloud-mounts` with the state `enabled`.
2. If it is listed as `disabled`, switch it on:

   ```bash
   omarchy plugin enable io.github.rsd.cloud-mounts right
   ```

3. If it is enabled but not on the bar, restart the Omarchy shell:

   ```bash
   omarchy restart shell
   ```

4. If it is not listed at all, run the add command from the
   [README](../README.md#install) again and read its output.

## The panel says "Installed parts: not installed" (or out of date)

The plugin and its helper files arrive in two steps, and the second has not been
done (or is older than the plugin).

- Click **Set up…** (or **Update installed parts**) in the panel. A terminal opens,
  runs the installer, and waits for Enter at the end so you can read the result.
- Or run it yourself:

  ```bash
  cd ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts
  ./install.sh
  ```

After updating the plugin you need this again; see [install.md](install.md#updating).
If the installer stops with a message, see
[install.md](install.md#if-the-installer-is-waiting-or-stops).

## Nothing happens when I click Configure… or Set up…

Both open a small terminal window with `omarchy-launch-tui`. Check that it exists
(`command -v omarchy-launch-tui`). As a workaround run `omarchy-cloud` or
`./install.sh` in a terminal yourself.

## `omarchy-cloud: command not found`

The installer puts the app at `~/.local/bin/omarchy-cloud`. Open a new terminal, or
run it by its full path (or click **Configure…** in the panel, which uses the full
path):

```bash
~/.local/bin/omarchy-cloud
```

If the file is missing, the installer has not run (or was run with `--no-build`): see
the section above. The panel's bottom line then says "Run install.sh from the plugin
folder to install omarchy-cloud."

## A mount does not appear

1. **Is the mount folder set up?** The panel (or the app) says "Mount root not set
   up: …" if not. Follow the
   [step-by-step](mount-folder.md#create-the-mount-folder-step-by-step), then switch
   the mount on again.
2. **Is the remote's mount on and running?** Read its log (top of this page).
   Typical causes:
   - A token or login error: your sign-in expired. In the app press `c` on the
     remote to sign in again.
   - A network error: failing mounts are retried every 15 seconds, so it comes up by
     itself when the network is back.
3. **Do you look in the right place?** The remote is inside the mount folder
   (default `/mnt/cloud/gdrive`) and `~/Cloud/<remote>` is a shortcut to it. If the
   mount works but the shortcut is missing, make it yourself:

   ```bash
   mkdir -p ~/Cloud && ln -s /mnt/cloud/gdrive ~/Cloud/gdrive
   ```

   (This creates the folder `~/Cloud` if needed, then the shortcut.)
4. **Did you change the mount folder?** Shortcuts in `~/Cloud` still point to the old
   one; re-point them: [mount-folder.md](mount-folder.md#changing-the-folder-later).
5. **A new remote was added but not mounted:** the mount folder was not ready at that
   time. Press `m` on it once the folder exists.

## A mount fails right away and is not retried

Normally a failing mount is retried every 15 seconds. If the log (top of this page)
instead shows one line like this, the mount folder setting was **refused** and the mount
is stopped until you fix it:

```
rclone-mount: gdrive: refusing to mount: <reason>. Fix: edit ~/.config/omarchy-cloud/cloud.env (one OMARCHY_CLOUD_ROOT=<path> line) or run install.sh --mount-root PATH.
```

What to do:

1. Read the reason in that line. Common ones:
   - **The root is not valid:** the folder path breaks the rules (inside your home, a
     space or special character, not plain text, trailing `/`, over 255 bytes). See
     [mount-folder.md](mount-folder.md#choosing-another-folder).
   - **"the mount root … resolves to …, at or inside your home":** the mount folder is
     a symbolic link (or sits under one) that leads into your home folder. Programs
     that look through your home (file search, indexers, backup tools) would follow
     the link into the cloud drive and download everything, so it is refused. Point
     the folder at a real folder outside your home (step 2 below).
   - **"the mount point … is a symbolic link":** `<mount folder>/<remote>` is a link, so
     rclone would mount wherever it points. Remove the link (`rm
     /mnt/cloud/gdrive`; the plugin then creates a real folder there), or choose
     another mount folder.
   - **"the unit was given the mount root …, but …":** the file
     `~/.config/omarchy-cloud/cloud.env` is written in a way the system reads
     differently from the rest of the plugin (quotes, spaces around the line, an
     indented line), or another file sets the same setting. Make the file hold
     exactly one plain line, `OMARCHY_CLOUD_ROOT=/mnt/cloud`, at the start of the
     line, and remove any other `OMARCHY_CLOUD_ROOT=` line: in
     `~/.config/rclone-mount/<remote>.env`, or an
     `Environment=OMARCHY_CLOUD_ROOT=` line in a systemd drop-in (a `.conf` file in
     `~/.config/systemd/user/rclone-mount@.service.d/` or
     `rclone-mount@<remote>.service.d/`; the message names both).
   - **"cannot create the mount point …":** something is already at
     `<mount folder>/<remote>` (a file). Remove or rename it. (If the mount is only
     retried with the words "cannot mount yet, will retry", see the next section.)
   - **`cloud.env` is not a readable regular file:** it is a folder, link or has wrong
     permissions. Replace it by running the installer's `--mount-root` (below).
2. Easiest fix: run, from the plugin folder, with the folder you want:

   ```bash
   cd ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts
   ./install.sh --mount-root /mnt/cloud
   ```

   The installer refuses while a mount is running or switched on; the message tells you
   which to stop first
   ([mount-folder.md](mount-folder.md#changing-the-folder-later)).
3. Then switch the mount on again (the panel switch, or `m` in the app).

A different, milder message, `rclone-mount: gdrive: not started: the mount root /mnt/cloud
is not an existing directory you can write to and search; …`, just means the folder
does not exist yet. The start was skipped (not failed) and nothing retries. Create it:
[the step-by-step](mount-folder.md#create-the-mount-folder-step-by-step).

## A mount stopped working ("Transport endpoint is not connected")

If rclone is killed hard (it ran out of memory, or was stopped with `kill -9`), it
cannot unmount the drive. The folder at `<mount folder>/<remote>` is then a dead
mount: opening it says "Transport endpoint is not connected". You do not need to do
anything. When the mount service starts again (about 15 seconds later), it clears
the leftover with `fusermount3 -uz` and mounts the drive afresh; your files in the
cloud are not affected.

If it does not come back, read the log (top of this page). A line like this means
the leftover could not be cleared yet, and the service keeps retrying:

```
rclone-mount: gdrive: cannot mount yet, will retry: the mount point /mnt/cloud/gdrive is a stale FUSE mount (Transport endpoint is not connected …), and fusermount3 -uz could not clear it (…). Fix: run fusermount3 -uz /mnt/cloud/gdrive.
```

Run that command yourself in a terminal, with your own mount folder and remote
name. If it says `fusermount3` is not found, install `fuse3`
([README](../README.md#what-you-need)). The next retry then succeeds. Only a
refused setting (the section above) stops the service for good; temporary problems
like this one are always retried. A line saying the mount point "did not answer within
5 s (a hung mount)" is handled the same way: `fusermount3 -uz <mount point>`.

## The drive is mounted but empty, or slow

- Wait a few seconds and press `r` in the app; the first listing of a big drive can
  take a while.
- Open the folder in the file manager rather than a search tool: listings are
  fetched as you browse.
- If Google reports "rate limit" or quota errors, many rclone users share one Google
  sign-in identity; setting your own helps: see
  [remotes.md](remotes.md#your-own-google-drive-client-usually-not-needed).

## The browser sign-in failed while adding a remote

- **The browser did not open.** In the terminal, rclone prints a link starting with
  `http://127.0.0.1:53682/…`. Select it with the mouse, copy it (`Ctrl` + `Shift` +
  `C`) and open it in your browser yourself.
- **The page says it cannot connect to 127.0.0.1.** The terminal stopped waiting, or
  another rclone window is still open. Close it, then add the remote again
  (press `a`).
- **You chose the wrong Google account or clicked Cancel.** Press `c` on the remote in
  the app and sign in again; or remove the remote and add it again.
- **The remote was created but never signed in** (the mount fails with a token
  error): press `c` on it.

## Google says "Google hasn't verified this app"

This can happen during the browser sign-in. It means Google has not reviewed the
application identity (the "client") that rclone uses. To continue: click
**Advanced**, then **Go to … (unsafe)** at the bottom, then **Continue** / **Allow**.
If you would rather not, use your own client:
[remotes.md](remotes.md#your-own-google-drive-client-usually-not-needed).

## The remote does not show in the app

The plugin ignores remote names that do not follow its rule: letters, digits, `_`,
`.` and `-`, starting with a letter or digit, up to 64. Rename the remote in
`rclone config`. If you see "rclone listremotes failed", run `rclone listremotes` in
a terminal and fix what it says; the app cannot add remotes until that works.

## "Mount root not set up" will not go away

- The panel re-checks on its next poll (a few seconds) while it is not ready, so wait
  a moment after you create the folder or finish the installer.
- Check the folder exists and is yours: `ls -ld /mnt/cloud` should list your user name
  as the owner, and you must be able to open it (it needs the write and enter
  permissions, which the `sudo install -d …` command gives you).
- If the message says the setting "is not a valid root", the saved path breaks the
  rules (no spaces or special characters, outside your home, no trailing `/`, plain
  UTF-8 text).
- If it says the folder "resolves inside your home (through a symbolic link)", the
  folder is a link into your home: choose a real folder outside your home, see
  [mount-folder.md](mount-folder.md#a-link-does-not-get-around-this). If it says it
  "could not be resolved", check that the path exists and is spelled right.
  Save a valid one: `./install.sh --mount-root /mnt/cloud` (run from the plugin
  folder).
- The installer will not rewrite an existing setting by itself; only `--mount-root`
  does.

## Conflict copies appeared

You changed the same file on both sides of an [offline folder](offline-folders.md)
between two syncs. Nothing was lost: both versions are kept as `X.conflict1`,
`X.conflict2`, and `X` itself was renamed. Open the copies, keep the version you want
(rename it back to `X`), or merge them into one file named `X`, then delete the other
copies. Details: [offline-folders.md](offline-folders.md#conflict-copies). The alert
on the bar icon goes away once the copies are gone. If a program (like KeePassXC)
reports that its file vanished, that is why: `X` was renamed; save it again to the
original name after merging.

## Sync does not run

- **"Sync not enabled" in the panel:** the offline folder is paused or not set up. In
  the app press Enter on it: it resumes, or checks and starts.
- **"Folder watch stopped (…)" or "Timer stopped (…)":** press `w` on it in the app to
  restart it. Meanwhile the timer keeps syncing every interval.
- **"Sync failed" with a log:** open the log. Offline: it is retried by itself. An
  rclone error (login expired, folder missing): fix it, then press Enter (sync now).
- **Adding an offline folder is refused:**
  - "differ": the two sides are not identical; see
    [offline-folders.md](offline-folders.md#if-both-folders-already-have-files).
  - "put a file on one side first": both sides are empty.
  - "overlaps …": the local folder is inside, equal to, or contains another offline
    folder, a backup destination, the mount folder, `~/Cloud` or a mounted drive.
    Choose a different folder.
- **A sync seems stuck after a crash or power loss:** wait about two minutes; its lock
  expires by itself.
- **A sync or a backup stops with "the run lock folder … is a symlink / not owned by
  you / writable by other accounts":** that is `~/.local/state/omarchy-cloud` or its
  `locks` folder. For "writable", run the `chmod go-w` it names; otherwise remove the
  `locks` folder (or replace the symlink with a real folder), and the next run creates
  it again with mode 700.

## A backup did not run

- Look at the panel's backup row (last and next run) and its log.
- A failed file does not stop the others; the run counts as failed and you get a
  notification.
- Press Enter on it in the app to run it now. The schedule needs `p` (on).
- A backup keeps dated copies of **single files, not folders**; a folder in the list
  is not supported ([backups.md](backups.md)).
- "Files list" errors: press `f` on the backup to open the files list screen. A
  `✗` and a reason mark each entry that cannot be used (a path starts or ends with
  `/`, has `//`, `.` or `..` parts, or two entries make the same copy name); fix it
  with Enter or remove it with `d`, then `s` saves. Saving is refused while the list
  is empty. See [backups.md](backups.md#add-one).

## A backup is refused: "Invalid configuration" or "DEST is writable by other accounts"

A backup refuses to run, or the app refuses to save it, when its destination folder
is not private to you. Another account on the computer could otherwise trick a
backup into overwriting one of your files. A scheduled run shows a notification
"Invalid configuration: …", copies nothing and the panel shows it as failed. The
message names the problem, for example:

```
documents-backup: DEST /home/you/Backups/documents is writable by other accounts (mode 0775); run chmod go-w /home/you/Backups/documents or choose a private folder
```

Other forms of the same refusal say that the folder "is not owned by you", "is not a
folder", that a folder above it is "owned by another account" or "writable by other
accounts without the sticky bit", or "cannot check" a folder (it did not answer within
5 seconds, as a stuck mount does).

What to do:

1. If the folder is yours and the message says it is writable by other accounts, run
   the command it gives, with your folder:

   ```bash
   chmod go-w ~/Backups/documents
   ```

   This stops the group and everyone else writing in it; you keep full access.
2. Otherwise choose another destination: a new folder under your home, such as
   `~/Backups/documents`. The backup creates it private. (A folder shared with a group,
   for example mode 775 or 770, is refused on purpose; so is a USB drive mounted with
   `umask=000`. A normally mounted USB drive that belongs to you, mode 755, is fine.)
3. "Cannot check": a drive or mount above the folder is not responding. Wait for it
   or reconnect it, then run the backup again.
4. In the app press `e` on the backup to change its destination, save, then press
   Enter on the backup to run it again. Copies already made in the old folder stay there.

## Unmounting says files are open

The app and panel list which programs have files open in the drive. Close them, or
choose **Force unmount**: waiting uploads are not lost, they continue at the next
mount. If it says it "could not check", install `psmisc` (see the
[README](../README.md#what-you-need)) or choose **Stop anyway**.

## I cannot clear a remote's cache

Clearing a remote's cache needs the remote to be stopped, and is refused while any
upload is waiting: mount the remote and let rclone upload them first. See
[tui.md](tui.md#maintenance).

## No desktop notifications

Notifications need `notify-send` (the `libnotify` package, see the
[README](../README.md#what-you-need)). Without it, conflict and failure notices are
skipped; the panel and the bar icon still show them.

## Still stuck

Open an issue at <https://github.com/rsd/omarchy-cloud-plugin> with the exact message,
the relevant log lines (top of this page) and the output of
`systemctl --user status <unit>`. Do not paste secrets: a log can contain account
names.
