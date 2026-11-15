# Installing, updating and removing

This page covers getting Omarchy Cloud onto your computer, keeping it up to date
and removing it. The short version is in the [README](../README.md). Words in the
README's table (remote, mount folder, installed parts…) are used here. Installer
internals (checksums, what it never overwrites, upgrade notes) are in
[how-it-works.md](how-it-works.md#installer-details).

## Two parts, two steps

Omarchy Cloud arrives in two steps:

1. **The plugin** is the cloud icon and panel on the bar. `omarchy plugin add`
   downloads it to `~/.config/omarchy/plugins/io.github.rsd.cloud-mounts` and runs
   it from there.
2. **The installed parts** are the helper files the plugin needs: small background
   services (systemd "units"), three helper scripts and the Omarchy Cloud app. The
   installer, `install.sh`, copies them into your home folder.
   `omarchy plugin add` never runs it for you, so you run it once, by clicking
   **Set up…** in the panel or by hand.

Without step 2 the icon and panel work, but say **Installed parts: not
installed**. Nothing is installed or switched on without a click or a command from
you.

## What you need

- An Omarchy desktop (it provides the bar, the file manager and the terminal tools).
- `rclone`, `fuse3`, `psmisc` and `libnotify`. The command to install them is in the
  [README](../README.md#what-you-need). Everything else the plugin uses (standard
  tools such as `grep`, `sed`, `flock`, `systemd`) is already part of a normal
  Omarchy install.
- Only on a computer that is not x86_64 (a prebuilt app is provided for x86_64
  only): `cargo`, the Rust build tool, so the installer can build the app
  (`sudo pacman -S rust`).
- `systemd-analyze` is optional (it checks a backup's schedule when you set it up).

The full list with what each needs is in [reference.md](reference.md#requirements).
Administrator rights (`sudo`) are needed only once, to create the mount folder, if
the folder you choose is one you cannot write to (see
[mount-folder.md](mount-folder.md)). There is no network access at install time,
except what `cargo` downloads if the app has to be built.

## Install

```bash
omarchy plugin add https://github.com/rsd/omarchy-cloud-plugin.git --enable
```

This adds the plugin and puts it on the right of the bar. Then run the installer,
either way:

- Click the cloud icon, then **Set up…**. A small terminal window opens, runs the
  installer, and waits for Enter at the end so you can read the result.
- Or, in a terminal:

  ```bash
  cd ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts
  ./install.sh
  ```

The installer refuses to run as root, and you can run it again at any time. At the
end it sets up the mount folder: see [mount-folder.md](mount-folder.md). Then open
the app with **Configure…** or `omarchy-cloud`.

### Options

```
./install.sh [--no-build | --from-source] [--no-prompt | --mount-root PATH]
./install.sh --uninstall [--force]
```

| Option | Does |
|---|---|
| `--no-build` | Installs everything except the Omarchy Cloud app (an app that is already installed is kept) |
| `--from-source` | Builds the app from source instead of using the prebuilt one |
| `--no-prompt` | Never asks anything; if the mount folder is not set up it prints what to do |
| `--mount-root PATH` | Saves PATH as the mount folder without asking ([mount-folder.md](mount-folder.md)) |
| `--uninstall` | Removes what the installer installed (below) |
| `--force` | With `--uninstall`: continue although some mounts start at login |

`./install.sh --help` prints the usage.

### What it installs, and where

Everything is **copied** into your home folder (nothing outside it), so moving or
removing the plugin folder changes nothing that is running.

| What | Where |
|---|---|
| Six background-service definitions | `~/.config/systemd/user/` |
| Three helper scripts: `rclone-bisync`, `rclone-backup` and `rclone-mount` | `~/.local/bin/` |
| The Omarchy Cloud app, `omarchy-cloud` | `~/.local/bin/` |
| A record of the above, with the version | `~/.local/state/omarchy-cloud/installed-files` |

It also creates the settings folders `~/.config/rclone-bisync`,
`~/.config/rclone-backup` and `~/.config/omarchy-cloud`, and **enables and starts
nothing**.

### If the installer is waiting or stops

- It waits up to a minute if a sync or backup is running, and if it is still
  running then it stops with exit code 75 and changes nothing: run it again when
  the sync has finished.
- If a file it would replace is not one it installed (or you edited it), it stops
  with nothing changed and names the file: move or delete that file, then run it
  again.
- On a computer that is not x86_64 without Rust installed, it says so and stops;
  install Rust, or use `--no-build`.

## Updating

The plugin (the bar icon) runs from its plugin folder, but the installed parts are
copies, so `omarchy plugin update` does not change them. After an update, run
`./install.sh` again, or click **Update installed parts** in the panel. It opens
the installer in a small terminal window, which waits for Enter at the end so you
can read the result.

**How you notice.** When the installed parts are of another version than the
plugin, are from a very old version, or are missing, the cloud icon gets a small
badge and the panel shows a notice with the button. The panel checks when it
opens, not continuously. The app shows a one-line notice too.

## Uninstalling

```bash
cd ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts
./install.sh --uninstall
omarchy plugin remove io.github.rsd.cloud-mounts
```

The first command removes the installed parts; the second removes the plugin
itself (it asks to confirm; `--yes` skips that).

- `--uninstall` refuses while offline folders or backups are switched on, and
  prints the commands to switch them off first.
- It refuses while mounts that start at login are enabled, unless you add
  `--force` (they then stop mounting at the next login).

It **keeps** your settings (`~/.config/rclone-bisync`, `~/.config/rclone-backup`,
the mount folder setting `~/.config/omarchy-cloud/cloud.env`, rclone's own
configuration), the on/off state of your remotes, offline folders and backups,
their state and cache, and every synced, mounted or backed-up file. Remove those
by hand if you want them gone.
