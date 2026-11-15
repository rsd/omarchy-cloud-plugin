# Development, tests, releasing and the marketplace

For people who change the plugin or publish it. Users do not need this page.

## Layout

The repository root is the plugin: `manifest.json`, `LICENSE`, `qmldir`,
`Model.js`, `BarWidget.qml`, `CloudState.qml` sit there. The pieces and what
they do: [how-it-works.md](how-it-works.md#the-pieces). The app is the crate in
`app/` (`main.rs`, `app.rs`, `ui.rs`, `cmd.rs`, `conf.rs`, `envfile.rs`,
`validate.rs`, `sys.rs`, `secret.rs`, and others); it calls `rclone-bisync` and
`rclone-backup` rather than reimplementing them. No symlink may exist inside the
plugin folder.

## Install from a local checkout

Work in the checkout and link it in under the plugin id. The folder name of the
checkout does not matter; the link must be named by the id:

```bash
ln -s ~/src/omarchy-cloud-plugin ~/.config/omarchy/plugins/io.github.rsd.cloud-mounts

omarchy plugin validate ~/src/omarchy-cloud-plugin   # the real path, not the link
omarchy-shell shell rescanPlugins      # a symlinked folder is not watched; rescan after adding or renaming files
omarchy restart shell                  # the shell caches QML: an edit only loads after a restart
omarchy plugin enable io.github.rsd.cloud-mounts right
```

Move it with `omarchy bar move io.github.rsd.cloud-mounts --section right` (see
`omarchy bar --help`).

The bar widget loads from the checkout, but the units, scripts and app are
copies: rerun `./install.sh` after editing `bin/`, `systemd/` or `app/`.

## Tests

```bash
bash tests/run.sh
```

Needs `node`, `bash` and the `omarchy` CLI. Besides the plugin suites below it runs:

- `tests/scripts-test.sh`: the helper scripts (including the `rclone-mount` guard), with stand-ins for `rclone`,
  `systemctl` and `notify-send`;
- `tests/install-test.sh`: `install.sh` in a scratch `HOME`, with stand-ins for
  `systemctl`, `cargo`, `uname` and `sudo`: copies, the record, identical-or-stop,
  the migration from a linked install, the prebuilt binary's checks, the
  mount-folder setup (adoption, the printed command, `--mount-root`, that `sudo`
  is never run), `--uninstall`, and that the repository holds no symlink;
  independent of whether `dist/` matches the sources;
- shellcheck over `install.sh`, `bin/*` and `tests/*.sh` (globbed at run time, so a
  new script is included; any finding fails), followed by a self-test that injects an
  unquoted variable into a scratch copy and checks that it is reported. It finds
  `shellcheck` via `$SHELLCHECK`, then `PATH`, then the newest mise install, and a
  candidate counts only if `--version` exits 0 (a mise shim with no version set does
  not). With none working it is reported **skipped**, not passed, and prints what it
  tried; set `SHELLCHECK` to a working binary to run it;
- the app's `cargo test` and `cargo clippy` (warnings fatal), built under
  `CARGO_TARGET_DIR=~/.cache/omarchy-cloud/target`, never inside the repo; skipped
  when `cargo` or `app/Cargo.lock` is missing.

Plugin suites (a suite that cannot run here is reported as **skipped**, not
passed):

- `omarchy plugin validate` (it does not check the folder name).
- `qmllint` from Qt 6 against the shell's own `qs.Ui` and `qs.Commons`
  (`/usr/share/omarchy/shell`, override with `OMARCHY_SHELL_DIR`), judged from its
  `--json` output by `tests/qmllint-check.js`, and a self-test that injects an
  unknown type into `BarWidget.qml` and `CloudState.qml`.
- A scratch Quickshell (`qs -p` on a temporary config) that loads `BarWidget.qml`
  by file URL, with a self-test (a duplicate property, a syntax error in the
  singleton); and one that creates the widget for real (its panel is never opened,
  so no window appears), which runs one read-only poll (`systemctl --user show`)
  and, through a stand-in panel hold, one `du`, and fails on any binding error.
  Skipped without `qs`, a Wayland session or a user manager. The scratch instance
  is stopped by its PID.
- `tests/model-test.js`: the model under node, including crafted remote names
  (`a;rm -rf ~`, `$(x)`, `-x`, `../x`, a newline, unicode, ...) that are rejected
  and appear in no command, the parsers against output captured from the real tools
  in the layout the widget receives (fuser's merged stdout from a live rclone mount,
  busy and idle), the keyboard cursor model, and source checks on the QML.
- `tests/process-pattern-test.sh`: the pending-upload script run through a real bash
  with printf stand-ins for `grep`, `head` and `wc`, asserting the arguments each
  receives for crafted `$HOME` values, then with the real `grep` on a fixture
  metadata tree; and the fuser script with a stand-in that splits its table across
  stdout and stderr as psmisc does, and one that hangs (cut by `timeout`).
- `tests/fixtures/roots.tsv` pins the mount-folder validator: the Rust, bash (the
  copies in `rclone-bisync`, `rclone-backup`, `rclone-mount` and `install.sh` must be
  identical) and JS implementations (the file holds raw non-UTF-8 bytes, so read it as bytes)
  all run its cases, as `tests/fixtures/names.tsv` does for names.
- `tests/fuser-live-test.js`: the busy check against the real `fuser`, read from
  stdout as the widget reads it, with a `sleep` the test starts holding its working
  folder on `/dev/shm` (busy) and on a non-mount temporary directory (could not
  check). Only that `sleep` is stopped, by its handle. Skipped without `fuser`,
  `timeout` or a `/dev/shm` mount point.
- `tests/manifest-test.js`: manifest, entry points, imports, no symlinks, and the
  folder name: passes when the checkout is named by the id; otherwise checks that
  `~/.config/omarchy/plugins/<id>` leads to this checkout, and is skipped when that
  path does not exist.

## Releasing

1. Bump the version in `app/Cargo.toml` (and `app/Cargo.lock`), `manifest.json`
   and `tests/manifest-test.js`; commit to `main`.
2. `git tag v0.3.5 && git push origin main v0.3.5` (with the new version number).
3. `.github/workflows/release.yml` runs two jobs.
   - **build** (token `contents: read`, not kept in the checkout) checks that the
     tag equals both versions, digests the tagged `app/` sources (`src_sha256`, the
     same pipeline as `install.sh`), builds `x86_64-unknown-linux-musl` with the
     pinned Rust toolchain (`cargo build --release --locked`), checks the binary is
     static, and uploads the binary, its `.sha256` and `BUILD-INFO` as an artifact;
     the dependencies' build scripts thus never run with a token that can write.
   - **publish** (`contents: write`, no cargo, no repository code) downloads the
     artifact, checks out `main`, checks that the tag still names the built commit
     and is on `main`, that `main` has not changed `app/` since the tag, and that
     the artifact is consistent (`sha256sum -c`, and `BUILD-INFO`'s version, commit
     and `src_sha256` recomputed from `main`), then commits `dist/` to `main` as
     `github-actions[bot]`. Any check failing stops it without pushing. Every
     action is pinned by commit SHA.

   The `dist/` commit is the only thing that writes the binary, so trust in the
   prebuilt rests on this publish job (see
   [install.md](how-it-works.md#installer-details)).
4. The marketplace listing is bound to a commit: submit the commit that carries
   `dist/` (the "Plugin verification" form, with its full 40-character SHA).

## The marketplace

The id `io.github.rsd.cloud-mounts` is permanent. Suggested listing: category
**System** (it installs and drives systemd user units, mounts and scheduled jobs;
it is plumbing for the machine rather than a productivity tool), tags `bar`,
`quickshell`, `system`. Expect the marketplace's automated scan to report review
capabilities, not failures: `installer` (`install.sh`), `service-management` (the
unit files and `systemctl --user` calls), `bundled-executable-binary` (`dist/`) and
`remote-build` (the cargo fallback). There is no symlink in the repository (checked
by `tests/install-test.sh` and `tests/manifest-test.js`), and nothing in `dist/` is
named `install*` or `setup*`. The root `preview.png` is the listing's preview
image.

The manifest's `barWidget.category` is "Files": that is the shell's widget-picker
group, which the marketplace ignores. The marketplace category (System, above)
comes from the submission form. They are different fields on purpose, so there is
no manifest change to make.

The marketplace installs with `omarchy plugin add <url> --enable`, which only
clones the plugin and never runs `install.sh`. For the submission's **Maintainer
notes** field:

> Please apply the `manual-setup` install override to this plugin. Besides the
> bar widget it needs `install.sh` to be run once, to install its systemd user
> units, three helper scripts and the `omarchy-cloud` TUI (a prebuilt x86_64
> binary in `dist/`, else built from source). Installed without that step the
> widget loads and stays functional: the panel shows "Installed parts: not
> installed - run install.sh" and a **Set up...** button that opens `install.sh`
> in a terminal and guides the user through it (including choosing the mount
> root, which `install.sh` asks for and never creates with `sudo`). Nothing is
> installed or enabled without that click.
