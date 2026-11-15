# Offline folders

An **offline folder** is a folder on your computer kept in two-way sync with a
folder on a remote. Edit a file on either side and the change is copied to the
other. Because the files really are on your disk, you can use them without a
connection; they sync when you are back online.

Use an offline folder for a small set of files you need everywhere. Use a
[mount](remotes.md) to browse a whole drive without copying it, and a
[backup](backups.md) for dated copies you can go back to.

**Removing is always safe:** removing an offline folder only stops syncing; it
never deletes your local files or your files in the cloud. Be aware, though, that
syncing is two-way: if you delete a file on one side, it is deleted on the other
too.

## Add one: the easy way first

The simplest start is **an empty local folder** and a cloud folder that already
holds the files you want. The first sync then copies them down.

1. Mount your remote first and look at `~/Cloud/gdrive` in the file manager, so
   you know the exact name of the cloud folder you want (for example
   `Documents/Notes`). Type it exactly as it appears, capitals included.
2. In the Omarchy Cloud app press `2` for **Offline folders**, then `a`. (You need
   at least one [remote](remotes.md) first.)
3. Fill in the form (Up/Down moves between fields, Enter saves, Esc cancels):

   | Field | What to enter |
   |---|---|
   | Name | A short label: letters, digits, `_`, `.`, `-` (up to 64, starting with a letter or digit), e.g. `notes` |
   | Remote | The remote to sync with (Left/Right chooses) |
   | Remote folder | The folder in the cloud, e.g. `Documents/Notes`. Empty means the very top of the remote |
   | Local folder | A folder on your computer that is **empty or does not exist yet**, e.g. `~/Notes`. If it does not exist the app asks to create it |
   | Include patterns | Leave empty to sync the whole folder. To sync only some files, type their names separated by commas, e.g. `Notes.txt, Budget.xlsx` |
   | Sync interval | How often to sync, at least `30s`: for example `2min`, `1h`, `1d`. The default `2min` is fine |

4. The app checks the two sides. With an empty local folder and files in the
   cloud it says the local folder is empty and offers **Copy remote → local
   first**. Choose **Copy**: the files are downloaded (this never deletes anything
   and never writes to the cloud), the app checks again, and asks **Start
   syncing?** Choose **Start syncing**.

   You should see `notes is syncing (timer and folder watch enabled)`.

From now on, changes sync in both directions within a few seconds, and at least
every interval.

### If both folders already have files

The first sync is only allowed when the two sides are **identical**, so that no
edit can be lost. If your local folder already has files, the app compares them:

- **Identical:** it asks **Start syncing?**: say yes.
- **Different:** the app refuses and lists the differences. There is no override.
  The simplest way out is to use a new empty local folder as above. Or make the two
  sides match yourself: in the file manager, copy the files that exist on only one
  side into the other (the cloud one is at `~/Cloud/<remote>/…`), delete extras,
  then select the offline folder in the app and press Enter to check again.
- **Both empty** (no file on either side after the filter): refused with "put a
  file on one side first". Put one file in either folder and check again.

The local folder must not be your home folder or `/`, and must not overlap another
offline folder, a backup's destination folder, the [mount folder](mount-folder.md),
`~/Cloud` or a mounted drive (inside it, equal to it or containing it). The app
refuses such a folder with a message saying which one.

## Day to day

Press `2` in the app. Enter syncs now; `p` pauses and resumes; `n` shows what a
sync would do without doing it; `c` lists conflict copies; `d` removes. All keys
are listed in [tui.md](tui.md#offline-folders).

The [panel](panel.md) shows each folder's last sync (time and result) and has a
**Sync now** button; it says "Sync not enabled" when the folder is paused.

Changes sync by themselves: within a few seconds of saving a file, and at least
every interval. If you are offline, syncs fail quietly and are retried. How this
works inside: [how-it-works.md](how-it-works.md#why-the-sync-units-look-the-way-they-do).

If the panel says **Folder watch stopped** or **Timer stopped**, press `w` on the
folder in the app. Syncing still happens on the timer meanwhile.

## Conflict copies

If the same file `X` is changed on both sides between two syncs, nothing is lost
and nothing is merged for you. Both versions are kept as numbered copies,
`X.conflict1` and `X.conflict2`, and `X` itself is renamed. (A program that has
`X` open then saves to a name that no longer exists, so close it.)

**What to do:**

1. Open both copies and decide.
2. If you only care about one version: rename that copy back to `X` and delete the
   other one.
3. If you need parts of both: merge them into one file, name it `X`, and delete
   the copies.

You are told in three ways:

- A critical desktop notification when a new copy appears ("<name>: conflict").
- The [panel](panel.md) and the bar icon show the copies until they are gone (the
  icon turns to the alert colour).
- `c` in the app lists them.

## Technical names and details

The files and units behind an offline folder call it a "pair" (for example
`rclone-bisync@<name>`), and the sync uses `rclone bisync`, rclone's two-way sync.
Include patterns, pause and resume rules, the safety guards, locks, and how syncs
are triggered are documented in
[how-it-works.md](how-it-works.md#offline-folders-the-details) and
[reference.md](reference.md#offline-folder-config-file).
