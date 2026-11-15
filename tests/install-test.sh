#!/bin/bash

# install.sh, hermetic: stand-ins for systemctl, cargo, uname and sudo come
# first on PATH and record their argv; HOME and the XDG_* dirs point into a
# scratch dir (the XDG_* ones away from HOME: install.sh must not follow them).
# Nothing outside the scratch dir is written, no unit is touched, and the
# real cargo is never run. install.sh runs from a scratch copy of this
# checkout without dist/ (R0), so the result does not depend on whether the
# checkout's dist/ prebuilt matches its app/ sources (a release commit makes
# it match, the next app/ change makes it stale); section 5 builds its own
# dist/. Its stdin is /dev/null, and the default mount root a scratch path
# (OMARCHY_CLOUD_TEST_DEFAULT_ROOT), unless a test sets them.
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
#  10. The mount root (cloud.env): silent adoption of an owned default, the
#      instructions without a terminal or with --no-prompt, the prompt (the
#      exact sudo command, never run; Enter re-checks; a typed path),
#      --mount-root and its refusals, an existing cloud.env never rewritten,
#      kept by --uninstall; a root must be searchable too (x), not only
#      writable; tests/fixtures/roots.tsv (raw bytes) through install.sh's
#      valid_root; every case of tests/fixtures/resolved-roots.tsv through
#      --mount-root (a root that resolves into the home refused, one realpath
#      cannot resolve too), and a default, a typed root and an existing
#      setting that link into the home (not adopted, refused, named); the
#      diff hint for a path with a '; the mount unit: its
#      lines (the guard bin/rclone-mount in ExecCondition and ExecStart, no
#      ExecStartPre, RestartPreventExitStatus=78), and those lines run as
#      systemd would against the installed guard.
#
# The checks are eval'd single-quoted strings, expanded when they run.
# shellcheck disable=SC2016,SC2034

set -o pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FAILURES=0
SCRATCH=$(mktemp -d) || exit 1
SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOLDER= # the PID of a background lock holder (section 8), stopped on exit
trap '[[ -n $HOLDER ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

# R0: the checkout as install.sh sees it, minus dist/ (and a snapshot, so a
# file edited while the suite runs does not change under it). The root's
# other files (preview.png, docs/) come along when present: never installed.
R0=$SCRATCH/checkout
mkdir -p "$R0/app"
cp -r "$PLUGIN_DIR/install.sh" "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/systemd" "$PLUGIN_DIR/bin" "$R0/"
cp -r "$PLUGIN_DIR/app/Cargo.toml" "$PLUGIN_DIR/app/Cargo.lock" "$PLUGIN_DIR/app/src" "$R0/app/"
for f in preview.png docs; do [[ -e $PLUGIN_DIR/$f ]] && cp -r "$PLUGIN_DIR/$f" "$R0/"; done
INSTALL=$R0/install.sh

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
# systemctl list-units prints FAKE_UNITS (the units "loaded" now); sudo
# only records that it ran.
cat >"$STUBS/systemctl" <<'EOF'
#!/bin/bash
{ printf 'systemctl'; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/systemctl"
for a; do [[ $a == list-units && -n ${FAKE_UNITS:-} ]] && printf '%s\n' "$FAKE_UNITS"; done
exit 0
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/bin/bash
{ printf 'sudo'; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/sudo"
exit 1
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
cp "$STUBS/systemctl" "$STUBS/uname" "$STUBS/sudo" "$NOCARGO/"
NOCARGO_PATH=$NOCARGO:/usr/bin:/bin
export PATH="$STUBS:$PATH"

# fresh: a new scratch HOME with empty logs; clears the stand-ins' knobs.
N=0
fresh() {
  N=$((N + 1))
  T=$SCRATCH/t$N
  mkdir -p "$T/home/.config" "$T/xdg/config" "$T/xdg/state" "$T/xdg/cache" "$T/log" "$T/run"
  # The XDG_* dirs exist but are not HOME's (install.sh is HOME-fixed);
  # XDG_RUNTIME_DIR too: the real one may hold the locks of real runs.
  export HOME=$T/home XDG_CONFIG_HOME=$T/xdg/config XDG_STATE_HOME=$T/xdg/state \
    XDG_CACHE_HOME=$T/xdg/cache FAKE_LOG=$T/log XDG_RUNTIME_DIR=$T/run \
    OMARCHY_CLOUD_TEST_DEFAULT_ROOT=$T/mnt/cloud
  unset FAKE_BUILD FAKE_ARCH FAKE_UNITS OMARCHY_CLOUD_INSTALL_WAIT_S OMARCHY_CLOUD_TEST_TTY
  UD=$HOME/.config/systemd/user BD=$HOME/.local/bin
  MAN=$HOME/.local/state/omarchy-cloud/installed-files
  MARK=$HOME/.local/state/omarchy-cloud/installed-binary.sha256
  ENVF=$HOME/.config/omarchy-cloud/cloud.env
}
# runc <cmd...>: OUT = stdout+stderr, RC = status; stdin is /dev/null.
runc() { OUT=$("$@" 2>&1 </dev/null); RC=$?; }
# runi <input> <cmd...>: runc on a "terminal" (OMARCHY_CLOUD_TEST_TTY=1)
# that answers <input>.
runi() {
  local in=$1
  shift
  OUT=$(printf '%s' "$in" | OMARCHY_CLOUD_TEST_TTY=1 "$@" 2>&1)
  RC=$?
}
log() { cat "$FAKE_LOG/$1" 2>/dev/null; }
q() { printf ' %q' "$@"; }
rc_is() { ((RC == $1)); }
sha() { sha256sum "$1" | cut -d' ' -f1; }
only_reload() { [[ $(log systemctl) == "systemctl --user daemon-reload" ]]; }

# copies_ok [repo]: every systemd/ and bin/ file is a regular copy with its mode.
copies_ok() {
  local r=${1:-$R0} f
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
# the sha256 the file has now (besides the # header lines, checked by
# header_ok).
manifest_ok() {
  local want got p
  want=$(for p; do printf '%s  %s\n' "$(sha "$p")" "$p"; done | sort -k 2)
  got=$(grep -v '^#' "$MAN" 2>/dev/null)
  [[ -n $want && $got == "$want" ]] || { diff <(echo "$want") <(echo "$got") | sed "s/^/     /" | head -6; return 1; }
}
# header_ok [repo] [version]: the manifest's first two lines are the version
# record (default: this checkout and its manifest.json version).
header_ok() {
  local want
  want=$(printf '#version=%s\n#repo=%s' "${2:-$PLUGIN_VERSION}" "${1:-$R0}")
  [[ $(head -n 2 "$MAN" 2>/dev/null) == "$want" ]] || { head -n 2 "$MAN" 2>/dev/null | sed "s/^/     got /"; return 1; }
}
PLUGIN_VERSION=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_DIR/manifest.json" | head -n 1)
all_files() { # the paths install.sh installs from a repo, besides the binary
  local r=${1:-$R0} f
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
snapshot() { # UD, BD, the state and config dirs and the XDG ones: types, link targets, hashes
  find "$UD" "$BD" "$HOME/.local/state" "$HOME/.config" "$T/xdg" 2>/dev/null | sort | while IFS= read -r p; do
    if [[ -L $p ]]; then echo "L $p -> $(readlink "$p")"
    elif [[ -f $p ]]; then echo "F $p $(stat -c %a "$p") $(sha "$p")"
    else echo "D $p $(stat -c %a "$p")"; fi
  done
}

# --- 1. syntax, lint, options -------------------------------------------------
check "bash -n install.sh" bash -n "$PLUGIN_DIR/install.sh"
check "install.sh is executable" test -x "$PLUGIN_DIR/install.sh"
# find_shellcheck: SHELLCHECK_BIN, a shellcheck that runs, found the way
# tests/run.sh finds it: $SHELLCHECK if set, else `shellcheck` on PATH, else
# the newest mise install; a candidate counts only if --version exits 0 (a
# mise shim with no version set is on PATH and fails). Returns 1, with what
# was tried in SHELLCHECK_TRIED, when none works.
find_shellcheck() {
  local c installs=()
  SHELLCHECK_BIN='' SHELLCHECK_TRIED=''
  if [[ -n ${SHELLCHECK:-} ]]; then
    "$SHELLCHECK" --version >/dev/null 2>&1 && SHELLCHECK_BIN=$SHELLCHECK && return 0
    SHELLCHECK_TRIED="\$SHELLCHECK=$SHELLCHECK (--version failed)"
    return 1
  fi
  if c=$(command -v shellcheck); then
    "$c" --version >/dev/null 2>&1 && SHELLCHECK_BIN=$c && return 0
    SHELLCHECK_TRIED="$c (--version failed); "
  else
    SHELLCHECK_TRIED="shellcheck not on PATH; "
  fi
  mapfile -t installs < <(printf '%s\n' \
    "$HOME"/.local/share/mise/installs/shellcheck/*/shellcheck*/shellcheck \
    "$HOME"/.local/share/mise/installs/shellcheck/*/shellcheck | sort -V -r)
  for c in "${installs[@]}"; do
    [[ -x $c ]] || continue
    "$c" --version >/dev/null 2>&1 && SHELLCHECK_BIN=$c && return 0
    SHELLCHECK_TRIED+="$c (--version failed); "
  done
  SHELLCHECK_TRIED+="no runnable ~/.local/share/mise/installs/shellcheck/*/shellcheck*/shellcheck"
  return 1
}
if find_shellcheck; then
  check "shellcheck" "$SHELLCHECK_BIN" "$PLUGIN_DIR/install.sh" "${BASH_SOURCE[0]}"
else
  echo "skip shellcheck (none runs; set SHELLCHECK to one; tried: $SHELLCHECK_TRIED)"
fi
fresh
for args in "--bogus" "--force" "--no-build --from-source" "--uninstall --from-source" "--uninstall --no-build" \
  "--mount-root" "--no-prompt --mount-root /srv" "--mount-root /srv --mount-root /opt" "--uninstall --no-prompt" \
  "--uninstall --mount-root /srv"; do
  # shellcheck disable=SC2086 # $args is split on purpose: one case, several options
  runc "$INSTALL" $args
  check "install.sh $args: exit 64, nothing written" eval 'rc_is 64 && [[ ! -e $UD && ! -e $BD && ! -e $MAN ]]'
done

# --- 2. fresh install -------------------------------------------------------------
fresh
runc "$INSTALL" --no-build
check "install: exit 0" rc_is 0
check "install: every systemd/ and bin/ file copied (regular files, 644 / 755), none linked" \
  eval 'copies_ok && [[ -z $(find "$UD" "$BD" -type l) ]]'
check "install: the manifest records each installed file with its sha256" manifest_all "$R0"
check "install: the manifest starts with #version=<manifest.json version> and #repo=<checkout>" header_ok
check "install: no temporary file left behind" eval '[[ -z $(find "$UD" "$BD" "$HOME/.local/state" -name ".*") ]]'
check "install: config dirs created 700" \
  eval '[[ $(stat -c %a "$HOME/.config/rclone-bisync") == 700 && $(stat -c %a "$HOME/.config/rclone-backup") == 700 ]]'
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
cp "$R0/bin/rclone-backup" "$BD/rclone-backup"
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
  eval 'rc_is 0 && copies_ok && [[ $OUT == *"installed $UD/rclone-bisync@.timer"* ]] && manifest_all "$R0"'

# --- 4. migration from a link install ------------------------------------------------
fresh
mkdir -p "$UD/default.target.wants" "$UD/timers.target.wants" "$BD" "${MAN%/*}"
for f in "$R0"/systemd/*; do ln -s "$f" "$UD/${f##*/}"; done
for f in "$R0"/bin/*; do ln -s "$f" "$BD/${f##*/}"; done
S=$R0/systemd
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
check "migrate: nothing under the unit or bin dir resolves into the repo" no_link_into "$R0"
check "migrate: the doubled legacy marker is accepted: the old binary is replaced" \
  eval '[[ $(cat "$BD/omarchy-cloud") == *"tui v2"* ]]'
check "migrate: the marker moved into the manifest (binary recorded, marker removed)" \
  eval 'manifest_all "$R0" "$BD/omarchy-cloud" && [[ ! -e $MARK ]]'
check "migrate: daemon-reload only, says nothing needs restarting" \
  eval 'only_reload && [[ $OUT == *"nothing needs restarting"* ]]'
check "migrate: no temporary link left behind" eval '[[ -z $(find "$UD" -name "*omarchy-cloud-tmp*" -o -name ".*" -type f) ]]'
snapshot >"$T/before"
FAKE_BUILD=v2 runc "$INSTALL"
check "migrate, again: idempotent" eval 'rc_is 0 && [[ $OUT != *installed\ /* && $OUT != *re-pointed* ]] && cmp -s <(snapshot) "$T/before"'

# A legacy marker that names another binary: still refused.
fresh
mkdir -p "$BD" "${MAN%/*}"
printf '#!/bin/sh\necho mine\n' >"$BD/omarchy-cloud"
printf '%064d' 0 >"$MARK"
runc "$INSTALL"
check "install: a binary that is not the one the legacy marker names stops it" \
  eval 'rc_is 1 && [[ $OUT == *"$BD/omarchy-cloud"*"not the binary"* && $(cat "$BD/omarchy-cloud") == *mine* ]]'

# --- 5. the binary's source --------------------------------------------------------
# A scratch copy of the repo with a dist/ (the real repo never gets one here).
R2=$SCRATCH/repo
mkdir -p "$R2/app" "$R2/dist"
cp -r "$R0/install.sh" "$R0/manifest.json" "$R0/systemd" "$R0/bin" "$R2/"
cp -r "$R0/app/Cargo.toml" "$R0/app/Cargo.lock" "$R0/app/src" "$R2/app/"
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
  eval 'grep -qF -- "$DIGEST_LINE" "$PLUGIN_DIR/install.sh" && (($(grep -cF -- "$DIGEST_LINE" "$PLUGIN_DIR/.github/workflows/release.yml") == 2))'
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
  eval '[[ $(log cargo) == "cargo$(q build --release --locked --manifest-path "$R2/app/Cargo.toml") CARGO_TARGET_DIR=$(printf %q "$HOME/.cache/omarchy-cloud/target")" ]]'

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
cp "$R0/app/src/main.rs" "$R2/app/src/main.rs"
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
cp "$R0/app/Cargo.lock" "$R2/app/"

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
  eval 'rc_is 0 && [[ $(cat "$BD/omarchy-cloud") == *"tui v2"* ]] && manifest_all "$R0" "$BD/omarchy-cloud"'
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
check "build: identical to the build is taken over" eval 'rc_is 0 && manifest_all "$R0" "$BD/omarchy-cloud"'
runc "$INSTALL" --no-build
check "--no-build: the recorded binary stays recorded" eval 'rc_is 0 && manifest_all "$R0" "$BD/omarchy-cloud"'

# --- 6. --uninstall -------------------------------------------------------------------
mkdir -p "$UD/default.target.wants"
ln -s "$UD/rclone-mount@.service" "$UD/default.target.wants/rclone-mount@onedrive.service"
mkdir -p "$HOME/.config/rclone-bisync"
echo "LOCAL=~/x" >"$HOME/.config/rclone-bisync/p.conf"
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
  eval '[[ ! -e $UD/rclone-mount@.service && ! -e $UD/rclone-bisync@.path && ! -e $BD/rclone-bisync && ! -e $BD/rclone-backup && ! -e $BD/rclone-mount ]]'
check "uninstall: an edited unit and a replaced binary are left, and named" \
  eval '[[ -f $UD/rclone-backup@.service && $(cat "$BD/omarchy-cloud") == "#!/bin/sh" && $OUT == *"left $UD/rclone-backup@.service"* && $OUT == *"left $BD/omarchy-cloud"* ]]'
check "uninstall: enablement links, config, other units kept; manifest gone; daemon-reload" \
  eval '[[ -L $UD/default.target.wants/rclone-mount@onedrive.service && -L $UD/rclone-bisync@vault-A.path && -f $HOME/.config/rclone-bisync/p.conf && -f $UD/my-own.service && ! -e $MAN ]] && only_reload'
runc "$INSTALL" --uninstall --force
check "uninstall again: exit 0, removes nothing more" eval 'rc_is 0 && [[ -f $UD/rclone-backup@.service && -f $UD/my-own.service ]]'

# An install by an older install.sh (links, legacy marker): still removed.
fresh
mkdir -p "$UD" "$BD" "${MAN%/*}"
for f in "$R0"/systemd/*; do ln -s "$f" "$UD/${f##*/}"; done
for f in "$R0"/bin/*; do ln -s "$f" "$BD/${f##*/}"; done
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
cp -r "$R0/install.sh" "$R0/manifest.json" "$R0/systemd" "$R0/bin" "$R3/"
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
  eval 'rc_is 0 && copies_ok && [[ $OUT == *"installed $UD/rclone-bisync@.timer"* ]] && manifest_all "$R0"'
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
check "a version-only change: no temporary file left behind" eval '[[ -z $(find "$HOME/.local/state" -name ".*") ]]'

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
    [[ $v == - ]] && cp "$R0/manifest.json" "$R3/manifest.json"
  done
done
cp "$R0/manifest.json" "$R3/manifest.json"

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
  eval 'rc_is 0 && [[ $OUT != *waiting* && $OUT == *"installed $UD/rclone-bisync@.timer"* ]] && copies_ok && manifest_all "$R0" && header_ok'

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
check "backup lock released: installs" eval 'rc_is 0 && copies_ok && manifest_all "$R0" && header_ok'

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

# --- 10. the mount root -------------------------------------------------------------
# The default root is a scratch stand-in ($T/mnt/cloud, via
# OMARCHY_CLOUD_TEST_DEFAULT_ROOT); a "terminal" is OMARCHY_CLOUD_TEST_TTY=1
# answering from a pipe. ALT is another root outside the scratch HOME.
mkroot_cmd() { printf 'sudo install -d -o "$USER" -m 755 %s' "'$1'"; } # C3, for a path without '
env_is() { [[ $(cat "$ENVF" 2>/dev/null) == "OMARCHY_CLOUD_ROOT=$1" ]]; }
env_modes_ok() { [[ $(stat -c %a "$ENVF") == 600 && $(stat -c %a "${ENVF%/*}") == 700 ]]; }
no_sudo() { [[ ! -s $FAKE_LOG/sudo ]]; }

fresh
ALT=$T/srv/cloud
check "fixture: the scratch roots are outside HOME" eval '[[ $T/mnt/cloud != "$HOME"/* && $ALT != "$HOME"/* ]]'
runc "$INSTALL" --no-build
check "root, no terminal, none set up: exit 0, nothing asked or written, the exact sudo command and --mount-root printed" \
  eval 'rc_is 0 && [[ $OUT != *"Mount root ["* && ! -e $ENVF && ! -e ${ENVF%/*} && $OUT == *"$(mkroot_cmd "$T/mnt/cloud")"* && $OUT == *"--mount-root PATH"* && $OUT == *"Nothing was written"* ]] && no_sudo'
check "root, no terminal: the manifest names no config" eval '! grep -q "^#config=" "$MAN"'
mkdir -p "$ALT"
runi "$ALT"$'\n' "$INSTALL" --no-build --no-prompt
check "root, --no-prompt on a terminal: nothing read, nothing written, instructions" \
  eval 'rc_is 0 && [[ ! -e $ENVF && $OUT != *"Mount root ["* && $OUT == *"$(mkroot_cmd "$T/mnt/cloud")"* ]]'

# Silent adoption: the default exists, is ours and writable. The "terminal"
# would answer another valid root, so a prompt read would show.
fresh
ALT=$T/srv/cloud
mkdir -p "$T/mnt/cloud" "$ALT"
runi "$ALT"$'\n' "$INSTALL" --no-build
check "root adopted: an owned, writable default is saved without a prompt, 600 in a 700 dir, one line says so" \
  eval 'rc_is 0 && env_is "$T/mnt/cloud" && env_modes_ok && [[ $OUT != *"Mount root ["* && $(grep -c "adopted" <<<"$OUT") == 1 ]]'
check "root adopted: the manifest records cloud.env as user config, not as a file to remove" \
  eval 'grep -qxF "#config=$ENVF" "$MAN" && ! grep -qF "  $ENVF" "$MAN" && header_ok && manifest_all "$R0"'
check "root adopted: no temporary file left behind" eval '[[ -z $(find "${ENVF%/*}" -name ".*") ]]'
snapshot >"$T/before"
runc "$INSTALL" --no-build
check "root adopted, again: idempotent, nothing said about the root" \
  eval 'rc_is 0 && cmp -s <(snapshot) "$T/before" && [[ $OUT != *adopted* && $OUT != *"mount root"* ]]'
check "root adopted, again: daemon-reload only (no list-units without --mount-root)" \
  eval '[[ $(log systemctl | sort -u) == "systemctl --user daemon-reload" ]]'

# A default that is not ours is never adopted (here: not writable).
fresh
mkdir -p "$T/mnt/cloud"
chmod 555 "$T/mnt/cloud"
runc "$INSTALL" --no-build
check "root: a default we cannot write to is not adopted, the sudo command is printed" \
  eval 'rc_is 0 && [[ ! -e $ENVF && $OUT == *"$(mkroot_cmd "$T/mnt/cloud")"* ]]'
chmod 755 "$T/mnt/cloud"
# Nor one we own and can write to but not search (no x: nothing inside it,
# the mount point included, could be reached).
fresh
mkdir -p "$T/mnt/cloud"
chmod 600 "$T/mnt/cloud"
runc "$INSTALL" --no-build
check "root: an owned, writable default we cannot search (mode 600) is not adopted, the sudo command is printed" \
  eval 'rc_is 0 && [[ ! -e $ENVF && $OUT != *adopted* && $OUT == *"can write to and search"* && $OUT == *"$(mkroot_cmd "$T/mnt/cloud")"* ]]'
chmod 755 "$T/mnt/cloud"
# A saved root we cannot search is named, with its sudo command.
fresh
mkdir -p "$T/srv/nx" "${ENVF%/*}"
chmod 600 "$T/srv/nx"
printf 'OMARCHY_CLOUD_ROOT=%s\n' "$T/srv/nx" >"$ENVF"
runc "$INSTALL" --no-build
check "root: a saved root we cannot search (mode 600) is named as not usable, with its sudo command, cloud.env kept" \
  eval 'rc_is 0 && env_is "$T/srv/nx" && [[ $OUT == *"$T/srv/nx'"'"' (from $ENVF) is not a directory you can write to and search"* && $OUT == *"$(mkroot_cmd "$T/srv/nx")"* ]]'
chmod 755 "$T/srv/nx"

# The prompt, the root missing: Enter prints the exact command and never runs
# sudo; the input ends: nothing written.
fresh
runi $'\n' "$INSTALL" --no-build
check "root prompt, Enter, the root missing: proposes the default, prints the exact sudo command, exit 0, nothing written" \
  eval 'rc_is 0 && [[ $OUT == *"Mount root [$T/mnt/cloud]"* && $OUT == *"$(mkroot_cmd "$T/mnt/cloud")"* && ! -e $ENVF ]]'
check "root prompt: sudo is never run (the sudo stand-in recorded nothing)" no_sudo
# Enter again after the root was created (in "another terminal"): re-checked
# and saved.
fresh
# The feeder reads the output install.sh writes on purpose: it waits for the
# sudo line before "creating" the root.
# shellcheck disable=SC2094
(
  printf '\n'
  for ((i = 0; i < 100; i++)); do grep -qF "sudo install" "$T/out" 2>/dev/null && break; sleep 0.05; done
  mkdir -p "$T/mnt/cloud"
  printf '\n'
) | OMARCHY_CLOUD_TEST_TTY=1 "$INSTALL" --no-build >"$T/out" 2>&1
RC=$? OUT=$(cat "$T/out")
check "root prompt: created in another terminal, Enter re-checks and saves it" \
  eval 'rc_is 0 && [[ $OUT == *"$(mkroot_cmd "$T/mnt/cloud")"*"set to $T/mnt/cloud"* ]] && env_is "$T/mnt/cloud" && env_modes_ok && no_sudo'
# A typed root that exists: saved. A typed root inside HOME: refused, asked again.
fresh
ALT=$T/srv/cloud
mkdir -p "$ALT"
runi "$HOME/cloud"$'\n'"$ALT"$'\n' "$INSTALL" --no-build
check "root prompt: a path inside HOME is refused and asked again; a typed existing path is saved" \
  eval 'rc_is 0 && [[ $OUT == *"$HOME/cloud'"'"' cannot be the mount root"* ]] && env_is "$ALT" && env_modes_ok && grep -qxF "#config=$ENVF" "$MAN"'
fresh
ALT=$T/srv/cloud
runi "$ALT"$'\n' "$INSTALL" --no-build
check "root prompt: a typed path that does not exist: its sudo command, nothing written" \
  eval 'rc_is 0 && [[ $OUT == *"$(mkroot_cmd "$ALT")"* && ! -e $ENVF ]] && no_sudo'

# An existing cloud.env is the user's: never rewritten by a plain install,
# whether its setting is valid, invalid or absent, terminal or not.
for content in "# mine"$'\n'"OMARCHY_CLOUD_ROOT=@ALT" "OMARCHY_CLOUD_ROOT=relative/path" "# only a comment"; do
  fresh
  ALT=$T/srv/cloud
  mkdir -p "$T/mnt/cloud" "$ALT" "${ENVF%/*}"
  printf '%s\n' "${content//@ALT/$ALT}" >"$ENVF"
  chmod 640 "$ENVF"
  before=$(sha "$ENVF")
  runc "$INSTALL" --no-build
  rc1=$RC
  runi "$T/mnt/cloud"$'\n' "$INSTALL" --no-build
  check "root: an edited cloud.env (${content//$'\n'/ \\n }) is never rewritten (no terminal, terminal)" \
    eval '((rc1 == 0)) && rc_is 0 && [[ $(sha "$ENVF") == "$before" && $(stat -c %a "$ENVF") == 640 && $OUT != *"Mount root ["* && $OUT != *adopted* ]]'
done
check "root: an invalid cloud.env is named and left as it is" eval '[[ $OUT == *"$ENVF"*"left as it is"* ]]'
# The last one has no OMARCHY_CLOUD_ROOT= line: not set up (as the TUI and
# the panel read it), so no default root is claimed for it.
check "root: a cloud.env with no OMARCHY_CLOUD_ROOT= line is named, points to --mount-root PATH, claims no default" \
  eval '[[ $OUT == *"$ENVF holds no usable"* && $OUT == *"--mount-root PATH"* && $OUT != *"mounts use"* && $OUT != *"$T/mnt/cloud"* ]]'

# A NUL in the value: invalid, as for the TUI and the panel (bash would drop
# it and read the valid $T/srv/ab, named as not set up), left as it is.
fresh
mkdir -p "$T/mnt/cloud" "${ENVF%/*}"
printf 'OMARCHY_CLOUD_ROOT=%s/srv/a\0b\n' "$T" >"$ENVF"
before=$(sha "$ENVF")
runc "$INSTALL" --no-build
check "root: a cloud.env value with a NUL byte is invalid: named, left as it is, \$T/srv/ab never read" \
  eval 'rc_is 0 && [[ $(sha "$ENVF") == "$before" && $OUT == *"$ENVF holds no usable"*"left as it is"* && $OUT != *"$T/srv/ab"* && $OUT != *"null byte"* ]]'

# A cloud.env that is not a regular file (a FIFO) is never read: no hang.
fresh
mkdir -p "$T/mnt/cloud" "${ENVF%/*}"
mkfifo "$ENVF"
OUT=$(timeout 20 "$INSTALL" --no-build 2>&1 </dev/null)
RC=$?
check "root: a FIFO cloud.env does not block (exit 0 within the timeout), is named and left as it is" \
  eval 'rc_is 0 && [[ -p $ENVF && $OUT == *"$ENVF holds no usable"*"left as it is"* && $OUT == *"--mount-root PATH"* ]]'

# --mount-root.
fresh
ALT=$T/srv/cloud
mkdir -p "$T/mnt/cloud" "$ALT" "$HOME/Cloud"
runc "$INSTALL" --no-build # adopts $T/mnt/cloud
mkdir -p "$UD/default.target.wants"
ln -s "$UD/rclone-mount@.service" "$UD/default.target.wants/rclone-mount@od.service"
ln -s "$T/mnt/cloud/od" "$HOME/Cloud/od"
ln -s /elsewhere "$HOME/Cloud/other"
snapshot >"$T/before"
runc "$INSTALL" --no-build --mount-root "$ALT"
check "--mount-root with a mount enabled: refused (exit 1), names it, nothing changed" \
  eval 'rc_is 1 && [[ $OUT == *"rclone-mount@od.service"* && $OUT == *"nothing was changed"* ]] && env_is "$T/mnt/cloud" && cmp -s <(snapshot) "$T/before"'
rm "$UD/default.target.wants/rclone-mount@od.service"
snapshot >"$T/before"
FAKE_UNITS="rclone-mount@gd.service loaded activating auto-restart rclone mount of gd:
rclone-mount@old.service loaded inactive dead rclone mount of old:" runc "$INSTALL" --no-build --mount-root "$ALT"
check "--mount-root with a mount active (waiting to restart): refused (exit 1), names it, not the inactive one" \
  eval 'rc_is 1 && [[ $OUT == *"rclone-mount@gd.service"* && $OUT != *"rclone-mount@old"* ]] && env_is "$T/mnt/cloud" && cmp -s <(snapshot) "$T/before"'
runc "$INSTALL" --no-build --mount-root "$HOME/inside"
check "--mount-root inside HOME: refused (exit 1), nothing changed" eval 'rc_is 1 && env_is "$T/mnt/cloud" && cmp -s <(snapshot) "$T/before"'
mkdir -p "$T/nx"
chmod 600 "$T/nx"
runc "$INSTALL" --no-build --mount-root "$T/nx"
check "--mount-root, a writable directory we cannot search (mode 600): refused (exit 1), nothing changed" \
  eval 'rc_is 1 && [[ $OUT == *"is not a directory you can write to and search"* ]] && env_is "$T/mnt/cloud" && cmp -s <(snapshot) "$T/before"'
chmod 755 "$T/nx"
runc "$INSTALL" --no-build --mount-root "$T/missing"
check "--mount-root, a path that does not exist: refused (exit 1) with its sudo command, nothing changed" \
  eval 'rc_is 1 && [[ $OUT == *"$(mkroot_cmd "$T/missing")"* ]] && env_is "$T/mnt/cloud" && cmp -s <(snapshot) "$T/before" && no_sudo'
FAKE_UNITS="rclone-mount@old.service loaded inactive dead rclone mount of old:" runc "$INSTALL" --no-build --mount-root "$ALT"
check "--mount-root, no mount running: saved (600 in 700), says the old root" \
  eval 'rc_is 0 && env_is "$ALT" && env_modes_ok && [[ $OUT == *"set to $ALT (was $T/mnt/cloud"* ]] && grep -qxF "#config=$ENVF" "$MAN"'
check "--mount-root: a ~/Cloud link into the old root is reported, not rewritten; others are not named" \
  eval '[[ $OUT == *"$HOME/Cloud/od -> $T/mnt/cloud/od"* && $OUT != *"Cloud/other"* && $(readlink "$HOME/Cloud/od") == "$T/mnt/cloud/od" ]]'
ln -s "$UD/rclone-mount@.service" "$UD/default.target.wants/rclone-mount@od.service"
runc "$INSTALL" --no-build --mount-root "$ALT"
check "--mount-root, the current setting again: nothing to refuse (exit 0), unchanged" eval 'rc_is 0 && env_is "$ALT"'

# --uninstall keeps cloud.env.
rm "$UD/default.target.wants/rclone-mount@od.service"
before=$(sha "$ENVF")
runc "$INSTALL" --uninstall
check "uninstall: cloud.env and its dir are kept (content, modes); said so" \
  eval 'rc_is 0 && [[ ! -e $MAN && $(sha "$ENVF") == "$before" ]] && env_modes_ok && [[ $OUT == *"$ENVF"* ]]'

# The root validator: install.sh's copy against tests/fixtures/roots.tsv.
VALID_ROOT=$(sed -n '/^# --- valid_root (shared: /,/^# --- end valid_root ---$/p' "$INSTALL")
check "fixture: install.sh carries the marked valid_root block" eval '[[ $VALID_ROOT == *"valid_root() {"* ]]'
roots_n=0 roots_bad=0
# Raw bytes: the file holds non-UTF-8 bytes and paths with leading and
# trailing spaces or backslashes, so no IFS splitting and no read escapes.
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line == *$'\t'* ]] || continue
  kind=${line%%$'\t'*} path=${line#*$'\t'}
  [[ $kind == valid || $kind == invalid ]] || continue
  roots_n=$((roots_n + 1))
  if HOME=/home/tester bash -c "$VALID_ROOT"$'\nvalid_root "$1"' _ "$path"; then got=valid; else got=invalid; fi
  [[ $got == "$kind" ]] || { echo "     roots.tsv: $(printf %q "$path") is $kind, valid_root says $got"; roots_bad=$((roots_bad + 1)); }
done <"$PLUGIN_DIR/tests/fixtures/roots.tsv"
check "valid_root: every case of tests/fixtures/roots.tsv ($roots_n)" eval '((roots_n > 20 && roots_bad == 0))'
# Every trailing / of HOME is dropped (as in Rust and the panel); a HOME of
# only / is no home.
vr_home() { HOME=$1 bash -c "$VALID_ROOT"$'\nvalid_root "$1"' _ "$2"; }
check "valid_root: HOME=/home/tester// still refuses /home/tester/x and /home/tester; HOME=// skips the home rule" \
  eval '! vr_home /home/tester// /home/tester/x && ! vr_home /home/tester/// /home/tester && vr_home // /home/x && vr_home /home/tester// /home/testerx'

# The root with its symlinks resolved (root_outside_home; the shared block
# itself, and every copy of it, is covered by tests/scripts-test.sh): every
# case of tests/fixtures/resolved-roots.tsv through --mount-root, the tree
# built under the scratch dir (rr_build, the fixture's header) with
# HOME=<it>/home. A valid root is created when missing, so it is saved; an
# invalid one is refused (exit 1), naming the home and why, nothing written.
# rr_build <T> <setup>: the tree of one case under T.
rr_build() {
  local t=$1 step p tg steps=()
  [[ $2 == - ]] || IFS=';' read -ra steps <<<"$2"
  mkdir -p "$t" || return 1
  [[ ";$2;" == *";link:home="* ]] || mkdir -p "$t/home" || return 1
  for step in "${steps[@]}"; do
    case $step in
      dir:*) mkdir -p "$t/${step#dir:}" || return 1 ;;
      link:*=*)
        p=${step#link:} tg=${step#*=}
        p=${p%%=*}
        [[ $tg == @/* ]] && tg=$t/${tg#@/}
        mkdir -p "$(dirname -- "$t/$p")" && ln -s -- "$tg" "$t/$p" || return 1
        ;;
      *) return 1 ;;
    esac
  done
}
CRAWL="programs that crawl the home (file search, indexers, backups) would follow the link into the cloud drive"
rr_n=0 rr_bad=()
while IFS=$'\t' read -r kind setup root; do
  rr_n=$((rr_n + 1))
  fresh
  rr_build "$T/rr" "$setup" || { rr_bad+=("unbuildable $setup"); continue; }
  export HOME=$T/rr/home
  ENVF=$HOME/.config/omarchy-cloud/cloud.env
  mkdir -p "$HOME/.config"
  r=$T/rr/$root
  [[ $kind == valid && ! -e $r ]] && mkdir -p "$r"
  runc "$INSTALL" --no-build --mount-root "$r"
  if [[ $kind == valid ]]; then
    { rc_is 0 && env_is "$r"; } || rr_bad+=("valid $setup $root rc=$RC")
  else
    { rc_is 1 && [[ ! -e $ENVF && $OUT == *"stopping, nothing was changed: the mount root "*" at or inside your home "*": $CRAWL."* ]]; } ||
      rr_bad+=("invalid $setup $root rc=$RC")
  fi
done < <(grep -v '^#' "$PLUGIN_DIR/tests/fixtures/resolved-roots.tsv" | grep $'\t')
check "resolved-roots.tsv: --mount-root saves every valid root and refuses every invalid one, nothing written ($rr_n cases${rr_bad:+; wrong: ${rr_bad[*]}})" \
  eval '((rr_n >= 15 && ${#rr_bad[@]} == 0))'
# A root that cannot be resolved (realpath failing): refused by the reader.
RPFAIL=$SCRATCH/rpfail
mkdir -p "$RPFAIL"
printf '#!/bin/bash\necho "realpath: stand-in failure" >&2\nexit 1\n' >"$RPFAIL/realpath"
chmod +x "$RPFAIL/realpath"
fresh
mkdir -p "$T/srv/cloud"
PATH="$RPFAIL:$PATH" runc "$INSTALL" --no-build --mount-root "$T/srv/cloud"
check "--mount-root, a root realpath cannot resolve: refused (exit 1), says so, nothing written" \
  eval 'rc_is 1 && [[ ! -e $ENVF && $OUT == *"stopping, nothing was changed: the mount root $T/srv/cloud could not be resolved"* ]]'
# The default root a link into the home: not adopted, the reason printed.
fresh
mkdir -p "$HOME/CloudDir" "$T/mnt"
ln -s "$HOME/CloudDir" "$T/mnt/cloud"
runc "$INSTALL" --no-build
check "root: a default root that links into HOME is not adopted; the reason, --mount-root PATH, nothing written" \
  eval 'rc_is 0 && [[ ! -e $ENVF && $OUT != *adopted* && $OUT == *"not set up, so no mount can start yet: the mount root $T/mnt/cloud resolves to $HOME/CloudDir, at or inside your home $HOME: $CRAWL."* && $OUT == *"--mount-root PATH"* && $OUT != *"sudo install"* ]]'
# Asked on a terminal: a typed root that links into the home is refused.
fresh
mkdir -p "$HOME/CloudDir" "$T/srv"
ln -s "$HOME/CloudDir" "$T/srv/link"
runi "$T/srv/link"$'\n' "$INSTALL" --no-build
check "root, asked: a typed root that links into HOME is refused with the reason, asked again, nothing written" \
  eval 'rc_is 0 && [[ ! -e $ENVF && $OUT == *"the mount root $T/srv/link resolves to $HOME/CloudDir, at or inside your home $HOME: $CRAWL."*"Type a real folder outside your home."*"Mount root ["* ]]'
# An existing setting that links into the home: named, left as it is.
mkdir -p "${ENVF%/*}"
printf 'OMARCHY_CLOUD_ROOT=%s\n' "$T/srv/link" >"$ENVF"
before=$(sha "$ENVF")
runc "$INSTALL" --no-build
check "root: an existing setting that links into HOME is named with the reason, left as it is" \
  eval 'rc_is 0 && [[ $(sha "$ENVF") == "$before" && $OUT == *"the mount root setting in $ENVF cannot be used, so no mount starts: the mount root $T/srv/link resolves to $HOME/CloudDir, at or inside your home $HOME: $CRAWL."* && $OUT == *"--mount-root PATH"* ]]'

# The diff hint pastes as is when a path holds a '.
R4="$SCRATCH/it's here"
cp -r "$R0" "$R4"
fresh
mkdir -p "$UD"
printf '[Service]\nExecStart=/bin/true\n' >"$UD/rclone-mount@.service"
runc "$R4/install.sh" --no-build
hint=$(sed -n 's/^ *compare:  //p' <<<"$OUT" | head -n 1)
check "the diff hint for a path with a ': it pastes into a shell and runs diff on the two files" \
  eval 'rc_is 1 && [[ -n $hint ]] && (cd / && bash -c "$hint" >"$T/diff" 2>&1; (($? == 1))) && grep "^+++ " "$T/diff" | grep -qF -- "$R4/systemd/rclone-mount@.service"'

# HOME-fixed (D6): with XDG_* elsewhere, nothing lands there.
fresh
mkdir -p "$T/mnt/cloud"
runc "$INSTALL" --no-build
check "HOME-fixed: units in ~/.config/systemd/user, state, config and cloud.env under HOME, nothing under XDG_*" \
  eval 'rc_is 0 && copies_ok && [[ -f $MAN && -f $ENVF && -z $(find "$T/xdg" -mindepth 2) ]]'
check "the root's other files (preview.png, docs/) are not installed" \
  eval '[[ -z $(find "$HOME" -name "*.png") ]] && manifest_all "$R0"'

# The mount unit, on a scratch copy as an instance. Its guard is the
# installed %h/.local/bin/rclone-mount (tests/scripts-test.sh covers the
# script itself); here: the unit's lines, and those lines run as systemd
# would run them against this scratch HOME's installed copy.
UNIT=$R0/systemd/rclone-mount@.service
UV=$SCRATCH/unit
mkdir -p "$UV"
cp "$UNIT" "$UV/rclone-mount@x.service"
check "fixture: this HOME has rclone-mount installed (systemd-analyze verify checks %h/.local/bin/rclone-mount)" \
  eval '[[ -x $BD/rclone-mount && $(sha "$BD/rclone-mount") == $(sha "$R0/bin/rclone-mount") ]]'
if command -v systemd-analyze >/dev/null && [[ -x /usr/bin/rclone && -x /usr/bin/fusermount3 ]]; then
  check "unit: systemd-analyze --user verify (a scratch instance)" eval 'systemd-analyze --user verify "$UV/rclone-mount@x.service" >"$T/verify" 2>&1 || { sed "s/^/     /" "$T/verify"; false; }'
else
  echo "skip unit: systemd-analyze --user verify (systemd-analyze, rclone or fusermount3 missing)"
fi
# exec_line <key>: the unit's <key>= line(s), continuations joined (a
# backslash-newline and the spaces around it read as one space).
exec_line() { sed -e ':a' -e '/\\$/N; s/ *\\\n */ /; ta' "$UNIT" | grep "^$1="; }
WANT_COND='ExecCondition=%h/.local/bin/rclone-mount check %i ${OMARCHY_CLOUD_ROOT} %h'
WANT_START='ExecStart=%h/.local/bin/rclone-mount start %i ${OMARCHY_CLOUD_ROOT} %h -- /usr/bin/rclone mount %i: ${OMARCHY_CLOUD_ROOT}/%i --cache-dir %h/.cache/rclone --vfs-cache-mode full --vfs-read-chunk-size 8M --vfs-read-chunk-size-limit 32M --vfs-read-ahead 8M --buffer-size 4M'
check "unit: one ExecCondition, through rclone-mount check (the root, the remote, %h)" eval '[[ $(exec_line ExecCondition) == "$WANT_COND" ]]'
check "unit: ExecStart runs rclone mount at \${OMARCHY_CLOUD_ROOT}/%i through rclone-mount start, the flags unchanged" \
  eval '[[ $(exec_line ExecStart) == "$WANT_START" ]]'
check "unit: no ExecStartPre (a mkdir there would run under a refused root)" eval '! exec_line ExecStartPre'
check "unit: ExecStop unmounts \${OMARCHY_CLOUD_ROOT}/%i, as before" \
  eval '[[ $(exec_line ExecStop) == "ExecStop=/usr/bin/fusermount3 -uz \${OMARCHY_CLOUD_ROOT}/%i" ]]'
check "unit: a refused start (exit 78) is not restarted; any other failure is" \
  eval '[[ $(grep -c "^RestartPreventExitStatus=" "$UNIT") == 1 && $(exec_line RestartPreventExitStatus) == RestartPreventExitStatus=78 && $(exec_line Restart) == Restart=on-failure ]]'
WANT_ENV='Environment=OMARCHY_CLOUD_ROOT=/mnt/cloud
EnvironmentFile=-%h/.config/omarchy-cloud/cloud.env'
check "unit: the default Environment=, then cloud.env (which wins), after it" \
  eval '[[ $(grep -e "^Environment=OMARCHY_CLOUD_ROOT=" -e "^EnvironmentFile=-%h/.config/omarchy-cloud/" "$UNIT") == "$WANT_ENV" ]]'
check "unit: no literal /mnt/cloud besides the default Environment= line" \
  eval '[[ $(grep -F /mnt/cloud "$UNIT") == "Environment=OMARCHY_CLOUD_ROOT=/mnt/cloud" ]]'
# The lines as systemd runs them: ${OMARCHY_CLOUD_ROOT} one word, %h and %i
# (no other $ or specifier in them, checked first), then the words split on
# spaces (there are no quotes); /usr/bin/rclone a stand-in that records its
# argv.
check "unit: the ExecCondition and ExecStart lines use no \$ but \${OMARCHY_CLOUD_ROOT}, no specifier but %h and %i" \
  eval '! exec_line "Exec\(Condition\|Start\)" | sed -e "s/[$]{OMARCHY_CLOUD_ROOT}//g" -e "s/%[hi]//g" | grep -q "[$%\"'"'"'\\\\]"'
FAKE_RCLONE=$SCRATCH/fake-rclone
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"$FAKE_LOG/rclone-mount"\n' >"$FAKE_RCLONE"
chmod +x "$FAKE_RCLONE"
unit_run() { # unit_run <key> <systemd root>: the unit's <key> line run as systemd would, for remote od
  local c
  c=$(exec_line "$1")
  c=${c#"$1"=}
  c=${c//\$\{OMARCHY_CLOUD_ROOT\}/$(printf %q "$2")}
  c=${c//%h/$(printf %q "$HOME")}
  c=${c//%i/od}
  c=${c//\/usr\/bin\/rclone /$(printf %q "$FAKE_RCLONE") }
  OUT=$(eval "$c" 2>&1)
  RC=$?
}
UR=$SCRATCH/unit-root
mkdir -p "$UR" "${ENVF%/*}"
printf 'OMARCHY_CLOUD_ROOT=%s\n' "$UR" >"$ENVF"
unit_run ExecCondition "$UR"
check "unit, as run: a valid, agreeing, usable root passes ExecCondition" rc_is 0
rm -f "$FAKE_LOG/rclone-mount"
unit_run ExecStart "$UR"
mapfile -t ra <"$FAKE_LOG/rclone-mount" 2>/dev/null
check "unit, as run: ExecStart makes <root>/od and runs rclone mount od: <root>/od with the unit's flags" \
  eval 'rc_is 0 && [[ -d $UR/od && "${ra[*]}" == "mount od: $UR/od --cache-dir $HOME/.cache/rclone --vfs-cache-mode full --vfs-read-chunk-size 8M --vfs-read-chunk-size-limit 32M --vfs-read-ahead 8M --buffer-size 4M" ]]'
printf 'OMARCHY_CLOUD_ROOT=%s\n' "$SCRATCH/no-root" >"$ENVF"
unit_run ExecCondition "$SCRATCH/no-root"
check "unit, as run: a valid root that does not exist skips (ExecCondition exit 1, one line)" \
  eval 'rc_is 1 && [[ $OUT == *"not started: the mount root $SCRATCH/no-root is not an existing directory you can write to and search"* ]]'
printf 'OMARCHY_CLOUD_ROOT="%s"\n' "$UR" >"$ENVF"
rm -rf "$UR/od" "$FAKE_LOG/rclone-mount"
unit_run ExecCondition "$UR"
rc1=$RC
unit_run ExecStart "$UR"
check "unit, as run: a quoted cloud.env value (systemd strips the quotes) goes past ExecCondition and fails ExecStart with 78, nothing made, rclone not run" \
  eval '((rc1 == 0)) && rc_is 78 && [[ $OUT == *"refusing to mount"* && ! -e $UR/od && ! -e $FAKE_LOG/rclone-mount ]]'
rm -f "$ENVF"

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
