# Backups

A **backup** downloads chosen files from a remote on a schedule and keeps several
dated copies of each on your computer. Use it for files you want to be able to go
back in time on, for example a copy of your budget spreadsheet kept for the last
14 days.

**A backup is a list of single files.** You list each file by its path. Folders
are not supported: do not list a folder, and wildcards such as `*.pdf` are not
expanded. If you need a whole folder kept on your computer, use an
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

3. **A text editor opens on the files list.** Write one file per line, as its path
   in the cloud (starting inside the remote prefix, if you set one), with no
   leading `/`. For example:

   ```
   # Files backed up by documents-backup
   Documents/budget.xlsx
   Documents/contracts/lease.pdf
   ```

   Lines starting with `#` are notes and are ignored. Each line is one file, not
   a folder. To see the exact names, look in `~/Cloud/<remote>` in the file
   manager.

   **Which editor?** The app uses `$VISUAL`, else `$EDITOR`, else `nvim` if it is
   installed, else `vi`. On Omarchy `$EDITOR` is set to open your default editor
   (set in Omarchy's settings; it is usually **nvim**). If nvim (or vim/vi) opens,
   it does not react to typing like other programs (it starts in a mode where keys are commands). Do this:

   1. Press `i` (insert mode; `-- INSERT --` appears at the bottom).
   2. Type or paste your lines (paste with `Ctrl` + `Shift` + `V`).
   3. Press `Esc`.
   4. Type `:wq` and press Enter. That saves and quits.

   If you want to leave without saving, press `Esc`, type `:q!` and press Enter.
   If a different terminal editor opens (for example `nano`), save and close it the
   usual way (in nano: `Ctrl`+`O`, Enter, then `Ctrl`+`X`). The app continues when
   the editor closes. If your Omarchy default editor is a graphical one, the app may
   not wait for it: finish editing, then press `f` on the backup to check the list.
4. The app checks the list and the settings, saves the backup and turns its
   schedule on.

   You should see `Backup <name> saved and scheduled (Enter runs it now)`.

The destination must not overlap an offline folder, another backup's destination,
the [mount folder](mount-folder.md), `~/Cloud` or a mounted drive. The app refuses
such a destination and says which one.

## Day to day

Press `3` in the app. Enter runs a backup now; `e` edits its settings; `f`
edits the files list again; `p` switches the schedule on and off; `d` removes it
(keeping the copies). All keys are in [tui.md](tui.md#backups).

The [panel](panel.md) shows each backup's last run and the schedule's next run,
and a "show log" button after a failed run. If one file fails the others are still
copied, you get a desktop notification, and the run counts as failed. A backup
that fails because you are offline tries again at the next scheduled run.

## Where the copies are, and how to restore one

Your copies are ordinary files in the **Destination** folder. To restore one, open
that folder in the file manager and copy the dated file you want wherever you
like.

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
