#!/usr/bin/env bash
# Installs the cloud plugin's helpers for the current user. Idempotent.
#
#   ./install.sh [--no-build | --from-source] [--no-prompt | --mount-root PATH]
#                               copy systemd/* into ~/.config/systemd/user and
#                               bin/* into ~/.local/bin, create the config dirs,
#                               install the omarchy-cloud TUI (the prebuilt
#                               dist/ binary on x86_64 when its sha256, version
#                               and source digest match this checkout, else
#                               built with cargo; --from-source always builds;
#                               --no-build installs no TUI), then set up the
#                               mount root (below)
#   ./install.sh --uninstall [--force]
#                               remove what install.sh installed; never config
#                               or data. Refuses while rclone-bisync@ or
#                               rclone-backup@ instances are enabled; refuses
#                               while rclone-mount@ instances are enabled unless
#                               --force (their unit goes: they stop mounting at
#                               the next login)
#
# The mount root: mounts live at <root>/<remote>, outside $HOME, with
# ~/Cloud/<remote> a symlink to them. The setting is the one line
# OMARCHY_CLOUD_ROOT=<path> in ~/.config/omarchy-cloud/cloud.env (absent:
# /mnt/cloud). After installing, with no setting yet: a /mnt/cloud you own
# and can write to and search is adopted (one line says so); else, on a
# terminal, you are asked for the root (Enter takes /mnt/cloud) and, when it
# does not exist or you cannot write to and search it, shown the one sudo
# command that creates it (to run yourself: install.sh never runs sudo).
# Without a terminal, or with --no-prompt, nothing is written and the
# instructions are printed.
# --mount-root PATH saves PATH (an existing directory you can write to and
# search, outside $HOME, also with its symlinks resolved: a link into the
# home is refused, as by every reader) without asking; it refuses while a
# rclone-mount@ instance is enabled or active, and it moves no mount and no
# ~/Cloud link (links into the old root are listed). An existing cloud.env is never
# rewritten except by --mount-root, and --uninstall keeps it.
#
# All paths are HOME-fixed: ~/.config, ~/.local/state, ~/.cache; the XDG_*
# variables are not followed (the services run under the user manager, whose
# environment usually lacks them).
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
# owned by this user is held (rclone-bisync-*.lock, rclone-backup-*.lock in
# the helpers' private lock folder ~/.local/state/omarchy-cloud/locks,
# whatever XDG_RUNTIME_DIR is; never /tmp), install.sh names it and waits up to
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
CONFIG_HOME=$HOME/.config
UNIT_DIR=$CONFIG_HOME/systemd/user
BIN_DIR=$HOME/.local/bin
APP=omarchy-cloud
STATE_DIR=$HOME/.local/state/$APP
MANIFEST=$STATE_DIR/installed-files
MARKER=$STATE_DIR/installed-binary.sha256 # legacy (<= 0.3.1): the binary's sha256
PREBUILT_NAME=$APP-x86_64-linux-musl
DIST=$REPO/dist
ROOT_DIR=$CONFIG_HOME/$APP
CLOUD_ENV=$ROOT_DIR/cloud.env
# The default mount root. OMARCHY_CLOUD_TEST_DEFAULT_ROOT is for
# tests/install-test.sh only (a scratch stand-in, as this machine may own a
# real /mnt/cloud); the unit's default is /mnt/cloud whatever it says.
DEFAULT_ROOT=${OMARCHY_CLOUD_TEST_DEFAULT_ROOT:-/mnt/cloud}
USAGE="usage: $PROG [--no-build | --from-source] [--no-prompt | --mount-root PATH] | --uninstall [--force]"

BUILD=1
FROM_SOURCE=0
UNINSTALL=0
FORCE=0
NO_PROMPT=0
MOUNT_ROOT='' SET_ROOT=0
while (($#)); do
  arg=$1
  shift
  case $arg in
    --no-prompt) NO_PROMPT=1 ;;
    --mount-root)
      if ((!$# || SET_ROOT)); then
        echo "$USAGE" >&2
        exit 64
      fi
      MOUNT_ROOT=$1 SET_ROOT=1
      shift
      ;;
    --no-build) BUILD=0 ;;
    --from-source) FROM_SOURCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --force) FORCE=1 ;;
    -h | --help)
      # The comment up to the copy rules: the usage, the mount root, the paths.
      sed -n '2,/^# Every file is copied/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "$USAGE" >&2
      exit 64
      ;;
  esac
done
if ((FORCE && !UNINSTALL)) || ((UNINSTALL && (FROM_SOURCE || !BUILD || NO_PROMPT || SET_ROOT))) ||
  ((FROM_SOURCE && !BUILD)) || ((NO_PROMPT && SET_ROOT)); then
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

# sq <string>: single-quoted for a shell, a ' inside as '\'' (pastes as is).
sq() {
  local q="'\\''"
  printf "'%s'" "${1//\'/$q}"
}

# --- valid_root (shared: bin/rclone-bisync, bin/rclone-backup, bin/rclone-mount, install.sh; tests/fixtures/roots.tsv) ---
# valid_root PATH: 0 when PATH may be the mount root. Absolute, not "/", no
# empty / "." / ".." component, no whitespace, control character, $ % \ " ' or
# backquote, not $HOME nor inside it ($HOME as norm_home gives it; a $HOME
# that normalises to "/" is no home: the rule is skipped;
# tests/fixtures/homes.tsv), at most 255 bytes; valid UTF-8 (valid_utf8)
# without U+FFFD (EF BF BD, what a lossy decoder puts in place of a bad
# byte), so a reader that decodes the path as text and one that reads bytes
# reach the same verdict.
valid_root() {
  local LC_ALL=C p=$1 home
  norm_home home "$HOME"
  [[ $p == /?* && ${#p} -le 255 ]] || return 1
  [[ $p == *[[:space:][:cntrl:]\$%\\\"\'\`]* ]] && return 1
  [[ $p/ == *//* || $p/ == */./* || $p/ == */../* ]] && return 1
  [[ -n $home && ($p == "$home" || $p == "$home"/*) ]] && return 1
  [[ $p == *$'\xef\xbf\xbd'* ]] && return 1
  valid_utf8 "$p"
}
# valid_utf8 STRING: 0 when STRING is well-formed UTF-8, checked byte by byte
# (C locale): no stray continuation byte, no truncated sequence, no overlong
# form (C0, C1, E0 80-9F, F0 80-8F), no surrogate (ED A0-BF), nothing past
# U+10FFFF (F4 90-BF, F5-FF).
valid_utf8() {
  local LC_ALL=C
  local s=$1 i=0 n=${#1} b need lo hi
  while ((i < n)); do
    printf -v b '%d' "'${s:i:1}"
    ((b < 0)) && b=$((b + 256))
    i=$((i + 1))
    if ((b < 0x80)); then continue
    elif ((b >= 0xc2 && b <= 0xdf)); then need=1 lo=0x80 hi=0xbf
    elif ((b == 0xe0)); then need=2 lo=0xa0 hi=0xbf
    elif ((b == 0xed)); then need=2 lo=0x80 hi=0x9f
    elif ((b >= 0xe1 && b <= 0xef)); then need=2 lo=0x80 hi=0xbf
    elif ((b == 0xf0)); then need=3 lo=0x90 hi=0xbf
    elif ((b >= 0xf1 && b <= 0xf3)); then need=3 lo=0x80 hi=0xbf
    elif ((b == 0xf4)); then need=3 lo=0x80 hi=0x8f
    else return 1; fi
    while ((need > 0)); do
      ((i < n)) || return 1
      printf -v b '%d' "'${s:i:1}"
      ((b < 0)) && b=$((b + 256))
      ((b >= lo && b <= hi)) || return 1
      need=$((need - 1)) lo=0x80 hi=0xbf i=$((i + 1))
    done
  done
  return 0
}
# norm_home VAR HOME: sets VAR to HOME normalised as every reader does
# (tests/fixtures/homes.tsv): runs of / collapsed, every "." component and
# every trailing / dropped, ".." kept as written; empty when that leaves "/"
# or nothing (no home).
norm_home() {
  local _h=$2/ _c _out='' _lead=''
  [[ $2 == /* ]] && _lead=/
  while [[ -n $_h ]]; do
    _c=${_h%%/*} _h=${_h#*/}
    [[ -z $_c || $_c == . ]] && continue
    _out+=${_out:+/}$_c
  done
  printf -v "$1" '%s' "${_out:+$_lead$_out}"
}
# --- end valid_root ---

# --- root_outside_home (shared: bin/rclone-bisync, bin/rclone-backup, bin/rclone-mount, install.sh; tests/fixtures/resolved-roots.tsv) ---
# root_outside_home ROOT: ROOT (one that passes valid_root) judged with its
# symlinks resolved (realpath -m: missing components are fine, a dangling
# link is followed as far as it goes; cut off after 5 s), against the home
# as written (norm_home) and resolved. Programs that crawl the home (file
# search, indexers, backups) would follow a link into the cloud drive, so:
#   0  ROOT resolves outside the home (or there is no home);
#   1  ROOT resolves to the home or inside it: refused;
#   2  ROOT (or the home) could not be resolved: realpath missing, failing
#      or hung (a reader refuses it; rclone-mount start retries it).
# On 1 and 2, ROOT_WHY is the reason, one clause (paths through printf %q).
root_outside_home() {
  local LC_ALL=C home real hr h where
  ROOT_WHY=''
  norm_home home "$HOME"
  if ! real=$(timeout -k 1 5 realpath -m -- "$1" 2>/dev/null) || [[ $real != /* ]]; then
    printf -v ROOT_WHY 'the mount root %q could not be resolved (realpath is missing, failed or did not answer within 5 s)' "$1"
    return 2
  fi
  [[ -n $home ]] || return 0
  hr=$home
  if [[ $home == /* ]] && { ! hr=$(timeout -k 1 5 realpath -m -- "$home" 2>/dev/null) || [[ $hr != /* ]]; }; then
    printf -v ROOT_WHY 'your home %q could not be resolved (realpath is missing, failed or did not answer within 5 s)' "$home"
    return 2
  fi
  for h in "$home" "$hr"; do
    [[ $h == / ]] && continue
    [[ $real == "$h" || $real == "$h"/* ]] || continue
    if [[ $real == "$1" ]]; then
      printf -v where 'the mount root %q is' "$1"
    else
      printf -v where 'the mount root %q resolves to %q,' "$1" "$real"
    fi
    if [[ $h == "$home" ]]; then
      printf -v ROOT_WHY '%s at or inside your home %q' "$where" "$home"
    else
      printf -v ROOT_WHY '%s at or inside your home %q (which resolves to %q)' "$where" "$home" "$hr"
    fi
    ROOT_WHY+=': programs that crawl the home (file search, indexers, backups) would follow the link into the cloud drive'
    return 1
  done
  return 0
}
# --- end root_outside_home ---

# --- lock_dir (shared: bin/rclone-bisync, bin/rclone-backup, install.sh) ---
# lock_dir VAR [create]: sets VAR to the folder of the run locks
# (rclone-bisync-<pair>.lock, rclone-backup-<job>.lock):
# ~/.local/state/omarchy-cloud/locks, HOME-fixed like every other path (a
# timer run and a shell run of the same job must lock the same file, whatever
# XDG_RUNTIME_DIR each has). Never a shared folder such as /tmp, where another
# account could plant a symlink at the predictable name. Both
# ~/.local/state/omarchy-cloud and its locks folder must be real folders (not
# symlinks, never followed) you own and not writable by group or others; with
# "create" a missing one is made 700 (install -d). Otherwise status 1, VAR
# empty and LOCK_WHY the reason.
# shellcheck disable=SC2034 # LOCK_WHY is read by the callers (not install.sh)
lock_dir() {
  local LC_ALL=C _p _st _uid _m
  printf -v "$1" '%s' ''
  LOCK_WHY=''
  for _p in "$HOME/.local/state/omarchy-cloud" "$HOME/.local/state/omarchy-cloud/locks"; do
    if [[ ${2:-} == create && ! -e $_p && ! -L $_p ]]; then
      install -d -m 700 -- "$_p" 2>/dev/null
    fi
    # stat without -L: a symlink is seen as one, never followed.
    _st=$(stat -c '%u %f' -- "$_p" 2>/dev/null)
    if ! [[ $_st =~ ^([0-9]+)\ ([0-9a-f]+)$ ]]; then
      LOCK_WHY="the run lock folder $_p is missing and could not be created"
      return 1
    fi
    _uid=${BASH_REMATCH[1]} _m=$((16#${BASH_REMATCH[2]}))
    if (((_m & 8#170000) == 8#120000)); then
      LOCK_WHY="the run lock folder $_p is a symlink; remove it (it is made again, private)"
      return 1
    elif (((_m & 8#170000) != 8#040000)); then
      LOCK_WHY="the run lock folder $_p is not a folder; remove it (it is made again, private)"
      return 1
    elif ((_uid != EUID)); then
      LOCK_WHY="the run lock folder $_p is not owned by you (owner uid $_uid)"
      return 1
    elif ((_m & 8#022)); then
      printf -v LOCK_WHY 'the run lock folder %s is writable by other accounts (mode %04o); run chmod go-w %s' "$_p" "$((_m & 8#7777))" "$_p"
      return 1
    fi
  done
  printf -v "$1" '%s' "$_p"
}
# --- end lock_dir ---

# The mount-root setting (cloud.env), parsed, never sourced: at most 4096
# bytes; empty and # lines skipped; one trailing \r dropped; the value of the
# last OMARCHY_CLOUD_ROOT= line, verbatim. ROOT_STATE: absent (no file or no
# such line), invalid (fails valid_root, not a regular file, or unreadable)
# or valid; ROOT_VALUE.
read_root_setting() {
  local line text
  ROOT_STATE=absent ROOT_VALUE=
  [[ -e $CLOUD_ENV || -L $CLOUD_ENV ]] || return 0
  # A regular file only: a FIFO (or a device) would block the read. A NUL
  # becomes \x01 (after the cap: same bytes): bash would drop it, and the
  # other readers see a control character, so the value is invalid.
  if [[ ! -f $CLOUD_ENV ]] || ! text=$(
    set -o pipefail
    head -c 4096 -- "$CLOUD_ENV" 2>/dev/null | tr '\0' '\1'
  ); then
    ROOT_STATE=invalid
    return 0
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == '#'* ]] && continue
    [[ $line == OMARCHY_CLOUD_ROOT=* ]] && ROOT_STATE=set ROOT_VALUE=${line#OMARCHY_CLOUD_ROOT=}
  done <<<"$text"
  if [[ $ROOT_STATE == set ]]; then
    if valid_root "$ROOT_VALUE"; then ROOT_STATE=valid; else ROOT_STATE=invalid; fi
  fi
}

# usable_root <path>: an existing directory this user can write to and
# search (x: without it nothing inside can be reached, the mount point
# included).
usable_root() { [[ -d $1 && -w $1 && -x $1 ]]; }

# mkroot_hint <path>: the one command that creates <path> for this user (run
# by the user: install.sh never runs sudo).
mkroot_hint() {
  echo "  create it once, in a terminal (it needs root, so $PROG does not do it):"
  echo "    sudo install -d -o \"\$USER\" -m 755 $(sq "$1")"
}

# save_root <path>: cloud.env, atomically, mode 600 in a 700 dir.
save_root() {
  local tmp
  { install -d -m 700 -- "$ROOT_DIR" && chmod 700 -- "$ROOT_DIR"; } || return 1
  tmp=$(mktemp -- "$ROOT_DIR/.cloud.env.XXXXXX") || return 1
  if printf 'OMARCHY_CLOUD_ROOT=%s\n' "$1" >"$tmp" && chmod 600 -- "$tmp" && mv -f -T -- "$tmp" "$CLOUD_ENV"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# mount_units: rclone-mount@ instances enabled (a *.wants/ link) or active
# (running, starting, stopping or waiting to restart) now.
mount_units() {
  {
    enabled_instances | grep '^rclone-mount@'
    if command -v systemctl >/dev/null; then
      systemctl --user list-units --all --plain --no-legend 'rclone-mount@*' 2>/dev/null |
        awk '$1 ~ /^rclone-mount@./ && $3 != "inactive" && $3 != "failed" { print $1 }'
    fi
  } | sort -u
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
# #repo=) first, then, when the mount-root setting exists, `#config=<its
# path>` (user config: never removed, never rewritten unasked), then the
# lines sorted by path.
write_manifest() {
  local tmp
  # 700 when made here: it also holds the helpers' run locks (lock_dir), which
  # refuse a folder writable by other accounts (a umask of 002).
  [[ -d $STATE_DIR ]] || install -d -m 700 -- "$STATE_DIR" || return 1
  tmp=$(mktemp -- "$STATE_DIR/.installed-files.XXXXXX") || return 1
  if { printf '#version=%s\n#repo=%s\n' "$VERSION" "$REPO" &&
    { [[ ! -f $CLOUD_ENV ]] || printf '#config=%s\n' "$CLOUD_ENV"; } &&
    printf '%s\n' "$@" | sort -k 2; } >"$tmp" &&
    chmod 644 -- "$tmp" && mv -f -T -- "$tmp" "$MANIFEST"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Running syncs and backups: the per-pair and per-job locks bin/rclone-bisync
# and bin/rclone-backup hold for a run (their lock(), an flock). Only existing
# regular lock files owned by this user, in the folder lock_dir gives (never
# created here; none usable: no lock is held), are looked at. The primary path never
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
  local dir f kind name dev ino type loc maj min lino
  local -A held=()
  local proc=0
  lock_dir dir || return 0
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
  echo "$PROG: uninstalled; config (~/.config/rclone-*, the mount root in $CLOUD_ENV), drop-ins, enabled-instance links, state and data were kept"
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

# --- --mount-root: decided before anything changes ----------------------------
read_root_setting
OLD_ROOT=$DEFAULT_ROOT
[[ $ROOT_STATE == valid ]] && OLD_ROOT=$ROOT_VALUE
if ((SET_ROOT)); then
  if ! valid_root "$MOUNT_ROOT"; then
    echo "$PROG: stopping, nothing was changed: --mount-root $(sq "$MOUNT_ROOT") cannot be the mount root." >&2
    echo "  It must be an absolute path outside your home ($HOME), not /, with no empty, . or .." >&2
    echo "  component, no space, control character, \$ % \\ \" ' or backquote, valid UTF-8" >&2
    echo "  (no U+FFFD), at most 255 bytes." >&2
    exit 1
  fi
  if ! root_outside_home "$MOUNT_ROOT"; then
    echo "$PROG: stopping, nothing was changed: $ROOT_WHY." >&2
    echo "  Choose a real folder outside your home: $PROG --mount-root PATH" >&2
    exit 1
  fi
  if ! usable_root "$MOUNT_ROOT"; then
    echo "$PROG: stopping, nothing was changed: $(sq "$MOUNT_ROOT") is not a directory you can write to and search;" >&2
    mkroot_hint "$MOUNT_ROOT" >&2
    echo "  then run $PROG --mount-root $(sq "$MOUNT_ROOT") again" >&2
    exit 1
  fi
  if [[ $ROOT_STATE == valid && $ROOT_VALUE == "$MOUNT_ROOT" ]]; then
    SET_ROOT=0 # already the setting: nothing to change, nothing to refuse
  else
    mapfile -t busy_mounts < <(mount_units)
    if ((${#busy_mounts[@]})); then
      echo "$PROG: stopping, nothing was changed: these mounts are enabled or running at the current" >&2
      echo "root ($OLD_ROOT), and a unit started there must stop there. Stop and disable them first," >&2
      echo "then run $PROG --mount-root $(sq "$MOUNT_ROOT") again (and enable them again after):" >&2
      for u in "${busy_mounts[@]}"; do echo "  systemctl --user disable --now $u" >&2; done
      exit 1
    fi
  fi
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
    target=$HOME/.cache/$APP/target
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
  in_the_way "$d" "compare:  diff -u $(sq "$d") $(sq "$s")" \
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
# --- the mount root ---------------------------------------------------------------
# root_not_set_up <path>: the instructions when no usable root is set.
root_not_set_up() {
  if ! root_outside_home "$1"; then
    echo "$PROG: the mount root is not set up, so no mount can start yet: $ROOT_WHY."
    echo "  Nothing was written. Choose a real folder outside your home you can write to and search:"
    echo "    $PROG --mount-root PATH"
    return 0
  fi
  echo "$PROG: the mount root is not set up, so no mount can start yet. Mounts go to <root>/<remote>"
  echo "(outside your home; ~/Cloud/<remote> links to them), and $(sq "$1") is not a directory you"
  echo "own and can write to and search. Nothing was written."
  mkroot_hint "$1"
  echo "  then run $PROG again; or choose a folder outside your home you can write to and search:"
  echo "    $PROG --mount-root PATH"
}
# ask_root: on a terminal, until a root is saved or the input ends.
ask_root() {
  local proposed=$DEFAULT_ROOT ans
  echo "Mounts go to <root>/<remote>, outside your home (~/Cloud/<remote> links to them)."
  while :; do
    printf 'Mount root [%s] (Enter to accept, or type another path): ' "$proposed"
    if ! IFS= read -r ans; then
      echo
      root_not_set_up "$proposed"
      return 0
    fi
    [[ -n $ans ]] && proposed=$ans
    if ! valid_root "$proposed"; then
      echo "  $(sq "$proposed") cannot be the mount root: it must be an absolute path outside your home,"
      echo "  not /, with no space, \$ % \\ \" ' or backquote, no . or .. component, valid UTF-8."
      proposed=$DEFAULT_ROOT
      continue
    fi
    if ! root_outside_home "$proposed"; then
      echo "  $ROOT_WHY."
      echo "  Type a real folder outside your home."
      proposed=$DEFAULT_ROOT
      continue
    fi
    if usable_root "$proposed"; then
      save_root "$proposed" || exit 1
      ROOT_WRITTEN=1
      echo "$PROG: mount root set to $proposed (in $CLOUD_ENV)"
      return 0
    fi
    echo "  $(sq "$proposed") is not a directory you can write to and search;"
    mkroot_hint "$proposed"
    echo "  Run it in another terminal, then press Enter to check again, or type another path."
  done
}
ROOT_WRITTEN=0
if ((SET_ROOT)); then
  save_root "$MOUNT_ROOT" || exit 1
  ROOT_WRITTEN=1
  echo "$PROG: mount root set to $MOUNT_ROOT (was $OLD_ROOT; in $CLOUD_ENV). Mounts start there from their next start."
  stale=()
  for l in "$HOME/Cloud"/*; do
    [[ -L $l ]] || continue
    t=$(readlink -- "$l") || continue
    [[ $t == "$OLD_ROOT" || $t == "$OLD_ROOT"/* ]] && stale+=("$l -> $t")
  done
  if ((${#stale[@]})); then
    echo "$PROG: these links still point into the old root and were not changed (re-point them yourself):"
    for l in "${stale[@]}"; do echo "  $l"; done
  fi
elif [[ $ROOT_STATE == valid ]]; then
  if ! root_outside_home "$ROOT_VALUE"; then
    echo "$PROG: the mount root setting in $CLOUD_ENV cannot be used, so no mount starts: $ROOT_WHY."
    echo "  It was left as it is. Choose a real folder outside your home: $PROG --mount-root PATH"
  elif ! usable_root "$ROOT_VALUE"; then
    echo "$PROG: the mount root $(sq "$ROOT_VALUE") (from $CLOUD_ENV) is not a directory you can write to and search;"
    mkroot_hint "$ROOT_VALUE"
  fi
# A cloud.env without the line is not set up either (the TUI and the panel
# read an absent key as no root): no default is assumed for it.
elif [[ $ROOT_STATE == invalid || -e $CLOUD_ENV || -L $CLOUD_ENV ]]; then
  echo "$PROG: $CLOUD_ENV holds no usable OMARCHY_CLOUD_ROOT=<path> line; it was left as it is."
  echo "  Edit it, or set the root with: $PROG --mount-root PATH"
elif valid_root "$DEFAULT_ROOT" && root_outside_home "$DEFAULT_ROOT" && [[ -d $DEFAULT_ROOT && -O $DEFAULT_ROOT && -w $DEFAULT_ROOT && -x $DEFAULT_ROOT ]]; then
  save_root "$DEFAULT_ROOT" || exit 1
  ROOT_WRITTEN=1
  echo "$PROG: mount root: adopted your existing $DEFAULT_ROOT (saved in $CLOUD_ENV)"
# Asked only on a terminal. OMARCHY_CLOUD_TEST_TTY=1 is for
# tests/install-test.sh only: it answers from a pipe as if stdin were one.
elif ((NO_PROMPT)) || ! { [[ -t 0 ]] || [[ ${OMARCHY_CLOUD_TEST_TTY:-} == 1 ]]; }; then
  root_not_set_up "$DEFAULT_ROOT"
else
  ask_root
fi
# The manifest names the setting once it exists (as user config).
((ROOT_WRITTEN)) && { write_manifest "${lines[@]}" || exit 1; }

echo "$PROG: done; nothing was enabled. Configure with: $APP"
