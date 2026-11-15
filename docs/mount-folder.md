# The mount folder

The **mount folder** is the one folder where all your mounted remotes appear. By
default it is `/mnt/cloud`: the remote `gdrive` is mounted at `/mnt/cloud/gdrive`,
and `~/Cloud/gdrive` is a shortcut (a "link") to it, so you still browse it from
your home folder. The installer and the panel call it the "mount root"; it is the
same thing.

## Create the mount folder, step by step

**Read this first.** The command below creates **one empty folder**,
`/mnt/cloud`, and makes you its owner. It changes nothing else on your computer.
You run it yourself, once. The installer never runs `sudo` for you, and clicking
**Set up…** in the panel never asks for your password.

You need this step when the installer shows a message that the folder does not
exist and prints a command that starts with `sudo`. (If you already have a
`/mnt/cloud` that is yours, the installer notices and skips this.)

1. **Leave the installer window open.** It is waiting for you.
2. **Open a second terminal:** press `Super` + `Enter` (`Super` is the Windows
   key; this is Omarchy's "Terminal" shortcut).
3. **Copy the command from the installer window and paste it into the second
   terminal.** To paste in a terminal press `Ctrl` + `Shift` + `V` (or `Super` +
   `V`). It is this one (the installer prints it for your folder):

   ```bash
   sudo install -d -o "$USER" -m 755 '/mnt/cloud'
   ```

   What it means: `sudo` runs one command as the administrator;
   `install -d` creates a folder; `-o "$USER"` makes you its owner, so mounts need
   no special rights later; `-m 755` lets everyone read it but only you change it.
4. **Press Enter, then type your password and press Enter again.** Nothing
   appears while you type your password, not even dots. That is normal; type it
   anyway.
5. **Success looks like nothing at all:** the command prints no message and you
   get your prompt back. (A wrong password shows `Sorry, try again.`; just type it
   again.) To be sure, run `ls -ld /mnt/cloud`: it should list your user name as
   the owner.
6. **Close the second terminal** (type `exit` and press Enter), go back to the
   installer window and **press Enter**. It checks the folder and says
   `mount root set to /mnt/cloud`. If it says again that the folder is not
   usable, redo step 3 and 4 and look for an error message in the second
   terminal.

Done: you never need to do this again. To undo it later, see
[Removing the mount folder](#removing-the-mount-folder).

## Why it is outside your home folder

Many tools that scan your home folder do not follow links by default: search
indexers, backup tools, `du` (disk usage), file pickers, editors' file watchers
and file managers. If the mount were inside your home folder, they would walk into
it and read it over the network. That is very slow, can grind the whole system,
and can cost download traffic or hit your provider's API limits. Because the real
mount is outside your home and `~/Cloud` only holds links, those tools leave it
alone, and you still find your cloud drives in `~/Cloud`.

The same reasoning is why offline folders and backups are refused when they
overlap this folder, `~/Cloud` or any mounted drive.

### A link does not get around this

It does not help to choose a mount folder that is itself a link (a "symbolic link")
leading into your home folder, for example `/mnt/cloud` made as a link to
`~/clouddrive`, or a folder that sits under such a link. The drive would then really
be mounted inside your home, and programs that look through your home (file search,
indexers, backup tools) would follow the link into the cloud drive and start
downloading everything. So the plugin looks at where the folder **really** ends up
and refuses it when that is your home folder or inside it. The installer, the app, the
panel and the mount itself all do this check.

For the same reason a mount point that is a link is refused: if `<mount folder>/gdrive`
is a link, rclone would mount wherever it points. Remove the link (`rm
/mnt/cloud/gdrive`; the plugin then creates it as a real folder), or choose another
mount folder.

## Why a `sudo` command is needed at all

`/mnt` belongs to the system, so your own user cannot create `/mnt/cloud` there.
The one-time command lets an administrator create it for you and hand it over.
Without the folder, no mount can start, and the panel and the app say "Mount root
not set up". They do not keep retrying.

## Choosing another folder

Use a simple path outside your home folder, such as `/mnt/cloud` or `/mnt/clouds`.
The rules, in plain words:

- It must be a full path starting with `/`, and not `/` itself.
- It must be outside your home folder (and not `~/Cloud`). A folder that is a link
  into your home, or sits under one, counts as inside it and is refused.
- Use only plain characters: letters, digits, `-`, `_`, `.` and `/`. No spaces, no
  quotes, no `$` or `%`, no trailing `/`, no `//`, no `.` or `..` parts. Keep it
  short (255 bytes at most). Ordinary text only: a path that is not valid UTF-8
  text is refused.
- The folder must already exist, and you must be able to write to it **and enter
  it** (open it as a folder). The `sudo install -d -o "$USER" …` command arranges
  both.

Two ways to choose it:

1. When the installer asks `Mount root [/mnt/cloud]`, type your path instead of
   pressing Enter. If it does not exist yet, the installer prints a `sudo install
   -d …` command for that path: follow the steps above with that command, then
   press Enter in the installer to check again (or type another path).
2. Without a question, use `--mount-root`:

   ```bash
   cd ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts
   ./install.sh --mount-root /mnt/clouds
   ```

   You should see `mount root set to /mnt/clouds`. The folder must already exist
   and be writable by you.

### How the installer decides

After installing the helper files, with no mount folder saved yet, the installer:

- **adopts silently** an existing `/mnt/cloud` that is a directory you own and can
  write to (so an existing install keeps working), saves it, and says so in one
  line;
- otherwise, in a terminal, proposes `/mnt/cloud` (Enter accepts) or takes another
  path. When the chosen path does not exist or is not writable, it prints the
  command that creates it, and you run it yourself;
- with no terminal, or with `--no-prompt`, writes nothing and prints those
  instructions. The panel then shows the notice, and **Set up…** runs the
  installer in a terminal where it can ask.

An already saved setting is never rewritten, except by `--mount-root`.
`--uninstall` keeps it.

### Changing the folder later

`./install.sh --mount-root PATH` refuses while any mount is enabled or running (it
names them), because a mount must be unmounted from the same path it was mounted
at. So:

1. Stop the mounts and stop them starting at login (once per remote; use your
   remote names):

   ```bash
   systemctl --user disable --now rclone-mount@gdrive.service
   ```

2. Run `./install.sh --mount-root NEWPATH` (create the new folder first, as in the
   steps above).
3. Enable the mounts again (press `m` in the app, or use the switch in the panel).

It moves no mount and rewrites no link. The `~/Cloud/<remote>` links that still
point into the old folder are listed for you to re-point (for example with
`ln -sfn /mnt/clouds/gdrive ~/Cloud/gdrive`). The app shows the mount folder and
checks it before enabling a mount, but does not change it; changing it goes through
`install.sh --mount-root`.

### Removing the mount folder

Uninstalling keeps the mount folder setting and the folder itself. If you want the
folder gone, stop and remove your remotes' mounts first, then
`sudo rmdir /mnt/cloud` (it only removes an empty folder).

## Technical details

- The setting is one line in `~/.config/omarchy-cloud/cloud.env` (a file in
  systemd's `EnvironmentFile` format, mode 600, in a folder of mode 700):

  ```
  OMARCHY_CLOUD_ROOT=/mnt/cloud
  ```

- `install.sh` is the only thing that writes it. The unit, the scripts, the app and
  the panel read it (parsed, never run as a script). Where a default is needed
  because the file is absent, it is `/mnt/cloud`.
- The mount unit uses it as `${OMARCHY_CLOUD_ROOT}/<remote>`. Before it mounts,
  the helper script `~/.local/bin/rclone-mount` (installed with the other helper
  scripts) reads `cloud.env` itself, exactly as the installer, the app and the
  panel do, and checks the folder. Two outcomes are possible:
  - The folder is valid but not an existing directory you can write to and enter
    (the usual case on a fresh computer): the start is **skipped**. The unit is
    neither failed nor restarted, so a machine without the folder does not retry
    every 15 s. The log says `rclone-mount: <remote>: not started: the mount root
    <folder> is not an existing directory you can write to and search; create it
    once with: sudo install -d -o "$USER" -m 755 '<folder>' (or choose another
    root: install.sh --mount-root PATH)`, and the panel and the app say the folder
    is not set up.
  - The folder setting is **refused** (invalid path, a path that leads into your
    home through a link, or the unit and the other readers disagree about it): the
    mount **fails right away and is not restarted** until you fix the setting. See
    [troubleshooting.md](troubleshooting.md#a-mount-fails-right-away-and-is-not-retried).
- The unit never creates anything under `/mnt`. The script makes only the
  per-remote folder `<folder>/<remote>` inside a folder you already own.
- `cloud.env` must hold the plain line `OMARCHY_CLOUD_ROOT=<path>` at the start of
  a line, with no quotes, indentation or spaces around it. systemd reads such a
  file its own way (it would strip quotes and whitespace), so a line written
  differently makes the mount fail rather than mount somewhere unexpected.
- A folder **inside your home folder is refused** everywhere (`install.sh`, the
  unit, the app, the panel). The same applies to `/`, a relative path, a path with a
  `.` or `..` part, one that is not valid UTF-8 text, one longer than 255 bytes, and
  one containing a space, a control character or any of the characters `$ % \ " '`
  or a backquote. The home folder is compared the same way everywhere: a doubled `/`
  and `/./` in it are ignored, and so are trailing `/` characters. The exact checks
  are pinned by `tests/fixtures/roots.tsv` (the folder rules) and
  `tests/fixtures/homes.tsv` (the home comparison), which the Rust, bash and
  JavaScript copies all run.
- A folder that is a **symbolic link (or sits under one) leading into your home
  folder** is refused everywhere too: the folder is resolved first (with
  `realpath`) and the result is compared with your home. A mount point
  `<folder>/<remote>` that is itself a symbolic link, to anywhere, is refused by the
  mount unit. If the folder or your home cannot be resolved within 5 seconds, the
  mount does not start and is retried (every 15 seconds); so it is when a leftover
  dead mount at the mount point cannot be cleared (see
  [troubleshooting.md](troubleshooting.md#a-mount-stopped-working-transport-endpoint-is-not-connected)).
- The mount folder, `/mnt/cloud` and `~/Cloud` are what the offline-folder and
  backup guards refuse to overlap.
