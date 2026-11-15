#!/bin/bash

# install.sh, hermetic: stand-ins for systemctl, cargo and uname come first on
# PATH and record their argv; HOME and the XDG_* dirs point into a scratch
# dir. Nothing outside the scratch dir is written, no unit is touched, and the
# real cargo is never run.
#
#   1. bash -n, and shellcheck when installed; option errors.
#   2. Fresh install: regular copies (not links), modes 644/755, the manifest
#      (one `<sha256>  <path>` line per file); idempotent rerun; an existing
#      ~/.local/bin keeps its mode.
#   3. Identical-or-stop: an identical file is taken over, a foreign file or
#      symlink stops the install before any change, and so does an installed
#      file edited since (its sha256 no longer the recorded one).
#   4. Migration from a link install laid out like a live one (templates,
#      instance aliases and *.wants/ links into the repo, mount wants links to
#      the installed template, drop-ins, a legacy binary marker holding the
#      hash twice without a newline): copies, links re-pointed, the rest kept.
#   5. The binary's source: the prebuilt dist/ binary when its sha256,
#      version and app source digest match (on x86_64), a sha256 mismatch
#      stops, a version or source digest mismatch, another arch or
#      --from-source builds, neither available is a clear
#      message; a foreign ~/.local/bin/omarchy-cloud stops it.
#   6. --uninstall: the refusals while instances are enabled, then only the
#      manifest's files that still match (and an old install's links).
#   7. The installed-version record: the manifest's #version= / #repo=
#      header lines (from manifest.json), a 0.3.2 manifest without them
#      upgraded, a version-only change recorded, an invalid version refused.
#   8. Running syncs and backups: a held bisync or backup lock (in a scratch
#      XDG_RUNTIME_DIR) makes install.sh wait, then stop with exit 75 and
#      nothing changed; a released one lets it install.
#   9. The repository holds no symlinks and gets no build output.
#
# The checks are eval'd single-quoted strings, expanded when they run.
# shellcheck disable=SC2016,SC2034

set -o pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
INSTALL=$PLUGIN_DIR/install.sh
FAILURES=0
SCRATCH=$(mktemp -d) || exit 1
HOLDER= # the PID of a background lock holder (section 8), stopped on exit
trap '[[ -n $HOLDER ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }
check() { # check <description> <command...>
  local d=$1
  shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}

# --- stand-ins --------------------------------------------------------------
STUBS=$SCRATCH/stubs
mkdir -p "$STUBS"
cat >"$STUBS/systemctl" <<'EOF'
#!/bin/bash
{ printf 'systemctl'; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/systemctl"
exit 0
EOF
cat >"$STUBS/cargo" <<'EOF'
#!/bin/bash
{ printf 'cargo'; printf ' %q' "$@"; printf ' CARGO_TARGET_DIR=%q\n' "$CARGO_TARGET_DIR"; } >>"$FAKE_LOG/cargo"
mkdir -p "$CARGO_TARGET_DIR/release" && printf '#!/bin/sh\necho tui %s\n' "${FAKE_BUILD:-}" >"$CARGO_TARGET_DIR/release/omarchy-cloud"
EOF
cat >"$STUBS/uname" <<'EOF'
#!/bin/bash
[[ $# == 1 && $1 == -m && -n ${FAKE_ARCH:-} ]] && { echo "$FAKE_ARCH"; exit 0; }
exec /usr/bin/uname "$@"
EOF
chmod +x "$STUBS"/*
# The same stand-ins without cargo, on a PATH without the real one.
NOCARGO=$SCRATCH/nocargo
mkdir -p "$NOCARGO"
cp "$STUBS/systemctl" "$STUBS/uname" "$NOCARGO/"
NOCARGO_PATH=$NOCARGO:/usr/bin:/bin
export PATH="$STUBS:$PATH"

# fresh: a new scratch HOME with empty logs; clears the stand-ins' knobs.
N=0
fresh() {
  N=$((N + 1))
  T=$SCRATCH/t$N
  mkdir -p "$T/home/.config" "$T/state" "$T/cache" "$T/log" "$T/run"
  # XDG_RUNTIME_DIR too: the real one may hold the locks of real runs.
  export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_STATE_HOME=$T/state \
    XDG_CACHE_HOME=$T/cache FAKE_LOG=$T/log XDG_RUNTIME_DIR=$T/run
  unset FAKE_BUILD FAKE_ARCH OMARCHY_CLOUD_INSTALL_WAIT_S
  UD=$XDG_CONFIG_HOME/systemd/user BD=$HOME/.local/bin
  MAN=$XDG_STATE_HOME/omarchy-cloud/installed-files
  MARK=$XDG_STATE_HOME/omarchy-cloud/installed-binary.sha256
}
# runc <cmd...>: OUT = stdout+stderr, RC = status.
runc() { OUT=$("$@" 2>&1); RC=$?; }
log() { cat "$FAKE_LOG/$1" 2>/dev/null; }
q() { printf ' %q' "$@"; }
rc_is() { ((RC == $1)); }
sha() { sha256sum "$1" | cut -d' ' -f1; }
only_reload() { [[ $(log systemctl) == "systemctl --user daemon-reload" ]]; }

# copies_ok [repo]: every systemd/ and bin/ file is a regular copy with its mode.
copies_ok() {
  local r=${1:-$PLUGIN_DIR} f
  for f in "$r"/systemd/*; do
    [[ -f $UD/${f##*/} && ! -L $UD/${f##*/} ]] && cmp -s "$f" "$UD/${f##*/}" &&
      [[ $(stat -c %a "$UD/${f##*/}") == 644 ]] || return 1
  done
  for f in "$r"/bin/*; do
    [[ -f $BD/${f##*/} && ! -L $BD/${f##*/} ]] && cmp -s "$f" "$BD/${f##*/}" &&
      [[ $(stat -c %a "$BD/${f##*/}") == 755 ]] || return 1
  done
}
# manifest_ok <path...>: the manifest lists exactly these paths, each with
# the sha256 the file has now (after the two header lines, checked by
# header_ok).
manifest_ok() {
  local want got p
  want=$(for p; do printf '%s  %s\n' "$(sha "$p")" "$p"; done | sort -k 2)
  got=$(tail -n +3 "$MAN" 2>/dev/null)
  [[ -n $want && $got == "$want" ]] || { diff <(echo "$want") <(echo "$got") | sed "s/^/     /" | head -6; return 1; }
}
# header_ok [repo] [version]: the manifest's first two lines are the version
# record (default: this checkout and its manifest.json version).
header_ok() {
  local want
  want=$(printf '#version=%s\n#repo=%s' "${2:-$PLUGIN_VERSION}" "${1:-$PLUGIN_DIR}")
  [[ $(head -n 2 "$MAN" 2>/dev/null) == "$want" ]] || { head -n 2 "$MAN" 2>/dev/null | sed "s/^/     got /"; return 1; }
}
PLUGIN_VERSION=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_DIR/manifest.json" | head -n 1)
all_files() { # the paths install.sh installs from a repo, besides the binary
  local r=${1:-$PLUGIN_DIR} f
  for f in "$r"/systemd/*; do echo "$UD/${f##*/}"; done
  for f in "$r"/bin/*; do echo "$BD/${f##*/}"; done
}
manifest_all() { # manifest_all <repo> [extra path...]: manifest_ok on all_files <repo> and the extras
  local -a f
  mapfile -t f < <(all_files "$1")
  shift
  manifest_ok "${f[@]}" "$@"
}
no_link_into() { # no_link_into <dir>: nothing under UD or BD resolves into it
  local l
  while IFS= read -r l; do
    [[ $(readlink -f "$l") == "$1"/* ]] && return 1
  done < <(find "$UD" "$BD" -type l 2>/dev/null)
  return 0
}
snapshot() { # a listing of UD, BD and the state dir: types, link targets, hashes
  find "$UD" "$BD" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" 2>/dev/null | sort | while IFS= read -r p; do
    if [[ -L $p ]]; then echo "L $p -> $(readlink "$p")"
    elif [[ -f $p ]]; then echo "F $p $(stat -c %a "$p") $(sha "$p")"
    else echo "D $p $(stat -c %a "$p")"; fi
  done
}

# --- 1. syntax, lint, options -------------------------------------------------
check "bash -n install.sh" bash -n "$INSTALL"
check "install.sh is executable" test -x "$INSTALL"
SHELLCHECK=$(command -v shellcheck)
if [[ -n $SHELLCHECK ]] && "$SHELLCHECK" --version >/dev/null 2>&1; then
  check "shellcheck" "$SHELLCHECK" "$INSTALL" "${BASH_SOURCE[0]}"
else
  echo "skip shellcheck (not installed or not runnable)"
fi
fresh
for args in "--bogus" "--force" "--no-build --from-source" "--uninstall --from-source" "--uninstall --no-build"; do
  # shellcheck disable=SC2086
  runc "$INSTALL" $args
  check "install.sh $args: exit 64, nothing written" eval 'rc_is 64 && [[ ! -e $UD && ! -e $BD && ! -e $MAN ]]'
done

# --- 2. fresh install -------------------------------------------------------------
fresh
runc "$INSTALL" --no-build
check "install: exit 0" rc_is 0
check "install: every systemd/ and bin/ file copied (regular files, 644 / 755), none linked" \
  eval 'copies_ok && [[ -z $(find "$UD" "$BD" -type l) ]]'
check "install: the manifest records each installed file with its sha256" manifest_all "$PLUGIN_DIR"
check "install: the manifest starts with #version=<manifest.json version> and #repo=<checkout>" header_ok
check "install: no temporary file left behind" eval '[[ -z $(find "$UD" "$BD" "$XDG_STATE_HOME" -name ".*") ]]'
check "install: config dirs created 700" \
  eval '[[ $(stat -c %a "$XDG_CONFIG_HOME/rclone-bisync") == 700 && $(stat -c %a "$XDG_CONFIG_HOME/rclone-backup") == 700 ]]'
check "install: daemon-reload only, nothing enabled or started" only_reload
check "install --no-build: no cargo, no binary" eval '[[ ! -s $FAKE_LOG/cargo && ! -e $BD/omarchy-cloud ]]'
snapshot >"$T/before"
: >"$FAKE_LOG/systemctl"
runc "$INSTALL" --no-build
check "install again: idempotent (exit 0, nothing reinstalled, same files and manifest)" \
  eval 'rc_is 0 && [[ $OUT != *installed\ /* ]] && cmp -s <(snapshot) "$T/before"'

fresh
mkdir -p "$BD"
chmod 700 "$BD"
runc "$INSTALL" --no-build
check "install: an existing ~/.local/bin keeps its mode (700)" eval 'rc_is 0 && [[ $(stat -c %a "$BD") == 700 ]]'

# --- 3. identical-or-stop -----------------------------------------------------------
fresh
mkdir -p "$UD" "$BD"
cp "$PLUGIN_DIR/bin/rclone-backup" "$BD/rclone-backup"
chmod 700 "$BD/rclone-backup"
runc "$INSTALL" --no-build
check "install: an identical regular file is taken over (mode set, recorded)" \
  eval 'rc_is 0 && copies_ok && grep -qF "  $BD/rclone-backup" "$MAN"'

fresh
mkdir -p "$UD"
printf '[Service]\nExecStart=/usr/bin/rclone mount x: /y --vfs-cache-max-size 10G\n' >"$UD/rclone-mount@.service"
snapshot >"$T/before"
runc "$INSTALL" --no-build
check "install: a differing foreign file stops it (exit 1) and is named, with a diff command" \
  eval 'rc_is 1 && [[ $OUT == *"$UD/rclone-mount@.service"*"diff -u"* ]]'
check "install stopped: nothing changed (no copy, no manifest, no reload)" \
  eval 'cmp -s <(snapshot) "$T/before" && [[ ! -s $FAKE_LOG/systemctl ]]'

fresh
mkdir -p "$BD"
ln -s /usr/bin/true "$BD/rclone-bisync"
runc "$INSTALL" --no-build
check "install: a foreign symlink in the way stops it" eval 'rc_is 1 && [[ $(readlink "$BD/rclone-bisync") == /usr/bin/true && ! -e $MAN ]]'

fresh
runc "$INSTALL" --no-build
echo "# my local edit" >>"$UD/rclone-mount@.service"
snapshot >"$T/before"
: >"$FAKE_LOG/systemctl"
runc "$INSTALL" --no-build
check "install: an installed file edited since stops it (exit 1) and is named" \
  eval 'rc_is 1 && [[ $OUT == *"$UD/rclone-mount@.service"* ]]'
check "install stopped by an edited file: nothing changed" eval 'cmp -s <(snapshot) "$T/before" && [[ ! -s $FAKE_LOG/systemctl ]]'

# A recorded file whose source changed (an update) is replaced.
fresh
runc "$INSTALL" --no-build
printf '# an older version\n' >"$UD/rclone-bisync@.timer"
sed -i "s|^[0-9a-f]\{64\}  $UD/rclone-bisync@.timer\$|$(sha "$UD/rclone-bisync@.timer")  $UD/rclone-bisync@.timer|" "$MAN"
runc "$INSTALL" --no-build
check "install: a recorded file with an older content is updated, the manifest follows" \
  eval 'rc_is 0 && copies_ok && [[ $OUT == *"installed $UD/rclone-bisync@.timer"* ]] && manifest_all "$PLUGIN_DIR"'

# --- 4. migration from a link install ------------------------------------------------
fresh
mkdir -p "$UD/default.target.wants" "$UD/timers.target.wants" "$BD" "$XDG_STATE_HOME/omarchy-cloud"
for f in "$PLUGIN_DIR"/systemd/*; do ln -s "$f" "$UD/${f##*/}"; done
for f in "$PLUGIN_DIR"/bin/*; do ln -s "$f" "$BD/${f##*/}"; done
S=$PLUGIN_DIR/systemd
ln -s "$S/rclone-bisync@.path" "$UD/rclone-bisync@personal.path"
ln -s "$S/rclone-bisync@.timer" "$UD/rclone-bisync@personal.timer"
ln -s "$S/rclone-backup@.timer" "$UD/rclone-backup@team-vaults.timer"
ln -s "$S/rclone-bisync@.path" "$UD/default.target.wants/rclone-bisync@personal.path"
ln -s "$S/rclone-bisync@.timer" "$UD/timers.target.wants/rclone-bisync@personal.timer"
ln -s "$S/rclone-backup@.timer" "$UD/timers.target.wants/rclone-backup@team-vaults.timer"
for r in onedrive gdrive; do
  ln -s "$UD/rclone-mount@.service" "$UD/default.target.wants/rclone-mount@$r.service"
done
ln -s ../rclone-bisync@.timer "$UD/timers.target.wants/rclone-bisync@rel.timer.bak" # relative, to the template link
mkdir -p "$UD/rclone-bisync@personal.path.d" "$UD/rclone-backup@team-vaults.timer.d"
echo "[Path]" >"$UD/rclone-bisync@personal.path.d/pair.conf"
echo "[Timer]" >"$UD/rclone-backup@team-vaults.timer.d/job.conf"
ln -s /usr/lib/systemd/user/foo.service "$UD/default.target.wants/foreign.service"
printf '#!/bin/sh\necho old tui\n' >"$BD/omarchy-cloud"
chmod 755 "$BD/omarchy-cloud"
h=$(sha "$BD/omarchy-cloud")
printf '%s%s' "$h" "$h" >"$MARK" # the live marker: the hash twice, no newline
DROPINS=$(cd "$UD" && find ./*.d -type f -exec sha256sum {} + | sort)
FAKE_BUILD=v2 runc "$INSTALL"
check "migrate: exit 0" rc_is 0
check "migrate: templates and scripts are now regular copies" copies_ok
check "migrate: instance aliases re-pointed at the installed templates" \
  eval '[[ $(readlink "$UD/rclone-bisync@personal.path") == "$UD/rclone-bisync@.path" && $(readlink "$UD/rclone-bisync@personal.timer") == "$UD/rclone-bisync@.timer" && $(readlink "$UD/rclone-backup@team-vaults.timer") == "$UD/rclone-backup@.timer" ]]'
check "migrate: *.wants/ links re-pointed at the installed templates" \
  eval '[[ $(readlink "$UD/default.target.wants/rclone-bisync@personal.path") == "$UD/rclone-bisync@.path" && $(readlink "$UD/timers.target.wants/rclone-bisync@personal.timer") == "$UD/rclone-bisync@.timer" && $(readlink "$UD/timers.target.wants/rclone-backup@team-vaults.timer") == "$UD/rclone-backup@.timer" ]]'
check "migrate: links that already pointed at the installed template are unchanged" \
  eval '[[ $(readlink "$UD/default.target.wants/rclone-mount@onedrive.service") == "$UD/rclone-mount@.service" && $(readlink "$UD/timers.target.wants/rclone-bisync@rel.timer.bak") == ../rclone-bisync@.timer ]]'
check "migrate: a foreign link and the drop-ins are untouched" \
  eval '[[ $(readlink "$UD/default.target.wants/foreign.service") == /usr/lib/systemd/user/foo.service && $(cd "$UD" && find ./*.d -type f -exec sha256sum {} + | sort) == "$DROPINS" ]]'
check "migrate: nothing under the unit or bin dir resolves into the repo" no_link_into "$PLUGIN_DIR"
check "migrate: the doubled legacy marker is accepted: the old binary is replaced" \
  eval '[[ $(cat "$BD/omarchy-cloud") == *"tui v2"* ]]'
check "migrate: the marker moved into the manifest (binary recorded, marker removed)" \
  eval 'manifest_all "$PLUGIN_DIR" "$BD/omarchy-cloud" && [[ ! -e $MARK ]]'
check "migrate: daemon-reload only, says nothing needs restarting" \
  eval 'only_reload && [[ $OUT == *"nothing needs restarting"* ]]'
check "migrate: no temporary link left behind" eval '[[ -z $(find "$UD" -name "*omarchy-cloud-tmp*" -o -name ".*" -type f) ]]'
snapshot >"$T/before"
FAKE_BUILD=v2 runc "$INSTALL"
check "migrate, again: idempotent" eval 'rc_is 0 && [[ $OUT != *installed\ /* && $OUT != *re-pointed* ]] && cmp -s <(snapshot) "$T/before"'

# A legacy marker that names another binary: still refused.
fresh
mkdir -p "$BD" "$XDG_STATE_HOME/omarchy-cloud"
printf '#!/bin/sh\necho mine\n' >"$BD/omarchy-cloud"
printf '%064d' 0 >"$MARK"
runc "$INSTALL"
check "install: a binary that is not the one the legacy marker names stops it" \
  eval 'rc_is 1 && [[ $OUT == *"$BD/omarchy-cloud"*"not the binary"* && $(cat "$BD/omarchy-cloud") == *mine* ]]'

# --- 5. the binary's source --------------------------------------------------------
# A scratch copy of the repo with a dist/ (the real repo never gets one here).
R2=$SCRATCH/repo
mkdir -p "$R2/app" "$R2/dist"
cp -r "$PLUGIN_DIR/install.sh" "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/systemd" "$PLUGIN_DIR/bin" "$R2/"
cp -r "$PLUGIN_DIR/app/Cargo.toml" "$PLUGIN_DIR/app/Cargo.lock" "$PLUGIN_DIR/app/src" "$R2/app/"
VERSION=$(sed -n '/^\[package\]/,/^\[/s/^version *= *"\([^"]*\)".*/\1/p' "$R2/app/Cargo.toml" | head -n 1)
PB=omarchy-cloud-x86_64-linux-musl
# src_digest: the app source digest as defined (sha256 of the `sha256sum`
# lines of app/Cargo.toml, app/Cargo.lock, app/src/*.rs by relative path in
# C-locale order), computed here another way than install.sh and the workflow
# do (app/src is flat in the fixture).
src_digest() {
  (cd "$R2" && export LC_ALL=C && sha256sum app/Cargo.lock app/Cargo.toml app/src/*.rs | sha256sum | cut -d' ' -f1)
}
dist() { # dist [version] [src_sha256]: a consistent prebuilt (src_sha256 "-": none)
  local src=${2:-$(src_digest)}
  printf '#!/bin/sh\necho prebuilt\n' >"$R2/dist/$PB"
  (cd "$R2/dist" && sha256sum "$PB" >"$PB.sha256")
  {
    printf 'version=%s\ncommit=0123456789abcdef0123456789abcdef01234567\n' "${1:-$VERSION}"
    [[ $src == - ]] || printf 'src_sha256=%s\n' "$src"
    printf 'rustc=1.99.1\ntarget=x86_64-unknown-linux-musl\n'
  } >"$R2/dist/BUILD-INFO"
}
check "fixture: app/Cargo.toml has a version" eval '[[ -n $VERSION ]]'
check "fixture: app/src is flat (src_digest's glob covers it)" eval '[[ -z $(find "$R2/app/src" -mindepth 1 -type d) ]]'
# The digest pipeline is one line, the same in install.sh and in the workflow
# (twice there: written by the build job, checked by the publish job).
DIGEST_LINE="{ echo app/Cargo.toml; echo app/Cargo.lock; find app/src -type f -name '*.rs'; } | LC_ALL=C sort | xargs -d '\\n' sha256sum -- | sha256sum"
check "source digest: the same pipeline in install.sh and release.yml (build and publish)" \
  eval 'grep -qF -- "$DIGEST_LINE" "$INSTALL" && (($(grep -cF -- "$DIGEST_LINE" "$PLUGIN_DIR/.github/workflows/release.yml") == 2))'
check "source digest: release.yml writes it into BUILD-INFO as src_sha256=" \
  eval 'grep -qF "echo \"src_sha256=\$SRC_SHA256\"" "$PLUGIN_DIR/.github/workflows/release.yml"'

fresh
dist
FAKE_ARCH=x86_64 runc "$R2/install.sh"
check "prebuilt: sha256 and version match on x86_64: installed, no cargo" \
  eval 'rc_is 0 && cmp -s "$R2/dist/$PB" "$BD/omarchy-cloud" && [[ $(stat -c %a "$BD/omarchy-cloud") == 755 && ! -s $FAKE_LOG/cargo && $OUT == *"using the prebuilt"* ]]'
check "prebuilt: recorded in the manifest" manifest_all "$R2" "$BD/omarchy-cloud"

fresh
dist
echo tampered >>"$R2/dist/$PB"
FAKE_ARCH=x86_64 runc "$R2/install.sh"
check "prebuilt: a sha256 mismatch stops it (exit 1), no fallback to cargo, nothing changed" \
  eval 'rc_is 1 && [[ $OUT == *"does not match"* && ! -s $FAKE_LOG/cargo && ! -e $UD && ! -e $BD && ! -e $MAN ]]'
dist
sed -i 's/^\([0-9a-f]*\)  .*/\1  other-file/' "$R2/dist/$PB.sha256"
FAKE_ARCH=x86_64 runc "$R2/install.sh"
check "prebuilt: a .sha256 naming another file stops it too" eval 'rc_is 1 && [[ $OUT == *"does not match"* && ! -s $FAKE_LOG/cargo ]]'

fresh
dist 0.0.1
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: another version builds with cargo instead (and says why)" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && $OUT == *"version 0.0.1"* ]]'
check "build: cargo build --release --locked, target dir in the cache" \
  eval '[[ $(log cargo) == "cargo$(q build --release --locked --manifest-path "$R2/app/Cargo.toml") CARGO_TARGET_DIR=$(printf %q "$XDG_CACHE_HOME/omarchy-cloud/target")" ]]'

fresh
dist
echo '// changed since the release' >>"$R2/app/src/main.rs"
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: same version, other app/ sources (src_sha256 mismatch): builds with cargo and says why" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && -s $FAKE_LOG/cargo && $OUT == *"building omarchy-cloud from source (the prebuilt binary was built from other app/ sources"* ]]'
fresh
FAKE_ARCH=x86_64 PATH=$NOCARGO_PATH runc "$R2/install.sh"
check "prebuilt: src_sha256 mismatch and no cargo: exit 1, says why, suggests Rust or --no-build, nothing changed" \
  eval 'rc_is 1 && [[ $OUT == *"other app/ sources"*"cargo was not found"*"Install Rust"*"--no-build"* && ! -e $UD && ! -e $BD && ! -e $MAN ]]'
FAKE_ARCH=x86_64 PATH=$NOCARGO_PATH runc "$R2/install.sh" --no-build
check "prebuilt: src_sha256 mismatch, --no-build: installs the rest, no TUI" eval 'rc_is 0 && copies_ok "$R2" && [[ ! -e $BD/omarchy-cloud ]]'
cp "$PLUGIN_DIR/app/src/main.rs" "$R2/app/src/main.rs"
mkdir "$R2/app/src/sub"
echo '// a new module' >"$R2/app/src/sub/new.rs"
fresh
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: a new .rs in a subdir of app/src changes the digest (builds)" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && $OUT == *"other app/ sources"* ]]'
rm -r "$R2/app/src/sub"
fresh
rm "$R2/app/Cargo.lock"
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: an unreadable source (no Cargo.lock) never matches (builds)" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && $OUT == *"this checkout unreadable"* ]]'
cp "$PLUGIN_DIR/app/Cargo.lock" "$R2/app/"

fresh
dist "" -
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: a BUILD-INFO without src_sha256 (an older release) builds with cargo" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && $OUT == *"src_sha256=none"* ]]'

fresh
dist
rm "$R2/dist/BUILD-INFO"
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: no BUILD-INFO builds with cargo" eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* ]]'

fresh
dist
FAKE_ARCH=aarch64 FAKE_BUILD=src runc "$R2/install.sh"
check "prebuilt: another arch builds with cargo" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && $OUT == *"x86_64 only"* ]]'

fresh
dist
FAKE_ARCH=x86_64 FAKE_BUILD=src runc "$R2/install.sh" --from-source
check "--from-source: builds with cargo although the prebuilt fits" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui src"* && -s $FAKE_LOG/cargo ]]'
# Switching from the prebuilt to a build replaces the recorded binary.
FAKE_ARCH=x86_64 runc "$R2/install.sh"
check "prebuilt after a source build: the recorded binary is replaced" \
  eval 'rc_is 0 && cmp -s "$R2/dist/$PB" "$BD/omarchy-cloud" && manifest_all "$R2" "$BD/omarchy-cloud"'

fresh
dist
FAKE_ARCH=aarch64 PATH=$NOCARGO_PATH runc "$R2/install.sh"
check "neither (aarch64, no cargo): exit 1, says the prebuilt is x86_64 only and cargo is missing, nothing changed" \
  eval 'rc_is 1 && [[ $OUT == *"x86_64 only"*"cargo was not found"*"--no-build"* && ! -e $UD && ! -e $BD ]]'
rm -f "$R2/dist/"*
FAKE_ARCH=x86_64 PATH=$NOCARGO_PATH runc "$R2/install.sh"
check "neither (no dist/, no cargo): exit 1, says what to install" \
  eval 'rc_is 1 && [[ $OUT == *"no prebuilt binary"*"Install Rust"* && ! -e $UD ]]'
FAKE_ARCH=x86_64 PATH=$NOCARGO_PATH runc "$R2/install.sh" --no-build
check "--no-build needs neither" eval 'rc_is 0 && [[ ! -e $BD/omarchy-cloud ]]'

# The installed binary against the build.
fresh
runc "$INSTALL"
check "build: binary installed 755, recorded" \
  eval 'rc_is 0 && [[ -f $BD/omarchy-cloud && ! -L $BD/omarchy-cloud && $(stat -c %a "$BD/omarchy-cloud") == 755 ]] && grep -qF "  $BD/omarchy-cloud" "$MAN"'
FAKE_BUILD=v2 runc "$INSTALL"
check "build: a different build replaces the recorded binary" \
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui v2"* ]] && manifest_all "$PLUGIN_DIR" "$BD/omarchy-cloud"'
cp "$BD/omarchy-cloud" "$T/ours.bak"
printf '#!/bin/sh\necho someone else\n' >"$BD/omarchy-cloud"
cp "$BD/omarchy-cloud" "$T/foreign"
rm -f "$BD/rclone-bisync"
: >"$FAKE_LOG/systemctl"
FAKE_BUILD=v3 runc "$INSTALL"
check "build: a foreign omarchy-cloud stops it (exit 1) and is named" \
  eval 'rc_is 1 && [[ $OUT == *"$BD/omarchy-cloud"*"not the binary"* ]]'
check "install stopped by the binary: it is untouched and nothing else changed" \
  eval 'cmp -s "$T/foreign" "$BD/omarchy-cloud" && [[ ! -e $BD/rclone-bisync && ! -s $FAKE_LOG/systemctl ]]'
runc "$INSTALL" --no-build
check "--no-build: a foreign omarchy-cloud is left alone and not recorded" \
  eval 'rc_is 0 && cmp -s "$T/foreign" "$BD/omarchy-cloud" && copies_ok && ! grep -qF "  $BD/omarchy-cloud" "$MAN"'
ln -sf "$T/ours.bak" "$BD/omarchy-cloud"
FAKE_BUILD=v2 runc "$INSTALL"
check "build: a symlink at omarchy-cloud stops it" eval 'rc_is 1 && [[ -L $BD/omarchy-cloud ]]'
rm -f "$BD/omarchy-cloud"
FAKE_BUILD=v2 runc "$INSTALL"
check "build: identical to the build is taken over" eval 'rc_is 0 && manifest_all "$PLUGIN_DIR" "$BD/omarchy-cloud"'
runc "$INSTALL" --no-build
check "--no-build: the recorded binary stays recorded" eval 'rc_is 0 && manifest_all "$PLUGIN_DIR" "$BD/omarchy-cloud"'

# --- 6. --uninstall -------------------------------------------------------------------
mkdir -p "$UD/default.target.wants"
ln -s "$UD/rclone-mount@.service" "$UD/default.target.wants/rclone-mount@onedrive.service"
mkdir -p "$XDG_CONFIG_HOME/rclone-bisync"
echo "LOCAL=~/x" >"$XDG_CONFIG_HOME/rclone-bisync/p.conf"
echo keep >"$UD/my-own.service"
snapshot >"$T/before"
runc "$INSTALL" --uninstall
check "uninstall with an enabled mount: refused (exit 1), names it, removes nothing" \
  eval 'rc_is 1 && [[ $OUT == *"systemctl --user disable --now rclone-mount@onedrive.service"* ]] && cmp -s <(snapshot) "$T/before"'
mkdir -p "$UD/timers.target.wants"
ln -s "$UD/rclone-bisync@.timer" "$UD/timers.target.wants/rclone-bisync@vault-A.timer"
snapshot >"$T/before"
runc "$INSTALL" --uninstall --force
check "uninstall --force with a bisync instance enabled: still refused, removes nothing" \
  eval 'rc_is 1 && [[ $OUT == *"disable --now rclone-bisync@vault-A.timer"* ]] && cmp -s <(snapshot) "$T/before"'
rm "$UD/timers.target.wants/rclone-bisync@vault-A.timer"
ln -s "$UD/rclone-bisync@.path" "$UD/rclone-bisync@vault-A.path" # an alias left by an instance
echo "# edited" >>"$UD/rclone-backup@.service"
printf '#!/bin/sh\n' >"$BD/omarchy-cloud"
: >"$FAKE_LOG/systemctl"
runc "$INSTALL" --uninstall --force
check "uninstall --force with an enabled mount: exit 0, names the mount" \
  eval 'rc_is 0 && [[ $OUT == *"--force"*"rclone-mount@onedrive.service"* ]]'
check "uninstall: the recorded files that still match are removed" \
  eval '[[ ! -e $UD/rclone-mount@.service && ! -e $UD/rclone-bisync@.path && ! -e $BD/rclone-bisync && ! -e $BD/rclone-backup ]]'
check "uninstall: an edited unit and a replaced binary are left, and named" \
  eval '[[ -f $UD/rclone-backup@.service && $(cat "$BD/omarchy-cloud") == "#!/bin/sh" && $OUT == *"left $UD/rclone-backup@.service"* && $OUT == *"left $BD/omarchy-cloud"* ]]'
check "uninstall: enablement links, config, other units kept; manifest gone; daemon-reload" \
  eval '[[ -L $UD/default.target.wants/rclone-mount@onedrive.service && -L $UD/rclone-bisync@vault-A.path && -f $XDG_CONFIG_HOME/rclone-bisync/p.conf && -f $UD/my-own.service && ! -e $MAN ]] && only_reload'
runc "$INSTALL" --uninstall --force
check "uninstall again: exit 0, removes nothing more" eval 'rc_is 0 && [[ -f $UD/rclone-backup@.service && -f $UD/my-own.service ]]'

# An install by an older install.sh (links, legacy marker): still removed.
fresh
mkdir -p "$UD" "$BD" "$XDG_STATE_HOME/omarchy-cloud"
for f in "$PLUGIN_DIR"/systemd/*; do ln -s "$f" "$UD/${f##*/}"; done
for f in "$PLUGIN_DIR"/bin/*; do ln -s "$f" "$BD/${f##*/}"; done
printf '#!/bin/sh\necho old tui\n' >"$BD/omarchy-cloud"
h=$(sha "$BD/omarchy-cloud")
printf '%s%s' "$h" "$h" >"$MARK"
runc "$INSTALL" --uninstall
check "uninstall of a link install: links and the marked binary removed, marker too" \
  eval 'rc_is 0 && [[ -z $(find "$UD" "$BD" -mindepth 1) && ! -e $MARK ]]'

# A manifest line outside the two dirs is never acted on.
fresh
runc "$INSTALL" --no-build
mkdir -p "$HOME/elsewhere"
echo precious >"$HOME/elsewhere/file"
printf '%s  %s\n' "$(sha "$HOME/elsewhere/file")" "$HOME/elsewhere/file" >>"$MAN"
printf '%s  %s\n' "$(sha "$HOME/elsewhere/file")" "$BD/../elsewhere/file" >>"$MAN"
runc "$INSTALL" --uninstall
check "uninstall: a manifest line naming a file elsewhere is ignored" eval 'rc_is 0 && [[ -f $HOME/elsewhere/file ]]'

# --- 7. the installed-version record ---------------------------------------------------
check "fixture: manifest.json has an N.N.N version" eval '[[ $PLUGIN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
# A scratch checkout whose manifest.json can be edited.
R3=$SCRATCH/repo3
mkdir -p "$R3"
cp -r "$PLUGIN_DIR/install.sh" "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/systemd" "$PLUGIN_DIR/bin" "$R3/"
R3=$(cd "$R3" && pwd -P)
set_version() { # set_version <version|->: the version line of R3's manifest.json ("-": none)
  if [[ $1 == - ]]; then
    sed -i '/^ *"version":/d' "$R3/manifest.json"
  else
    sed -i "s/^\( *\"version\": *\"\)[^\"]*\"/\1$1\"/; t; /^ *\"name\":/a\\  \"version\": \"$1\"," "$R3/manifest.json"
  fi
}

# A manifest written by 0.3.2 (no header lines), with a recorded file whose
# source has changed since: still ours, replaced, and the header is added.
fresh
runc "$INSTALL" --no-build
sed -i '/^#/d' "$MAN"
printf '# an older version\n' >"$UD/rclone-bisync@.timer"
sed -i "s|^[0-9a-f]\{64\}  $UD/rclone-bisync@.timer\$|$(sha "$UD/rclone-bisync@.timer")  $UD/rclone-bisync@.timer|" "$MAN"
check "fixture: a 0.3.2-format manifest (no # line)" eval '! grep -q "^#" "$MAN" && [[ -s $MAN ]]'
runc "$INSTALL" --no-build
check "0.3.2 manifest: read as before (the recorded file is still ours and updated)" \
  eval 'rc_is 0 && copies_ok && [[ $OUT == *"installed $UD/rclone-bisync@.timer"* ]] && manifest_all "$PLUGIN_DIR"'
check "0.3.2 manifest: rewritten with the version header" header_ok
snapshot >"$T/before"
runc "$INSTALL" --no-build
check "0.3.2 manifest upgraded, again: idempotent" eval 'rc_is 0 && [[ $OUT != *installed\ /* ]] && cmp -s <(snapshot) "$T/before"'

# A pull that changed only manifest.json: nothing is reinstalled, the new
# version is recorded.
fresh
set_version 1.2.3
runc "$R3/install.sh" --no-build
check "install from another checkout: header names it and its version" eval 'rc_is 0 && header_ok "$R3" 1.2.3 && manifest_all "$R3"'
set_version 1.2.4
runc "$R3/install.sh" --no-build
check "a version-only change: nothing reinstalled, the new version recorded" \
  eval 'rc_is 0 && [[ $OUT != *installed\ /* ]] && header_ok "$R3" 1.2.4 && manifest_all "$R3"'
check "a version-only change: no temporary file left behind" eval '[[ -z $(find "$XDG_STATE_HOME" -name ".*") ]]'

# An invalid version: refused before any change, installed or not.
for v in 1.2 1.2.3-rc1 v1.2.3 "1.2.3 " -; do
  for state in fresh installed; do
    fresh
    if [[ $state == installed ]]; then
      set_version 1.2.3
      runc "$R3/install.sh" --no-build
      : >"$FAKE_LOG/systemctl"
    fi
    set_version "$v"
    snapshot >"$T/before"
    runc "$R3/install.sh" --no-build
    check "invalid version '$v' ($state): exit 1, says why, nothing changed" \
      eval 'rc_is 1 && [[ $OUT == *"nothing was changed"*"N.N.N"* ]] && cmp -s <(snapshot) "$T/before" && [[ ! -s $FAKE_LOG/systemctl ]]'
    [[ $v == - ]] && cp "$PLUGIN_DIR/manifest.json" "$R3/manifest.json"
  done
done
cp "$PLUGIN_DIR/manifest.json" "$R3/manifest.json"

# --- 8. running syncs and backups ------------------------------------------------------
# hold <lock file>: an exclusive flock on it, held by a background process
# (the subshell execs into sleep, so HOLDER is the holder's own PID).
hold() {
  (exec 9>"$1" && flock 9 && exec sleep 300) &
  HOLDER=$!
  local i
  for ((i = 0; i < 50; i++)); do
    flock -n "$1" true || return 0
    sleep 0.1
  done
  echo "     the lock holder did not take $1"
  return 1
}
release() {
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  HOLDER=
}
runs() { find "$XDG_RUNTIME_DIR" -mindepth 1 | sort; }

fresh
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=abc "$INSTALL" --no-build
check "OMARCHY_CLOUD_INSTALL_WAIT_S not a number: exit 64, nothing written" eval 'rc_is 64 && [[ ! -e $UD && ! -e $BD && ! -e $MAN ]]'

fresh
runc "$INSTALL" --no-build
printf '# an older version\n' >"$UD/rclone-bisync@.timer"
sed -i "s|^[0-9a-f]\{64\}  $UD/rclone-bisync@.timer\$|$(sha "$UD/rclone-bisync@.timer")  $UD/rclone-bisync@.timer|" "$MAN"
: >"$XDG_RUNTIME_DIR/rclone-backup-idle.lock" # a lock file nobody holds
check "fixture: a bisync lock is held" hold "$XDG_RUNTIME_DIR/rclone-bisync-vault-A.lock"
snapshot >"$T/before"
runs >"$T/runs"
: >"$FAKE_LOG/systemctl"
start=$SECONDS
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=1 "$INSTALL" --no-build
check "bisync lock held, wait 1: exit 75, names the pair, says nothing changed" \
  eval 'rc_is 75 && [[ $OUT == *"offline folder vault-A is running"*"nothing was changed"*"rerun install.sh when the sync or backup finishes"* ]]'
check "bisync lock held: waited about the bound (1-4 s)" eval '((SECONDS - start >= 1 && SECONDS - start <= 4))'
check "bisync lock held: nothing changed (files, manifest, no reload)" \
  eval 'cmp -s <(snapshot) "$T/before" && [[ ! -s $FAKE_LOG/systemctl ]]'
check "bisync lock held: an idle lock file is not named; no lock file created" \
  eval '[[ $OUT != *idle* ]] && cmp -s <(runs) "$T/runs"'
release
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=1 "$INSTALL" --no-build
check "bisync lock released: installs (the update goes in)" \
  eval 'rc_is 0 && [[ $OUT != *waiting* && $OUT == *"installed $UD/rclone-bisync@.timer"* ]] && copies_ok && manifest_all "$PLUGIN_DIR" && header_ok'

# Released while install.sh waits: it goes on.
fresh
check "fixture: a bisync lock is held" hold "$XDG_RUNTIME_DIR/rclone-bisync-vault-A.lock"
(sleep 1 && kill "$HOLDER") &
killer=$!
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=20 "$INSTALL" --no-build
wait "$killer"
release
check "bisync lock released during the wait: waited, then installed" \
  eval 'rc_is 0 && [[ $OUT == *waiting*"vault-A is running"* ]] && copies_ok && header_ok'

fresh
check "fixture: a backup lock is held" hold "$XDG_RUNTIME_DIR/rclone-backup-team-vaults.lock"
snapshot >"$T/before"
start=$SECONDS
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=0 "$INSTALL" --no-build
check "backup lock held, wait 0: exit 75 at once, names the job, nothing changed" \
  eval 'rc_is 75 && ((SECONDS - start <= 2)) && [[ $OUT == *"backup team-vaults is running"*"nothing was changed"* ]] && cmp -s <(snapshot) "$T/before" && [[ ! -s $FAKE_LOG/systemctl ]]'
release
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=1 "$INSTALL" --no-build
check "backup lock released: installs" eval 'rc_is 0 && copies_ok && manifest_all "$PLUGIN_DIR" && header_ok'

# --uninstall waits the same way.
check "fixture: a backup lock is held" hold "$XDG_RUNTIME_DIR/rclone-backup-team-vaults.lock"
snapshot >"$T/before"
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=1 "$INSTALL" --uninstall
check "uninstall with a backup lock held: exit 75, removes nothing, hint says --uninstall" \
  eval 'rc_is 75 && [[ $OUT == *"backup team-vaults is running"*"rerun install.sh --uninstall when the sync or backup finishes"* ]] && cmp -s <(snapshot) "$T/before"'
release
runc env OMARCHY_CLOUD_INSTALL_WAIT_S=1 "$INSTALL" --uninstall
check "uninstall with the lock released: exit 0, removed" eval 'rc_is 0 && [[ ! -e $MAN && ! -e $BD/rclone-bisync ]]'

# The locks are read from /proc/locks, never taken: with a flock on PATH
# that records each call and always "gets" the lock, a held lock is still
# named, an idle one is not, and flock is never run.
NOFLOCK=$SCRATCH/noflock
mkdir -p "$NOFLOCK"
cat >"$NOFLOCK/flock" <<'EOF'
#!/bin/bash
echo "flock $*" >>"$FAKE_LOG/flock"
exit 0
EOF
chmod +x "$NOFLOCK/flock"
fresh
: >"$XDG_RUNTIME_DIR/rclone-bisync-idle.lock"
check "fixture: a backup lock is held" hold "$XDG_RUNTIME_DIR/rclone-backup-team-vaults.lock"
snapshot >"$T/before"
runc env PATH="$NOFLOCK:$PATH" OMARCHY_CLOUD_INSTALL_WAIT_S=0 "$INSTALL" --no-build
check "/proc/locks: the held lock is named, the idle one is not, no lock is taken" \
  eval 'rc_is 75 && [[ $OUT == *"backup team-vaults is running"* && $OUT != *idle* && ! -e $FAKE_LOG/flock ]] && cmp -s <(snapshot) "$T/before"'
# The fallback (no mount entry for the dir, so /proc/locks cannot be
# matched): the probe flock, which also sees the held lock.
NOMNT=$SCRATCH/nomnt
mkdir -p "$NOMNT"
printf '#!/bin/sh\nexit 1\n' >"$NOMNT/findmnt"
chmod +x "$NOMNT/findmnt"
runc env PATH="$NOMNT:$PATH" OMARCHY_CLOUD_INSTALL_WAIT_S=0 "$INSTALL" --no-build
check "fallback probe (findmnt fails): the held lock is named, the idle one is not" \
  eval 'rc_is 75 && [[ $OUT == *"backup team-vaults is running"* && $OUT != *idle* ]] && cmp -s <(snapshot) "$T/before"'
release
runc env PATH="$NOFLOCK:$PATH" OMARCHY_CLOUD_INSTALL_WAIT_S=0 "$INSTALL" --no-build
check "/proc/locks: released, installs without running flock" eval 'rc_is 0 && copies_ok && [[ ! -e $FAKE_LOG/flock ]]'
# The same on tmpfs (the usual /run/user/<uid>), when /dev/shm is one: there
# stat's device and /proc/locks' agree, on btrfs ($SCRATCH here, often) not.
if [[ $(findmnt -no FSTYPE -T /dev/shm 2>/dev/null) == tmpfs ]] && SHMRUN=$(mktemp -d /dev/shm/install-test.XXXXXX); then
  fresh
  export XDG_RUNTIME_DIR=$SHMRUN
  check "fixture: a bisync lock is held on tmpfs" hold "$XDG_RUNTIME_DIR/rclone-bisync-vault-A.lock"
  runc env PATH="$NOFLOCK:$PATH" OMARCHY_CLOUD_INSTALL_WAIT_S=0 "$INSTALL" --no-build
  check "/proc/locks on tmpfs: the held lock is named, no lock is taken" \
    eval 'rc_is 75 && [[ $OUT == *"offline folder vault-A is running"* && ! -e $FAKE_LOG/flock ]]'
  release
  rm -rf -- "$SHMRUN"
else
  echo "skip /proc/locks on tmpfs (/dev/shm is not a writable tmpfs)"
fi

# A lock file owned by another user (with XDG_RUNTIME_DIR unset the dir is
# the shared /tmp) is ignored: not tested, a foreign owner needs root.

# --- 9. the repository ---------------------------------------------------------------
if git -C "$PLUGIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  check "repo: no symlink is tracked (git ls-files mode 120000)" \
    eval '[[ -z $(git -C "$PLUGIN_DIR" ls-files -s | awk "\$1 == 120000") ]]'
else
  echo "skip repo: tracked symlinks (not a git checkout)"
fi
check "repo: no symlink in the working tree (outside .git and target/)" \
  eval '[[ -z $(find "$PLUGIN_DIR" \( -name .git -o -name target \) -prune -o -type l -print) ]]'
check "repo: nothing built into it" eval '[[ ! -e $PLUGIN_DIR/app/target && ! -e $PLUGIN_DIR/target ]]'

echo
if ((FAILURES)); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
