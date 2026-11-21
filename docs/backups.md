# Backups

A **backup** keeps dated copies of important files. On a schedule it downloads
the files you chose from a remote and keeps several dated copies of each on your
computer. Use it for files you want to be able to go back in time on, for example
a copy of your budget spreadsheet kept for the last 14 days.

**A backup is a list of single files, not folders.** You list each file by its
path. Do not list a folder, and wildcards such as `*.pdf` are not expanded. If you
need a whole folder kept on your computer, use an
[offline folder](offline-folders.md) instead.

A backup only **downloads**: it never changes or deletes anything in the cloud,
and removing a backup never deletes the copies on your computer.

## Add one

1. In the Omarchy Cloud app ([tui.md](tui.md)) press `3` for **Backups**, then
   `a`. (You need at least one [remote](remotes.md) first.)
2. Fill in the form (Up/Down moves between fields, Enter saves, Esc cancels). The
   defaults are fine for most fields:

   | Field | What to enter |
   |---|---|
   | Name | A short label: letters, digits, `_`, `.`, `-`, e.g. `documents-backup` |
   | Remote | The remote to download from |
   | Remote prefix | Optional folder on the remote that all your listed files are inside, no trailing `/` |
   | Destination | The folder on your computer for the copies, e.g. `~/Backups/documents`. It is created for you and is private to you |
   | Keep copies | How many dated copies to keep per file, 1 to 365. Default 14 |
   | Schedule | When to run. `daily` (once a day) is the default; others: `weekly`, or a time such as `*-*-* 03:00` (every day at 3 am) |
   | Strip prefix | Optional, for tidy file names: text removed from the front of each path when naming copies |
   | Files list | Where the list of files is stored. Empty uses the default, `~/.config/rclone-backup/<name>.files` |

3. **The files list opens.** This is a small screen inside the app where you
   add the files to back up, one path per entry. Nothing to learn: the keys are
   shown at the bottom. A path is the file's path in the cloud (starting inside the
   remote prefix, if you set one), with no leading `/`, for example
   `Documents/budget.xlsx` or `Documents/contracts/lease.pdf`. To see the exact
   names, look in `~/Cloud/<remote>` in the file manager.

   - Press `a`, type or paste a path, and press Enter to keep it. Each path is
     checked as you type: `✓ copied as <name>@<file>.<date><ext>` shows the name
     the copies will get, `✗` and a reason means the path cannot be used (for
     example it starts or ends with `/`, or has `//`, `.` or `..` parts). The app
     cannot tell a folder name without a trailing `/` from a file, so make sure
     each entry really is a file.
   - Move with the arrow keys; press Enter on an entry to change it and `d` to
     remove it. Nothing is written to disk until you press `s`.
   - Press `s` to save. It is refused while an entry shows `✗` or the list is
     empty; fix the entry (Enter) or remove it (`d`).
   - Press Esc (or `q`) to close without saving. If you changed something it asks
     first: press Esc (or `q`) again to throw the changes away.

   All the keys are in [tui.md](tui.md#the-files-list-screen).
4. The app checks the list and the settings, saves the backup and turns its
   schedule on.

   You should see `Backup <name> saved and scheduled (Enter runs it now)`.

**Editing the file directly (optional).** The list is a plain text file, one path
per line, with `#` lines as notes. Press `E` on the files-list screen to open it in
your own editor instead (`$VISUAL`, else `$EDITOR`, else `nvim` if installed, else
`vi`; `E` is refused while you have unsaved changes). Omarchy's usual editor,
nvim, starts in a mode where keys are commands: press `i` to type, `Esc` then `:wq`
and Enter to save and quit, or `Esc` then `:q!` and Enter to leave without saving.
The app opens the editor for you automatically only when the screen cannot handle
the file: a list that is a symlink, is not UTF-8 text or is over 1 MiB (it then
says so, for example `~/.config/rclone-backup/<name>.files is not UTF-8 text of at
most 1 MiB: opened in $VISUAL / $EDITOR`). If your editor is a graphical one, the
app may not wait for it: finish editing, then press `f` on the backup to check the
list.

The destination must not overlap an offline folder, another backup's destination,
the [mount folder](mount-folder.md), `~/Cloud` or a mounted drive. The app refuses
such a destination and says which one.

**The destination must also be private to you.** If it is a folder that already
exists, it must be yours and no one else may be able to write in it. Otherwise
another account on the computer could trick a backup into overwriting one of your
own files. A folder the backup creates is private from the start, so the easiest
choice is a new name under your home, such as `~/Backups/documents`. The app
refuses a destination that is not safe and says why, and so does a scheduled run
(you get a notification and nothing is copied). The usual cases are a folder you
share with a group (for example permissions 775) and a USB drive mounted so that
everyone can write to it. For a folder of yours, open a terminal and run
`chmod go-w <folder>`; otherwise choose another folder. A normally mounted USB drive
that belongs to you is fine. See
[troubleshooting.md](troubleshooting.md#a-backup-is-refused-invalid-configuration-or-dest-is-writable-by-other-accounts).

## Day to day

Press `3` in the app. Enter runs a backup now; `e` edits its settings; `f`
opens the files list again; `p` switches the schedule on and off; `d` removes it
(keeping the copies). All keys are in [tui.md](tui.md#backups).

The [panel](panel.md) shows each backup's last run and the schedule's next run,
and a "show log" button after a failed run. If one file fails the others are still
copied, you get a desktop notification, and the run counts as failed. A backup
that fails because you are offline tries again at the next scheduled run.

## Where the copies are, and how to restore one

Your copies are ordinary files in the **Destination** folder. To restore one, open
that folder in the file manager and copy the dated file you want wherever you
like. While a backup runs, you may see a hidden folder there whose name starts with
`.rclone-backup@`; it is where the files are downloaded first, and it is removed
when the run ends.

Each copy's name is the backup's name, an `@`, the file's path (with `/` shown as
`__`, minus the strip prefix) and the date before the extension. For the backup
`team-docs`, the file `acme/A/B/C.xlsx` with strip prefix `acme/` is saved as:

```
team-docs@A__B__C.2026-11-14.xlsx
```

A name without an extension gets the date at the end. The newest "keep" copies of
each file are kept; older copies are deleted automatically, and only this backup's
own `<name>@` copies are ever deleted. Copies written by 0.3.1 and earlier (named
`<stem>.<date><ext>`, no prefix) are never touched: delete them by hand once the
new copies exist.

## Technical names and details

The files and units behind a backup call it a "job" (`rclone-backup@<name>`). The
config file, schedule rules, exit codes and the safety rules (read-only toward the
remote, private permissions, the destination guards) are in
[reference.md](reference.md#backup-config-file) and
[how-it-works.md](how-it-works.md#backups-the-details).
