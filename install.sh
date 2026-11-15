#!/usr/bin/env bash
# Installs the cloud plugin's helpers for the current user. Idempotent.
#
#   ./install.sh [--no-build | --from-source]
#                               copy systemd/* into ~/.config/systemd/user and
#                               bin/* into ~/.local/bin, create the config dirs,
#                               install the omarchy-cloud TUI (the prebuilt
#                               dist/ binary on x86_64 when its sha256, version
#                               and source digest match this checkout, else
#                               built with cargo; --from-source always builds;
#                               --no-build installs no TUI)
#   ./install.sh --uninstall [--force]
#                               remove what install.sh installed; never config
#                               or data. Refuses while rclone-bisync@ or
#                               rclone-backup@ instances are enabled; refuses
#                               while rclone-mount@ instances are enabled unless
#                               --force (their unit goes: they stop mounting at
#                               the next login)
#
# Every file is copied, not linked: the plugin folder can be updated, moved or
# removed without changing what systemd runs. Each copy is atomic (a temporary
# file in the target dir, then mv), mode 644 for units and 755 for programs,
# and is recorded in a manifest, ~/.local/state/omarchy-cloud/installed-files:
# two header lines, `#version=<manifest.json version>` and `#repo=<this
# checkout>` (what the widget and the TUI compare their own version against),
# then one `<sha256>  <absolute path>` line per file (the TUI binary included),
# sorted by path. The manifest is rewritten on every install, so a rerun after
# a pull records the new version even when no file changed; a manifest without
# the header lines (written by 0.3.2) is read as before and gains them. A
# version in manifest.json that is not N.N.N stops the install before any
# change.
#
# Runs already in progress are waited for: while a pair's or a job's lock
# owned by this user is held (${XDG_RUNTIME_DIR:-/tmp}/rclone-bisync-*.lock,
# rclone-backup-*.lock), install.sh names it and waits up to
# OMARCHY_CLOUD_INSTALL_WAIT_S seconds (default 60), then stops with exit 75
# and nothing changed. A run may still start right after the wait; it is
# safe because every copy is an atomic rename. Normally the locks are only
# looked at (in /proc/locks), not opened or taken, so a timer run is not made
# to skip; only when /proc/locks or findmnt is unusable does a fallback open
# each lock file read-only and probe it with `flock -n`, holding it for an
# instant.
#
# An existing file in the way is replaced only when it is absent, a symlink
# into this repo (an install by an older install.sh, which linked), identical
# to the file it would become, or listed in the manifest with the sha256 it
# still has; anything else (another program's file, or one of ours edited
# since) stops the install before any change, naming the file. A symlink in
# ~/.config/systemd/user or its *.wants/ dirs that points at this repo's
# systemd/<unit> (an enabled instance of a linked template) is re-pointed at
# the installed copy of <unit>. Instance drop-ins (*.d/) are never touched;
# nothing is enabled, disabled, started or stopped here. The binary is chosen
# and, if needed, built (into the build cache only) first, so that all this is
# decided before anything changes.
set -u

PROG=install.sh
REPO=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
UNIT_DIR=$CONFIG_HOME/systemd/user
BIN_DIR=$HOME/.local/bin
APP=omarchy-cloud
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/$APP
MANIFEST=$STATE_DIR/installed-files
MARKER=$STATE_DIR/installed-binary.sha256 # legacy (<= 0.3.1): the binary's sha256
PREBUILT_NAME=$APP-x86_64-linux-musl
DIST=$REPO/dist
USAGE="usage: $PROG [--no-build | --from-source] | --uninstall [--force]"

BUILD=1
FROM_SOURCE=0
UNINSTALL=0
FORCE=0
for arg; do
  case $arg in
    --no-build) BUILD=0 ;;
    --from-source) FROM_SOURCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --force) FORCE=1 ;;
    -h | --help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "$USAGE" >&2
      exit 64
      ;;
  esac
done
if ((FORCE && !UNINSTALL)) || ((UNINSTALL && (FROM_SOURCE || !BUILD))) || ((FROM_SOURCE && !BUILD)); then
  echo "$USAGE" >&2
  exit 64
fi

if ((EUID == 0)); then
  echo "$PROG: run as your user, not as root" >&2
  exit 1
fi

WAIT_S=${OMARCHY_CLOUD_INSTALL_WAIT_S:-60}
if ! [[ $WAIT_S =~ ^[0-9]{1,4}$ ]]; then
  echo "$PROG: OMARCHY_CLOUD_INSTALL_WAIT_S must be a number of seconds (0-9999), not '$WAIT_S'" >&2
  exit 64
fi
WAIT_S=$((10#$WAIT_S))

shopt -s nullglob

# Every (source, target, mode) this script manages, besides the binary.
SRCS=() DSTS=() MODES=()
for f in "$REPO"/systemd/*; do
  [[ -f $f ]] && SRCS+=("$f") DSTS+=("$UNIT_DIR/${f##*/}") MODES+=(644)
done
for f in "$REPO"/bin/*; do
  [[ -f $f ]] && SRCS+=("$f") DSTS+=("$BIN_DIR/${f##*/}") MODES+=(755)
done
BIN=$BIN_DIR/$APP

# ours <target>: a symlink that resolves into this repo (a link install).
ours() {
  [[ -L $1 ]] || return 1
  local t
  t=$(readlink -f -- "$1") || return 1
  [[ $t == "$REPO"/* ]]
}

reload() {
  if command -v systemctl >/dev/null; then
    systemctl --user daemon-reload || echo "$PROG: systemctl --user daemon-reload failed (no user manager?)" >&2
  fi
}

# Enabled instances of our templates: their symlinks in *.wants/ dirs.
enabled_instances() {
  local w
  for w in "$UNIT_DIR"/*.wants/rclone-mount@?*.service "$UNIT_DIR"/*.wants/rclone-bisync@?*.path \
    "$UNIT_DIR"/*.wants/rclone-bisync@?*.timer "$UNIT_DIR"/*.wants/rclone-backup@?*.timer; do
    [[ -L $w ]] && printf '%s\n' "${w##*/}"
  done | sort -u
}

# sha256 <file>: its hash, nothing else.
sha256() {
  local h
  h=$(sha256sum -- "$1") || return 1
  printf '%s' "${h%% *}"
}

# The manifest, read once: path -> recorded sha256. Only well-formed lines
# naming a file directly in one of the two dirs install.sh writes to count.
declare -A RECORDED=()
in_our_dirs() {
  [[ $1 != *"/../"* && $1 != *"/./"* ]] || return 1
  [[ ${1%/*} == "$UNIT_DIR" || ${1%/*} == "$BIN_DIR" ]]
}
if [[ -f $MANIFEST ]]; then
  while IFS= read -r line; do
    if [[ $line =~ ^([0-9a-f]{64})\ \ (/.+)$ ]] && in_our_dirs "${BASH_REMATCH[2]}"; then
      RECORDED[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
    fi
  done <"$MANIFEST"
fi
# The legacy marker: only its first 64 characters count (a marker may hold
# the hash twice, without a newline).
LEGACY_SHA=
if [[ -f $MARKER ]]; then
  LEGACY_SHA=$(head -c 64 -- "$MARKER")
  [[ $LEGACY_SHA =~ ^[0-9a-f]{64}$ ]] || LEGACY_SHA=
fi

# recorded_ours <file>: a regular file still holding the content install.sh
# recorded for it (the manifest, or for the binary the legacy marker).
recorded_ours() {
  [[ -f $1 && ! -L $1 ]] || return 1
  local want=${RECORDED[$1]:-}
  [[ -z $want && $1 == "$BIN" ]] && want=$LEGACY_SHA
  [[ -n $want && $(sha256 "$1") == "$want" ]]
}

# atomic_copy <src> <dst> <mode>: a temporary file next to dst, then mv.
atomic_copy() {
  local tmp
  tmp=$(mktemp -- "${2%/*}/.${2##*/}.XXXXXX") || return 1
  if cp -- "$1" "$tmp" && chmod "$3" -- "$tmp" && mv -f -T -- "$tmp" "$2"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# write_manifest <lines...>: atomically, the two header lines (#version=,
# #repo=) first, then the lines sorted by path.
write_manifest() {
  local tmp
  mkdir -p -- "$STATE_DIR" || return 1
  tmp=$(mktemp -- "$STATE_DIR/.installed-files.XXXXXX") || return 1
  if { printf '#version=%s\n#repo=%s\n' "$VERSION" "$REPO" && printf '%s\n' "$@" | sort -k 2; } >"$tmp" &&
    chmod 644 -- "$tmp" && mv -f -T -- "$tmp" "$MANIFEST"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Running syncs and backups: the per-pair and per-job locks bin/rclone-bisync
# and bin/rclone-backup hold for a run (their lock(), an flock). Only existing
# regular lock files owned by this user are looked at (with XDG_RUNTIME_DIR
# unset the dir is /tmp, shared with other users). The primary path never
# opens or locks them: the helpers take theirs with flock -n, so even an
# instant's probe lock would make a run starting in that instant skip.
# Instead each file's device and inode are matched against the FLOCK entries
# in /proc/locks, "<id>: FLOCK ADVISORY WRITE <pid> <maj>:<min>:<inode> 0 EOF" (waiters
# carry a "->" after the id). maj:min there is the superblock's device in
# hex, which is not stat's st_dev on btrfs (a subvolume reports its own
# anonymous device there), so it is taken from the mount table instead:
# findmnt's MAJ:MIN (decimal), the same superblock device. Every copy is an
# atomic rename, so a running helper keeps reading its old inode; this is
# belt and braces against a run that starts another helper and would see a
# mix of old and new files. Only the fallback (no usable /proc/locks or
# findmnt) opens each file read-only and probes it with flock -n for an
# instant.
#
# busy_locks: prints "<kind> <name>" for each lock held right now.
busy_locks() {
  local dir=${XDG_RUNTIME_DIR:-/tmp} f kind name dev ino type loc maj min lino
  local -A held=()
  local proc=0
  if [[ -r /proc/locks ]] && dev=$(findmnt -no MAJ:MIN -T "$dir" 2>/dev/null) &&
    dev=${dev//[[:space:]]/} && [[ $dev =~ ^[0-9]+:[0-9]+$ ]]; then
    proc=1
    while read -r _ type _ _ _ loc _; do
      [[ $type == FLOCK ]] || continue # POSIX/OFD locks, and "->" waiters
      IFS=: read -r maj min lino <<<"$loc"
      [[ $maj =~ ^[0-9a-f]+$ && $min =~ ^[0-9a-f]+$ && $lino =~ ^[0-9]+$ ]] || continue
      held["$((16#$maj)):$((16#$min)):$lino"]=1
    done </proc/locks
  fi
  for f in "$dir"/rclone-bisync-*.lock "$dir"/rclone-backup-*.lock; do
    [[ -f $f && ! -L $f && -O $f ]] || continue
    name=${f##*/}
    name=${name%.lock}
    case $name in
      rclone-bisync-*) kind="offline folder" name=${name#rclone-bisync-} ;;
      *) kind=backup name=${name#rclone-backup-} ;;
    esac
    if ((proc)); then
      # A file that vanished since the glob is not busy.
      ino=$(stat -c %i -- "$f" 2>/dev/null) || continue
      [[ -n ${held["$dev:$ino"]:-} ]] && printf '%s %s\n' "$kind" "$name"
    else
      # Fallback, /proc/locks unreadable or no mount entry for the dir: a
      # non-blocking probe lock, read-only (never creates the file). It holds
      # the lock for an instant, so a helper starting in that instant skips
      # its run (a timer retries later).
      { flock -n 8 || printf '%s %s\n' "$kind" "$name"; } 2>/dev/null 8<"$f"
    fi
  done
}

# wait_for_runs: returns once no lock is held; after WAIT_S seconds of
# waiting, stops the script (exit 75) with nothing changed.
wait_for_runs() {
  local busy l start=$SECONDS cmd=$PROG
  busy=$(busy_locks)
  [[ -z $busy ]] && return 0
  echo "$PROG: waiting (up to ${WAIT_S} s) for these runs to finish before changing anything:" >&2
  while IFS= read -r l; do echo "  $l is running" >&2; done <<<"$busy"
  while ((SECONDS - start < WAIT_S)); do
    sleep 1
    busy=$(busy_locks)
    [[ -z $busy ]] && return 0
  done
  echo "$PROG: stopping, nothing was changed: still running after ${WAIT_S} s:" >&2
  while IFS= read -r l; do echo "  $l" >&2; done <<<"$busy"
  if ((UNINSTALL)); then
    cmd="$PROG --uninstall"
    ((FORCE)) && cmd+=" --force"
  fi
  echo "  rerun $cmd when the sync or backup finishes" >&2
  exit 75
}

if ((UNINSTALL)); then
  mapfile -t enabled < <(enabled_instances)
  mounts=() others=()
  for u in "${enabled[@]}"; do
    if [[ $u == rclone-mount@* ]]; then mounts+=("$u"); else others+=("$u"); fi
  done
  if ((${#others[@]})); then
    echo "$PROG: these instances are still enabled; disable them first, then run --uninstall again:" >&2
    for u in "${others[@]}" "${mounts[@]}"; do echo "  systemctl --user disable --now $u" >&2; done
    exit 1
  fi
  if ((${#mounts[@]})) && ((!FORCE)); then
    echo "$PROG: these mounts are enabled; uninstalling removes rclone-mount@.service, so they keep" >&2
    echo "running now but are not mounted again at the next login. Disable them first:" >&2
    for u in "${mounts[@]}"; do echo "  systemctl --user disable --now $u" >&2; done
    echo "or keep them enabled and remove anyway: $PROG --uninstall --force" >&2
    exit 1
  fi
  if ((${#mounts[@]})); then
    echo "$PROG: --force: these enabled mounts lose their unit at the next login (disable with" >&2
    echo "systemctl --user disable <unit>, or rerun $PROG to restore the unit):" >&2
    for u in "${mounts[@]}"; do echo "  $u" >&2; done
  fi
  wait_for_runs
  # Links from a link install, then the files the manifest (or the legacy
  # marker) records, each only while it still has the recorded content.
  declare -A seen=()
  targets=("${DSTS[@]}" "$BIN")
  for p in "${!RECORDED[@]}"; do targets+=("$p"); done
  for p in "${targets[@]}"; do
    [[ -n ${seen[$p]:-} ]] && continue
    seen[$p]=1
    if ours "$p" && [[ $p != "$BIN" ]]; then
      rm -f -- "$p" && echo "removed $p"
    elif recorded_ours "$p"; then
      rm -f -- "$p" && echo "removed $p"
    elif [[ -e $p || -L $p ]]; then
      echo "$PROG: left $p (changed since $PROG installed it, or not installed by it)"
    fi
  done
  rm -f -- "$MANIFEST" "$MARKER"
  reload
  echo "$PROG: uninstalled; config (~/.config/rclone-*), drop-ins, enabled-instance links, state and data were kept"
  exit 0
fi

# --- the version to record: manifest.json's, N.N.N --------------------------------
VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' -- "$REPO/manifest.json" 2>/dev/null | head -n 1)
if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "$PROG: stopping, nothing was changed: $REPO/manifest.json has no \"version\" of the form N.N.N (found '${VERSION}')" >&2
  exit 1
fi
# The checkout's path goes into the manifest as one line.
if [[ $REPO == *[[:cntrl:]]* ]]; then
  echo "$PROG: stopping, nothing was changed: the checkout's path contains a control character" >&2
  exit 1
fi

# --- the binary: the prebuilt one when it fits, else a build -----------------
cargo_version() {
  sed -n '/^\[package\]/,/^\[/s/^version *= *"\([^"]*\)".*/\1/p' -- "$REPO/app/Cargo.toml" | head -n 1
}

# src_sha256: the digest of the app sources a binary is built from, the same
# recipe .github/workflows/release.yml writes into dist/BUILD-INFO: in the repo
# root, the `sha256sum` lines of app/Cargo.toml, app/Cargo.lock and every
# app/src/**/*.rs, by relative path in C-locale sorted order, hashed with
# sha256sum. Prints nothing (fails) when a file is missing or unreadable.
src_sha256() {
  local d
  d=$(cd -- "$REPO" && set -o pipefail &&
    { echo app/Cargo.toml; echo app/Cargo.lock; find app/src -type f -name '*.rs'; } | LC_ALL=C sort | xargs -d '\n' sha256sum -- | sha256sum) || return 1
  printf '%s' "${d%% *}"
}

# prebuilt_status: 0 usable (prints nothing), 1 unusable (prints why),
# 2 present but its sha256 does not match (prints why: an error, never a
# fallback to a build).
prebuilt_status() {
  local bin=$DIST/$PREBUILT_NAME sum=$DIST/$PREBUILT_NAME.sha256 info=$DIST/BUILD-INFO arch line want have
  arch=$(uname -m)
  if [[ $arch != x86_64 ]]; then
    echo "the prebuilt binary is x86_64 only (this machine is $arch)"
    return 1
  fi
  if [[ ! -f $bin || ! -f $sum ]]; then
    echo "no prebuilt binary in dist/ (a release commit carries $PREBUILT_NAME and its .sha256)"
    return 1
  fi
  line=$(head -n 1 -- "$sum")
  if ! [[ $line =~ ^[0-9a-f]{64}\ [\ *]$PREBUILT_NAME$ ]] ||
    ! (cd -- "$DIST" && sha256sum --check --strict --status -- "$PREBUILT_NAME.sha256"); then
    echo "dist/$PREBUILT_NAME does not match dist/$PREBUILT_NAME.sha256; refusing to install it."
    echo "  Restore the checkout (git status, git diff dist/) or install from source: $PROG --from-source"
    return 2
  fi
  want=$(cargo_version)
  have=$(sed -n 's/^version=//p' -- "$info" 2>/dev/null | head -n 1)
  if [[ -z $have || $have != "$want" ]]; then
    echo "the prebuilt binary is version ${have:-unknown} (dist/BUILD-INFO), this checkout is $want"
    return 1
  fi
  # The same version is not the same source: app/ can change between tags.
  want=$(src_sha256)
  have=$(sed -n 's/^src_sha256=//p' -- "$info" | head -n 1)
  if [[ -z $want || $have != "$want" ]]; then
    echo "the prebuilt binary was built from other app/ sources than this checkout's" \
      "(dist/BUILD-INFO src_sha256=${have:-none}, this checkout ${want:-unreadable})"
    return 1
  fi
}

find_cargo() {
  if command -v cargo >/dev/null; then
    command -v cargo
  elif [[ -x $HOME/.cargo/bin/cargo ]]; then
    echo "$HOME/.cargo/bin/cargo"
  else
    return 1
  fi
}

built= # the binary to install, when there is one
if ((BUILD)); then
  why=
  if ((FROM_SOURCE)); then
    why="--from-source"
  else
    why=$(prebuilt_status)
    case $? in
      0)
        built=$DIST/$PREBUILT_NAME
        echo "using the prebuilt $built ($(sed -n 's/^\(version\|commit\)=//p' -- "$DIST/BUILD-INFO" | paste -sd ' ' -))"
        ;;
      2)
        echo "$PROG: stopping, nothing was changed: $why" >&2
        exit 1
        ;;
    esac
  fi
  if [[ -z $built ]]; then
    if ! cargo=$(find_cargo); then
      echo "$PROG: cannot install the $APP TUI: $why, and cargo was not found (PATH or ~/.cargo/bin)." >&2
      echo "  Install Rust (https://rustup.rs, or pacman -S rust) to build it from source," >&2
      echo "  or rerun with --no-build to install everything but the TUI (an installed" >&2
      echo "  $APP is kept as it is)." >&2
      exit 1
    fi
    echo "building $APP from source ($why)"
    target=${XDG_CACHE_HOME:-$HOME/.cache}/$APP/target
    CARGO_TARGET_DIR=$target "$cargo" build --release --locked --manifest-path "$REPO/app/Cargo.toml" || exit 1
    built=$target/release/$APP
    if [[ ! -f $built ]]; then
      echo "$PROG: the build reported success but $built does not exist" >&2
      exit 1
    fi
  fi
fi

# --- preflight: decide for every target before changing anything --------------
blocked=0
in_the_way() { # in_the_way <target> <hint...>
  if ((!blocked)); then
    echo "$PROG: stopping, nothing was changed. These files are in the way and are not what $PROG installed:" >&2
  fi
  blocked=1
  echo "  $1" >&2
  shift
  local l
  for l; do echo "      $l" >&2; done
}
for i in "${!DSTS[@]}"; do
  s=${SRCS[i]} d=${DSTS[i]}
  if [[ ! -e $d && ! -L $d ]] || ours "$d" || recorded_ours "$d"; then
    continue
  fi
  if [[ -f $d ]] && cmp -s -- "$d" "$s"; then
    continue # identical content (a regular file, or a link to one)
  fi
  in_the_way "$d" "compare:  diff -u '$d' '$s'" \
    "once it is migrated (its instances stopped, the file moved aside), run $PROG again"
done
if [[ -n $built ]] && [[ -e $BIN || -L $BIN ]] &&
  ! { [[ -f $BIN && ! -L $BIN ]] && cmp -s -- "$BIN" "$built"; } && ! recorded_ours "$BIN"; then
  in_the_way "$BIN" "not the binary $PROG installed (its sha256 is not the one recorded in $MANIFEST)" \
    "move it aside (or rerun with --no-build to keep it), then run $PROG again"
fi
((blocked)) && exit 1

wait_for_runs

# --- install --------------------------------------------------------------------
# mkdir -p, not install -d -m 755: an existing dir keeps its mode.
mkdir -p -- "$UNIT_DIR" "$BIN_DIR" || exit 1
migrated=0 changed=0
declare -A NEW=() # path -> sha256 of what is installed there now
for i in "${!DSTS[@]}"; do
  s=${SRCS[i]} d=${DSTS[i]} m=${MODES[i]}
  if [[ -f $d && ! -L $d ]] && cmp -s -- "$d" "$s" && [[ $(stat -c %a -- "$d") == "$m" ]]; then
    NEW[$d]=$(sha256 "$d")
    continue
  fi
  ours "$d" && migrated=1
  atomic_copy "$s" "$d" "$m" || exit 1
  NEW[$d]=$(sha256 "$d")
  changed=1
  echo "installed $d"
done

# Links that point at this repo's systemd/<unit> (instances enabled while the
# template was linked) now point at the installed copy. The link's own last
# component is not followed: only the directory it names is resolved.
declare -A UNIT_SRC=()
for s in "${SRCS[@]}"; do [[ $s == "$REPO/systemd/"* ]] && UNIT_SRC[${s##*/}]=1; done
for l in "$UNIT_DIR"/* "$UNIT_DIR"/*.wants/*; do
  [[ -L $l ]] || continue
  t=$(readlink -- "$l") || continue
  [[ $t == /* ]] || t=${l%/*}/$t
  base=${t##*/}
  dir=$(readlink -f -- "${t%/*}") || continue
  [[ $dir == "$REPO/systemd" && -n ${UNIT_SRC[$base]:-} ]] || continue
  tmp=$l.omarchy-cloud-tmp.$$
  if ln -s -- "$UNIT_DIR/$base" "$tmp" && mv -f -T -- "$tmp" "$l"; then
    echo "re-pointed $l -> $UNIT_DIR/$base"
    migrated=1 changed=1
  else
    rm -f -- "$tmp"
    echo "$PROG: could not re-point $l (it still points at $t)" >&2
    exit 1
  fi
done

for d in "$CONFIG_HOME/rclone-bisync" "$CONFIG_HOME/rclone-backup"; do
  install -d -m 700 "$d" && chmod 700 "$d" || exit 1
done

if [[ -n $built ]]; then
  if ! { [[ -f $BIN && ! -L $BIN ]] && cmp -s -- "$BIN" "$built" && [[ $(stat -c %a -- "$BIN") == 755 ]]; }; then
    atomic_copy "$built" "$BIN" 755 || exit 1
    echo "installed $BIN"
  fi
  NEW[$BIN]=$(sha256 "$BIN")
elif recorded_ours "$BIN"; then
  NEW[$BIN]=$(sha256 "$BIN") # --no-build: still ours, keep it recorded
fi
# Other recorded files (a unit a later version dropped): kept in the manifest
# while they still hold the recorded content, so --uninstall can remove them.
for p in "${!RECORDED[@]}"; do
  [[ -z ${NEW[$p]:-} ]] && recorded_ours "$p" && NEW[$p]=${RECORDED[$p]}
done
lines=()
for p in "${!NEW[@]}"; do lines+=("${NEW[$p]}  $p"); done
write_manifest "${lines[@]}" || exit 1
rm -f -- "$MARKER"

reload

if ((migrated)); then
  echo "$PROG: migrated a link install to copies. Running units keep running: systemd reads the"
  echo "copied unit files from the daemon-reload above, so nothing needs restarting. From now on an"
  echo "update of the plugin folder changes nothing installed until $PROG is run again."
elif ((changed)); then
  echo "$PROG: installed files changed; systemd reads the unit files from the daemon-reload above"
  echo "(running units keep running and use them from their next start; no restart needed)."
fi
echo "$PROG: done; nothing was enabled. Configure with: $APP"
