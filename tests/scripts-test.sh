#!/bin/bash

# The helper scripts (bin/rclone-bisync, bin/rclone-backup, bin/rclone-mount), hermetic:
# stand-ins for rclone, systemctl, notify-send and date come first on PATH and record their argv (one line per call, each argument through
# printf %q; notify-send also keeps its last argv NUL-separated); HOME and the
# XDG_* dirs point into a scratch dir (the XDG_* ones away from HOME, which the
# scripts must ignore), and the mounts table the cloud guard reads is a
# scratch file. The real rclone is never run,
# no unit is touched, nothing outside the scratch dir is written. install.sh
# has its own suite (tests/install-test.sh).
#
#   1. bash -n, and shellcheck when installed.
#   2. Conf parsing: a valid pair, an unknown key, a bad name, a conf that would
#      run code if sourced, a missing LOCAL, INTERVAL (at least 30s, s|min|h|d),
#      a CRLF conf; every line of tests/fixtures/names.tsv through both scripts;
#      the shared valid_root: its marker blocks in the three scripts and
#      install.sh byte-identical, every line of tests/fixtures/roots.tsv
#      (read as raw bytes) through each, and the UTF-8 forms a TSV line does
#      not spell out (overlong, surrogate, past U+10FFFF, truncated);
#      every line of tests/fixtures/homes.tsv through each valid_root (HOME
#      set per line); the shared root_outside_home: its marker blocks
#      byte-identical, every line of tests/fixtures/resolved-roots.tsv
#      through each (the tree built per the fixture's header), status 2 when
#      realpath fails or hangs;
#      HOME-fixed paths (XDG_CONFIG_HOME / XDG_STATE_HOME ignored);
#      backup FILES with .., an absolute path, duplicate copy names, empty.
#   3. rclone-bisync: run passes exactly the safety flags and bisync's exit
#      code; a busy lock: run exits 0, resync and dry-run 75, without rclone;
#      check's three outcomes; resync refuses (exit 3, never --resync) when
#      check differs or fails, and runs when check passes; non-bisync commands
#      take the filter as --filter-from; FILTER= (empty) is no filter; the
#      workdir is pinned; an empty pair is check/resync exit 4;
#      conflicts are listed (even those the filter hides), notified and written
#      to the state file; a hostile copy name reaches the notification without
#      < > & (and, when the shell's Markup.js is installed, renders no link); setup writes the drop-ins (and warns when the filter
#      excludes conflict copies), teardown removes them; validate; the guards
#      (backup DEST, other pairs' LOCAL, cloud locations and FUSE mounts, in
#      both directions: LOCAL inside one or containing one; the configured
#      mount root of cloud.env, parsed and validated, never run; one that
#      links into the home still a cloud location: fail closed); a
#      hung FUSE mount: the guards never resolve a path in it and a run
#      completes, setup and validate still refuse; a hung realpath elsewhere is
#      cut off after 5 s.
#   4. rclone-backup: the copy names follow the reference naming rule (job@
#      prefix) on representative path shapes; prune keeps the newest KEEP per
#      file and never touches legacy (unprefixed) copies; modes (only a new DEST
#      is made 700, the missing folders above it too); a DEST other accounts
#      could redirect (group/other-writable, under a non-sticky
#      group/other-writable folder, a file) refused by run (exit 64, notified
#      with the fix, before any copy; planted symlinks never written through;
#      a missing DEST made 0777, or a symlink, by another account while the
#      run waits for its lock; a stat that hangs or fails other than ENOENT),
#      setup and validate, a sticky parent and a DEST symlinked to a private
#      folder accepted (written resolved); the per-run private staging folder
#      (never left behind, an interrupted run's removed, another job's kept)
#      and the legacy .part cleanup; a failure (copy or mv) notifies and does
#      not prune; a busy job lock exits 0; only `rclone copyto <remote> <local>`;
#      validate; the guards (pairs' LOCAL, other jobs' DEST, cloud locations,
#      both directions), the same hung-mount cases; a hostile path in the
#      failure notification is stripped of < > &; every case of
#      tests/fixtures/files-lines.tsv (a conf with its STRIP_PREFIX, a files
#      list of its lines) through `list`, under LC_ALL=C and C.UTF-8.
#   5. The generated drop-ins against the repo's templates, through the real
#      systemd (`systemd --test`, `systemd-analyze verify`), read-only.
#   6. rclone-mount (the mount unit's guard): every line of roots.tsv end to
#      end (a scratch cloud.env holding it: refused = exit 78 and nothing
#      created, valid = mounted, or skipped when the root cannot exist
#      here); systemd's value differing from the raw file (quotes, an
#      indented line, invalid UTF-8, past 4096 bytes); %h with a trailing /;
#      check's skip (exit 1 and one line) for a valid root that is missing,
#      not writable or not searchable; start never creates the root, execs
#      the command (same PID, argv intact, the environment's HOME); every
#      line of names.tsv as the remote; usage errors; <root>/<remote> a
#      file or a symlink (to a folder outside or inside the home, dangling):
#      78; the transient failures, 75, never 78: a stale FUSE mount (stand-in
#      stat and fusermount3 on PATH: cleared then mounted, or fusermount3
#      failing, missing, not clearing it: the fusermount3 -uz hint), a hung
#      mount point, mkdir failing with nothing in the way, realpath failing
#      or hung; every line of resolved-roots.tsv end to end.

# The checks are eval'd single-quoted strings, expanded when they run: the
# variables they read look unused to shellcheck, and the quotes are on purpose.
# A quoted ~/ is the conf syntax under test, written into confs unexpanded.
# shellcheck disable=SC2016,SC2034,SC2088

set -o pipefail
# The folders made here are 755: rclone-backup refuses a DEST (or a folder
# above it) that other accounts can write, so a permissive umask in the
# caller's shell must not change the verdicts.
umask 022

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BISYNC=$PLUGIN_DIR/bin/rclone-bisync
BACKUP=$PLUGIN_DIR/bin/rclone-backup
MOUNT=$PLUGIN_DIR/bin/rclone-mount
NAMES_TSV=$PLUGIN_DIR/tests/fixtures/names.tsv
ROOTS_TSV=$PLUGIN_DIR/tests/fixtures/roots.tsv
HOMES_TSV=$PLUGIN_DIR/tests/fixtures/homes.tsv
RESOLVED_TSV=$PLUGIN_DIR/tests/fixtures/resolved-roots.tsv
FILES_TSV=$PLUGIN_DIR/tests/fixtures/files-lines.tsv
FAILURES=0
SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

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
cat >"$STUBS/rclone" <<'EOF'
#!/bin/bash
{ printf 'rclone'; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/rclone"
case $1 in
  bisync) exit "${FAKE_BISYNC_RC:-0}" ;;
  check)
    prev= out=
    for a; do [[ $prev == --combined ]] && out=$a; prev=$a; done
    # Unset: one identical file (an empty pair is check exit 4).
    [[ -n $out ]] && printf '%b' "${FAKE_CHECK_COMBINED-= Personal.kdbx\n}" >"$out"
    exit "${FAKE_CHECK_RC:-0}" ;;
  lsf)
    # Filtered (--filter-from, or --filters-file which lsf does not know):
    # FAKE_LSF_FILTERED when set. FAKE_LSF_FIND=1 lists the real directory
    # instead, dropping the names matching FAKE_LSF_DROP when filtered.
    filtered=0
    for a; do [[ $a == --filter-from || $a == --filters-file ]] && filtered=1; done
    if [[ -n ${FAKE_LSF_FIND:-} ]]; then
      (cd "${*: -1}" && find . -type f -printf '%P\n') | LC_ALL=C sort | while IFS= read -r f; do
        ((filtered)) && [[ -n ${FAKE_LSF_DROP:-} && $f == $FAKE_LSF_DROP ]] && continue
        printf '%s\n' "$f"
      done
      exit 0
    fi
    if ((filtered)) && [[ -n ${FAKE_LSF_FILTERED+x} ]]; then
      printf '%b' "$FAKE_LSF_FILTERED"
    else
      printf '%b' "${FAKE_LSF:-}"
    fi
    exit "${FAKE_LSF_RC:-0}" ;;
  lsl) echo "listing of ${*: -1}"; exit 0 ;;
  copyto)
    if [[ -n ${FAKE_COPY_FAIL:-} && $2 == "$FAKE_COPY_FAIL" ]]; then
      echo partial >"$3"; exit 1
    fi
    # As rclone does: written at a temporary name next to the target, then
    # renamed onto it (a symlink planted at that name would be written through).
    printf 'copy of %s\n' "$2" >"$3.a1b2c3d4.partial" && /usr/bin/mv -f -- "$3.a1b2c3d4.partial" "$3"; exit ;;
  *) exit 99 ;;
esac
EOF
for tool in systemctl notify-send; do
  cat >"$STUBS/$tool" <<'EOF'
#!/bin/bash
{ printf '%s' "${0##*/}"; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/${0##*/}"
[[ ${0##*/} == notify-send ]] && { printf '%s\0' "$@" >"$FAKE_LOG/notify-send.argv"; exit "${FAKE_NOTIFY_RC:-0}"; }
exit 0
EOF
done
cat >"$STUBS/date" <<'EOF'
#!/bin/bash
[[ $# == 1 && $1 == +%F ]] && { echo 2026-11-14; exit 0; }
exec /usr/bin/date "$@"
EOF
chmod +x "$STUBS"/*
# A mv that fails for one target (FAKE_MV_FAIL); only on PATH where asked.
MVSTUB=$SCRATCH/mvstub
mkdir -p "$MVSTUB"
cat >"$MVSTUB/mv" <<'EOF'
#!/bin/bash
[[ -n ${FAKE_MV_FAIL:-} && ${*: -1} == "$FAKE_MV_FAIL" ]] && { echo "mv: stand-in failure" >&2; exit 1; }
exec /usr/bin/mv "$@"
EOF
chmod +x "$MVSTUB/mv"
# A flock that, before locking, does what another account could do while a
# backup run waits for its lock: makes FAKE_FLOCK_DEST a 0777 folder, or (with
# FAKE_FLOCK_LINK) a symlink to that folder; only on PATH where asked.
FLOCKSTUB=$SCRATCH/flockstub
mkdir -p "$FLOCKSTUB"
cat >"$FLOCKSTUB/flock" <<'EOF'
#!/bin/bash
if [[ -n ${FAKE_FLOCK_DEST:-} && ! -e $FAKE_FLOCK_DEST && ! -L $FAKE_FLOCK_DEST ]]; then
  if [[ -n ${FAKE_FLOCK_LINK:-} ]]; then
    /usr/bin/mkdir -p -m 777 -- "$FAKE_FLOCK_LINK" && /usr/bin/chmod 777 -- "$FAKE_FLOCK_LINK" &&
      /usr/bin/ln -s -- "$FAKE_FLOCK_LINK" "$FAKE_FLOCK_DEST"
  else
    /usr/bin/mkdir -m 777 -- "$FAKE_FLOCK_DEST" && /usr/bin/chmod 777 -- "$FAKE_FLOCK_DEST"
  fi
fi
exec /usr/bin/flock "$@"
EOF
chmod +x "$FLOCKSTUB/flock"
# A stat that hangs (sleep 30, a hung FUSE mount) on FAKE_STAT_HANG and fails
# with EACCES on FAKE_STAT_EACCES; only on PATH where asked.
STATSTUB=$SCRATCH/statstub
mkdir -p "$STATSTUB"
cat >"$STATSTUB/stat" <<'EOF'
#!/bin/bash
p=${*: -1}
[[ -n ${FAKE_STAT_HANG:-} && $p == "$FAKE_STAT_HANG" ]] && exec sleep 30
if [[ -n ${FAKE_STAT_EACCES:-} && $p == "$FAKE_STAT_EACCES" ]]; then
  echo "stat: cannot statx '$p': Permission denied" >&2
  exit 1
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$STATSTUB/stat"
# A realpath that records each path it is asked to resolve ($FAKE_LOG/realpath)
# and hangs (sleep 30, like a hung FUSE mount) on a path at or under one of
# FAKE_HUNG (space-separated); only on PATH where asked.
RPSTUB=$SCRATCH/rpstub
mkdir -p "$RPSTUB"
cat >"$RPSTUB/realpath" <<'EOF'
#!/bin/bash
p=${*: -1}
printf '%s\n' "$p" >>"$FAKE_LOG/realpath"
for h in ${FAKE_HUNG:-}; do
  [[ $p == "$h" || $p == "$h"/* ]] && exec sleep 30
done
exec /usr/bin/realpath "$@"
EOF
chmod +x "$RPSTUB/realpath"
# A realpath that always fails (as if missing); only on PATH where asked.
RPFAIL=$SCRATCH/rpfail
mkdir -p "$RPFAIL"
printf '#!/bin/bash\necho "realpath: stand-in failure" >&2\nexit 1\n' >"$RPFAIL/realpath"
chmod +x "$RPFAIL/realpath"
export PATH="$STUBS:$PATH"
TODAY=2026-11-14

# The Omarchy shell's notification markup renderer (decodes entities, then
# re-allows <a href> and a few tags), when it and node are installed:
# render_markup <file> prints the rendered text of the file's content.
MARKUP_JS=${OMARCHY_MARKUP_JS:-/usr/share/omarchy/shell/plugins/notifications/Markup.js}
RENDER=
if [[ -r $MARKUP_JS && -r ${MARKUP_JS%/*}/Security.js ]] && command -v node >/dev/null; then
  RENDER=$SCRATCH/render.js
  cat >"$RENDER" <<'EOF'
const fs = require('fs');
const dir = process.argv[2], text = fs.readFileSync(process.argv[3], 'utf8');
const strip = s => s.split('\n').filter(l => !/^\s*\.(pragma|import)/.test(l)).join('\n');
const Qt = { openUrlExternally() {} };
// Every top-level function and variable of Security.js, as the .import gives.
const src = strip(fs.readFileSync(dir + '/Security.js', 'utf8'));
const names = [...src.matchAll(/^(?:function\s+|(?:var|const|let)\s+)([A-Za-z_$][\w$]*)/gm)].map(m => m[1]);
const Security = new Function('Qt', src + '\nreturn {' + names.join(', ') + '};')(Qt);
const Markup = new Function('Security', strip(fs.readFileSync(dir + '/Markup.js', 'utf8')) + '\nreturn {render};')(Security);
process.stdout.write(Markup.render(text));
EOF
fi
render_markup() { node "$RENDER" "${MARKUP_JS%/*}" "$1"; }
# notify_arg <n>: argument n (from 0) of the last notify-send call.
notify_arg() {
  local a=()
  mapfile -d '' -t a <"$FAKE_LOG/notify-send.argv"
  printf '%s' "${a[$1]}"
}
# no_markup_chars <text>: no < > & in it.
no_markup_chars() { [[ $1 != *[\<\>\&]* ]]; }
# A remote-made file name that the renderer turns into a clickable link.
HOSTILE='<a href="https:&#47;&#47;evil.example">Open the fix<&#47;a>'

# fresh: a new scratch HOME with empty logs; clears the stand-ins' knobs.
N=0
fresh() {
  N=$((N + 1))
  T=$SCRATCH/t$N
  mkdir -p "$T/home/.config" "$T/state" "$T/run" "$T/cache" "$T/log"
  # The XDG_* dirs point away from HOME on purpose: the scripts ignore them
  # (HOME-fixed paths), so every check below reads and writes under $HOME.
  export HOME=$T/home XDG_CONFIG_HOME=$T/xdg-config XDG_STATE_HOME=$T/state \
    XDG_RUNTIME_DIR=$T/run XDG_CACHE_HOME=$T/cache FAKE_LOG=$T/log OMARCHY_CLOUD_MOUNTS=$T/mounts
  unset FAKE_BISYNC_RC FAKE_CHECK_COMBINED FAKE_CHECK_RC FAKE_LSF FAKE_LSF_RC FAKE_COPY_FAIL \
    FAKE_LSF_FILTERED FAKE_LSF_FIND FAKE_LSF_DROP FAKE_MV_FAIL FAKE_NOTIFY_RC FAKE_HUNG
  : >"$T/log/rclone"
  : >"$T/mounts"
}
# runhung <cmd...>: runc with the realpath stand-in first on PATH, capped at
# 20 s (RC 124: the command hung).
runhung() { PATH="$RPSTUB:$PATH" runc timeout 20 "$@"; }
# resolved_under <dir>: the realpath stand-in was asked for a path in dir.
resolved_under() { grep -q -e "^$1\$" -e "^$1/" "$FAKE_LOG/realpath" 2>/dev/null; }
# runc <cmd...>: OUT = stdout+stderr, RC = status.
runc() { OUT=$("$@" 2>&1); RC=$?; }
log() { cat "$FAKE_LOG/$1" 2>/dev/null; }
q() { printf ' %q' "$@"; }
rc_is() { ((RC == $1)); }
no_rclone() { [[ ! -s $FAKE_LOG/rclone ]]; }

# --- 1. syntax and lint -----------------------------------------------------
for f in "$BISYNC" "$BACKUP" "$MOUNT" "${BASH_SOURCE[0]}"; do
  check "bash -n ${f#"$PLUGIN_DIR"/}" bash -n "$f"
done
for f in "$BISYNC" "$BACKUP" "$MOUNT"; do
  check "${f#"$PLUGIN_DIR"/} is executable" test -x "$f"
done
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
  check "shellcheck" "$SHELLCHECK_BIN" "$BISYNC" "$BACKUP" "$MOUNT" "${BASH_SOURCE[0]}"
else
  echo "skip shellcheck (none runs; set SHELLCHECK to one; tried: $SHELLCHECK_TRIED)"
fi

# --- pair fixture -----------------------------------------------------------
# pair <name> [extra conf lines...]: conf with LOCAL and REMOTE, LOCAL created.
pair() {
  local name=$1
  shift
  mkdir -p "$HOME/.config/rclone-bisync" "$HOME/Vaults"
  {
    echo "# offline folder"
    echo "LOCAL=~/Vaults"
    echo "REMOTE=onedrive:Backup/Vaults"
    printf '%s\n' "$@"
  } >"$HOME/.config/rclone-bisync/$name.conf"
}
filter() {
  printf '+ /Personal.kdbx\n+ /Personal.kdbx.conflict*\n- **\n' >"$HOME/.config/rclone-bisync/$1.filter"
}

# --- 2. conf parsing (bisync) -----------------------------------------------
fresh
pair vault-A
runc "$BISYNC" check vault-A
check "valid conf: check runs (exit 0)" rc_is 0

fresh
pair vault-A "COLOR=blue"
runc "$BISYNC" run vault-A
check "unknown key: exit 64, rclone not called" eval 'rc_is 64 && no_rclone && [[ $OUT == *"unknown key COLOR"* ]]'

fresh
pair vault-A "INTERVAL=2min" "INTERVAL=5min"
runc "$BISYNC" run vault-A
check "repeated key: exit 64" rc_is 64

for bad in ../x -x 'a b' '' "$(printf 'a%.0s' {1..65})" 'x/y'; do
  fresh
  runc "$BISYNC" run "$bad"
  check "bad pair name '${bad:0:12}': exit 64" eval 'rc_is 64 && no_rclone'
done

fresh
mkdir -p "$HOME/.config/rclone-bisync"
printf 'LOCAL=$(touch %s/canary)\nREMOTE=onedrive:x\n' "$T" >"$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "conf is parsed, never sourced (no canary, exit 64)" eval 'rc_is 64 && [[ ! -e $T/canary ]]'

fresh
mkdir -p "$HOME/.config/rclone-bisync"
echo "REMOTE=onedrive:x" >"$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "missing LOCAL: exit 64" eval 'rc_is 64 && [[ $OUT == *"LOCAL is required"* ]]'

fresh
pair p
sed -i 's|^LOCAL=.*|LOCAL=Vaults|' "$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "relative LOCAL: exit 64" rc_is 64

fresh
pair p
sed -i 's|^LOCAL=.*|LOCAL=~/nope|' "$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "LOCAL not an existing directory: exit 64" rc_is 64

fresh
pair p
sed -i 's|^REMOTE=.*|REMOTE=-bad:x|' "$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "bad remote name in REMOTE: exit 64" rc_is 64

fresh
pair p "INTERVAL=0min"
runc "$BISYNC" setup p
check "INTERVAL 0min: exit 64" rc_is 64

for iv in 29s 0 0s 0min 500ms 30000ms 2m 1w; do
  fresh
  pair p "INTERVAL=$iv"
  runc "$BISYNC" setup p
  check "INTERVAL $iv: exit 64, no drop-in" eval 'rc_is 64 && [[ ! -e $HOME/.config/systemd/user/rclone-bisync@p.timer.d ]]'
done
for iv in 30s 1min 1h 1d 045s; do
  fresh
  pair p "INTERVAL=$iv"
  runc "$BISYNC" setup p
  check "INTERVAL $iv: accepted" \
    eval 'rc_is 0 && grep -qx "OnUnitInactiveSec=$iv" "$HOME/.config/systemd/user/rclone-bisync@p.timer.d/10-interval.conf"'
done

fresh
pair p "  # indented comment" "" "INTERVAL=5min"
runc "$BISYNC" check p
check "comments and blank lines are skipped" rc_is 0

fresh
runc "$BISYNC" run
check "usage error: exit 64" rc_is 64
runc "$BISYNC" frobnicate x
check "unknown command: exit 64" rc_is 64

# Every case of the shared names list (tests/fixtures/names.tsv), through both
# sync scripts (and, as the remote, rclone-mount: section 6): teardown checks only the name (exit 0 valid, 64 invalid), validate
# says which (an accepted name then fails on its missing conf).
names_n=0
while IFS=$'\t' read -r kind name; do
  [[ $kind == valid || $kind == invalid ]] || continue
  names_n=$((names_n + 1))
  fresh
  for script in "$BISYNC" "$BACKUP"; do
    runc "$script" teardown "$name"
    trc=$RC
    runc "$script" validate "$name"
    if [[ $kind == valid ]]; then
      check "names.tsv: ${script##*/} accepts '${name:0:12}'" eval '((trc == 0)) && rc_is 64 && [[ $OUT == *"no conf"* && $OUT != *"invalid "*" name"* ]]'
    else
      check "names.tsv: ${script##*/} rejects '${name:0:12}'" eval '((trc == 64)) && rc_is 64 && [[ $OUT == *"invalid "*" name"* ]] && no_rclone'
    fi
  done
done < <(grep -v '^#' "$NAMES_TSV")
check "names.tsv: read (at least 20 cases)" eval '((names_n >= 20))'

# rr_cases: the cases of tests/fixtures/resolved-roots.tsv, as
# "<kind>\t<setup>\t<root>" lines.
rr_cases() { grep -v '^#' "$RESOLVED_TSV" | grep $'\t'; }
# rr_build <T> <setup>: the tree of one resolved-roots.tsv case under T (the
# fixture's header): T/home a directory unless a step links it; the steps
# in order: dir:<p> is mkdir -p T/<p>; link:<p>=<t> is ln -s <t> T/<p> (its
# parent made first; a <t> of @/<rest> is T/<rest>, any other verbatim).
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
# roots_cases: the cases of tests/fixtures/roots.tsv as "<kind>\t<path>"
# lines, the path as raw bytes (the file holds non-UTF-8 bytes, so no grep,
# which calls it binary in a UTF-8 locale, and no IFS splitting, which would
# trim): # lines and lines without a tab skipped.
roots_cases() {
  local LC_ALL=C line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == '#'* || $line != *$'\t'* ]] && continue
    printf '%s\n' "$line"
  done <"$ROOTS_TSV"
}
# The mount-root validator: one bash function, valid_root, copied byte for
# byte between its marker lines into the three scripts and install.sh; every
# case of tests/fixtures/roots.tsv through each copy, with HOME=/home/tester.
VR_BEGIN='# --- valid_root (shared: bin/rclone-bisync, bin/rclone-backup, bin/rclone-mount, install.sh; tests/fixtures/roots.tsv) ---'
VR_END='# --- end valid_root ---'
# vr_block <file>: the marker block of the file, markers included.
vr_block() { awk -v b="$VR_BEGIN" -v e="$VR_END" '$0 == b { p = 1 } p { print } p && $0 == e { exit }' "$1"; }
# vr <block> <path>: the block's valid_root on path (status).
vr() { HOME=/home/tester bash -c 'eval "$1"; valid_root "$2"' vr "$1" "$2"; }
VR_FILES=("$BISYNC" "$BACKUP" "$MOUNT" "$PLUGIN_DIR/install.sh")
VR_REF=$(vr_block "$BISYNC")
for f in "${VR_FILES[@]}"; do
  blk=$(vr_block "$f")
  check "valid_root: ${f#"$PLUGIN_DIR"/} has the marker block" \
    eval '[[ $blk == "$VR_BEGIN"$'"'"'\n'"'"'*valid_root\(\)*"$VR_END" ]]'
  check "valid_root: ${f#"$PLUGIN_DIR"/}'s block is byte-identical to bin/rclone-bisync's" eval '[[ -n $blk && $blk == "$VR_REF" ]]'
  [[ -n $blk ]] || continue
  roots_n=0 roots_bad=()
  while IFS= read -r line; do
    kind=${line%%$'\t'*} path=${line#*$'\t'}
    [[ $kind == valid || $kind == invalid ]] || continue
    roots_n=$((roots_n + 1))
    if vr "$blk" "$path"; then got=valid; else got=invalid; fi
    [[ $got == "$kind" ]] || roots_bad+=("$kind $(printf %q "${path:0:40}")")
  done < <(roots_cases)
  check "roots.tsv: ${f#"$PLUGIN_DIR"/} valid_root gives every verdict ($roots_n cases${roots_bad:+; wrong: ${roots_bad[*]}})" \
    eval '((roots_n >= 30 && ${#roots_bad[@]} == 0))'
  # Cases a TSV line cannot carry: control characters, and the 255-byte limit
  # counted in bytes (é is two), non-ASCII allowed.
  e127=$(printf 'é%.0s' {1..127})
  # A HOME with trailing slashes is the same home (all of them dropped, as in
  # Rust and the panel); a HOME of only slashes is no home (the rule skipped).
  check "valid_root (${f##*/}): HOME=/home/tester// still refuses /home/tester/x and /home/tester; HOME=// skips the home rule" \
    eval '! HOME=/home/tester// bash -c '"'"'eval "$1"; valid_root "$2"'"'"' vr "$blk" /home/tester/x && ! HOME=/home/tester/// bash -c '"'"'eval "$1"; valid_root "$2"'"'"' vr "$blk" /home/tester && HOME=// bash -c '"'"'eval "$1"; valid_root "$2"'"'"' vr "$blk" /home/x'
  check "valid_root (${f##*/}): tab, newline, DEL and ESC are invalid; é is valid; 255 bytes, not characters" \
    eval '! vr "$blk" /mnt/a$'"'"'\t'"'"'b && ! vr "$blk" /mnt/a$'"'"'\n'"'"'b && ! vr "$blk" /mnt/a$'"'"'\x7f'"'"'b && ! vr "$blk" /mnt/a$'"'"'\e'"'"'b && vr "$blk" /mnt/é && vr "$blk" "/$e127" && ! vr "$blk" "/${e127}a"'
  # Every UTF-8 boundary, by bytes: the first and last of each length are
  # valid; overlong forms, surrogates, past U+10FFFF, a lone lead or
  # continuation byte, a truncated sequence and U+FFFD itself are not.
  u8_bad=()
  for b in '\xc2\x80' '\xdf\xbf' '\xe0\xa0\x80' '\xed\x9f\xbf' '\xee\x80\x80' '\xef\xbf\xbc' '\xf0\x90\x80\x80' '\xf0\x9f\x98\x80' '\xf4\x8f\xbf\xbf'; do
    vr "$blk" "/mnt/a$(printf %b "$b")b" || u8_bad+=("valid $b")
  done
  for b in '\xc0\xaf' '\xc1\xbf' '\xe0\x80\xaf' '\xe0\x9f\xbf' '\xf0\x80\x80\xaf' '\xf0\x8f\xbf\xbf' '\xed\xa0\x80' '\xed\xbf\xbf' \
    '\xf4\x90\x80\x80' '\xf5\x80\x80\x80' '\xf8\x88\x80\x80\x80' '\xff' '\x80' '\xbf' '\xc3' '\xe2\x82' '\xf0\x9f\x98' '\xe2\x82x' '\xef\xbf\xbd' '\xef\xbf\xbe\xef\xbf\xbd'; do
    ! vr "$blk" "/mnt/a$(printf %b "$b")b" || u8_bad+=("invalid $b")
    ! vr "$blk" "/mnt/a$(printf %b "$b")" || u8_bad+=("invalid $b at the end")
  done
  check "valid_root (${f##*/}): strict UTF-8 by bytes (overlong, surrogate, past U+10FFFF, stray, truncated, U+FFFD refused)${u8_bad:+; wrong: ${u8_bad[*]}}" \
    eval '((${#u8_bad[@]} == 0))'
done

# The home, normalised the same way in every copy (tests/fixtures/homes.tsv:
# runs of / collapsed, "." components and trailing / dropped, ".." kept; a
# home that normalises to "/" skips the home rule), HOME set per line.
for f in "${VR_FILES[@]}"; do
  blk=$(vr_block "$f")
  homes_n=0 homes_bad=()
  while IFS=$'\t' read -r kind home path; do
    [[ $kind == valid || $kind == invalid ]] || continue
    homes_n=$((homes_n + 1))
    if HOME=$home bash -c 'eval "$1"; valid_root "$2"' vr "$blk" "$path"; then got=valid; else got=invalid; fi
    [[ $got == "$kind" ]] || homes_bad+=("$kind home=$home $path")
  done < <(grep -v '^#' "$HOMES_TSV")
  check "homes.tsv: ${f#"$PLUGIN_DIR"/} valid_root normalises the home ($homes_n cases${homes_bad:+; wrong: ${homes_bad[*]}})" \
    eval '((homes_n >= 15 && ${#homes_bad[@]} == 0))'
done

# The resolved-root rule: one bash function, root_outside_home, copied byte
# for byte between its marker lines into the three scripts and install.sh;
# every case of tests/fixtures/resolved-roots.tsv through each copy, the
# tree of the case built under a fresh scratch dir (rr_build), HOME=<it>/home.
RH_BEGIN='# --- root_outside_home (shared: bin/rclone-bisync, bin/rclone-backup, bin/rclone-mount, install.sh; tests/fixtures/resolved-roots.tsv) ---'
RH_END='# --- end root_outside_home ---'
rh_block() { awk -v b="$RH_BEGIN" -v e="$RH_END" '$0 == b { p = 1 } p { print } p && $0 == e { exit }' "$1"; }
RH_REF=$(rh_block "$BISYNC")
RRN=0
for f in "${VR_FILES[@]}"; do
  rblk=$(rh_block "$f")
  check "root_outside_home: ${f#"$PLUGIN_DIR"/} has the marker block" \
    eval '[[ $rblk == "$RH_BEGIN"$'"'"'\n'"'"'*root_outside_home\(\)*"$RH_END" ]]'
  check "root_outside_home: ${f#"$PLUGIN_DIR"/}'s block is byte-identical to bin/rclone-bisync's" eval '[[ -n $rblk && $rblk == "$RH_REF" ]]'
  blk=$(vr_block "$f")$'\n'$rblk
  rr_n=0 rr_bad=()
  while IFS=$'\t' read -r kind setup root; do
    rr_n=$((rr_n + 1)) RRN=$((RRN + 1))
    t=$SCRATCH/rr/$RRN
    rr_build "$t" "$setup" || { rr_bad+=("unbuildable $setup"); continue; }
    HOME=$t/home bash -c 'eval "$1"; valid_root "$2"' vr "$blk" "$t/$root" || { rr_bad+=("valid_root refuses $root"); continue; }
    HOME=$t/home bash -c 'eval "$1"; root_outside_home "$2"' vr "$blk" "$t/$root"
    case $?:$kind in
      0:valid | 1:invalid) ;;
      *) rr_bad+=("$kind $setup $root") ;;
    esac
  done < <(rr_cases)
  check "resolved-roots.tsv: ${f#"$PLUGIN_DIR"/} root_outside_home gives every verdict ($rr_n cases${rr_bad:+; wrong: ${rr_bad[*]}})" \
    eval '((rr_n >= 15 && ${#rr_bad[@]} == 0))'
  # Could not resolve (realpath failing, missing, hung past 5 s): status 2.
  t=$SCRATCH/rr/x
  mkdir -p "$t/home" "$t/mnt/cloud"
  rh() { HOME=$t/home PATH=$1 bash -c 'eval "$1"; root_outside_home "$2"; echo "$?|$ROOT_WHY"' vr "$blk" "$t/mnt/cloud"; }
  out_fail=$(rh "$RPFAIL:$PATH")
  out_hung=$(FAKE_HUNG=$t/mnt/cloud rh "$RPSTUB:$PATH")
  check "root_outside_home (${f##*/}): realpath failing or hung (cut off after 5 s): status 2, the reason said" \
    eval '[[ $out_fail == "2|the mount root $t/mnt/cloud could not be resolved"* && $out_hung == "2|the mount root $t/mnt/cloud could not be resolved"* ]]'
  out=$(HOME=$t/home bash -c 'eval "$1"; root_outside_home "$2"; echo "$?|$ROOT_WHY"' vr "$blk" "$t/home/x")
  check "root_outside_home (${f##*/}): the reason names the root, the home and why (home crawlers)" \
    eval '[[ $out == "1|the mount root $t/home/x is at or inside your home $t/home: programs that crawl the home (file search, indexers, backups) would follow the link into the cloud drive" ]]'
done

# HOME-fixed paths: XDG_CONFIG_HOME and XDG_STATE_HOME (pointed away from
# HOME by fresh) are ignored: confs are read from ~/.config, state is written
# to ~/.local/state, drop-ins go to ~/.config/systemd/user, as the services
# (run with the user manager's environment) see them.
fresh
check "XDG dirs point away from HOME in these tests" \
  eval '[[ $XDG_CONFIG_HOME != "$HOME/.config" && $XDG_STATE_HOME != "$HOME/.local/state" ]]'
mkdir -p "$XDG_CONFIG_HOME/rclone-bisync" "$XDG_CONFIG_HOME/rclone-backup" "$HOME/Vaults"
printf 'LOCAL=~/Vaults\nREMOTE=onedrive:x\n' >"$XDG_CONFIG_HOME/rclone-bisync/xonly.conf"
printf 'REMOTE=work_drive:\nDEST=~/b\n' >"$XDG_CONFIG_HOME/rclone-backup/xonly.conf"
echo a.kdbx >"$XDG_CONFIG_HOME/rclone-backup/xonly.files"
for script in "$BISYNC" "$BACKUP"; do
  runc "$script" validate xonly
  check "${script##*/}: a conf only under XDG_CONFIG_HOME is not read (no conf in ~/.config)" \
    eval 'rc_is 64 && [[ $OUT == *"no conf $HOME/.config/"* ]]'
done
pair p
FAKE_LSF='a.conflict1\n' runc "$BISYNC" run p
runc "$BISYNC" setup p
check "rclone-bisync: state in ~/.local/state, drop-ins in ~/.config/systemd/user, nothing under the XDG dirs" \
  eval '[[ -s $HOME/.local/state/rclone-bisync/p.state && -f $HOME/.config/systemd/user/rclone-bisync@p.path.d/10-local.conf && ! -e $XDG_STATE_HOME/rclone-bisync && ! -e $XDG_CONFIG_HOME/systemd ]]'
mkdir -p "$HOME/.config/rclone-backup"
printf 'REMOTE=work_drive:\nDEST=~/b\n' >"$HOME/.config/rclone-backup/j.conf"
echo a.kdbx >"$HOME/.config/rclone-backup/j.files"
runc "$BACKUP" run j
runc "$BACKUP" setup j
check "rclone-backup: state in ~/.local/state, drop-in in ~/.config/systemd/user, nothing under the XDG dirs" \
  eval '[[ -s $HOME/.local/state/rclone-backup/j.state && -f $HOME/.config/systemd/user/rclone-backup@j.timer.d/10-schedule.conf && ! -e $XDG_STATE_HOME/rclone-backup && ! -e $XDG_CONFIG_HOME/systemd ]]'
fresh
mkdir -p "$T/srv/clouds" "$XDG_CONFIG_HOME/omarchy-cloud"
printf 'OMARCHY_CLOUD_ROOT=%s\n' "$T/srv/clouds" >"$XDG_CONFIG_HOME/omarchy-cloud/cloud.env"
pair p
sed -i "s|^LOCAL=.*|LOCAL=$T/srv|" "$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" validate p
check "rclone-bisync: a cloud.env only under XDG_CONFIG_HOME is not read" eval 'rc_is 0 && [[ -z $OUT ]]'

# A conf with CRLF line ends is invalid (a \r is a control character).
fresh
pair p
sed -i 's/$/\r/' "$HOME/.config/rclone-bisync/p.conf"
runc "$BISYNC" validate p
check "bisync: a CRLF conf is invalid (exit 64)" eval 'rc_is 64 && [[ $OUT == *"not a KEY=VALUE line"* ]]'
runc "$BISYNC" run p
check "bisync run: a CRLF conf is exit 64, rclone not called" eval 'rc_is 64 && no_rclone'

# --- 3. rclone-bisync ---------------------------------------------------------
LOCALDIR() { printf '%s' "$HOME/Vaults"; }
SAFETY=(--conflict-resolve none --conflict-loser num --resilient --recover --create-empty-src-dirs=false --max-lock 2m -v)
# WORKDIR: bisync's pinned workdir under the current scratch HOME.
WORKDIR() { printf '%s' "$HOME/.cache/rclone/bisync"; }
# conflict_note <names>: the body of the conflict notification.
conflict_note() {
  printf 'New conflict copies: %s. A file changed on both sides: bisync kept both versions as X.conflictN copies (X itself is renamed). Merge them into one file, rename it back to X, delete the other copies.' "$1"
}

fresh
pair vault-A
filter vault-A
F=$HOME/.config/rclone-bisync/vault-A.filter
FAKE_BISYNC_RC=7 runc "$BISYNC" run vault-A
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults --filters-file "$F" "${SAFETY[@]}" --workdir "$(WORKDIR)")"
check "run: rclone bisync with exactly the safety flags (default filter)" eval '[[ $(head -1 "$FAKE_LOG/rclone") == "$want" ]]'
check "run: exit code is bisync's (7)" rc_is 7
check "run: bisync's lock expires (--max-lock 2m), so a killed run cannot block later ones" \
  eval 'grep -q "^rclone bisync .* --max-lock 2m" "$FAKE_LOG/rclone"'
check "run: state file exit=7, a unix time" \
  eval 'grep -qx "exit=7" "$HOME/.local/state/rclone-bisync/vault-A.state" && grep -qE "^time=[0-9]{9,}$" "$HOME/.local/state/rclone-bisync/vault-A.state"'
check "run: conflicts listed via rclone lsf of LOCAL, conflict copies only, the filter not applied" \
  eval '[[ $(sed -n 2p "$FAKE_LOG/rclone") == "rclone$(q lsf -R --files-only --include "*.conflict[0-9]*" "$(LOCALDIR)")" ]]'
check "run: no conflict, no notification" eval '[[ ! -s $FAKE_LOG/notify-send ]]'
check "run: never --resync" eval '! grep -q -- --resync "$FAKE_LOG/rclone"'

fresh
pair p
runc "$BISYNC" run p
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults "${SAFETY[@]}" --workdir "$(WORKDIR)")"
check "run without a filter file: no --filters-file" eval '[[ $(head -1 "$FAKE_LOG/rclone") == "$want" ]]'

fresh
printf -- '- **\n' >"$T/custom.filter"
pair p "FILTER=$T/custom.filter"
runc "$BISYNC" run p
check "FILTER= from the conf is used" eval 'grep -qF -- "--filters-file $T/custom.filter" "$FAKE_LOG/rclone"'

fresh
pair p "FILTER="
filter p
runc "$BISYNC" run p
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults "${SAFETY[@]}" --workdir "$(WORKDIR)")"
check "FILTER= (empty): no filter, even with <pair>.filter present" eval 'rc_is 0 && [[ $(head -1 "$FAKE_LOG/rclone") == "$want" ]]'
runc "$BISYNC" check p
check "FILTER= (empty): check without a filter" eval 'rc_is 0 && [[ $(tail -1 "$FAKE_LOG/rclone") != *--filter* ]]'

fresh
pair p "FILTER=~/missing.filter"
runc "$BISYNC" run p
check "FILTER that does not exist: exit 64" rc_is 64

fresh
pair vault-A
mkdir -p "$HOME/.local/state/omarchy-cloud/locks"
flock "$HOME/.local/state/omarchy-cloud/locks/rclone-bisync-vault-A.lock" sleep 10 &
holder=$!
for _ in {1..50}; do flock -n "$HOME/.local/state/omarchy-cloud/locks/rclone-bisync-vault-A.lock" true || break; sleep 0.05; done
runc "$BISYNC" run vault-A
check "lock busy: run exits 0 without calling rclone" eval 'rc_is 0 && no_rclone && [[ $OUT == *"another run is active"* ]]'
runc "$BISYNC" resync vault-A
check "lock busy: resync exits 75 (EX_TEMPFAIL) without calling rclone" eval 'rc_is 75 && no_rclone && [[ $OUT == *"another run is active"* ]]'
runc "$BISYNC" dry-run vault-A
check "lock busy: dry-run exits 75 without calling rclone" eval 'rc_is 75 && no_rclone && [[ $OUT == *"another run is active"* ]]'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

fresh
pair vault-A
filter vault-A
export FAKE_LSF='Personal.kdbx\nPersonal.kdbx.conflict1\nsub/notes.conflict2.txt\nfoo.conflictx\nconflict3\n'
runc "$BISYNC" conflicts vault-A
check "conflicts: the *.conflict[0-9]* copies, relative paths" \
  eval '[[ $OUT == $'"'"'Personal.kdbx.conflict1\nsub/notes.conflict2.txt'"'"' ]] && rc_is 0'
: >"$FAKE_LOG/rclone"
runc "$BISYNC" run vault-A
want="notify-send$(q -u critical -a rclone-bisync "vault-A: conflict" "$(conflict_note "Personal.kdbx.conflict1 notes.conflict2.txt")")"
check "run with conflicts: one critical notification naming them" eval '[[ $(log notify-send) == "$want" ]]'
check "run with conflicts: logged" eval '[[ $OUT == *"CONFLICT copies present: Personal.kdbx.conflict1 notes.conflict2.txt"* ]]'
check "run with conflicts: state file lists them" \
  eval '[[ $(grep ^conflict= "$HOME/.local/state/rclone-bisync/vault-A.state") == $'"'"'conflict=Personal.kdbx.conflict1\nconflict=sub/notes.conflict2.txt'"'"' ]]'
check "state written atomically (no temp file left)" eval '[[ -z $(find "$HOME/.local/state/rclone-bisync" -name ".*") ]]'
: >"$FAKE_LOG/notify-send"
runc "$BISYNC" run vault-A
check "run with the same conflicts again: no new notification, still logged" \
  eval '[[ ! -s $FAKE_LOG/notify-send && $OUT == *"CONFLICT copies present: Personal.kdbx.conflict1 notes.conflict2.txt"* ]]'
check "run with the same conflicts again: the state file still lists them all" \
  eval '[[ $(grep -c ^conflict= "$HOME/.local/state/rclone-bisync/vault-A.state") == 2 ]]'
FAKE_LSF='Personal.kdbx.conflict1\nsub/notes.conflict2.txt\nWork.kdbx.conflict1\nWork.kdbx.conflict2\n' runc "$BISYNC" run vault-A
want="notify-send$(q -u critical -a rclone-bisync "vault-A: conflict" "$(conflict_note "Work.kdbx.conflict1 Work.kdbx.conflict2")")"
check "run with a new conflict: one notification naming only the new copies" eval '[[ $(log notify-send) == "$want" ]]'
check "run with a new conflict: the state file lists all four" \
  eval '[[ $(grep -c ^conflict= "$HOME/.local/state/rclone-bisync/vault-A.state") == 4 ]]'
: >"$FAKE_LOG/notify-send"
FAKE_LSF='Personal.kdbx.conflict1\n' runc "$BISYNC" run vault-A
check "run after some copies were merged away: no notification" eval '[[ ! -s $FAKE_LOG/notify-send ]]'
FAKE_LSF='Personal.kdbx.conflict1\nWork.kdbx.conflict1\n' runc "$BISYNC" run vault-A
check "a copy that comes back after it was gone is new again" eval '[[ $(log notify-send) == *Work.kdbx.conflict1* ]]'
FAKE_LSF_RC=3 runc "$BISYNC" conflicts vault-A
check "conflicts: lsf failure is exit 2" rc_is 2

# A copy is recorded as notified only when notify-send exists and succeeded;
# a failed listing keeps the previous state's copies and notified set.
# NONOTIFY: the same PATH without any notify-send.
NONOTIFY=$SCRATCH/nonotify
mkdir -p "$NONOTIFY"
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  for f in "$d"/*; do
    n=${f##*/}
    [[ $n == notify-send || -e $NONOTIFY/$n || ! -x $f ]] || ln -s "$f" "$NONOTIFY/$n"
  done
done
fresh
pair vault-A
filter vault-A
ST=$HOME/.local/state/rclone-bisync/vault-A.state
export FAKE_LSF='a.conflict1\n'
FAKE_NOTIFY_RC=1 runc "$BISYNC" run vault-A
check "notify-send fails: the copy is in the state file, not as notified" \
  eval 'rc_is 0 && [[ $(log notify-send) == *a.conflict1* ]] && grep -qx conflict=a.conflict1 "$ST" && ! grep -q ^notified= "$ST"'
: >"$FAKE_LOG/notify-send"
runc "$BISYNC" run vault-A
check "after a failed notification: notified on the next run, then recorded" \
  eval '[[ $(log notify-send) == *a.conflict1* ]] && grep -qx notified=a.conflict1 "$ST"'
: >"$FAKE_LOG/notify-send"
runc "$BISYNC" run vault-A
check "a notified copy is not notified again" eval '[[ ! -s $FAKE_LOG/notify-send ]] && grep -qx notified=a.conflict1 "$ST"'
FAKE_LSF='a.conflict1\nb.conflict1\n' PATH=$NONOTIFY runc "$BISYNC" run vault-A
check "no notify-send: the new copy is listed but not recorded as notified" \
  eval 'rc_is 0 && [[ ! -s $FAKE_LOG/notify-send ]] && grep -qx conflict=b.conflict1 "$ST" && grep -qx notified=a.conflict1 "$ST" && ! grep -qx notified=b.conflict1 "$ST"'
FAKE_LSF='a.conflict1\nb.conflict1\n' runc "$BISYNC" run vault-A
check "notify-send back: only the copy not yet notified is notified" \
  eval '[[ $(log notify-send) == *b.conflict1* && $(log notify-send) != *a.conflict1* ]] && grep -qx notified=b.conflict1 "$ST"'
: >"$FAKE_LOG/notify-send"
FAKE_LSF='' FAKE_LSF_RC=3 runc "$BISYNC" run vault-A
check "listing fails: the previous copies and notified set are kept, run's exit kept" \
  eval 'rc_is 0 && [[ $(grep -c ^conflict= "$ST") == 2 && $(grep -c ^notified= "$ST") == 2 ]] && [[ $OUT == *"could not list the conflict copies"* ]]'
FAKE_LSF='a.conflict1\nb.conflict1\n' runc "$BISYNC" run vault-A
check "after a failed listing: nothing is notified again" eval '[[ ! -s $FAKE_LOG/notify-send ]]'
unset FAKE_LSF

# A hand-written filter without `+ X.conflict*`: the filtered listing would
# not show the copy, the conflict listing must.
fresh
pair vault-A
printf '+ /Personal.kdbx\n- **\n' >"$HOME/.config/rclone-bisync/vault-A.filter"
export FAKE_LSF_FILTERED='Personal.kdbx\n' FAKE_LSF='Personal.kdbx.conflict1\n'
runc "$BISYNC" run vault-A
check "run: a conflict copy the filter hides is still notified" eval '[[ $(log notify-send) == "notify-send$(q -u critical -a rclone-bisync "vault-A: conflict" "$(conflict_note Personal.kdbx.conflict1)")" ]]'
check "run: a conflict copy the filter hides is in the state file" \
  eval 'grep -qx "conflict=Personal.kdbx.conflict1" "$HOME/.local/state/rclone-bisync/vault-A.state"'
runc "$BISYNC" conflicts vault-A
check "conflicts: lists a copy the filter hides" eval 'rc_is 0 && [[ $OUT == Personal.kdbx.conflict1 ]]'
unset FAKE_LSF_FILTERED FAKE_LSF

# A conflict copy name is chosen by whoever writes into the remote: the
# notification strips < > & from it (and from the pair name), so the shell's
# renderer cannot make it a link; the log line keeps the real name.
fresh
pair vault-A
FAKE_LSF="$HOSTILE.conflict1\nsub/x&y.conflict2\n" runc "$BISYNC" run vault-A
check "conflict notification: summary and body have no < > & (hostile copy name)" \
  eval 'rc_is 0 && [[ $(notify_arg 4) == "vault-A: conflict" ]] && no_markup_chars "$(notify_arg 4)" && no_markup_chars "$(notify_arg 5)"'
check "conflict notification: the body still names the copies, minus < > &" \
  eval '[[ $(notify_arg 5) == "$(conflict_note "a href=\"https:#47;#47;evil.example\"Open the fix#47;a.conflict1 xy.conflict2")" ]]'
check "conflict log line: the real names, unchanged" \
  eval '[[ $OUT == *"CONFLICT copies present: $HOSTILE.conflict1 x&y.conflict2"* ]] && grep -qxF "conflict=$HOSTILE.conflict1" "$HOME/.local/state/rclone-bisync/vault-A.state"'
if [[ -n $RENDER ]]; then
  notify_arg 5 >"$T/body"
  printf '%s' "$(conflict_note "$HOSTILE.conflict1")" >"$T/raw"
  check "conflict notification: the shell's Markup.render of the body has no link" \
    eval '[[ $(render_markup "$T/body") != *"<a"* ]]'
  [[ $(render_markup "$T/raw") == *"<a href="* ]] ||
    echo "note: Markup.render no longer makes a link of the raw name; the render check above proves less"
else
  echo "skip Markup.render check (no $MARKUP_JS or no node)"
fi

fresh
pair vault-A
printf '+ /Personal.kdbx\n- **\n' >"$HOME/.config/rclone-bisync/vault-A.filter"
touch "$(LOCALDIR)/Personal.kdbx"
FAKE_LSF_FIND=1 FAKE_LSF_DROP='*.conflict*' runc "$BISYNC" setup vault-A
check "setup: warns when the filter excludes an included file's conflict copies" \
  eval 'rc_is 0 && [[ $OUT == *"warning: the filter"*"excludes the conflict copies"*Personal.kdbx* ]]'
check "setup with the warning: drop-ins still written" test -f "$HOME/.config/systemd/user/rclone-bisync@vault-A.timer.d/10-interval.conf"
check "setup: the probe asks rclone with --filter-from, on a temp dir, not on LOCAL" \
  eval '[[ $(sed -n 2p "$FAKE_LOG/rclone") == "rclone lsf -R --files-only --filter-from "* && $(sed -n 2p "$FAKE_LOG/rclone") != *"$(LOCALDIR)"* ]]'
filter vault-A
FAKE_LSF_FIND=1 runc "$BISYNC" setup vault-A
check "setup: no warning when the filter includes the conflict copies" eval 'rc_is 0 && [[ $OUT != *warning* ]]'

fresh
pair vault-A
filter vault-A
F=$HOME/.config/rclone-bisync/vault-A.filter
runc "$BISYNC" check vault-A
want="rclone$(q check "$(LOCALDIR)" onedrive:Backup/Vaults --filter-from "$F" --download --combined)"
check "check: rclone check LOCAL REMOTE --filter-from F --download (check has no --filters-file)" eval '[[ $(head -1 "$FAKE_LOG/rclone") == "$want "* ]] && rc_is 0'
FAKE_CHECK_RC=1 FAKE_CHECK_COMBINED='= a\n* Personal.kdbx\n+ Personal.kdbx.conflict1\n' runc "$BISYNC" check vault-A
check "check: differences are exit 1 and printed" eval 'rc_is 1 && [[ $OUT == *"* Personal.kdbx"* && $OUT == *"+ Personal.kdbx.conflict1"* && $OUT != *"= a"* ]]'
FAKE_CHECK_RC=3 FAKE_CHECK_COMBINED='' runc "$BISYNC" check vault-A
check "check: an error without differences is exit 2" rc_is 2
FAKE_CHECK_RC=1 FAKE_CHECK_COMBINED='* x\n! y\n' runc "$BISYNC" check vault-A
check "check: an error line (!) is exit 2" rc_is 2

fresh
pair vault-A
filter vault-A
F=$HOME/.config/rclone-bisync/vault-A.filter
FAKE_CHECK_RC=1 FAKE_CHECK_COMBINED='* Personal.kdbx\n' runc "$BISYNC" resync vault-A
check "resync when they differ: REFUSED, exit 3" eval 'rc_is 3 && [[ $OUT == *REFUSING* ]]'
check "resync when they differ: bisync never called" eval '! grep -q "^rclone bisync" "$FAKE_LOG/rclone"'
check "resync when they differ: both sides listed with lsl and the filter" \
  eval 'grep -qxF "rclone$(q lsl --filter-from "$F" "$(LOCALDIR)")" "$FAKE_LOG/rclone" && grep -qxF "rclone$(q lsl --filter-from "$F" onedrive:Backup/Vaults)" "$FAKE_LOG/rclone"'
: >"$FAKE_LOG/rclone"
FAKE_CHECK_RC=7 FAKE_CHECK_COMBINED='' runc "$BISYNC" resync vault-A
check "resync when check fails: refused (exit 2), bisync never called" eval 'rc_is 2 && ! grep -q "^rclone bisync" "$FAKE_LOG/rclone"'
: >"$FAKE_LOG/rclone"
runc "$BISYNC" resync vault-A
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults --filters-file "$F" "${SAFETY[@]}" --workdir "$(WORKDIR)" --resync)"
check "resync when identical: check first, then bisync --resync" \
  eval '[[ $(sed -n 1p "$FAKE_LOG/rclone") == "rclone check "* && $(sed -n 2p "$FAKE_LOG/rclone") == "$want" ]] && rc_is 0'
check "resync writes the state file" test -s "$HOME/.local/state/rclone-bisync/vault-A.state"

fresh
pair vault-A
runc "$BISYNC" dry-run vault-A
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults "${SAFETY[@]}" --workdir "$(WORKDIR)" --dry-run)"
check "dry-run: bisync --dry-run, no --resync, no state" \
  eval '[[ $(log rclone) == "$want" ]] && [[ ! -e $HOME/.local/state/rclone-bisync/vault-A.state ]]'

fresh
mkdir -p "$HOME/My Vault%d"
pair vault-A "INTERVAL=5min"
sed -i 's|^LOCAL=.*|LOCAL=~/My Vault%d|' "$HOME/.config/rclone-bisync/vault-A.conf"
runc "$BISYNC" setup vault-A
UD=$HOME/.config/systemd/user
check "setup: path drop-in, % escaped" \
  eval '[[ $(cat "$UD/rclone-bisync@vault-A.path.d/10-local.conf") == "$(printf "[Path]\nPathChanged=%s" "$HOME/My Vault%%d")" ]]'
check "setup: timer drop-in resets and restates OnStartupSec" \
  eval '[[ $(cat "$UD/rclone-bisync@vault-A.timer.d/10-interval.conf") == $'"'"'[Timer]\nOnUnitInactiveSec=\nOnStartupSec=1min\nOnUnitInactiveSec=5min'"'"' ]]'
check "setup: daemon-reload, nothing enabled" eval '[[ $(log systemctl) == "systemctl --user daemon-reload" ]]'
check "setup: rclone not called" no_rclone
SETUP_UD=$UD SETUP_HOME=$HOME
touch "$UD/rclone-bisync@vault-A.path.d/20-mine.conf"
: >"$FAKE_LOG/systemctl"
runc "$BISYNC" teardown vault-A
check "teardown: our drop-ins gone, a foreign drop-in and LOCAL kept" \
  eval '[[ ! -e $UD/rclone-bisync@vault-A.path.d/10-local.conf && ! -e $UD/rclone-bisync@vault-A.timer.d ]] && [[ -e $UD/rclone-bisync@vault-A.path.d/20-mine.conf && -d "$HOME/My Vault%d" ]]'
check "teardown: daemon-reload" eval '[[ $(log systemctl) == "systemctl --user daemon-reload" ]]'
rm -f "$UD/rclone-bisync@vault-A.path.d/20-mine.conf"
runc "$BISYNC" setup vault-A # keep the drop-ins for section 5

# A backup DEST that overlaps the pair's LOCAL (~/Vaults), by path components,
# as written and through a symlink: setup refuses; run, check, resync and
# dry-run warn and go on (a sync is never stopped for it).
bk_dest() { # bk_dest <job> <DEST value>
  mkdir -p "$HOME/.config/rclone-backup"
  printf 'REMOTE=work_drive:\nDEST=%s\n' "$2" >"$HOME/.config/rclone-backup/$1.conf"
}
for dest in "~/Vaults/backups" "~/Vaults" "~/Vaults/" "~/" "@HOME@/Vaults/a/b"; do
  fresh
  dest=${dest//@HOME@/$HOME}
  pair vault-A
  bk_dest archive-vaults "$dest"
  runc "$BISYNC" setup vault-A
  check "bisync setup: LOCAL overlapping backup DEST $dest is refused (exit 64, no rclone, no drop-in)" \
    eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps DEST"*"archive-vaults"* && $OUT != *continuing* && ! -e $HOME/.config/systemd/user/rclone-bisync@vault-A.path.d ]]'
  for sub in run check resync dry-run; do
    : >"$FAKE_LOG/rclone"
    runc "$BISYNC" "$sub" vault-A
    verb=bisync
    [[ $sub == check ]] && verb=check
    check "bisync $sub: LOCAL overlapping backup DEST $dest warns and runs (exit 0, rclone $verb called)" \
      eval 'rc_is 0 && grep -q "^rclone $verb " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: vault-A: LOCAL"*"overlaps DEST"*"archive-vaults"*"; continuing"* ]]'
  done
done
fresh
pair vault-A
bk_dest archive-vaults "~/Vaults2/backups"
bk_dest other "~/Backups/vaults"
runc "$BISYNC" run vault-A
check "bisync run: a DEST next to LOCAL (~/Vaults2 vs ~/Vaults) is not an overlap" rc_is 0
runc "$BISYNC" check vault-A
check "bisync check: runs with an unrelated backup job" rc_is 0
fresh
pair vault-A
mkdir -p "$HOME/Backups"
ln -s "$HOME/Vaults" "$HOME/Backups/link"
bk_dest archive-vaults "~/Backups/link/old"
runc "$BISYNC" setup vault-A
check "bisync setup: a DEST inside LOCAL through a symlink is refused" eval 'rc_is 64 && no_rclone'
runc "$BISYNC" run vault-A
check "bisync run: a DEST inside LOCAL through a symlink warns and runs" \
  eval 'rc_is 0 && grep -q "^rclone bisync " "$FAKE_LOG/rclone" && [[ $OUT == *"overlaps DEST"*"; continuing"* ]]'

# The empty pair: identical (check rc 0) but no `= ` line, nothing on either
# side after the filter. check is exit 4; resync refuses with 4, never --resync.
fresh
pair vault-A
FAKE_CHECK_COMBINED='' runc "$BISYNC" check vault-A
check "check of an empty pair: exit 4, nothing to sync" \
  eval 'rc_is 4 && [[ $OUT == *"nothing to sync: no file on either side (after the filter); put a file on one side first"* ]]'
: >"$FAKE_LOG/rclone"
FAKE_CHECK_COMBINED='' runc "$BISYNC" resync vault-A
check "resync of an empty pair: refused (exit 4), bisync never called, no state" \
  eval 'rc_is 4 && [[ $OUT == *REFUSING*"nothing to sync"* ]] && ! grep -q "^rclone bisync" "$FAKE_LOG/rclone" && [[ ! -e $HOME/.local/state/rclone-bisync/vault-A.state ]]'
FAKE_CHECK_COMBINED='= Personal.kdbx\n= sub/x\n' runc "$BISYNC" check vault-A
check "check with identical files: exit 0" rc_is 0

# The pinned workdir: $HOME/.cache, not XDG_CACHE_HOME.
check "workdir: pinned to \$HOME/.cache/rclone/bisync on every bisync call, never XDG_CACHE_HOME" \
  eval '[[ $XDG_CACHE_HOME != "$HOME/.cache" ]] && ! grep "^rclone bisync" "$SCRATCH"/t*/log/rclone | grep -v -- "--workdir $HOME/.cache/rclone/bisync" | grep -q "$HOME/" && ! grep -q -- "--workdir $XDG_CACHE_HOME" "$FAKE_LOG/rclone"'

# validate: the conf and every setup-time guard, writing nothing, no rclone,
# no systemctl.
fresh
pair vault-A
filter vault-A
touch "$(LOCALDIR)/Personal.kdbx"
before=$(find "$T" | LC_ALL=C sort)
runc "$BISYNC" validate vault-A
check "bisync validate: a valid pair is exit 0, silent, no rclone, no systemctl, nothing written" \
  eval 'rc_is 0 && [[ -z $OUT ]] && no_rclone && [[ ! -e $FAKE_LOG/systemctl && $(find "$T" | LC_ALL=C sort) == "$before" ]]'
runc "$BISYNC" validate
check "bisync validate without a pair: usage, exit 64" rc_is 64
bk_dest archive-vaults "~/Vaults/backups"
runc "$BISYNC" validate vault-A
check "bisync validate: LOCAL overlapping a backup DEST is exit 64, no warning-and-go-on" \
  eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps DEST"* && $OUT != *continuing* ]]'

# LOCAL against the LOCAL of the other pairs.
other_pair() { # other_pair <name> <LOCAL value>
  mkdir -p "$HOME/.config/rclone-bisync"
  printf 'LOCAL=%s\nREMOTE=gdrive:other\n' "$2" >"$HOME/.config/rclone-bisync/$1.conf"
}
for other in "~/Vaults" "~/Vaults/sub" "~/" "@HOME@/Vaults/"; do
  fresh
  pair vault-A
  other_pair vault-B "${other//@HOME@/$HOME}"
  for sub in setup validate; do
    runc "$BISYNC" "$sub" vault-A
    check "bisync $sub: LOCAL overlapping the LOCAL $other of another pair is refused (exit 64, no drop-in)" \
      eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps LOCAL"*"offline folder vault-B"* && $OUT != *continuing* && ! -e $HOME/.config/systemd/user/rclone-bisync@vault-A.path.d ]]'
  done
  for sub in run check resync dry-run; do
    : >"$FAKE_LOG/rclone"
    runc "$BISYNC" "$sub" vault-A
    verb=bisync
    [[ $sub == check ]] && verb=check
    check "bisync $sub: LOCAL overlapping another pair's LOCAL $other warns and runs" \
      eval 'rc_is 0 && grep -q "^rclone $verb " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: vault-A: LOCAL"*"overlaps LOCAL"*"vault-B"*"; continuing"* ]]'
  done
done
fresh
pair vault-A
other_pair vault-B "~/Vaults2"
runc "$BISYNC" validate vault-A
check "bisync validate: another pair next to LOCAL (~/Vaults2 vs ~/Vaults) is not an overlap" eval 'rc_is 0 && [[ -z $OUT ]]'
fresh
pair vault-A
ln -s "$HOME/Vaults" "$HOME/link"
other_pair vault-B "~/link/sub"
runc "$BISYNC" setup vault-A
check "bisync setup: another pair's LOCAL inside LOCAL through a symlink is refused" eval 'rc_is 64 && [[ $OUT == *"vault-B"* ]]'

# LOCAL inside a cloud location: ~/Cloud (as written or resolved), a FUSE mount
# of the mounts table (octal escapes decoded; fusectl is not one).
cloud_local() { # cloud_local <dir under HOME>: pair vault-A on it
  mkdir -p "$HOME/$1"
  pair vault-A
  sed -i "s|^LOCAL=.*|LOCAL=~/$1|" "$HOME/.config/rclone-bisync/vault-A.conf"
}
fresh
cloud_local Cloud/onedrive/K
for sub in setup validate; do
  runc "$BISYNC" "$sub" vault-A
  check "bisync $sub: LOCAL inside ~/Cloud is refused (exit 64), naming it" \
    eval 'rc_is 64 && no_rclone && [[ $OUT == *"inside the cloud location $HOME/Cloud"* && $OUT != *continuing* ]]'
done
runc "$BISYNC" run vault-A
check "bisync run: LOCAL inside ~/Cloud warns and runs" \
  eval 'rc_is 0 && grep -q "^rclone bisync " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: vault-A: LOCAL"*"cloud location"*"; continuing"* ]]'
fresh
mkdir -p "$HOME/real/K"
ln -s "$HOME/real" "$HOME/Cloud"
cloud_local real/K
runc "$BISYNC" validate vault-A
check "bisync validate: LOCAL inside the folder ~/Cloud links to is refused" eval 'rc_is 64 && [[ $OUT == *"cloud location"* ]]'
fresh
cloud_local "Mnt x/K"
printf 'onedrive: %s fuse.rclone rw,nosuid 0 0\nfusectl %s fusectl rw 0 0\n' "${HOME// /\\040}/Mnt\\040x" "$HOME/Vaults" >"$OMARCHY_CLOUD_MOUNTS"
for sub in setup validate; do
  runc "$BISYNC" "$sub" vault-A
  check "bisync $sub: LOCAL inside a FUSE mount (\\040 decoded) is refused, naming the mount" \
    eval 'rc_is 64 && [[ $OUT == *"inside the FUSE mount $HOME/Mnt x (fuse.rclone)"* ]]'
done
runc "$BISYNC" check vault-A
check "bisync check: LOCAL inside a FUSE mount warns and checks" \
  eval 'rc_is 0 && grep -q "^rclone check " "$FAKE_LOG/rclone" && [[ $OUT == *"FUSE mount"*"; continuing"* ]]'
fresh
pair vault-A
printf 'fusectl %s fusectl rw 0 0\nx %s fuse.rclone rw 0 0\nportal %s fuse.portal rw 0 0\n' "$HOME" "$HOME/Vault" "$HOME/Vaults2" >"$OMARCHY_CLOUD_MOUNTS"
runc "$BISYNC" validate vault-A
check "bisync validate: fusectl, and FUSE mounts next to LOCAL (~/Vault, ~/Vaults2), are not hits" eval 'rc_is 0 && [[ -z $OUT ]]'
fresh
pair vault-A
printf 'x %s fuse rw 0 0\n' "$HOME" >"$OMARCHY_CLOUD_MOUNTS"
runc "$BISYNC" validate vault-A
check "bisync validate: fstype fuse (no subtype) counts" eval 'rc_is 64 && [[ $OUT == *"FUSE mount $HOME (fuse)"* ]]'

# The cloud guard checks overlap both ways: a LOCAL that contains a cloud
# location (the configured mount root of cloud.env, /mnt/cloud, ~/Cloud, a
# FUSE mount) would sync a remote into itself. The configured root is a
# scratch dir outside the scratch HOME: $T/srv/clouds.
# cloud_env <line...>: the scratch HOME's cloud.env.
cloud_env() {
  mkdir -p "$HOME/.config/omarchy-cloud"
  printf '%s\n' "$@" >"$HOME/.config/omarchy-cloud/cloud.env"
}
# local_at <path>: pair vault-A on the absolute path (created).
local_at() {
  mkdir -p "$1"
  pair vault-A
  sed -i "s|^LOCAL=.*|LOCAL=$1|" "$HOME/.config/rclone-bisync/vault-A.conf"
}
# root_cases <script> <setter>: the overlap cases against the configured root,
# for LOCAL (bisync) or DEST (backup); <setter> <path> points the pair or job
# at path.
root_cases() {
  local script=$1 setter=$2 what=$3 at
  for at in "$T/srv" "$T" "$T/srv/clouds" "$T/srv/clouds/od/x"; do
    "$setter" "$at"
    runc "$script" validate "$what"
    check "${script##*/} validate: \$T${at#"$T"} overlapping the configured root srv/clouds is refused (exit 64)" \
      eval 'rc_is 64 && no_rclone && [[ $OUT == *"the cloud location $T/srv/clouds;"* ]]'
  done
  "$setter" "$T/srv"
  runc "$script" setup "$what"
  check "${script##*/} setup: the parent of the configured root is refused, naming it (contains)" \
    eval 'rc_is 64 && [[ $OUT == *" $T/srv contains the cloud location $T/srv/clouds;"* && $OUT != *continuing* ]]'
  for at in "$T/srv/cloudsy" "$T/srv/cl"; do
    "$setter" "$at"
    runc "$script" validate "$what"
    check "${script##*/} validate: \$T${at#"$T"}, next to the configured root, is not a hit (exit 0)" eval 'rc_is 0 && [[ -z $OUT ]]'
  done
}
fresh
mkdir -p "$T/srv/clouds/od"
cloud_env "# set by install.sh" "OMARCHY_CLOUD_ROOT=$T/srv/clouds"
root_cases "$BISYNC" local_at vault-A
local_at "$T/srv"
runc "$BISYNC" run vault-A
check "bisync run: LOCAL containing the configured root warns and runs" \
  eval 'rc_is 0 && grep -q "^rclone bisync " "$FAKE_LOG/rclone" && [[ $OUT == *"contains the cloud location $T/srv/clouds; "*"continuing"* ]]'
# The root through a symlink: LOCAL is the link's parent's real folder.
fresh
mkdir -p "$T/real/clouds" "$T/links"
ln -s "$T/real/clouds" "$T/links/clouds"
cloud_env "OMARCHY_CLOUD_ROOT=$T/links/clouds"
local_at "$T/real"
runc "$BISYNC" validate vault-A
check "bisync validate: LOCAL containing the folder the configured root links to is refused" \
  eval 'rc_is 64 && [[ $OUT == *"contains the cloud location $T/links/clouds"* ]]'
# /mnt/cloud stays a target whatever the setting says (an old mount there).
if [[ -d /mnt ]]; then
  for env in "OMARCHY_CLOUD_ROOT=$T/srv/clouds" ""; do
    fresh
    lbl=without
    [[ -n $env ]] && cloud_env "$env" && lbl=with
    local_at /mnt
    runc "$BISYNC" validate vault-A
    check "bisync validate: LOCAL=/mnt contains /mnt/cloud: refused ($lbl a configured root)" \
      eval 'rc_is 64 && [[ $OUT == *"LOCAL /mnt contains the cloud location /mnt/cloud;"* ]]'
  done
else
  echo "skip LOCAL=/mnt cases (no /mnt)"
fi
# Invalid or unsafe settings are ignored (the guard falls back to /mnt/cloud
# and ~/Cloud), and are never executed.
for env in "OMARCHY_CLOUD_ROOT=\$(touch $T/canary)" "OMARCHY_CLOUD_ROOT=\"$T/srv/clouds\"" \
  "OMARCHY_CLOUD_ROOT=\`touch $T/canary\`" "OMARCHY_CLOUD_ROOT=$T/srv/clouds/" "OMARCHY_CLOUD_ROOT=srv/clouds" \
  "OMARCHY_CLOUD_ROOT=$T/srv/clouds x" " OMARCHY_CLOUD_ROOT=$T/srv/clouds" "OMARCHY_CLOUD_ROOT=\$HOME/../srv/clouds"; do
  fresh
  mkdir -p "$T/srv/clouds"
  cloud_env "$env"
  local_at "$T/srv"
  runc "$BISYNC" validate vault-A
  check "bisync validate: cloud.env '${env:0:40}' is invalid: ignored, never run (exit 0, no canary)" \
    eval 'rc_is 0 && [[ -z $OUT && ! -e $T/canary ]]'
done
fresh
mkdir -p "$T/srv/clouds" "$T/srv/old"
cloud_env "OMARCHY_CLOUD_ROOT=$T/srv/old" "" "#OMARCHY_CLOUD_ROOT=$T/x" "OMARCHY_CLOUD_ROOT=$T/srv/clouds"$'\r'
local_at "$T/srv/clouds/x"
runc "$BISYNC" validate vault-A
check "bisync: cloud.env, the last key line wins, \\r stripped, # lines skipped" \
  eval 'rc_is 64 && [[ $OUT == *"inside the cloud location $T/srv/clouds;"* ]]'
local_at "$T/srv/old"
runc "$BISYNC" validate vault-A
check "bisync: cloud.env, an earlier key line is overridden" eval 'rc_is 0'
# A NUL in the value: invalid, as for the readers that keep it (bash would
# drop it and read the existing $T/srv/ab).
fresh
mkdir -p "$T/srv/ab" "$HOME/.config/omarchy-cloud"
printf 'OMARCHY_CLOUD_ROOT=%s/srv/a\0b\n' "$T" >"$HOME/.config/omarchy-cloud/cloud.env"
local_at "$T/srv"
runc "$BISYNC" validate vault-A
check "bisync: a cloud.env value with a NUL byte is invalid, ignored (exit 0, not \$T/srv/ab)" eval 'rc_is 0 && [[ -z $OUT ]]'
# A root setting inside HOME is invalid (valid_root): not used as a target.
fresh
cloud_env "OMARCHY_CLOUD_ROOT=$HOME/mnt"
local_at "$HOME/mnt"
runc "$BISYNC" validate vault-A
check "bisync: a configured root inside HOME is invalid, ignored" eval 'rc_is 0 && [[ -z $OUT ]]'
# A root that resolves into HOME (the mount refuses it: root_outside_home)
# is still a cloud location for the guard: fail closed, as written and
# resolved.
for rel in home/CloudReal/x srv/link/x; do
  fresh
  at=$T/$rel
  mkdir -p "$HOME/CloudReal" "$T/srv"
  ln -s "$HOME/CloudReal" "$T/srv/link"
  cloud_env "OMARCHY_CLOUD_ROOT=$T/srv/link"
  local_at "$at"
  runc "$BISYNC" validate vault-A
  check "bisync validate: a configured root that links into HOME is still a cloud location: LOCAL \$T${at#"$T"} refused" \
    eval 'rc_is 64 && [[ $OUT == *"is inside the cloud location $T/srv/link;"* ]]'
done
# Only the first 4096 bytes are read: a key line past them is not seen.
fresh
mkdir -p "$T/srv/clouds"
cloud_env "#$(printf 'x%.0s' {1..4100})" "OMARCHY_CLOUD_ROOT=$T/srv/clouds"
local_at "$T/srv"
runc "$BISYNC" validate vault-A
check "bisync: cloud.env is read up to 4096 bytes only" eval 'rc_is 0 && [[ -z $OUT ]]'
# ~/Cloud and FUSE mounts, the containing direction.
fresh
mkdir -p "$HOME/Cloud"
local_at "$HOME"
runc "$BISYNC" validate vault-A
check "bisync validate: LOCAL=\$HOME contains ~/Cloud: refused" \
  eval 'rc_is 64 && [[ $OUT == *"LOCAL $HOME contains the cloud location $HOME/Cloud;"* ]]'
fresh
local_at "$HOME/sub"
printf 'me@nas:/ %s fuse.sshfs rw 0 0\n' "$HOME/sub/nas" >"$OMARCHY_CLOUD_MOUNTS"
for sub in setup validate; do
  runc "$BISYNC" "$sub" vault-A
  check "bisync $sub: LOCAL containing a FUSE mount is refused, naming it" \
    eval 'rc_is 64 && [[ $OUT == *"LOCAL $HOME/sub contains the FUSE mount $HOME/sub/nas (fuse.sshfs)"* && $OUT != *continuing* ]]'
done
runc "$BISYNC" run vault-A
check "bisync run: LOCAL containing a FUSE mount warns and runs" \
  eval 'rc_is 0 && grep -q "^rclone bisync " "$FAKE_LOG/rclone" && [[ $OUT == *"contains the FUSE mount"*"; continuing"* ]]'

# A hung FUSE mount (~/Mnt/hung, realpath hangs under it): the guards never
# resolve a path at or under a FUSE mount point; a run completes, and setup
# and validate still refuse the same overlaps (found as written).
hung_mount() {
  mkdir -p "$HOME/Mnt/hung"
  printf 'od: %s fuse.rclone rw 0 0\n' "$HOME/Mnt/hung" >"$OMARCHY_CLOUD_MOUNTS"
  export FAKE_HUNG=$HOME/Mnt/hung
}
fresh
hung_mount
pair vault-A
other_pair vault-B "~/Mnt/hung/x"
bk_dest archive-x "~/Mnt/hung/backups"
for sub in run check; do
  : >"$FAKE_LOG/rclone"
  runhung "$BISYNC" "$sub" vault-A
  check "bisync $sub: other pairs' LOCAL and backup DESTs in a hung FUSE mount are never resolved, the run completes" \
    eval 'rc_is 0 && grep -q "^rclone " "$FAKE_LOG/rclone" && ! resolved_under "$HOME/Mnt" && resolved_under "$HOME/Vaults" && [[ $OUT != *warning:* ]]'
done
fresh
hung_mount
pair vault-A
mkdir -p "$HOME/Mnt/hung/x"
sed -i 's|^LOCAL=.*|LOCAL=~/Mnt/hung/x|' "$HOME/.config/rclone-bisync/vault-A.conf"
other_pair vault-B "~/Mnt/hung/x/sub"
bk_dest archive-x "~/Mnt/hung/x/backups"
runhung "$BISYNC" run vault-A
check "bisync run: overlaps inside a hung FUSE mount warn (backup DEST, pair LOCAL, the mount) and the run completes, nothing resolved there" \
  eval 'rc_is 0 && grep -q "^rclone bisync " "$FAKE_LOG/rclone" && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps DEST"*"; continuing"* && $OUT == *"overlaps LOCAL"*"vault-B"*"; continuing"* && $OUT == *"inside the FUSE mount $HOME/Mnt/hung"*"; continuing"* ]]'
for sub in setup validate; do
  : >"$FAKE_LOG/rclone"
  runhung "$BISYNC" "$sub" vault-A
  check "bisync $sub: the same overlap inside a hung FUSE mount is still refused (exit 64), nothing resolved there" \
    eval 'rc_is 64 && no_rclone && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps DEST"*"archive-x"* && $OUT != *continuing* ]]'
done
rm "$HOME/.config/rclone-backup/archive-x.conf"
runhung "$BISYNC" validate vault-A
check "bisync validate: another pair's LOCAL inside LOCAL, both in a hung FUSE mount, is refused" \
  eval 'rc_is 64 && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps LOCAL"*"vault-B"* ]]'
rm "$HOME/.config/rclone-bisync/vault-B.conf"
runhung "$BISYNC" setup vault-A
check "bisync setup: LOCAL inside a hung FUSE mount is refused, naming the mount" \
  eval 'rc_is 64 && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"inside the FUSE mount $HOME/Mnt/hung (fuse.rclone)"* ]]'
# A path outside every FUSE mount whose realpath hangs anyway (a symlink into
# a hung mount): cut off after 5 s, the path as written is used.
fresh
pair vault-A
other_pair vault-B "~/slow"
export FAKE_HUNG=$HOME/slow
runhung "$BISYNC" run vault-A
check "bisync run: a realpath that hangs outside the FUSE mounts is cut off (timeout 5), the run completes" \
  eval 'rc_is 0 && grep -q "^rclone bisync " "$FAKE_LOG/rclone" && resolved_under "$HOME/slow"'

# --- 4. rclone-backup -------------------------------------------------------------
# The reference naming rule (<job>@, path with / as __), over invented example
# paths; the job is archive-vaults unless given.
live_name() {
  local path=$1 job=${2:-archive-vaults} base
  base="${path#acme/}"; base="${base//\//__}"; base="${base%.kdbx}"
  printf '%s' "$job@$base.$TODAY.kdbx"
}
LIST_SHAPES=(
  "acme/Admin/Segurança/Team.kdbx"
  "acme/Admin/Segurança/Team.old.kdbx"
  "acme/Admin/Segurança/Team-Archive.kdbx"
  "acme/Admin/Segurança/Backup/Team-Archive.kdbx"
  "acme/External/Partner/vaults/Partner-Team.old.kdbx"
)
job() { # job <name> [extra conf lines...]; files list from LIST_SHAPES
  local name=$1
  shift
  mkdir -p "$HOME/.config/rclone-backup"
  {
    echo "REMOTE=work_drive:"
    echo "STRIP_PREFIX=acme/"
    echo "DEST=~/Backups/vaults"
    printf '%s\n' "$@"
  } >"$HOME/.config/rclone-backup/$name.conf"
  { echo "# admin databases"; printf '%s\n' "${LIST_SHAPES[@]}"; } >"$HOME/.config/rclone-backup/$name.files"
}

# staged_log: the rclone log with the random part of each staging folder name
# (.rclone-backup@<job>@XXXXXX) written as XXXXXX.
staged_log() { sed 's/\(\.rclone-backup@[A-Za-z0-9_.-]*@\)[A-Za-z0-9]\{6\}\//\1XXXXXX\//g' "$FAKE_LOG/rclone"; }
# no_stage <dir>: no staging folder of any job left in dir.
no_stage() { [[ -z $(find "$1" -maxdepth 1 -name '.rclone-backup@*') ]]; }

fresh
job archive-vaults "KEEP=3"
DEST=$HOME/Backups/vaults
mkdir -p "$DEST"
chmod 755 "$DEST"
J=archive-vaults@Admin__Segurança__Team
for d in 01 02 03 04 05; do echo old >"$DEST/$J.2026-11-$d.kdbx"; done
echo other >"$DEST/$J.old.2026-11-01.kdbx"
echo stale >"$DEST/$J.2026-11-13.kdbx.part"
echo mine >"$DEST/notes.txt"
# Legacy (<= 0.3.1, unprefixed) copies and .part of the same file, and the
# copies of another job sharing DEST: never touched.
for d in 01 02 03 04 05; do echo legacy >"$DEST/Admin__Segurança__Team.2026-10-$d.kdbx"; done
echo legacy >"$DEST/Admin__Segurança__Team.2026-10-06.kdbx.part"
for d in 01 02 03 04 05; do echo theirs >"$DEST/other-job@Admin__Segurança__Team.2026-11-$d.kdbx"; done
runc "$BACKUP" run archive-vaults
check "backup run: exit 0" rc_is 0
check "names: job archive-vaults, acme/Admin/Segurança/Team.kdbx -> archive-vaults@Admin__Segurança__Team.2026-11-14.kdbx" \
  test -f "$DEST/archive-vaults@Admin__Segurança__Team.2026-11-14.kdbx"
names_ok=1
for p in "${LIST_SHAPES[@]}"; do
  [[ -f $DEST/$(live_name "$p") ]] || { names_ok=0; echo "     missing $(live_name "$p") for $p"; }
done
check "names: every list shape is named exactly as the reference rule names it" test "$names_ok" = 1
check "names: 5 copies made, nothing else new" eval '[[ $(find "$DEST" -name "*.$TODAY.kdbx" | wc -l) == 5 ]]'
check "prune: newest KEEP=3 of that file remain (11-04, 11-05, 11-14)" \
  eval '[[ "$(cd "$DEST" && printf "%s " "$J".2026-11-*.kdbx)" == "$J.2026-11-04.kdbx $J.2026-11-05.kdbx $J.$TODAY.kdbx " ]]'
check "prune: another file's copies and unrelated files untouched" \
  eval '[[ -f $DEST/$J.old.2026-11-01.kdbx && -f $DEST/notes.txt ]]'
check "prune: legacy unprefixed copies (5 > KEEP=3) and their .part untouched" \
  eval '[[ $(cd "$DEST" && printf "%s\n" Admin__Segurança__Team.2026-10-*.kdbx | wc -l) == 5 && -f $DEST/Admin__Segurança__Team.2026-10-06.kdbx.part ]]'
check "prune: another job's copies of the same file in a shared DEST untouched" \
  eval '[[ $(cd "$DEST" && printf "%s\n" other-job@Admin__Segurança__Team.2026-11-*.kdbx | wc -l) == 5 ]]'
check "a stale .part of an earlier run is removed; only the legacy .part left" \
  eval '[[ $(find "$DEST" -name "*.part") == "$DEST/Admin__Segurança__Team.2026-10-06.kdbx.part" ]]'
check "modes: an existing DEST keeps its mode (755), copies 600" \
  eval '[[ $(stat -c %a "$DEST") == 755 && $(stat -c %a "$DEST/$(live_name "${LIST_SHAPES[1]}")") == 600 ]]'
check "copyto <remote path> <this run's private staging folder in DEST>/<copy name>, with retries" \
  eval 'staged_log | grep -qxF "rclone$(q copyto "work_drive:${LIST_SHAPES[0]}" "$DEST/.rclone-backup@archive-vaults@XXXXXX/$J.$TODAY.kdbx" --retries 3 --log-level ERROR)"'
check "read-only toward the remote: every rclone call is copyto <remote> <staging folder in DEST>" \
  eval '! grep -v "^rclone copyto work_drive:[^ ]* $(printf %q "$DEST")/\.rclone-backup@archive-vaults@[A-Za-z0-9]\{6\}/[^/ ]* --retries 3 --log-level ERROR$" "$FAKE_LOG/rclone" | grep -q .'
check "no staging folder left after a successful run" no_stage "$DEST"
check "state: exit=0 ok=5 failed=0" \
  eval 'grep -qx exit=0 "$HOME/.local/state/rclone-backup/archive-vaults.state" && grep -qx ok=5 "$HOME/.local/state/rclone-backup/archive-vaults.state" && grep -qx failed=0 "$HOME/.local/state/rclone-backup/archive-vaults.state"'
check "no notification on success" eval '[[ ! -s $FAKE_LOG/notify-send ]]'
runc "$BACKUP" run archive-vaults
check "a second run the same day replaces, does not duplicate" eval 'rc_is 0 && [[ $(find "$DEST" -name "*.$TODAY.kdbx" | wc -l) == 5 ]]'

fresh
job archive-vaults
DEST=$HOME/Backups/vaults
runc "$BACKUP" run archive-vaults
check "modes: a DEST the run creates is 700" eval 'rc_is 0 && [[ $(stat -c %a "$DEST") == 700 ]]'

fresh
job archive-vaults
DEST=$HOME/Backups/vaults
FAKE_COPY_FAIL="work_drive:${LIST_SHAPES[2]}" runc "$BACKUP" run archive-vaults
check "a failed copy: exit 1, the others still copied" eval 'rc_is 1 && [[ $(find "$DEST" -name "*.$TODAY.kdbx" | wc -l) == 4 ]]'
check "a failed copy: no partial file left, no copy under its name, no staging folder" \
  eval '[[ -z $(find "$DEST" -name "*.part") && ! -e $DEST/$(live_name "${LIST_SHAPES[2]}") ]] && no_stage "$DEST"'
check "a failed copy: one normal notification from rclone-backup" \
  eval '[[ $(log notify-send | wc -l) == 1 && $(log notify-send) == "notify-send -u normal -a rclone-backup "* ]]'
check "a failed copy: state exit=1 ok=4 failed=1" \
  eval 'grep -qx exit=1 "$HOME/.local/state/rclone-backup/archive-vaults.state" && grep -qx ok=4 "$HOME/.local/state/rclone-backup/archive-vaults.state" && grep -qx failed=1 "$HOME/.local/state/rclone-backup/archive-vaults.state"'

fresh
job archive-vaults "KEEP=1"
DEST=$HOME/Backups/vaults
mkdir -p "$DEST"
J=archive-vaults@Admin__Segurança__Team
echo old1 >"$DEST/$J.2026-11-01.kdbx"
echo old2 >"$DEST/$J.2026-11-02.kdbx"
PATH="$MVSTUB:$PATH" FAKE_MV_FAIL="$DEST/$J.$TODAY.kdbx" runc "$BACKUP" run archive-vaults
check "a failed mv: exit 1, counted failed (state ok=4 failed=1)" \
  eval 'rc_is 1 && grep -qx ok=4 "$HOME/.local/state/rclone-backup/archive-vaults.state" && grep -qx failed=1 "$HOME/.local/state/rclone-backup/archive-vaults.state"'
check "a failed mv: no staging folder left, its older copies not pruned" \
  eval 'no_stage "$DEST" && [[ -f $DEST/$J.2026-11-01.kdbx && -f $DEST/$J.2026-11-02.kdbx && ! -e $DEST/$J.$TODAY.kdbx ]]'
check "a failed mv: notified" eval '[[ $(log notify-send) == *"$(printf %q "1 of 5 files failed")"* ]]'

fresh
job archive-vaults
mkdir -p "$HOME/.local/state/omarchy-cloud/locks"
flock "$HOME/.local/state/omarchy-cloud/locks/rclone-backup-archive-vaults.lock" sleep 10 &
holder=$!
for _ in {1..50}; do flock -n "$HOME/.local/state/omarchy-cloud/locks/rclone-backup-archive-vaults.lock" true || break; sleep 0.05; done
runc "$BACKUP" run archive-vaults
check "backup lock busy: run exits 0 without rclone or state" \
  eval 'rc_is 0 && no_rclone && [[ $OUT == *"another run is active"* && ! -e $HOME/.local/state/rclone-backup/archive-vaults.state ]]'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# The run locks (lock_dir, one bash function copied byte for byte between its
# marker lines into both helpers and install.sh): always
# ~/.local/state/omarchy-cloud/locks, whatever XDG_RUNTIME_DIR is (a timer
# run and a shell run must lock the same file), never a predictable name in a
# shared folder. With XDG_RUNTIME_DIR unset the helpers used to open
# /tmp/rclone-<kind>-<name>.lock with truncation, so another account's
# symlink there truncated the file it pointed to. The only writes outside the
# scratch dir: those /tmp symlinks, under a name unique to this run, removed.
LD_BEGIN='# --- lock_dir (shared: bin/rclone-bisync, bin/rclone-backup, install.sh) ---'
LD_END='# --- end lock_dir ---'
ld_block() { awk -v b="$LD_BEGIN" -v e="$LD_END" '$0 == b { p = 1 } p { print } p && $0 == e { exit }' "$1"; }
LD_REF=$(ld_block "$BISYNC")
for f in "$BISYNC" "$BACKUP" "$PLUGIN_DIR/install.sh"; do
  blk=$(ld_block "$f")
  check "lock_dir: ${f#"$PLUGIN_DIR"/} has the marker block, byte-identical to bin/rclone-bisync's" \
    eval '[[ $blk == "$LD_BEGIN"$'"'"'\n'"'"'*lock_dir\(\)*"$LD_END" && $blk == "$LD_REF" ]]'
done
LKD_REL=.local/state/omarchy-cloud/locks
LK=lk-$$-$RANDOM
LK_TMP=("/tmp/rclone-backup-$LK.lock" "/tmp/rclone-bisync-$LK.lock")
# unset_run <tag> <cmd...>: runc with XDG_RUNTIME_DIR unset (a subshell);
# RC and OUT copied back.
unset_run() {
  local tag=$1
  shift
  (unset XDG_RUNTIME_DIR && runc "$@" && printf '%s' "$RC" >"$T/$tag.rc" && printf '%s' "$OUT" >"$T/$tag.out")
  RC=$(cat "$T/$tag.rc" 2>/dev/null || echo 255) OUT=$(cat "$T/$tag.out" 2>/dev/null)
}
# lk_run <script> <kind>: a run of job/pair $LK with XDG_RUNTIME_DIR unset and
# another account's symlink planted at the old /tmp name, aimed at $T/victim.
lk_run() {
  printf 'keep\n' >"$T/victim"
  rm -f -- "/tmp/rclone-$2-$LK.lock"
  ln -s -- "$T/victim" "/tmp/rclone-$2-$LK.lock" || return 1
  unset_run "$2" "$1" run "$LK"
  rm -f -- "/tmp/rclone-$2-$LK.lock"
}
fresh
job "$LK"
lk_run "$BACKUP" backup
check "backup lock, XDG_RUNTIME_DIR unset: a symlink planted at /tmp/rclone-backup-<job>.lock is never written through; the run uses ~/$LKD_REL (700)" \
  eval '[[ $(cat "$T/victim") == keep && -f $HOME/$LKD_REL/rclone-backup-$LK.lock && $(stat -c %a "$HOME/$LKD_REL") == 700 ]] && rc_is 0'
fresh
pair "$LK"
lk_run "$BISYNC" bisync
check "bisync lock, XDG_RUNTIME_DIR unset: a symlink planted at /tmp/rclone-bisync-<pair>.lock is never written through; the run uses ~/$LKD_REL" \
  eval '[[ $(cat "$T/victim") == keep && -f $HOME/$LKD_REL/rclone-bisync-$LK.lock ]] && rc_is 0'
rm -f -- "${LK_TMP[@]}"

# XDG_RUNTIME_DIR set or unset: the same lock file, opened without truncation.
fresh
job j
pair p
mkdir -p "$HOME/$LKD_REL"
printf 'held\n' >"$HOME/$LKD_REL/rclone-backup-j.lock"
printf 'held\n' >"$HOME/$LKD_REL/rclone-bisync-p.lock"
runc "$BACKUP" run j
rc_b=$RC
runc "$BISYNC" run p
check "locks with XDG_RUNTIME_DIR set: in ~/$LKD_REL, not truncated, nothing in XDG_RUNTIME_DIR" \
  eval '((rc_b == 0)) && rc_is 0 && [[ $(cat "$HOME/$LKD_REL/rclone-backup-j.lock") == held && $(cat "$HOME/$LKD_REL/rclone-bisync-p.lock") == held && -z $(ls -A "$XDG_RUNTIME_DIR") ]]'
flock "$HOME/$LKD_REL/rclone-backup-j.lock" sleep 10 &
holder=$!
for _ in {1..50}; do flock -n "$HOME/$LKD_REL/rclone-backup-j.lock" true || break; sleep 0.05; done
: >"$FAKE_LOG/rclone"
unset_run b "$BACKUP" run j
check "backup lock held by a run with XDG_RUNTIME_DIR set: a run with it unset sees it (exit 0, skipped)" \
  eval 'rc_is 0 && no_rclone && [[ $OUT == *"another run is active"* ]]'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# An unusable lock folder: refused, said, notified, recorded (exit=1), no rclone.
# lk_bad <description> <setup command>: both helpers on a fresh tree.
lk_bad() {
  fresh
  job j
  pair p
  mkdir -p "$HOME/.local/state" "$T/elsewhere"
  eval "$2"
  runc "$BACKUP" run j
  rc_b=$RC out_b=$OUT
  runc "$BISYNC" run p
  check "lock folder $1: backup and bisync exit 1, say why, notify, record exit=1, no rclone, nothing written through it" \
    eval '((rc_b == 1)) && rc_is 1 && [[ $out_b == *"the run lock folder"* && $OUT == *"the run lock folder"* ]] && no_rclone &&
      grep -qx exit=1 "$HOME/.local/state/rclone-backup/j.state" && grep -qx exit=1 "$HOME/.local/state/rclone-bisync/p.state" &&
      [[ $(log notify-send) == *rclone-backup*rclone-bisync* && -z $(ls -A "$T/elsewhere") ]]'
}
lk_bad "a symlink" 'mkdir -p "$HOME/.local/state/omarchy-cloud" && ln -s "$T/elsewhere" "$HOME/$LKD_REL"'
lk_bad "writable by other accounts (777)" 'mkdir -p "$HOME/$LKD_REL" && chmod 777 "$HOME/$LKD_REL"'
lk_bad "under a group-writable omarchy-cloud folder (775)" 'mkdir -p "$HOME/$LKD_REL" && chmod 775 "$HOME/.local/state/omarchy-cloud"'
lk_bad "under a symlinked omarchy-cloud folder" 'ln -s "$T/elsewhere" "$HOME/.local/state/omarchy-cloud"'
fresh
job j
mkdir -p "$HOME/$LKD_REL"
chmod 777 "$HOME/$LKD_REL"
runc "$BACKUP" run j
check "lock folder writable by other accounts: the reason names the mode and the fix" eval 'rc_is 1 && [[ $OUT == *"writable by other accounts (mode 0777); run chmod go-w"* ]]'
# A conflict list kept: a lock failure does not drop the previous state's copies.
fresh
pair p
mkdir -p "$HOME/.local/state/rclone-bisync" "$HOME/.local/state/omarchy-cloud"
printf 'time=1\nexit=0\nconflict=a.conflict1\nnotified=a.conflict1\n' >"$HOME/.local/state/rclone-bisync/p.state"
ln -s "$T" "$HOME/$LKD_REL"
runc "$BISYNC" run p
check "bisync lock folder refused: the state keeps the previous conflict copies" \
  eval 'rc_is 1 && grep -qx exit=1 "$HOME/.local/state/rclone-bisync/p.state" && grep -qx conflict=a.conflict1 "$HOME/.local/state/rclone-bisync/p.state" && grep -qx notified=a.conflict1 "$HOME/.local/state/rclone-bisync/p.state"'
: >"$FAKE_LOG/notify-send"
runc "$BISYNC" dry-run p
check "bisync dry-run, lock folder refused: exit 1, no rclone, not notified" eval 'rc_is 1 && no_rclone && [[ ! -s $FAKE_LOG/notify-send ]]'

# A symlink as the lock file: refused (exit 1), never followed.
fresh
job j
pair p
mkdir -p "$HOME/$LKD_REL"
ln -s "$T/victim2" "$HOME/$LKD_REL/rclone-backup-j.lock"
ln -s "$T/victim3" "$HOME/$LKD_REL/rclone-bisync-p.lock"
runc "$BACKUP" run j
rc_b=$RC out_b=$OUT
runc "$BISYNC" run p
check "a symlink as the lock file: backup and bisync refuse (exit 1), never follow it" \
  eval '((rc_b == 1)) && rc_is 1 && no_rclone && [[ ! -e $T/victim2 && ! -e $T/victim3 && $out_b == *"is a symlink"* && $OUT == *"is a symlink"* ]]'
fresh
mkdir -p "$HOME/.config/rclone-backup"
printf 'REMOTE=gd:Shared/docs\nDEST=%s/out\nFILES=~/list\n' "$T" >"$HOME/.config/rclone-backup/j.conf"
printf 'a/report.pdf\nREADME\n.hidden\n' >"$HOME/list"
runc "$BACKUP" run j
check "prefix in REMOTE, other extensions, none, dotfile" \
  eval 'rc_is 0 && [[ -f $T/out/j@a__report.$TODAY.pdf && -f $T/out/j@README.$TODAY && -f $T/out/j@.hidden.$TODAY ]]'
check "prefix joined with /" eval 'grep -qF "copyto gd:Shared/docs/a/report.pdf" "$FAKE_LOG/rclone"'
runc "$BACKUP" list j
check "list: the validated paths" eval 'rc_is 0 && [[ $OUT == $'"'"'a/report.pdf\nREADME\n.hidden'"'"' ]]'

bad_files() { # bad_files <description> <list line>
  fresh
  job j
  printf '%s\n' "$2" >>"$HOME/.config/rclone-backup/j.files"
  runc "$BACKUP" run j
  check "files list $1: exit 64, nothing copied" eval 'rc_is 64 && no_rclone'
}
bad_files "with a .. segment" "acme/../etc/passwd"
bad_files "with an absolute path" "/etc/passwd"
bad_files "with a trailing /" "acme/dir/"
bad_files "with an empty segment" "acme//x.kdbx"
bad_files "with a duplicate copy name" "acme/Admin/Segurança/Team.kdbx"
check "invalid conf on run: notified and recorded (exit=64)" \
  eval '[[ -s $FAKE_LOG/notify-send ]] && grep -qx exit=64 "$HOME/.local/state/rclone-backup/j.state"'

for kv in "KEEP=0" "KEEP=366" "KEEP=x" "SCHEDULE=daily;rm" "COLOR=red" "REMOTE=work_drive:x/" "REMOTE=work_drive:../x"; do
  fresh
  job j "$kv"
  [[ $kv == REMOTE=* ]] && sed -i '1d' "$HOME/.config/rclone-backup/j.conf"
  runc "$BACKUP" run j
  check "backup conf $kv: exit 64" eval 'rc_is 64 && no_rclone'
done
fresh
mkdir -p "$HOME/.config/rclone-backup"
echo "REMOTE=work_drive:" >"$HOME/.config/rclone-backup/j.conf"
: >"$HOME/.config/rclone-backup/j.files"
runc "$BACKUP" run j
check "backup conf without DEST: exit 64" rc_is 64
runc "$BACKUP" run ../j
check "bad job name: exit 64" rc_is 64

# Every case of the shared files-list cases (tests/fixtures/files-lines.tsv;
# the app's verdict, conf::check_files_list, is tested against the same
# file): a conf with the case's STRIP_PREFIX, a files list of its lines
# (decoded with printf %b: \t \r \\ \xHH). `list` exits 0 for a valid case,
# 64 for an invalid one, under LC_ALL=C and C.UTF-8 (when installed); a
# stricter case (the app refuses it) exits 0 under C.
FL_LOCALES=(C)
locale -a 2>/dev/null | grep -qix 'c\.utf-\?8' && FL_LOCALES+=(C.UTF-8)
fl_n=0 fl_bad=()
while IFS= read -r fl_line; do
  [[ -z $fl_line || $fl_line == '#'* ]] && continue
  fl_kind=${fl_line%%$'\t'*} fl_rest=${fl_line#*$'\t'}
  fl_strip=${fl_rest%%$'\t'*} fl_rest=${fl_rest#*$'\t'}
  fresh
  mkdir -p "$HOME/.config/rclone-backup"
  {
    echo "REMOTE=work_drive:"
    echo "DEST=~/Backups/fl"
    [[ $fl_strip == - ]] || LC_ALL=C printf 'STRIP_PREFIX=%b\n' "$fl_strip"
  } >"$HOME/.config/rclone-backup/fl.conf"
  : >"$HOME/.config/rclone-backup/fl.files"
  while :; do
    LC_ALL=C printf '%b\n' "${fl_rest%%$'\t'*}" >>"$HOME/.config/rclone-backup/fl.files"
    [[ $fl_rest == *$'\t'* ]] || break
    fl_rest=${fl_rest#*$'\t'}
  done
  fl_n=$((fl_n + 1))
  for fl_loc in "${FL_LOCALES[@]}"; do
    case $fl_kind in
      valid) fl_want=0 ;;
      invalid) fl_want=64 ;;
      stricter) [[ $fl_loc == C ]] || continue; fl_want=0 ;;
      *) fl_want='unknown kind' ;;
    esac
    runc env LC_ALL="$fl_loc" "$BACKUP" list fl
    if [[ $RC != "$fl_want" ]] || ! no_rclone; then
      fl_bad+=("$fl_loc:$fl_kind:$(printf %q "${fl_line#*$'\t'}")=$RC")
    fi
  done
done <"$FILES_TSV"
check "files-lines.tsv: rclone-backup list agrees with every case ($fl_n, locales ${FL_LOCALES[*]}${fl_bad:+; wrong: ${fl_bad[*]}})" \
  eval '((fl_n >= 40 && ${#fl_bad[@]} == 0))'

# DEST (~/Backups/vaults) against the LOCAL of offline folders.
for local in "~/Backups/vaults/sub" "~/Backups/vaults" "~/Backups" "~/"; do
  fresh
  job archive-vaults
  mkdir -p "$HOME/.config/rclone-bisync"
  printf 'LOCAL=%s\nREMOTE=onedrive:x\n' "$local" >"$HOME/.config/rclone-bisync/vault-A.conf"
  runc "$BACKUP" setup archive-vaults
  check "backup setup: DEST overlapping LOCAL $local is refused (exit 64, no rclone, no drop-in)" \
    eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps LOCAL"*"vault-A"* && $OUT != *continuing* && ! -e $HOME/.config/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
  runc "$BACKUP" run archive-vaults
  check "backup run: DEST overlapping offline folder LOCAL $local warns and backs up (exit 0, copied, not notified)" \
    eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: archive-vaults: DEST"*"overlaps LOCAL"*"vault-A"*"; continuing"* && ! -s $FAKE_LOG/notify-send ]] && grep -qx exit=0 "$HOME/.local/state/rclone-backup/archive-vaults.state"'
done
fresh
job archive-vaults
mkdir -p "$HOME/.config/rclone-bisync"
printf 'LOCAL=~/Backups/vaults-sync\nREMOTE=onedrive:x\n' >"$HOME/.config/rclone-bisync/vault-A.conf"
runc "$BACKUP" run archive-vaults
check "backup run: a LOCAL next to DEST (vaults-sync vs vaults) is not an overlap" rc_is 0
fresh
job archive-vaults
mkdir -p "$HOME/Vaults" "$HOME/Backups" "$HOME/.config/rclone-bisync"
ln -s "$HOME/Vaults" "$HOME/Backups/vaults"
printf 'LOCAL=~/Vaults\nREMOTE=onedrive:x\n' >"$HOME/.config/rclone-bisync/vault-A.conf"
runc "$BACKUP" setup archive-vaults
check "backup setup: a DEST that is LOCAL through a symlink is refused" eval 'rc_is 64 && no_rclone'
runc "$BACKUP" run archive-vaults
check "backup run: a DEST that is LOCAL through a symlink warns and backs up" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"overlaps LOCAL"*"; continuing"* ]]'

fresh
job archive-vaults "SCHEDULE=*-*-* 03:30"
runc "$BACKUP" setup archive-vaults
UD=$HOME/.config/systemd/user
check "backup setup: drop-in resets OnCalendar then sets SCHEDULE" \
  eval '[[ $(cat "$UD/rclone-backup@archive-vaults.timer.d/10-schedule.conf") == $'"'"'[Timer]\nOnCalendar=\nOnCalendar=*-*-* 03:30'"'"' ]]'
check "backup setup: daemon-reload, rclone not called" eval '[[ $(log systemctl) == "systemctl --user daemon-reload" ]] && no_rclone'
BK_UD=$UD
fresh
job j "SCHEDULE=every day"
runc "$BACKUP" setup j
if command -v systemd-analyze >/dev/null; then
  check "backup setup: a SCHEDULE systemd cannot parse is exit 64" eval 'rc_is 64 && [[ ! -e $HOME/.config/systemd/user/rclone-backup@j.timer.d ]]'
fi
fresh
mkdir -p "$HOME/.config/systemd/user/rclone-backup@j.timer.d"
echo x >"$HOME/.config/systemd/user/rclone-backup@j.timer.d/10-schedule.conf"
runc "$BACKUP" teardown j
check "backup teardown: drop-in dir gone, no conf needed" eval 'rc_is 0 && [[ ! -e $HOME/.config/systemd/user/rclone-backup@j.timer.d ]]'

# An empty files list is an invalid conf everywhere: run notifies and records
# exit=64; setup, validate and list are exit 64.
fresh
job archive-vaults
printf '# nothing yet\n\n' >"$HOME/.config/rclone-backup/archive-vaults.files"
runc "$BACKUP" run archive-vaults
check "empty files list: run exit 64, no rclone, notified, state exit=64" \
  eval 'rc_is 64 && no_rclone && [[ $OUT == *"files list"*"is empty"* && -s $FAKE_LOG/notify-send ]] && grep -qx exit=64 "$HOME/.local/state/rclone-backup/archive-vaults.state"'
check "empty files list: run creates no DEST" eval '[[ ! -e $HOME/Backups/vaults ]]'
for sub in setup validate list; do
  runc "$BACKUP" "$sub" archive-vaults
  check "empty files list: $sub exit 64, no drop-in" \
    eval 'rc_is 64 && [[ $OUT == *"is empty"* && ! -e $HOME/.config/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
done

# validate: the conf, the list and every setup-time guard; nothing written.
fresh
job archive-vaults
before=$(find "$T" | LC_ALL=C sort)
runc "$BACKUP" validate archive-vaults
check "backup validate: a valid job is exit 0, silent, no rclone, no systemctl, nothing written" \
  eval 'rc_is 0 && [[ -z $OUT ]] && no_rclone && [[ ! -e $FAKE_LOG/systemctl && ! -e $FAKE_LOG/notify-send && $(find "$T" | LC_ALL=C sort) == "$before" ]]'
if command -v systemd-analyze >/dev/null; then
  fresh
  job j "SCHEDULE=every day"
  runc "$BACKUP" validate j
  check "backup validate: a SCHEDULE systemd cannot parse is exit 64" eval 'rc_is 64 && [[ $OUT == *SCHEDULE* ]]'
fi

# set_dest <job> <DEST value>
set_dest() { sed -i "s|^DEST=.*|DEST=$2|" "$HOME/.config/rclone-backup/$1.conf"; }

# DEST against the DEST of the other jobs.
for other in "~/Backups/vaults" "~/Backups" "~/Backups/vaults/old" "@HOME@/Backups/vaults/"; do
  fresh
  job archive-vaults
  bk_dest other-job "${other//@HOME@/$HOME}"
  for sub in setup validate; do
    runc "$BACKUP" "$sub" archive-vaults
    check "backup $sub: DEST overlapping the DEST $other of another job is refused (exit 64, no drop-in)" \
      eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps DEST"*"backup job other-job"* && $OUT != *continuing* && ! -e $HOME/.config/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
  done
  runc "$BACKUP" run archive-vaults
  check "backup run: DEST overlapping another job's DEST $other warns and backs up (exit 0)" \
    eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: archive-vaults: DEST"*"overlaps DEST"*"other-job"*"; continuing"* ]] && grep -qx exit=0 "$HOME/.local/state/rclone-backup/archive-vaults.state"'
done
fresh
job archive-vaults
bk_dest other-job "~/Backups/vaults-2"
runc "$BACKUP" validate archive-vaults
check "backup validate: another job's DEST next to DEST (vaults-2 vs vaults) is not an overlap" eval 'rc_is 0 && [[ -z $OUT ]]'
fresh
job archive-vaults
mkdir -p "$HOME/Backups/vaults"
ln -s "$HOME/Backups/vaults" "$HOME/vlink"
bk_dest other-job "~/vlink"
runc "$BACKUP" validate archive-vaults
check "backup validate: another job's DEST that is DEST through a symlink is refused" eval 'rc_is 64 && [[ $OUT == *"other-job"* ]]'

# DEST inside a cloud location.
fresh
job archive-vaults
set_dest archive-vaults /mnt/cloud/onedrive/backups
for sub in setup validate; do
  runc "$BACKUP" "$sub" archive-vaults
  check "backup $sub: DEST inside /mnt/cloud is refused (exit 64), naming it" \
    eval 'rc_is 64 && no_rclone && [[ $OUT == *"inside the cloud location /mnt/cloud"* && $OUT != *continuing* ]]'
done
fresh
job archive-vaults
set_dest archive-vaults "~/Cloud/onedrive/backups"
runc "$BACKUP" validate archive-vaults
check "backup validate: DEST inside ~/Cloud is refused" eval 'rc_is 64 && [[ $OUT == *"inside the cloud location $HOME/Cloud"* ]]'
runc "$BACKUP" run archive-vaults
check "backup run: DEST inside ~/Cloud warns and backs up" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"cloud location"*"; continuing"* ]]'
fresh
job archive-vaults
printf 'gdrive: %s fuse.rclone rw 0 0\n' "$HOME/Backups" >"$OMARCHY_CLOUD_MOUNTS"
runc "$BACKUP" validate archive-vaults
check "backup validate: DEST inside a FUSE mount is refused, naming the mount" \
  eval 'rc_is 64 && [[ $OUT == *"inside the FUSE mount $HOME/Backups (fuse.rclone)"* ]]'
runc "$BACKUP" run archive-vaults
check "backup run: DEST inside a FUSE mount warns and backs up" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"FUSE mount"*"; continuing"* ]]'

# The cloud guard both ways (see the bisync cases): DEST containing the
# configured root, /mnt/cloud, ~/Cloud or a FUSE mount.
dest_at() { job archive-vaults; set_dest archive-vaults "$1"; }
fresh
mkdir -p "$T/srv/clouds/od"
cloud_env "OMARCHY_CLOUD_ROOT=$T/srv/clouds"
root_cases "$BACKUP" dest_at archive-vaults
dest_at "$T/srv"
runc "$BACKUP" run archive-vaults
check "backup run: DEST containing the configured root warns and backs up" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"contains the cloud location $T/srv/clouds; "*"continuing"* ]]'
for rel in home/CloudReal/x srv/link/x; do
  fresh
  at=$T/$rel
  mkdir -p "$HOME/CloudReal" "$T/srv"
  ln -s "$HOME/CloudReal" "$T/srv/link"
  cloud_env "OMARCHY_CLOUD_ROOT=$T/srv/link"
  dest_at "$at"
  runc "$BACKUP" validate archive-vaults
  check "backup validate: a configured root that links into HOME is still a cloud location: DEST \$T${at#"$T"} refused" \
    eval 'rc_is 64 && [[ $OUT == *"is inside the cloud location $T/srv/link;"* ]]'
done
for at in /mnt /; do
  fresh
  dest_at "$at"
  runc "$BACKUP" validate archive-vaults
  check "backup validate: DEST=$at contains /mnt/cloud: refused (no setting)" \
    eval 'rc_is 64 && [[ $OUT == *"DEST $at contains the cloud location /mnt/cloud;"* ]]'
done
for at in /mnt/cloudy/backups /mnt/cloud-backups; do
  fresh
  dest_at "$at"
  runc "$BACKUP" validate archive-vaults
  check "backup validate: DEST=$at (next to /mnt/cloud) is not a hit (exit 0)" eval 'rc_is 0 && [[ -z $OUT ]]'
done
fresh
mkdir -p "$HOME/Cloud"
dest_at "$HOME"
runc "$BACKUP" validate archive-vaults
check "backup validate: DEST=\$HOME contains ~/Cloud: refused" \
  eval 'rc_is 64 && [[ $OUT == *"DEST $HOME contains the cloud location $HOME/Cloud;"* ]]'
fresh
job archive-vaults
printf 'me@nas:/ %s fuse.sshfs rw 0 0\n' "$HOME/Backups/vaults/nas" >"$OMARCHY_CLOUD_MOUNTS"
runc "$BACKUP" setup archive-vaults
check "backup setup: DEST containing a FUSE mount is refused, naming it" \
  eval 'rc_is 64 && [[ $OUT == *"DEST $HOME/Backups/vaults contains the FUSE mount $HOME/Backups/vaults/nas (fuse.sshfs)"* && $OUT != *continuing* ]]'
fresh
mkdir -p "$T/srv/clouds"
cloud_env "OMARCHY_CLOUD_ROOT=\$(touch $T/canary)"
dest_at "$T/srv"
runc "$BACKUP" validate archive-vaults
check "backup: an invalid cloud.env is ignored and never run (exit 0, no canary)" eval 'rc_is 0 && [[ -z $OUT && ! -e $T/canary ]]'
fresh
mkdir -p "$T/srv/ab" "$HOME/.config/omarchy-cloud"
printf 'OMARCHY_CLOUD_ROOT=%s/srv/a\0b\n' "$T" >"$HOME/.config/omarchy-cloud/cloud.env"
dest_at "$T/srv"
runc "$BACKUP" validate archive-vaults
check "backup: a cloud.env value with a NUL byte is invalid, ignored (exit 0, not \$T/srv/ab)" eval 'rc_is 0 && [[ -z $OUT ]]'

# The failure notification strips < > & from the message (it carries paths)
# and the job name; stderr (the journal) keeps the real text.
fresh
job archive-vaults "FILES=~/$HOSTILE"
runc "$BACKUP" run archive-vaults
check "backup notification: summary and body have no < > & (hostile path in the message)" \
  eval 'rc_is 64 && [[ $(notify_arg 4) == "Backup archive-vaults" ]] && no_markup_chars "$(notify_arg 4)" && no_markup_chars "$(notify_arg 5)" && [[ $(notify_arg 5) == *"a href=\"https:#47;#47;evil.example\"Open the fix#47;a does not exist; see: journalctl --user -u rclone-backup@archive-vaults" ]]'
check "backup stderr: the real path, unchanged" eval '[[ $OUT == *"files list $HOME/$HOSTILE does not exist"* ]]'
if [[ -n $RENDER ]]; then
  notify_arg 5 >"$T/body"
  check "backup notification: the shell's Markup.render of the body has no link" \
    eval '[[ $(render_markup "$T/body") != *"<a"* ]]'
else
  echo "skip Markup.render check (no $MARKUP_JS or no node)"
fi

# A hung FUSE mount (see the bisync tests): other jobs' DEST and pairs' LOCAL
# in it are never resolved; a run completes; validate and setup still refuse.
fresh
hung_mount
job archive-vaults
bk_dest other-job "~/Mnt/hung/b"
other_pair vault-B "~/Mnt/hung/x"
runhung "$BACKUP" run archive-vaults
check "backup run: other jobs' DEST and pairs' LOCAL in a hung FUSE mount are never resolved, the backup completes" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && ! resolved_under "$HOME/Mnt" && resolved_under "$HOME/Backups/vaults" && [[ $OUT != *warning:* ]] && grep -qx exit=0 "$HOME/.local/state/rclone-backup/archive-vaults.state"'
fresh
hung_mount
job archive-vaults
set_dest archive-vaults "~/Mnt/hung/b"
bk_dest other-job "~/Mnt/hung/b/old"
other_pair vault-B "~/Mnt/hung"
runhung "$BACKUP" run archive-vaults
check "backup run: overlaps inside a hung FUSE mount warn (pair LOCAL, job DEST, the mount) and the backup completes, nothing resolved there" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps LOCAL"*"vault-B"*"; continuing"* && $OUT == *"overlaps DEST"*"other-job"*"; continuing"* && $OUT == *"inside the FUSE mount $HOME/Mnt/hung"*"; continuing"* ]]'
for sub in setup validate; do
  : >"$FAKE_LOG/rclone"
  runhung "$BACKUP" "$sub" archive-vaults
  check "backup $sub: the same overlap inside a hung FUSE mount is still refused (exit 64), nothing resolved there" \
    eval 'rc_is 64 && no_rclone && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps LOCAL"*"vault-B"* && $OUT != *continuing* ]]'
done
rm "$HOME/.config/rclone-bisync/vault-B.conf"
runhung "$BACKUP" validate archive-vaults
check "backup validate: another job's DEST inside DEST, both in a hung FUSE mount, is refused" \
  eval 'rc_is 64 && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps DEST"*"other-job"* ]]'
fresh
job archive-vaults
bk_dest other-job "~/slow"
export FAKE_HUNG=$HOME/slow
runhung "$BACKUP" run archive-vaults
check "backup run: a realpath that hangs outside the FUSE mounts is cut off (timeout 5), the backup completes" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && resolved_under "$HOME/slow"'

# DEST safe from other local accounts: an existing DEST is yours and not
# group/other-writable, every folder above it root's or yours and not
# group/other-writable unless sticky; run, setup and validate refuse (exit 64;
# run notifies with the fix and records exit=64, before any copy). Another
# uid as owner needs root to set up: not tested here.
# refused_run <what>: the last run was refused before any copy.
refused_run() {
  rc_is 64 && no_rclone && [[ $OUT == *"$1"* && $(notify_arg 5) == *"$1"* ]] &&
    grep -qx exit=64 "$HOME/.local/state/rclone-backup/archive-vaults.state"
}
for m in 775 757 777; do
  fresh
  job archive-vaults
  DEST=$HOME/Backups/vaults
  mkdir -p "$DEST"
  chmod "$m" "$DEST"
  for sub in setup validate; do
    runc "$BACKUP" "$sub" archive-vaults
    check "backup $sub: an existing DEST of mode $m is refused (exit 64, no drop-in), naming the fix" \
      eval 'rc_is 64 && no_rclone && [[ $OUT == *"DEST $DEST is writable by other accounts (mode 0$m); run chmod go-w $DEST or choose a private folder"* && ! -e $HOME/.config/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
  done
  runc "$BACKUP" run archive-vaults
  check "backup run: an existing DEST of mode $m is refused before any copy (exit 64, notified with the fix, state exit=64)" \
    eval 'refused_run "run chmod go-w $DEST or choose a private folder" && [[ -z $(ls -A "$DEST") ]]'
done

# A symlink planted in a shared DEST at a name a run would write (the legacy
# .part, the copy itself), pointing at a private file outside DEST: refused
# before any copy, so never written through.
fresh
job archive-vaults
DEST=$HOME/Backups/vaults
mkdir -p "$DEST" "$T/private"
chmod 777 "$DEST"
chmod 700 "$T/private"
echo secret >"$T/private/keep"
chmod 600 "$T/private/keep"
J=archive-vaults@Admin__Segurança__Team
ln -s "$T/private/keep" "$DEST/$J.$TODAY.kdbx.part"
ln -s "$T/private/keep" "$DEST/$J.$TODAY.kdbx"
runc "$BACKUP" run archive-vaults
check "backup run: symlinks planted in a shared DEST at the predicted names: refused, the private file outside untouched" \
  eval 'refused_run "chmod go-w" && [[ $(cat "$T/private/keep") == secret && $(stat -c %a "$T/private/keep") == 600 ]]'

# Stale symlinks in a DEST of your own (700, left over), at the copy name,
# the legacy .part and the temporary name the stand-in rclone (like rclone)
# writes next to its target: rclone's target is in the staging folder, so
# none is written through; the copy replaces the link at its name, the legacy
# .part link is removed, the temporary-name link left alone.
chmod 700 "$DEST"
ln -s "$T/private/keep" "$DEST/$J.$TODAY.kdbx.a1b2c3d4.partial"
runc "$BACKUP" run archive-vaults
check "backup run: in a private DEST, stale symlinks at the copy, .part and rclone temporary names are never written through" \
  eval 'rc_is 0 && [[ $(cat "$T/private/keep") == secret && $(stat -c %a "$T/private/keep") == 600 && -f $DEST/$J.$TODAY.kdbx && ! -L $DEST/$J.$TODAY.kdbx && ! -e $DEST/$J.$TODAY.kdbx.part && ! -L $DEST/$J.$TODAY.kdbx.part && -L $DEST/$J.$TODAY.kdbx.a1b2c3d4.partial ]] && no_stage "$DEST"'

# A folder above DEST that others can write without the sticky bit could
# have DEST swapped for a symlink: refused, DEST existing or not. Sticky
# (/tmp's 1777) is fine.
for state in existing missing; do
  fresh
  job archive-vaults
  mkdir -p "$T/shared"
  chmod 777 "$T/shared"
  set_dest archive-vaults "$T/shared/vaults"
  [[ $state == existing ]] && mkdir -m 700 "$T/shared/vaults"
  for sub in setup validate; do
    runc "$BACKUP" "$sub" archive-vaults
    check "backup $sub: DEST ($state) under a 0777 non-sticky folder is refused (exit 64), naming the folder and the fix" \
      eval 'rc_is 64 && [[ $OUT == *"the folder $T/shared above it is writable by other accounts without the sticky bit (mode 0777)"*"run chmod go-w $T/shared or choose another folder"* ]]'
  done
  runc "$BACKUP" run archive-vaults
  check "backup run: DEST ($state) under a 0777 non-sticky folder is refused before any copy, nothing created" \
    eval 'refused_run "chmod go-w $T/shared" && [[ $state == existing || ! -e $T/shared/vaults ]]'
done
for state in existing missing; do
  fresh
  job archive-vaults
  mkdir -p "$T/shared"
  chmod 1777 "$T/shared"
  set_dest archive-vaults "$T/shared/vaults"
  [[ $state == existing ]] && mkdir -m 700 "$T/shared/vaults"
  runc "$BACKUP" validate archive-vaults
  check "backup validate: DEST ($state) under a sticky 1777 folder is accepted" eval 'rc_is 0 && [[ -z $OUT ]]'
  runc "$BACKUP" run archive-vaults
  check "backup run: DEST ($state) under a sticky 1777 folder backs up (exit 0), DEST 700" \
    eval 'rc_is 0 && [[ $(stat -c %a "$T/shared/vaults") == 700 && -f $T/shared/vaults/$(live_name "${LIST_SHAPES[0]}") ]]'
done

# A DEST that is a file is refused, as is a DEST under a file.
fresh
job archive-vaults
mkdir -p "$HOME/Backups"
echo x >"$HOME/Backups/vaults"
runc "$BACKUP" validate archive-vaults
check "backup validate: a DEST that is a file is refused (exit 64)" eval 'rc_is 64 && [[ $OUT == *"$HOME/Backups/vaults is not a folder"* ]]'
runc "$BACKUP" run archive-vaults
check "backup run: a DEST that is a file is refused before any copy" eval 'refused_run "is not a folder"'

# DEST given as a symlink to a private folder: accepted, judged and written
# resolved (the copies, the staging folder, rclone's target).
fresh
job archive-vaults
mkdir -p "$HOME/Backups" "$T/real"
chmod 700 "$T/real"
ln -s "$T/real" "$HOME/Backups/vaults"
runc "$BACKUP" validate archive-vaults
check "backup validate: a DEST symlinked to a private folder is accepted" eval 'rc_is 0 && [[ -z $OUT ]]'
runc "$BACKUP" run archive-vaults
check "backup run: a DEST symlinked to a private folder: the copies land in the resolved folder, rclone given the resolved path" \
  eval 'rc_is 0 && [[ $(find "$T/real" -name "*.$TODAY.kdbx" | wc -l) == 5 ]] && ! grep -qF "$HOME/Backups/vaults" "$FAKE_LOG/rclone" && grep -qF " $T/real/.rclone-backup@archive-vaults@" "$FAKE_LOG/rclone" && no_stage "$T/real"'
fresh
job archive-vaults
mkdir -p "$HOME/Backups" "$T/real"
chmod 775 "$T/real"
ln -s "$T/real" "$HOME/Backups/vaults"
runc "$BACKUP" run archive-vaults
check "backup run: a DEST symlinked to a group-writable folder is refused, naming where it resolves" \
  eval 'refused_run "DEST $HOME/Backups/vaults (resolves to $T/real) is writable by other accounts (mode 0775); run chmod go-w $T/real"'

# A DEST missing at the first check that another account makes before the
# run creates it (while the lock waits; a sticky folder above it, as /tmp,
# lets them): judged again, refused before any copy, nothing written into it.
for how in folder symlink; do
  fresh
  job archive-vaults
  mkdir -p "$T/shared"
  chmod 1777 "$T/shared"
  set_dest archive-vaults "$T/shared/vaults"
  if [[ $how == folder ]]; then
    PATH="$FLOCKSTUB:$PATH" FAKE_FLOCK_DEST=$T/shared/vaults runc "$BACKUP" run archive-vaults
    theirs=$T/shared/vaults
  else
    PATH="$FLOCKSTUB:$PATH" FAKE_FLOCK_DEST=$T/shared/vaults FAKE_FLOCK_LINK=$T/shared/theirs runc "$BACKUP" run archive-vaults
    theirs=$T/shared/theirs
  fi
  check "backup run: a missing DEST made a 0777 $how by another account before the run creates it: refused (exit 64, state exit=64), nothing written into it" \
    eval 'refused_run "is writable by other accounts (mode 0777)" && [[ -d $theirs && $(stat -c %a "$theirs") == 777 && -z $(ls -A "$theirs") ]]'
done

# A stat that hangs (or fails other than "no such file") on a missing DEST is
# a refusal, never a fall-through to an untimed existence test.
fresh
job archive-vaults
set_dest archive-vaults "~/Backups/vaults"
PATH="$STATSTUB:$PATH" FAKE_STAT_HANG=$HOME/Backups/vaults runc timeout 20 "$BACKUP" validate archive-vaults
check "backup validate: a stat that hangs on a missing DEST is cut off (timeout 5) and refused (exit 64)" \
  eval 'rc_is 64 && [[ $OUT == *"cannot check $HOME/Backups/vaults (stat failed or did not answer within 5 s)"* ]]'
PATH="$STATSTUB:$PATH" FAKE_STAT_EACCES=$HOME/Backups/vaults runc "$BACKUP" run archive-vaults
check "backup run: a stat failing with EACCES on a missing DEST is refused before any copy, nothing created" \
  eval 'refused_run "cannot check $HOME/Backups/vaults" && [[ ! -e $HOME/Backups/vaults ]]'

# A private existing DEST works; a missing one is created 700, the missing
# folders above it too.
fresh
job archive-vaults
mkdir -p "$HOME/Backups/vaults"; chmod 700 "$HOME/Backups/vaults"
runc "$BACKUP" run archive-vaults
check "backup run: an existing 700 DEST backs up (exit 0), stays 700" \
  eval 'rc_is 0 && [[ $(stat -c %a "$HOME/Backups/vaults") == 700 && $(find "$HOME/Backups/vaults" -name "*.$TODAY.kdbx" | wc -l) == 5 ]] && no_stage "$HOME/Backups/vaults"'
fresh
job archive-vaults
set_dest archive-vaults "~/a/b/vaults"
runc "$BACKUP" run archive-vaults
check "backup run: a missing DEST and the missing folders above it are created 700" \
  eval 'rc_is 0 && [[ $(stat -c %a "$HOME/a") == 700 && $(stat -c %a "$HOME/a/b") == 700 && $(stat -c %a "$HOME/a/b/vaults") == 700 && $(find "$HOME/a/b/vaults" -name "*.$TODAY.kdbx" | wc -l) == 5 ]]'

# Leftovers of an interrupted run: this job's staging folders go, another
# job's stay (job a never matches job a.b: a job name has no @), and the
# legacy (<= 0.3.6) .part is still removed.
fresh
job a
job a.b
DEST=$HOME/Backups/vaults
mkdir -p "$DEST"; chmod 700 "$DEST"
mkdir "$DEST/.rclone-backup@a@Ab12Cd" "$DEST/.rclone-backup@a.b@Ab12Cd"
echo partial >"$DEST/.rclone-backup@a@Ab12Cd/a@Admin__Segurança__Team.2026-11-13.kdbx"
echo partial >"$DEST/.rclone-backup@a.b@Ab12Cd/a.b@Admin__Segurança__Team.2026-11-13.kdbx"
echo stale >"$DEST/a@Admin__Segurança__Team.2026-11-13.kdbx.part"
runc "$BACKUP" run a
check "backup run: an interrupted run's staging folder of this job is removed, another job's (a.b) untouched, the legacy .part removed" \
  eval 'rc_is 0 && [[ ! -e $DEST/.rclone-backup@a@Ab12Cd && -f $DEST/.rclone-backup@a.b@Ab12Cd/a.b@Admin__Segurança__Team.2026-11-13.kdbx && ! -e $DEST/a@Admin__Segurança__Team.2026-11-13.kdbx.part ]] && [[ $(find "$DEST" -maxdepth 1 -name ".rclone-backup@*") == "$DEST/.rclone-backup@a.b@Ab12Cd" ]]'

# A CRLF conf is invalid.
fresh
job j
sed -i 's/$/\r/' "$HOME/.config/rclone-backup/j.conf"
runc "$BACKUP" validate j
check "backup: a CRLF conf is invalid (exit 64)" eval 'rc_is 64 && [[ $OUT == *"not a KEY=VALUE line"* ]] && no_rclone'

# --- 5. the drop-ins against the templates, through the real systemd --------------------
SYSTEMD_BIN=/usr/lib/systemd/systemd
if [[ -x $SYSTEMD_BIN ]] && command -v systemd-analyze >/dev/null; then
  U=$SCRATCH/units
  mkdir -p "$U"
  for f in "$PLUGIN_DIR"/systemd/*; do ln -s "$f" "$U/"; done # symlinked, as install.sh does
  cp -r "$SETUP_UD/rclone-bisync@vault-A.path.d" "$SETUP_UD/rclone-bisync@vault-A.timer.d" "$BK_UD/rclone-backup@archive-vaults.timer.d" "$U/"
  # dump <unit>: the effective settings of one unit as systemd loads it.
  dump() {
    SYSTEMD_UNIT_PATH=$U: timeout 20 "$SYSTEMD_BIN" --test --user --unit="$1" --no-pager 2>/dev/null |
      awk -v u="→ Unit $1:" '$0 ~ /→ Unit / { p = (index($0, u) > 0) } p'
  }
  D=$(dump rclone-bisync@vault-A.path)
  check "systemd: the path instance takes PathChanged= from the drop-in next to a symlinked template" \
    eval 'grep -qF "PathChanged: $SETUP_HOME/My Vault%d" <<<"$D" && grep -q "DropIn Path: .*rclone-bisync@vault-A.path.d/10-local.conf" <<<"$D"'
  D=$(dump rclone-bisync@vault-A.timer)
  check "systemd: the timer instance has OnStartupSec 1min and only OnUnitInactiveSec 5min" \
    eval 'grep -q "OnStartupSec: 1min" <<<"$D" && grep -q "OnUnitInactiveSec: 5min" <<<"$D" && ! grep -q "OnUnitInactiveSec: 2min" <<<"$D"'
  D=$(dump rclone-backup@archive-vaults.timer)
  check "systemd: the backup timer instance has only the job's OnCalendar" \
    eval 'grep -q "OnCalendar: .*03:30" <<<"$D" && ! grep -q "OnCalendar: daily" <<<"$D" && grep -q "Persistent: yes" <<<"$D"'
  runc env SYSTEMD_UNIT_PATH="$U:" systemd-analyze --user verify rclone-bisync@nopair.path
  check "systemd: a path instance without setup is refused (lacks path setting)" eval '[[ $OUT == *"lacks path setting"* ]]'
  D=$(dump rclone-bisync@vault-A.path)
  check "systemd: the path unit's trigger limit is out of reach of editor saves (200 in 2s)" \
    eval 'grep -q "TriggerLimitIntervalSec: 2s" <<<"$D" && grep -q "TriggerLimitBurst: 200" <<<"$D"'
  for u in rclone-bisync@vault-A.service rclone-backup@archive-vaults.service; do
    D=$(dump "$u")
    check "systemd: $u has a start timeout (1h), so a hung run frees its lock" eval 'grep -q "TimeoutStartSec: 1h" <<<"$D"'
  done
  D=$(dump rclone-mount@onedrive.service)
  check "systemd: the mount restarts on failure every 15s and has a 2min start timeout" \
    eval 'grep -q "Restart: on-failure" <<<"$D" && grep -q "RestartSec: 15s" <<<"$D" && grep -q "TimeoutStartSec: 2min" <<<"$D"'
  check "systemd: mount defaults are Environment=, no VFS tunable on the command line" \
    eval 'grep -q "RCLONE_VFS_CACHE_MAX_SIZE=10G" <<<"$D" && ! grep -qE -- "--(vfs-cache-max-size|vfs-cache-max-age|vfs-write-back|dir-cache-time|poll-interval)" "$PLUGIN_DIR/systemd/rclone-mount@.service"'
else
  echo "skip systemd checks (no $SYSTEMD_BIN or systemd-analyze)"
fi

# Textual (systemd --test does not print start limits): no start limit on
# the bisync service (its failure would stop the path unit) nor on the mount
# (it retries until the network is up); no network-online.target, which the
# user manager does not have.
check "units: rclone-bisync@.service has StartLimitIntervalSec=0" \
  grep -qx 'StartLimitIntervalSec=0' "$PLUGIN_DIR/systemd/rclone-bisync@.service"
check "units: rclone-bisync@.service gives bisync 2min to stop (30s drain + 60s cleanup)" \
  grep -qx 'TimeoutStopSec=2min' "$PLUGIN_DIR/systemd/rclone-bisync@.service"
check "units: rclone-mount@.service has StartLimitIntervalSec=0" \
  grep -qx 'StartLimitIntervalSec=0' "$PLUGIN_DIR/systemd/rclone-mount@.service"
check "units: no StartLimitBurst left in any unit" eval '! grep -q "^StartLimitBurst=" "$PLUGIN_DIR"/systemd/*'
check "units: no network-online.target (a no-op in the user manager)" eval '! grep -q "^[^#]*network-online" "$PLUGIN_DIR"/systemd/*'

# --- 6. rclone-mount: the mount unit's guard ------------------------------------------
# The unit runs `rclone-mount check %i ${OMARCHY_CLOUD_ROOT} %h` (ExecCondition)
# and `rclone-mount start %i ${OMARCHY_CLOUD_ROOT} %h -- <rclone mount ...>`
# (ExecStart); here the command is a stand-in that records its PID, its HOME
# and its argv. The scratch home MH ends in /home/tester, so a roots.tsv case
# under /home/tester keeps its meaning once that prefix is mapped to MH.
MOUNTED=$SCRATCH/mounted
cat >"$MOUNTED" <<'STUB'
#!/bin/bash
printf '%s\n' "$$" "$HOME" "$@" >"$FAKE_LOG/mounted"
STUB
chmod +x "$MOUNTED"
mfresh() {
  fresh
  MH=$T/m/home/tester
  MENV=$MH/.config/omarchy-cloud/cloud.env
  MR=$T/m/srv/cloud
  mkdir -p "${MENV%/*}" "$MR" "$T/cwd"
}
menv() { printf '%s\n' "$@" >"$MENV"; } # menv <line...>: cloud.env, raw
# mstart <remote> <systemd root> [home]: start, from a scratch cwd (a
# relative root wrongly accepted would land there).
mstart() {
  rm -f "$FAKE_LOG/mounted"
  OUT=$(cd "$T/cwd" && "$MOUNT" start "$1" "$2" "${3-$MH}" -- "$MOUNTED" mount "$1:" "$2/$1" 2>&1)
  RC=$?
}
mcheck() { OUT=$(cd "$T/cwd" && "$MOUNT" check "$1" "$2" "${3-$MH}" 2>&1); RC=$?; }
mounted() { [[ -s $FAKE_LOG/mounted ]]; }
one_line() { [[ -n $OUT && $OUT != *$'\n'* ]]; }
# refused [reason]: exit 78, one line naming the remote, the reason and the
# fix, the command never run.
refused() {
  rc_is 78 && one_line && [[ $OUT == "rclone-mount: "*": refusing to mount: "*"${1:-}"*". Fix: "* ]] && ! mounted
}
NOT_VALID="is not valid: it must be an absolute path outside your home"
DIFFERS="the unit was given the mount root"
# map_home <path>: /home/tester... -> MH...
map_home() { if [[ $1 == /home/tester* ]]; then printf '%s' "$MH${1#/home/tester}"; else printf '%s' "$1"; fi; }

# The verdict for every line, without writing anything: systemd's value is a
# sentinel no case holds, so a valid setting is refused as "systemd read it
# differently" and an invalid one as "not valid".
mfresh
mv_n=0 mv_bad=()
while IFS= read -r line; do
  kind=${line%%$'\t'*} path=$(map_home "${line#*$'\t'}")
  [[ $kind == valid || $kind == invalid ]] || continue
  mv_n=$((mv_n + 1))
  menv "OMARCHY_CLOUD_ROOT=$path"
  mstart od /nonexistent/sentinel
  if [[ $kind == valid ]]; then refused "$DIFFERS" || mv_bad+=("valid $(printf %q "${path:0:40}")")
  else refused "$NOT_VALID" || mv_bad+=("invalid $(printf %q "${path:0:40}")"); fi
done < <(roots_cases)
check "roots.tsv: rclone-mount refuses every invalid setting as invalid and judges every valid one ($mv_n cases${mv_bad:+; wrong: ${mv_bad[*]}})" \
  eval '((mv_n >= 30 && ${#mv_bad[@]} == 0))'

# End to end, systemd agreeing with the file: every absolute case moved
# under the scratch dir ($T/m<path>; /home/tester is then MH) and created
# there, so a valid one is mounted (its <root>/od made, the command run) and
# an invalid one refused with nothing made, even though the directory
# exists. Skipped: a valid case that the move makes longer than 255 bytes.
# The relative cases run as they are, from the scratch cwd.
mfresh
me_n=0 me_bad=()
while IFS= read -r line; do
  kind=${line%%$'\t'*} path=${line#*$'\t'}
  [[ $kind == valid || $kind == invalid ]] || continue
  if [[ $path == /* ]]; then
    path=$T/m$path
    if [[ $kind == valid ]] && (($(LC_ALL=C; echo "${#path}") > 255)); then continue; fi
    mkdir -p -- "$path" 2>/dev/null
  fi
  me_n=$((me_n + 1))
  menv "OMARCHY_CLOUD_ROOT=$path"
  before=$(find "$T/m" "$T/cwd" | LC_ALL=C sort)
  mstart od "$path"
  if [[ $kind == valid ]]; then
    { rc_is 0 && [[ -z $OUT && -d $path/od ]] && mounted; } || me_bad+=("valid $(printf %q "${path#"$T"}") rc=$RC")
  else
    { refused && [[ $(find "$T/m" "$T/cwd" | LC_ALL=C sort) == "$before" ]]; } || me_bad+=("invalid $(printf %q "${path#"$T"}") rc=$RC")
  fi
done < <(roots_cases)
check "roots.tsv: rclone-mount start, end to end: valid mounted, invalid exit 78 with nothing created ($me_n cases${me_bad:+; wrong: ${me_bad[*]}})" \
  eval '((me_n >= 30 && ${#me_bad[@]} == 0))'

# A valid setting systemd reads the same: mounted, exactly the command given
# (argv intact, through exec: the same PID), with the environment's HOME (not %h).
mfresh
menv "# set by install.sh" "OMARCHY_CLOUD_ROOT=$MR"
rm -f "$FAKE_LOG/mounted"
(cd "$T/cwd" && exec "$MOUNT" start od "$MR" "$MH" -- "$MOUNTED" mount od: "$MR/od" "a b" "") >"$T/out" 2>&1 &
mpid=$!
wait "$mpid"
RC=$?
mapfile -t ml <"$FAKE_LOG/mounted"
check "rclone-mount start: a valid, agreeing root: exit 0, <root>/od made, the command exec'd (same PID) with its argv as given and the environment's HOME" \
  eval 'rc_is 0 && [[ ! -s $T/out && -d $MR/od && ${ml[0]} == "$mpid" && ${ml[1]} == "$HOME" && ${#ml[@]} == 7 && ${ml[2]} == mount && ${ml[3]} == od: && ${ml[4]} == "$MR/od" && ${ml[5]} == "a b" && ${ml[6]} == "" ]]'
mstart od "$MR"
check "rclone-mount start: <root>/od already there: mounted again (exit 0)" eval 'rc_is 0 && mounted'
mcheck od "$MR"
check "rclone-mount check: a valid, agreeing, usable root: exit 0, silent" eval 'rc_is 0 && [[ -z $OUT ]]'
# The default: no cloud.env, or no OMARCHY_CLOUD_ROOT= line, is /mnt/cloud;
# systemd's value must be that too (only judged here: check never writes).
rm -f "$MENV"
mstart od "$MR"
check "rclone-mount: no cloud.env means /mnt/cloud; another systemd value is refused, blamed on another file (od.env), not on a cloud.env parse" \
  eval 'refused "$DIFFERS" && [[ $OUT == *"the other readers use the built-in default /mnt/cloud (there is no "*"); systemd got it from another file the unit reads or a drop-in (an OMARCHY_CLOUD_ROOT= line in ~/.config/rclone-mount/od.env, or an Environment=OMARCHY_CLOUD_ROOT= line in rclone-mount@.service.d/*.conf or rclone-mount@od.service.d/*.conf under ~/.config/systemd/user/, /etc/systemd/user/ or ~/.config/systemd/user.control/ (systemctl set-property): remove it)"* && $OUT != *"its own way"* ]]'
menv "# only a comment" "OMARCHY_CLOUD_ROOT_X=$MR"
mstart od "$MR"
check "rclone-mount: a cloud.env without the line means /mnt/cloud too; either cause named" \
  eval 'refused "$DIFFERS" && [[ $OUT == *"the other readers use the built-in default /mnt/cloud ("*"has no OMARCHY_CLOUD_ROOT= line they see); systemd got it either from that file read its own way"*"or from another file the unit reads"*"rclone-mount/od.env"* ]]'

# systemd's own parse differs from the raw one: refused, never mounted at
# the root systemd made of it.
mfresh
menv "OMARCHY_CLOUD_ROOT=\"$MR\""
mstart od "$MR"
check "rclone-mount: a quoted value (systemd strips the quotes): refused as not valid, exit 78" \
  eval 'refused "$NOT_VALID" && [[ $OUT == *"od: refusing"* && ! -e $MR/od ]]'
menv "  OMARCHY_CLOUD_ROOT=$MR"
mstart od "$MR"
check "rclone-mount: an indented line (the readers skip it, systemd takes it): refused, says systemd read it differently" \
  eval 'refused "$DIFFERS" && [[ $OUT == *"has no OMARCHY_CLOUD_ROOT= line"* && ! -e $MR/od ]]'
menv "OMARCHY_CLOUD_ROOT=$MR "
mstart od "$MR"
check "rclone-mount: trailing whitespace (systemd trims it): refused" eval 'refused "$NOT_VALID" && [[ ! -e $MR/od ]]'
menv "OMARCHY_CLOUD_ROOT=/mnt/caf"$'\xe9'
mstart od /mnt/cloud
check "rclone-mount: a value that is not UTF-8 (systemd skips the line, its default wins): refused, the bytes shown escaped" \
  eval 'refused "$NOT_VALID" && [[ $OUT == *"\$'"'"'/mnt/caf\\351'"'"'"* && $OUT != *$'"'"'\xe9'"'"'* ]]'
menv "#$(printf 'x%.0s' {1..4100})" "OMARCHY_CLOUD_ROOT=$MR"
mstart od "$MR"
check "rclone-mount: a line past 4096 bytes is not read (systemd reads it): refused" eval 'refused "$DIFFERS" && [[ ! -e $MR/od ]]'
menv "OMARCHY_CLOUD_ROOT=$T/m/old" "OMARCHY_CLOUD_ROOT=$MR"$'\r'
mstart od "$MR"
check "rclone-mount: the last line wins, one trailing \\r dropped" eval 'rc_is 0 && mounted'
menv "OMARCHY_CLOUD_ROOT=$MR"
mstart od "$MR/"
check "rclone-mount: systemd's value differs by a trailing / only: refused, naming the line's value and both causes" \
  eval 'refused "$DIFFERS" && [[ $OUT == *"$DIFFERS $MR/, but the OMARCHY_CLOUD_ROOT= line of "*" says $MR; systemd got it either from that file read its own way"*"or from another file the unit reads"* ]]'
# A NUL in the value: invalid (bash would drop it and mount at the existing
# $T/m/srv/ab, the root systemd may well pass).
mkdir -p "$T/m/srv/ab"
printf 'OMARCHY_CLOUD_ROOT=%s/m/srv/a\0b\n' "$T" >"$MENV"
mstart od "$T/m/srv/ab"
check "rclone-mount start: a cloud.env value with a NUL byte is refused as not valid (exit 78), nothing created" \
  eval 'refused "$NOT_VALID" && [[ ! -e $T/m/srv/ab/od ]]'
mcheck od /nonexistent/sentinel
check "rclone-mount check: a refused root goes on (exit 0, silent), so that start fails loudly" eval 'rc_is 0 && [[ -z $OUT ]]'
mkfifo "$T/fifo"
ln -sf "$T/fifo" "$MENV"
OUT=$(cd "$T/cwd" && timeout 20 "$MOUNT" start od "$MR" "$MH" -- "$MOUNTED" 2>&1)
RC=$?
check "rclone-mount: a FIFO cloud.env is never read (no hang): refused" eval 'refused "not a readable regular file"'
rm -f "$MENV"
menv "OMARCHY_CLOUD_ROOT=$MR"
chmod 000 "$MENV"
if [[ ! -r $MENV ]]; then
  mstart od "$MR"
  check "rclone-mount: an unreadable cloud.env: refused" eval 'refused "not a readable regular file"'
else
  echo "skip rclone-mount: unreadable cloud.env (running as root)"
fi
chmod 600 "$MENV"

# %h with trailing /: every trailing / dropped, so a root inside the home is still
# inside it, even as an existing, writable directory.
mfresh
mkdir -p "$MH/mnt"
menv "OMARCHY_CLOUD_ROOT=$MH/mnt"
mstart od "$MH/mnt" "$MH/"
check "rclone-mount: %h with a trailing /: a root inside the home is refused (exit 78), nothing created" \
  eval 'refused "$NOT_VALID" && [[ ! -e $MH/mnt/od ]]'
menv "OMARCHY_CLOUD_ROOT=$MH"
mstart od "$MH" "$MH/"
check "rclone-mount: %h with a trailing /: the home itself is refused" eval 'refused "$NOT_VALID" && [[ ! -e $MH/od ]]'
mstart od "$MH/mnt" "$MH//"
check "rclone-mount: %h with two trailing /: every / dropped, a root inside the home is refused" \
  eval 'refused "$NOT_VALID" && [[ ! -e $MH/mnt/od ]]'
mstart od /nonexistent/sentinel "$MH///"
check "rclone-mount: %h with trailing /: cloud.env still found under the home" \
  eval 'refused "$NOT_VALID" && [[ $OUT == *"$MH/.config/omarchy-cloud/cloud.env"* && $OUT != *"$MH//"* ]]'
mstart od "$MR" ""
check "rclone-mount: an empty %h is refused" eval 'refused "is not an absolute path"'
# A home of "/" (no cloud.env there: the default) skips the home rule, as
# every reader does; judged against a sentinel, so nothing is written.
mstart od /nonexistent/sentinel /
check "rclone-mount: %h \"/\": the home rule is skipped, the default /mnt/cloud is judged valid" \
  eval 'refused "$DIFFERS" && [[ $OUT == *"default /mnt/cloud"* ]]'
mstart od /nonexistent/sentinel //
check "rclone-mount: %h \"//\" is \"/\": the home rule is skipped, cloud.env looked for at /.config" \
  eval 'refused "$DIFFERS" && [[ $OUT == *"default /mnt/cloud (there is no /.config/omarchy-cloud/cloud.env)"* ]]'

# A valid root that is not usable yet: check skips (exit 1, one line with
# the sudo command), start refuses to create it (exit 1, the root untouched).
mfresh
for how in missing read-only unsearchable; do
  r=$T/m/srv/$how
  case $how in
    read-only) mkdir -p "$r" && chmod 555 "$r" ;;
    unsearchable) mkdir -p "$r" && chmod 600 "$r" ;;
  esac
  menv "OMARCHY_CLOUD_ROOT=$r"
  mcheck od "$r"
  check "rclone-mount check: a valid root that is $how: skip (exit 1), one line naming it and the sudo command" \
    eval 'rc_is 1 && one_line && [[ $OUT == "rclone-mount: od: not started: the mount root $r is not an existing directory you can write to and search; create it once with: sudo install -d -o \"\$USER\" -m 755 '"'"'$r'"'"'"* ]]'
  mstart od "$r"
  check "rclone-mount start: a valid root that is $how: exit 1, not mounted, nothing created" \
    eval 'rc_is 1 && ! mounted && [[ ! -e $r/od ]] && { [[ $how != missing ]] || [[ ! -e $r ]]; }'
  [[ -d $r ]] && chmod 755 "$r"
done

# <root>/<remote> cannot be made (a regular file, a dangling link in the
# way): exit 78 (not restarted), one line, nothing run.
mfresh
menv "OMARCHY_CLOUD_ROOT=$MR"
: >"$MR/od"
mstart od "$MR"
check "rclone-mount start: <root>/od is a regular file: exit 78, one line naming it and why, not mounted" \
  eval 'refused "cannot create the mount point $MR/od (File exists)" && [[ $OUT == *"Fix: remove or rename what is at $MR/od"* && -f $MR/od ]]'
rm -f "$MR/od"
# A symlink where the mount point goes (rclone would mount where it points):
# refused, exit 78, whether it points to a folder outside the home, one
# inside it, or nowhere; the link and its target left as they are.
mkdir -p "$T/m/srv/elsewhere" "$MH/Inside"
for tg in "$T/m/srv/elsewhere" "$MH/Inside" "$T/nowhere"; do
  ln -s "$tg" "$MR/od"
  mstart od "$MR"
  check "rclone-mount start: <root>/od is a symlink to \$T/${tg#"$T"/}: exit 78, one line, not mounted, the link and its target untouched" \
    eval 'refused "the mount point $MR/od is a symbolic link (to $tg)" && [[ $OUT == *"Fix: remove the link (rm $MR/od"* && -L $MR/od && ! -e $tg/od && $(find "$T/m/srv/elsewhere" "$MH/Inside" -mindepth 1 | wc -l) == 0 ]]'
  rm -f "$MR/od"
done
check "rclone-mount start: a dangling link's target is not created" eval '[[ ! -e $T/nowhere ]]'

# Transient failures exit 75 (EX_TEMPFAIL: Restart=on-failure retries),
# never 78, with one line; nothing is run. Stand-ins first on PATH:
# FUSESTUB's stat reports ENOTCONN ("Transport endpoint is not connected")
# for the path in $FAKE_LOG/stale (a stale FUSE mount: rclone died without
# unmounting; a regular file stands in for the dead mount, in the way of
# mkdir as the real one is) and hangs on $FAKE_STAT_HANG; its fusermount3
# records its argv and, unless FAKE_FUSER_FAIL or FAKE_FUSER_NOOP, unmounts
# (the stand-in file goes, the folder beneath it shows). MKSTUB's mkdir
# fails with ENOSPC. NOFUSER: the tools rclone-mount runs, no fusermount3.
FUSESTUB=$SCRATCH/fusestub MKSTUB=$SCRATCH/mkstub NOFUSER=$SCRATCH/nofuser
mkdir -p "$FUSESTUB" "$MKSTUB" "$NOFUSER"
cat >"$FUSESTUB/stat" <<'STUB'
#!/bin/bash
p=${*: -1}
[[ -n ${FAKE_STAT_HANG:-} && $p == "$FAKE_STAT_HANG" ]] && exec sleep 30
if [[ -f $FAKE_LOG/stale && $p == "$(<"$FAKE_LOG/stale")" ]]; then
  echo "stat: cannot statx '$p': Transport endpoint is not connected" >&2
  exit 1
fi
exec /usr/bin/stat "$@"
STUB
cat >"$FUSESTUB/fusermount3" <<'STUB'
#!/bin/bash
{ printf 'fusermount3'; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/fusermount3"
if [[ -n ${FAKE_FUSER_FAIL:-} ]]; then
  echo "fusermount3: failed to unmount ${*: -1}: Device or resource busy" >&2
  exit 1
fi
if [[ -z ${FAKE_FUSER_NOOP:-} && -f $FAKE_LOG/stale ]]; then
  p=$(<"$FAKE_LOG/stale")
  rm -f "$FAKE_LOG/stale" "$p" && mkdir "$p"
fi
exit 0
STUB
cat >"$MKSTUB/mkdir" <<'STUB'
#!/bin/bash
echo "mkdir: cannot create directory '${*: -1}': No space left on device" >&2
exit 1
STUB
for tool in bash timeout realpath mkdir head tr readlink sleep rm; do ln -sf "$(command -v "$tool")" "$NOFUSER/$tool"; done
cp "$FUSESTUB/stat" "$NOFUSER/stat"
chmod +x "$FUSESTUB/stat" "$FUSESTUB/fusermount3" "$MKSTUB/mkdir" "$NOFUSER/stat"
# stale: <root>/od a stale mount (as the stand-ins see it).
stale() { : >"$MR/od" && printf '%s' "$MR/od" >"$FAKE_LOG/stale"; }
fuser_log() { cat "$FAKE_LOG/fusermount3" 2>/dev/null; }
# retried [text]: exit 75, one line (with text), the command never run.
retried() {
  rc_is 75 && one_line && [[ $OUT == "rclone-mount: od: cannot mount yet, will retry: "*"${1:-}"* ]] && ! mounted
}
mfresh
menv "OMARCHY_CLOUD_ROOT=$MR"
stale
PATH="$FUSESTUB:$PATH" mstart od "$MR"
check "rclone-mount start: a stale FUSE mount at <root>/od is cleared (fusermount3 -uz -- <root>/od), then mounted (exit 0, the command run)" \
  eval 'rc_is 0 && [[ -z $OUT && -d $MR/od ]] && mounted && [[ $(fuser_log) == "fusermount3 -uz -- $MR/od" ]]'
mfresh
menv "OMARCHY_CLOUD_ROOT=$MR"
stale
FAKE_FUSER_FAIL=1 PATH="$FUSESTUB:$PATH" mstart od "$MR"
check "rclone-mount start: a stale mount fusermount3 cannot clear: exit 75 (retried), one line with the hint fusermount3 -uz <path>" \
  eval 'retried "the mount point $MR/od is a stale FUSE mount (Transport endpoint is not connected" && [[ $OUT == *"(Device or resource busy). Fix: run fusermount3 -uz $MR/od." ]]'
FAKE_FUSER_NOOP=1 PATH="$FUSESTUB:$PATH" mstart od "$MR"
check "rclone-mount start: a stale mount still there after fusermount3 -uz: exit 75, the hint" \
  eval 'retried "still there after fusermount3 -uz" && [[ $OUT == *"Fix: run fusermount3 -uz $MR/od." ]]'
PATH=$NOFUSER mstart od "$MR"
check "rclone-mount start: a stale mount and no fusermount3: exit 75, says so, the hint" \
  eval 'retried "could not clear it (fusermount3 is not installed). Fix: run fusermount3 -uz $MR/od."'
rm -f "$FAKE_LOG/stale" "$MR/od"
FAKE_STAT_HANG=$MR/od PATH="$FUSESTUB:$PATH" mstart od "$MR"
check "rclone-mount start: a mount point that does not answer (stat hung, cut off after 5 s): exit 75, the hint" \
  eval 'retried "the mount point $MR/od did not answer within 5 s (a hung mount). Fix: run fusermount3 -uz $MR/od."'
PATH="$MKSTUB:$PATH" mstart od "$MR"
check "rclone-mount start: mkdir of <root>/od failing with nothing in the way (ENOSPC): exit 75, not 78" \
  eval 'retried "cannot create the mount point $MR/od (No space left on device)"'
PATH="$RPFAIL:$PATH" mstart od "$MR"
check "rclone-mount start: the root cannot be resolved (realpath failing): exit 75, nothing made" \
  eval 'retried "the mount root $MR could not be resolved" && [[ ! -e $MR/od ]]'
FAKE_HUNG=$MR PATH="$RPSTUB:$PATH" mstart od "$MR"
check "rclone-mount start: realpath of the root hung (cut off after 5 s): exit 75" \
  eval 'retried "the mount root $MR could not be resolved" && [[ ! -e $MR/od ]]'
PATH="$RPFAIL:$PATH" mcheck od "$MR"
check "rclone-mount check: the root cannot be resolved: exit 0, silent (start retries)" eval 'rc_is 0 && [[ -z $OUT ]]'

# The root with its symlinks resolved: every case of resolved-roots.tsv end
# to end, systemd agreeing with the file, the tree built under a fresh
# scratch dir (rr_build) with %h = <it>/home and cloud.env under it. A valid
# root is created when missing, so it is mounted; an invalid one: check goes
# on (exit 0, silent), start refuses it (exit 78, one line naming the home
# and why) with nothing created.
mfresh
rm_n=0 rm_bad=()
while IFS=$'\t' read -r kind setup root; do
  rm_n=$((rm_n + 1))
  t=$T/rrm$rm_n
  rr_build "$t" "$setup" || { rm_bad+=("unbuildable $setup"); continue; }
  MH=$t/home r=$t/$root
  mkdir -p "$MH/.config/omarchy-cloud"
  printf 'OMARCHY_CLOUD_ROOT=%s\n' "$r" >"$MH/.config/omarchy-cloud/cloud.env"
  [[ $kind == valid && ! -e $r ]] && mkdir -p "$r"
  before=$(find "$t" | LC_ALL=C sort)
  mcheck od "$r"
  crc=$RC cout=$OUT
  mstart od "$r"
  if [[ $kind == valid ]]; then
    { ((crc == 0)) && [[ -z $cout ]] && rc_is 0 && [[ -z $OUT && -d $r/od ]] && mounted; } || rm_bad+=("valid $setup $root rc=$RC")
  else
    { ((crc == 0)) && [[ -z $cout ]] && refused "at or inside your home " &&
      [[ $OUT == *": programs that crawl the home (file search, indexers, backups) would follow the link into the cloud drive. Fix: point the root at a real folder outside your home: "* &&
        $(find "$t" | LC_ALL=C sort) == "$before" ]]; } || rm_bad+=("invalid $setup $root rc=$RC")
  fi
done < <(rr_cases)
check "resolved-roots.tsv: rclone-mount check and start, end to end: valid mounted, invalid exit 78 with nothing created ($rm_n cases${rm_bad:+; wrong: ${rm_bad[*]}})" \
  eval '((rm_n >= 15 && ${#rm_bad[@]} == 0))'
mfresh

# The remote: every case of names.tsv (valid: mounted; invalid: exit 78, its
# name shown escaped, nothing created).
mfresh
menv "OMARCHY_CLOUD_ROOT=$MR"
mn_bad=() mn_n=0
while IFS=$'\t' read -r kind name; do
  [[ $kind == valid || $kind == invalid ]] || continue
  mn_n=$((mn_n + 1))
  mstart "$name" "$MR"
  if [[ $kind == valid ]]; then
    { rc_is 0 && mounted && [[ -d $MR/$name ]]; } || mn_bad+=("valid '$name'")
  else
    { refused "invalid remote name" && [[ $OUT == *"Fix: rename the remote"* ]]; } || mn_bad+=("invalid '$name'")
  fi
done < <(grep -v '^#' "$NAMES_TSV")
check "names.tsv: rclone-mount mounts every valid remote name and refuses every invalid one ($mn_n${mn_bad:+; wrong: ${mn_bad[*]}})" \
  eval '((mn_n >= 20 && ${#mn_bad[@]} == 0)) && [[ $(find "$MR" -mindepth 1 -maxdepth 1 | wc -l) -le $mn_n ]]'

# Usage: check defers (exit 0), start refuses (78: no restart), an unknown
# mode is 64.
mfresh
runc "$MOUNT" check od "$MR"
check "rclone-mount check, missing an argument: exit 0 (start then refuses)" rc_is 0
runc "$MOUNT" start od "$MR" "$MH" "$MOUNTED"
check "rclone-mount start without --: exit 78, usage, nothing run" eval 'rc_is 78 && [[ $OUT == "usage: "* ]] && ! mounted'
runc "$MOUNT" start od "$MR" "$MH" --
check "rclone-mount start, no command after --: exit 78" rc_is 78
runc "$MOUNT" frobnicate od "$MR" "$MH"
check "rclone-mount, unknown mode: exit 64" rc_is 64

echo
if ((FAILURES)); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
