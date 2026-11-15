# Remotes and mounts

A **remote** is your Google Drive (or OneDrive, Dropbox…) as rclone calls it.
**Mounting** it makes it appear as a folder inside the
[mount folder](mount-folder.md), with a shortcut at `~/Cloud/<remote>`. This page
covers adding, mounting, tuning and removing remotes. You do all of it in the
Omarchy Cloud app ([tui.md](tui.md) lists every key); the mount switch is also in
the [panel](panel.md).

Before you start, the mount folder must be set up (see the
[README](../README.md#one-time-step-the-mount-folder)).

## Add Google Drive, step by step

1. Open the app (`omarchy-cloud`, or **Configure…** in the panel). It starts on
   **Remotes**. Press `a`. The app hands the screen to rclone's own question
   screen (rclone is the program that talks to Google). It asks a series of
   questions; you answer by typing a short answer and pressing Enter. **When unsure,
   just press Enter: that takes the default.**
2. Answer like this. The questions and their order can differ slightly between
   rclone versions (this list was checked against rclone 1.75).

   | rclone asks | You type |
   |---|---|
   | The menu `n) New remote  s) Set configuration password  q) Quit config` | `n` |
   | `name>` | `gdrive` (any name you like: letters, digits, `_`, `.`, `-`, starting with a letter or digit, up to 64 characters; the name appears as the folder name in `~/Cloud`) |
   | `Storage>` (a long numbered list) | `drive` (the word, for "Google Drive") |
   | `client_id>` | just Enter |
   | `client_secret>` | just Enter |
   | `scope>` | `1` (full access to your files) |
   | `service_account_file>` | just Enter |
   | `Edit advanced config?` | `n` |
   | `Use web browser to automatically authenticate rclone with remote?` | `y` |
   | (a browser opens, see below) | |
   | `Configure this as a Shared Drive (Team Drive)?` | `n` (answer `y` only if your files live in a company or school "Shared drive", then pick it from the list) |
   | `Keep this "gdrive" remote?` | `y` |
   | The menu again (`e) Edit existing remote … q) Quit config`) | `q` |

3. **The browser sign-in.** After the web-browser question, your browser opens a
   Google page. Choose your Google account. Google asks whether *rclone* may see
   and manage your Drive files: click **Allow** (or **Continue**). The page then
   says the sign-in succeeded, and you can close the tab; go back to the terminal.
   - If Google shows **"Google hasn't verified this app"**: this can happen. Click
     **Advanced**, then the link at the bottom (**Go to … (unsafe)**), then
     **Continue/Allow**. rclone is the program on your own computer that you
     are letting in; the warning is about the sign-in application being new to
     Google. If you prefer not to, use your own Google client (see below).
   - If the browser does not open by itself, rclone prints a link starting with
     `http://127.0.0.1:53682/…`. Copy it and open it in your browser.
4. When rclone finishes (after `q`), the app takes over again. For the new remote
   it saves the mount settings, switches the mount on so it starts at login,
   starts it, and creates the shortcut `~/Cloud/gdrive`. You should see a message
   like:

   ```
   gdrive mounted, ~/Cloud/gdrive linked
   ```

   If instead it says the mount folder is not set up, the remote is saved but
   not mounted: set the folder up (see [mount-folder.md](mount-folder.md)), then
   press `m` on the remote.
5. Open `~/Cloud/gdrive` in the file manager (or the folder button in the
   panel). You should see your Drive files. If it looks empty, wait a few seconds
   and press `r` (refresh) in the app. Google Docs, Sheets and Slides look a bit
   different, see the [FAQ](faq.md#what-about-google-docs-sheets-and-slides).

**Other services** (OneDrive, Dropbox, …) work the same way: `n`, a name, the
service's name or number at `Storage>`, then mostly Enter and a browser sign-in.
rclone's documentation for each service is at <https://rclone.org/docs/>.

## Mount and unmount

- In the app, press `m` on a remote. In the panel, use the switch on its row.
- A remote set to **Start at login** mounts by itself when you log in. Stopping a
  mount does not change that; change it in the remote's settings (Enter or `s`,
  field **Start at login**).
- Mounting is refused, with a message telling you what to do, while the mount
  folder is not set up.

### Unmounting something in use

Before switching a remote off, the app and the panel check which programs have
files open in it and whether uploads are still waiting.

- If nothing is in use, it stops at once.
- Otherwise it lists the programs and the waiting uploads and asks. You can close
  those programs, or choose **Force unmount** (the panel) or confirm (the app).
  Forcing is safe for your data: waiting uploads are kept and finish at the next
  mount. The programs themselves are not closed; their open files in the drive just
  start returning errors.
- If the check could not run, it says so and offers **Stop anyway** and **Cancel**.

Technical details: [how-it-works.md](how-it-works.md#force-unmount).

## When you are offline

The mount does not wait for the network. If it cannot start, it retries every 15
seconds until the network is back; nothing needs restarting. Offline folders and
backups also retry by themselves.

## Mount settings (cache and polling)

You normally never need to change these. The one most people touch is **Cache max
size**: how much disk space the drive may use to keep recently opened files (the
"cache"; the glossary has [more on the VFS cache](glossary.md#vfs-cache)).

Press Enter (or `s`) on a remote to open its settings. Every field can stay empty
to use the default. After you save, the app offers to restart the mount so the
changes apply.

| Field in the app | Default | Meaning |
|---|---|---|
| Cache max size | `10G` | Disk space for the cache, e.g. `10G`, `500M` |
| Cache max age | `72h` | How long to keep unused cached files |
| Write-back delay | `1s` | How long a saved file waits before upload starts |
| Dir cache time | `5m` | How long folder listings are remembered |
| Poll interval | `1m` | How often to ask the cloud for changes; `0` = never |
| Start at login | on for new remotes | Space toggles |

Durations are written like `1h30m`, `500ms`, `0`. Google Drive and OneDrive can
tell rclone when something changed, so when you add them the app sets a long
directory cache time (`1000h`) and a one-minute poll. The other defaults suit
services without that. The settings live in `~/.config/rclone-mount/<remote>.env`;
the exact variable names are in [reference.md](reference.md#mount-settings).

## Reconnect (sign in again)

If the drive suddenly stops showing files, or the panel shows **Mount failed** for
a remote and its log mentions a token or authorisation, the login has probably
expired. Press `c` on the remote in the app. It hands the screen to rclone, which
opens the browser for a new sign-in, as in step 3 above.

## Your own Google Drive client (usually not needed)

Press `g` on a Google Drive remote to enter your own Google "client id" and
"client secret". When rclone signs you in to Google, it uses an application
identity (a client) that is **shared by all rclone users** unless you give it your
own. You only need your own if:

- Google Drive becomes slow or reports "rate limit" or "quota" errors, because
  many users share the same limits; or
- Google refuses the sign-in with the shared client.

Creating your own client is done in Google's developer console; rclone explains it
step by step at <https://rclone.org/drive/#making-your-own-client-id>. Then, in the
app, press `g`, paste the id, and type the secret (it is hidden while you type and
never shown again). The app saves both and runs a reconnect so you sign in again
for the new client. If `rclone.conf` is encrypted or a symlink, the app refuses;
set the client in `rclone config` instead. A secret containing a space, `"`, `'` or
a backquote is refused. Where the secret is stored and why: see
[how-it-works.md](how-it-works.md#safety-and-security-notes).

## Remove a remote

Press `d` on a remote.

1. The app asks to remove the **mount**: it stops it and switches off Start at
   login, removes the shortcut `~/Cloud/<remote>` (only if it is the mount's
   shortcut) and the settings file. It refuses while files are open, and asks when
   uploads are waiting.
2. The remote itself stays known to rclone. Deleting it from rclone is asked
   separately, needs you to type its name, and is refused while an offline folder
   or a backup uses the remote.

**Removing never deletes your files in the cloud.** It only removes the
connection from this computer.

## Free the cache of a remote

See Maintenance in [tui.md](tui.md#maintenance).
