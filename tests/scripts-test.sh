#!/bin/bash

# The helper scripts (bin/rclone-bisync, bin/rclone-backup), hermetic:
# stand-ins for rclone, systemctl, notify-send and date come first on PATH and record their argv (one line per call, each argument through
# printf %q); HOME and the XDG_* dirs point into a scratch dir, and the mounts
# table the cloud guard reads is a scratch file. The real rclone is never run,
# no unit is touched, nothing outside the scratch dir is written. install.sh
# has its own suite (tests/install-test.sh).
#
#   1. bash -n, and shellcheck when installed.
#   2. Conf parsing: a valid pair, an unknown key, a bad name, a conf that would
#      run code if sourced, a missing LOCAL, INTERVAL (at least 30s, s|min|h|d),
#      a CRLF conf; every line of tests/fixtures/names.tsv through both scripts;
#      backup FILES with .., an absolute path, duplicate copy names, empty.
#   3. rclone-bisync: run passes exactly the safety flags and bisync's exit
#      code; a busy lock: run exits 0, resync and dry-run 75, without rclone;
#      check's three outcomes; resync refuses (exit 3, never --resync) when
#      check differs or fails, and runs when check passes; non-bisync commands
#      take the filter as --filter-from; FILTER= (empty) is no filter; the
#      workdir is pinned; an empty pair is check/resync exit 4;
#      conflicts are listed (even those the filter hides), notified and written
#      to the state file; setup writes the drop-ins (and warns when the filter
#      excludes conflict copies), teardown removes them; validate; the guards
#      (backup DEST, other pairs' LOCAL, cloud locations and FUSE mounts); a
#      hung FUSE mount: the guards never resolve a path in it and a run
#      completes, setup and validate still refuse; a hung realpath elsewhere is
#      cut off after 5 s.
#   4. rclone-backup: the copy names follow the reference naming rule (job@
#      prefix) on representative path shapes; prune keeps the newest KEEP per
#      file and never touches legacy (unprefixed) copies; modes (only a new DEST
#      is made 700); .part handling; a failure (copy or mv) notifies and does
#      not prune; a busy job lock exits 0; only `rclone copyto <remote> <local>`;
#      validate; the guards (pairs' LOCAL, other jobs' DEST, cloud locations),
#      and the same hung-mount cases.
#   5. The generated drop-ins against the repo's templates, through the real
#      systemd (`systemd --test`, `systemd-analyze verify`), read-only.

# The checks are eval'd single-quoted strings, expanded when they run: the
# variables they read look unused to shellcheck, and the quotes are on purpose.
# A quoted ~/ is the conf syntax under test, written into confs unexpanded.
# shellcheck disable=SC2016,SC2034,SC2088

set -o pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BISYNC=$PLUGIN_DIR/bin/rclone-bisync
BACKUP=$PLUGIN_DIR/bin/rclone-backup
NAMES_TSV=$PLUGIN_DIR/tests/fixtures/names.tsv
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
    printf 'copy of %s\n' "$2" >"$3"; exit 0 ;;
  *) exit 99 ;;
esac
EOF
for tool in systemctl notify-send; do
  cat >"$STUBS/$tool" <<'EOF'
#!/bin/bash
{ printf '%s' "${0##*/}"; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_LOG/${0##*/}"
[[ ${0##*/} == notify-send ]] && exit "${FAKE_NOTIFY_RC:-0}"
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
export PATH="$STUBS:$PATH"
TODAY=2026-11-14

# fresh: a new scratch HOME with empty logs; clears the stand-ins' knobs.
N=0
fresh() {
  N=$((N + 1))
  T=$SCRATCH/t$N
  mkdir -p "$T/home/.config" "$T/state" "$T/run" "$T/cache" "$T/log"
  export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_STATE_HOME=$T/state \
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
for f in "$BISYNC" "$BACKUP" "${BASH_SOURCE[0]}"; do
  check "bash -n ${f#"$PLUGIN_DIR"/}" bash -n "$f"
done
for f in "$BISYNC" "$BACKUP"; do
  check "${f#"$PLUGIN_DIR"/} is executable" test -x "$f"
done
SHELLCHECK=$(command -v shellcheck)
if [[ -n $SHELLCHECK ]] && "$SHELLCHECK" --version >/dev/null 2>&1; then
  check "shellcheck" "$SHELLCHECK" "$BISYNC" "$BACKUP" "${BASH_SOURCE[0]}"
else
  echo "skip shellcheck (not installed or not runnable)"
fi

# --- pair fixture -----------------------------------------------------------
# pair <name> [extra conf lines...]: conf with LOCAL and REMOTE, LOCAL created.
pair() {
  local name=$1
  shift
  mkdir -p "$XDG_CONFIG_HOME/rclone-bisync" "$HOME/Vaults"
  {
    echo "# offline folder"
    echo "LOCAL=~/Vaults"
    echo "REMOTE=onedrive:Backup/Vaults"
    printf '%s\n' "$@"
  } >"$XDG_CONFIG_HOME/rclone-bisync/$name.conf"
}
filter() {
  printf '+ /Personal.kdbx\n+ /Personal.kdbx.conflict*\n- **\n' >"$XDG_CONFIG_HOME/rclone-bisync/$1.filter"
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
mkdir -p "$XDG_CONFIG_HOME/rclone-bisync"
printf 'LOCAL=$(touch %s/canary)\nREMOTE=onedrive:x\n' "$T" >"$XDG_CONFIG_HOME/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "conf is parsed, never sourced (no canary, exit 64)" eval 'rc_is 64 && [[ ! -e $T/canary ]]'

fresh
mkdir -p "$XDG_CONFIG_HOME/rclone-bisync"
echo "REMOTE=onedrive:x" >"$XDG_CONFIG_HOME/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "missing LOCAL: exit 64" eval 'rc_is 64 && [[ $OUT == *"LOCAL is required"* ]]'

fresh
pair p
sed -i 's|^LOCAL=.*|LOCAL=Vaults|' "$XDG_CONFIG_HOME/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "relative LOCAL: exit 64" rc_is 64

fresh
pair p
sed -i 's|^LOCAL=.*|LOCAL=~/nope|' "$XDG_CONFIG_HOME/rclone-bisync/p.conf"
runc "$BISYNC" run p
check "LOCAL not an existing directory: exit 64" rc_is 64

fresh
pair p
sed -i 's|^REMOTE=.*|REMOTE=-bad:x|' "$XDG_CONFIG_HOME/rclone-bisync/p.conf"
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
  check "INTERVAL $iv: exit 64, no drop-in" eval 'rc_is 64 && [[ ! -e $XDG_CONFIG_HOME/systemd/user/rclone-bisync@p.timer.d ]]'
done
for iv in 30s 1min 1h 1d 045s; do
  fresh
  pair p "INTERVAL=$iv"
  runc "$BISYNC" setup p
  check "INTERVAL $iv: accepted" \
    eval 'rc_is 0 && grep -qx "OnUnitInactiveSec=$iv" "$XDG_CONFIG_HOME/systemd/user/rclone-bisync@p.timer.d/10-interval.conf"'
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
# scripts: teardown checks only the name (exit 0 valid, 64 invalid), validate
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

# A conf with CRLF line ends is invalid (a \r is a control character).
fresh
pair p
sed -i 's/$/\r/' "$XDG_CONFIG_HOME/rclone-bisync/p.conf"
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
F=$XDG_CONFIG_HOME/rclone-bisync/vault-A.filter
FAKE_BISYNC_RC=7 runc "$BISYNC" run vault-A
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults --filters-file "$F" "${SAFETY[@]}" --workdir "$(WORKDIR)")"
check "run: rclone bisync with exactly the safety flags (default filter)" eval '[[ $(head -1 "$FAKE_LOG/rclone") == "$want" ]]'
check "run: exit code is bisync's (7)" rc_is 7
check "run: bisync's lock expires (--max-lock 2m), so a killed run cannot block later ones" \
  eval 'grep -q "^rclone bisync .* --max-lock 2m" "$FAKE_LOG/rclone"'
check "run: state file exit=7, a unix time" \
  eval 'grep -qx "exit=7" "$XDG_STATE_HOME/rclone-bisync/vault-A.state" && grep -qE "^time=[0-9]{9,}$" "$XDG_STATE_HOME/rclone-bisync/vault-A.state"'
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
flock "$XDG_RUNTIME_DIR/rclone-bisync-vault-A.lock" sleep 10 &
holder=$!
for _ in {1..50}; do flock -n "$XDG_RUNTIME_DIR/rclone-bisync-vault-A.lock" true || break; sleep 0.05; done
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
  eval '[[ $(grep ^conflict= "$XDG_STATE_HOME/rclone-bisync/vault-A.state") == $'"'"'conflict=Personal.kdbx.conflict1\nconflict=sub/notes.conflict2.txt'"'"' ]]'
check "state written atomically (no temp file left)" eval '[[ -z $(find "$XDG_STATE_HOME/rclone-bisync" -name ".*") ]]'
: >"$FAKE_LOG/notify-send"
runc "$BISYNC" run vault-A
check "run with the same conflicts again: no new notification, still logged" \
  eval '[[ ! -s $FAKE_LOG/notify-send && $OUT == *"CONFLICT copies present: Personal.kdbx.conflict1 notes.conflict2.txt"* ]]'
check "run with the same conflicts again: the state file still lists them all" \
  eval '[[ $(grep -c ^conflict= "$XDG_STATE_HOME/rclone-bisync/vault-A.state") == 2 ]]'
FAKE_LSF='Personal.kdbx.conflict1\nsub/notes.conflict2.txt\nWork.kdbx.conflict1\nWork.kdbx.conflict2\n' runc "$BISYNC" run vault-A
want="notify-send$(q -u critical -a rclone-bisync "vault-A: conflict" "$(conflict_note "Work.kdbx.conflict1 Work.kdbx.conflict2")")"
check "run with a new conflict: one notification naming only the new copies" eval '[[ $(log notify-send) == "$want" ]]'
check "run with a new conflict: the state file lists all four" \
  eval '[[ $(grep -c ^conflict= "$XDG_STATE_HOME/rclone-bisync/vault-A.state") == 4 ]]'
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
ST=$XDG_STATE_HOME/rclone-bisync/vault-A.state
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
printf '+ /Personal.kdbx\n- **\n' >"$XDG_CONFIG_HOME/rclone-bisync/vault-A.filter"
export FAKE_LSF_FILTERED='Personal.kdbx\n' FAKE_LSF='Personal.kdbx.conflict1\n'
runc "$BISYNC" run vault-A
check "run: a conflict copy the filter hides is still notified" eval '[[ $(log notify-send) == "notify-send$(q -u critical -a rclone-bisync "vault-A: conflict" "$(conflict_note Personal.kdbx.conflict1)")" ]]'
check "run: a conflict copy the filter hides is in the state file" \
  eval 'grep -qx "conflict=Personal.kdbx.conflict1" "$XDG_STATE_HOME/rclone-bisync/vault-A.state"'
runc "$BISYNC" conflicts vault-A
check "conflicts: lists a copy the filter hides" eval 'rc_is 0 && [[ $OUT == Personal.kdbx.conflict1 ]]'
unset FAKE_LSF_FILTERED FAKE_LSF

fresh
pair vault-A
printf '+ /Personal.kdbx\n- **\n' >"$XDG_CONFIG_HOME/rclone-bisync/vault-A.filter"
touch "$(LOCALDIR)/Personal.kdbx"
FAKE_LSF_FIND=1 FAKE_LSF_DROP='*.conflict*' runc "$BISYNC" setup vault-A
check "setup: warns when the filter excludes an included file's conflict copies" \
  eval 'rc_is 0 && [[ $OUT == *"warning: the filter"*"excludes the conflict copies"*Personal.kdbx* ]]'
check "setup with the warning: drop-ins still written" test -f "$XDG_CONFIG_HOME/systemd/user/rclone-bisync@vault-A.timer.d/10-interval.conf"
check "setup: the probe asks rclone with --filter-from, on a temp dir, not on LOCAL" \
  eval '[[ $(sed -n 2p "$FAKE_LOG/rclone") == "rclone lsf -R --files-only --filter-from "* && $(sed -n 2p "$FAKE_LOG/rclone") != *"$(LOCALDIR)"* ]]'
filter vault-A
FAKE_LSF_FIND=1 runc "$BISYNC" setup vault-A
check "setup: no warning when the filter includes the conflict copies" eval 'rc_is 0 && [[ $OUT != *warning* ]]'

fresh
pair vault-A
filter vault-A
F=$XDG_CONFIG_HOME/rclone-bisync/vault-A.filter
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
F=$XDG_CONFIG_HOME/rclone-bisync/vault-A.filter
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
check "resync writes the state file" test -s "$XDG_STATE_HOME/rclone-bisync/vault-A.state"

fresh
pair vault-A
runc "$BISYNC" dry-run vault-A
want="rclone$(q bisync "$(LOCALDIR)" onedrive:Backup/Vaults "${SAFETY[@]}" --workdir "$(WORKDIR)" --dry-run)"
check "dry-run: bisync --dry-run, no --resync, no state" \
  eval '[[ $(log rclone) == "$want" ]] && [[ ! -e $XDG_STATE_HOME/rclone-bisync/vault-A.state ]]'

fresh
mkdir -p "$HOME/My Vault%d"
pair vault-A "INTERVAL=5min"
sed -i 's|^LOCAL=.*|LOCAL=~/My Vault%d|' "$XDG_CONFIG_HOME/rclone-bisync/vault-A.conf"
runc "$BISYNC" setup vault-A
UD=$XDG_CONFIG_HOME/systemd/user
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
  mkdir -p "$XDG_CONFIG_HOME/rclone-backup"
  printf 'REMOTE=work_drive:\nDEST=%s\n' "$2" >"$XDG_CONFIG_HOME/rclone-backup/$1.conf"
}
for dest in "~/Vaults/backups" "~/Vaults" "~/Vaults/" "~/" "@HOME@/Vaults/a/b"; do
  fresh
  dest=${dest//@HOME@/$HOME}
  pair vault-A
  bk_dest archive-vaults "$dest"
  runc "$BISYNC" setup vault-A
  check "bisync setup: LOCAL overlapping backup DEST $dest is refused (exit 64, no rclone, no drop-in)" \
    eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps DEST"*"archive-vaults"* && $OUT != *continuing* && ! -e $XDG_CONFIG_HOME/systemd/user/rclone-bisync@vault-A.path.d ]]'
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
  eval 'rc_is 4 && [[ $OUT == *REFUSING*"nothing to sync"* ]] && ! grep -q "^rclone bisync" "$FAKE_LOG/rclone" && [[ ! -e $XDG_STATE_HOME/rclone-bisync/vault-A.state ]]'
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
  mkdir -p "$XDG_CONFIG_HOME/rclone-bisync"
  printf 'LOCAL=%s\nREMOTE=gdrive:other\n' "$2" >"$XDG_CONFIG_HOME/rclone-bisync/$1.conf"
}
for other in "~/Vaults" "~/Vaults/sub" "~/" "@HOME@/Vaults/"; do
  fresh
  pair vault-A
  other_pair vault-B "${other//@HOME@/$HOME}"
  for sub in setup validate; do
    runc "$BISYNC" "$sub" vault-A
    check "bisync $sub: LOCAL overlapping the LOCAL $other of another pair is refused (exit 64, no drop-in)" \
      eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps LOCAL"*"offline folder vault-B"* && $OUT != *continuing* && ! -e $XDG_CONFIG_HOME/systemd/user/rclone-bisync@vault-A.path.d ]]'
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
  sed -i "s|^LOCAL=.*|LOCAL=~/$1|" "$XDG_CONFIG_HOME/rclone-bisync/vault-A.conf"
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
sed -i 's|^LOCAL=.*|LOCAL=~/Mnt/hung/x|' "$XDG_CONFIG_HOME/rclone-bisync/vault-A.conf"
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
rm "$XDG_CONFIG_HOME/rclone-backup/archive-x.conf"
runhung "$BISYNC" validate vault-A
check "bisync validate: another pair's LOCAL inside LOCAL, both in a hung FUSE mount, is refused" \
  eval 'rc_is 64 && ! resolved_under "$HOME/Mnt" && [[ $OUT == *"overlaps LOCAL"*"vault-B"* ]]'
rm "$XDG_CONFIG_HOME/rclone-bisync/vault-B.conf"
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
  mkdir -p "$XDG_CONFIG_HOME/rclone-backup"
  {
    echo "REMOTE=work_drive:"
    echo "STRIP_PREFIX=acme/"
    echo "DEST=~/Backups/vaults"
    printf '%s\n' "$@"
  } >"$XDG_CONFIG_HOME/rclone-backup/$name.conf"
  { echo "# admin databases"; printf '%s\n' "${LIST_SHAPES[@]}"; } >"$XDG_CONFIG_HOME/rclone-backup/$name.files"
}

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
check "copyto <remote path> <local .part>, with retries" \
  eval 'grep -qxF "rclone$(q copyto "work_drive:${LIST_SHAPES[0]}" "$DEST/$J.$TODAY.kdbx.part" --retries 3 --log-level ERROR)" "$FAKE_LOG/rclone"'
check "read-only toward the remote: every rclone call is copyto <remote> <local DEST>" \
  eval '! grep -v "^rclone copyto work_drive:[^ ]* $(printf %q "$DEST")/[^ ]*\.part --retries 3 --log-level ERROR$" "$FAKE_LOG/rclone" | grep -q .'
check "state: exit=0 ok=5 failed=0" \
  eval 'grep -qx exit=0 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state" && grep -qx ok=5 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state" && grep -qx failed=0 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'
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
check "a failed copy: its .part removed, no copy under its name" \
  eval '[[ -z $(find "$DEST" -name "*.part") && ! -e $DEST/$(live_name "${LIST_SHAPES[2]}") ]]'
check "a failed copy: one normal notification from rclone-backup" \
  eval '[[ $(log notify-send | wc -l) == 1 && $(log notify-send) == "notify-send -u normal -a rclone-backup "* ]]'
check "a failed copy: state exit=1 ok=4 failed=1" \
  eval 'grep -qx exit=1 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state" && grep -qx ok=4 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state" && grep -qx failed=1 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'

fresh
job archive-vaults "KEEP=1"
DEST=$HOME/Backups/vaults
mkdir -p "$DEST"
J=archive-vaults@Admin__Segurança__Team
echo old1 >"$DEST/$J.2026-11-01.kdbx"
echo old2 >"$DEST/$J.2026-11-02.kdbx"
PATH="$MVSTUB:$PATH" FAKE_MV_FAIL="$DEST/$J.$TODAY.kdbx" runc "$BACKUP" run archive-vaults
check "a failed mv: exit 1, counted failed (state ok=4 failed=1)" \
  eval 'rc_is 1 && grep -qx ok=4 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state" && grep -qx failed=1 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'
check "a failed mv: its .part removed, its older copies not pruned" \
  eval '[[ -z $(find "$DEST" -name "*.part") && -f $DEST/$J.2026-11-01.kdbx && -f $DEST/$J.2026-11-02.kdbx && ! -e $DEST/$J.$TODAY.kdbx ]]'
check "a failed mv: notified" eval '[[ $(log notify-send) == *"$(printf %q "1 of 5 files failed")"* ]]'

fresh
job archive-vaults
flock "$XDG_RUNTIME_DIR/rclone-backup-archive-vaults.lock" sleep 10 &
holder=$!
for _ in {1..50}; do flock -n "$XDG_RUNTIME_DIR/rclone-backup-archive-vaults.lock" true || break; sleep 0.05; done
runc "$BACKUP" run archive-vaults
check "backup lock busy: run exits 0 without rclone or state" \
  eval 'rc_is 0 && no_rclone && [[ $OUT == *"another run is active"* && ! -e $XDG_STATE_HOME/rclone-backup/archive-vaults.state ]]'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

fresh
mkdir -p "$XDG_CONFIG_HOME/rclone-backup"
printf 'REMOTE=gd:Shared/docs\nDEST=%s/out\nFILES=~/list\n' "$T" >"$XDG_CONFIG_HOME/rclone-backup/j.conf"
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
  printf '%s\n' "$2" >>"$XDG_CONFIG_HOME/rclone-backup/j.files"
  runc "$BACKUP" run j
  check "files list $1: exit 64, nothing copied" eval 'rc_is 64 && no_rclone'
}
bad_files "with a .. segment" "acme/../etc/passwd"
bad_files "with an absolute path" "/etc/passwd"
bad_files "with a trailing /" "acme/dir/"
bad_files "with an empty segment" "acme//x.kdbx"
bad_files "with a duplicate copy name" "acme/Admin/Segurança/Team.kdbx"
check "invalid conf on run: notified and recorded (exit=64)" \
  eval '[[ -s $FAKE_LOG/notify-send ]] && grep -qx exit=64 "$XDG_STATE_HOME/rclone-backup/j.state"'

for kv in "KEEP=0" "KEEP=366" "KEEP=x" "SCHEDULE=daily;rm" "COLOR=red" "REMOTE=work_drive:x/" "REMOTE=work_drive:../x"; do
  fresh
  job j "$kv"
  [[ $kv == REMOTE=* ]] && sed -i '1d' "$XDG_CONFIG_HOME/rclone-backup/j.conf"
  runc "$BACKUP" run j
  check "backup conf $kv: exit 64" eval 'rc_is 64 && no_rclone'
done
fresh
mkdir -p "$XDG_CONFIG_HOME/rclone-backup"
echo "REMOTE=work_drive:" >"$XDG_CONFIG_HOME/rclone-backup/j.conf"
: >"$XDG_CONFIG_HOME/rclone-backup/j.files"
runc "$BACKUP" run j
check "backup conf without DEST: exit 64" rc_is 64
runc "$BACKUP" run ../j
check "bad job name: exit 64" rc_is 64

# DEST (~/Backups/vaults) against the LOCAL of offline folders.
for local in "~/Backups/vaults/sub" "~/Backups/vaults" "~/Backups" "~/"; do
  fresh
  job archive-vaults
  mkdir -p "$XDG_CONFIG_HOME/rclone-bisync"
  printf 'LOCAL=%s\nREMOTE=onedrive:x\n' "$local" >"$XDG_CONFIG_HOME/rclone-bisync/vault-A.conf"
  runc "$BACKUP" setup archive-vaults
  check "backup setup: DEST overlapping LOCAL $local is refused (exit 64, no rclone, no drop-in)" \
    eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps LOCAL"*"vault-A"* && $OUT != *continuing* && ! -e $XDG_CONFIG_HOME/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
  runc "$BACKUP" run archive-vaults
  check "backup run: DEST overlapping offline folder LOCAL $local warns and backs up (exit 0, copied, not notified)" \
    eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: archive-vaults: DEST"*"overlaps LOCAL"*"vault-A"*"; continuing"* && ! -s $FAKE_LOG/notify-send ]] && grep -qx exit=0 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'
done
fresh
job archive-vaults
mkdir -p "$XDG_CONFIG_HOME/rclone-bisync"
printf 'LOCAL=~/Backups/vaults-sync\nREMOTE=onedrive:x\n' >"$XDG_CONFIG_HOME/rclone-bisync/vault-A.conf"
runc "$BACKUP" run archive-vaults
check "backup run: a LOCAL next to DEST (vaults-sync vs vaults) is not an overlap" rc_is 0
fresh
job archive-vaults
mkdir -p "$HOME/Vaults" "$HOME/Backups" "$XDG_CONFIG_HOME/rclone-bisync"
ln -s "$HOME/Vaults" "$HOME/Backups/vaults"
printf 'LOCAL=~/Vaults\nREMOTE=onedrive:x\n' >"$XDG_CONFIG_HOME/rclone-bisync/vault-A.conf"
runc "$BACKUP" setup archive-vaults
check "backup setup: a DEST that is LOCAL through a symlink is refused" eval 'rc_is 64 && no_rclone'
runc "$BACKUP" run archive-vaults
check "backup run: a DEST that is LOCAL through a symlink warns and backs up" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"overlaps LOCAL"*"; continuing"* ]]'

fresh
job archive-vaults "SCHEDULE=*-*-* 03:30"
runc "$BACKUP" setup archive-vaults
UD=$XDG_CONFIG_HOME/systemd/user
check "backup setup: drop-in resets OnCalendar then sets SCHEDULE" \
  eval '[[ $(cat "$UD/rclone-backup@archive-vaults.timer.d/10-schedule.conf") == $'"'"'[Timer]\nOnCalendar=\nOnCalendar=*-*-* 03:30'"'"' ]]'
check "backup setup: daemon-reload, rclone not called" eval '[[ $(log systemctl) == "systemctl --user daemon-reload" ]] && no_rclone'
BK_UD=$UD
fresh
job j "SCHEDULE=every day"
runc "$BACKUP" setup j
if command -v systemd-analyze >/dev/null; then
  check "backup setup: a SCHEDULE systemd cannot parse is exit 64" eval 'rc_is 64 && [[ ! -e $XDG_CONFIG_HOME/systemd/user/rclone-backup@j.timer.d ]]'
fi
fresh
mkdir -p "$XDG_CONFIG_HOME/systemd/user/rclone-backup@j.timer.d"
echo x >"$XDG_CONFIG_HOME/systemd/user/rclone-backup@j.timer.d/10-schedule.conf"
runc "$BACKUP" teardown j
check "backup teardown: drop-in dir gone, no conf needed" eval 'rc_is 0 && [[ ! -e $XDG_CONFIG_HOME/systemd/user/rclone-backup@j.timer.d ]]'

# An empty files list is an invalid conf everywhere: run notifies and records
# exit=64; setup, validate and list are exit 64.
fresh
job archive-vaults
printf '# nothing yet\n\n' >"$XDG_CONFIG_HOME/rclone-backup/archive-vaults.files"
runc "$BACKUP" run archive-vaults
check "empty files list: run exit 64, no rclone, notified, state exit=64" \
  eval 'rc_is 64 && no_rclone && [[ $OUT == *"files list"*"is empty"* && -s $FAKE_LOG/notify-send ]] && grep -qx exit=64 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'
check "empty files list: run creates no DEST" eval '[[ ! -e $HOME/Backups/vaults ]]'
for sub in setup validate list; do
  runc "$BACKUP" "$sub" archive-vaults
  check "empty files list: $sub exit 64, no drop-in" \
    eval 'rc_is 64 && [[ $OUT == *"is empty"* && ! -e $XDG_CONFIG_HOME/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
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
set_dest() { sed -i "s|^DEST=.*|DEST=$2|" "$XDG_CONFIG_HOME/rclone-backup/$1.conf"; }

# DEST against the DEST of the other jobs.
for other in "~/Backups/vaults" "~/Backups" "~/Backups/vaults/old" "@HOME@/Backups/vaults/"; do
  fresh
  job archive-vaults
  bk_dest other-job "${other//@HOME@/$HOME}"
  for sub in setup validate; do
    runc "$BACKUP" "$sub" archive-vaults
    check "backup $sub: DEST overlapping the DEST $other of another job is refused (exit 64, no drop-in)" \
      eval 'rc_is 64 && no_rclone && [[ $OUT == *"overlaps DEST"*"backup job other-job"* && $OUT != *continuing* && ! -e $XDG_CONFIG_HOME/systemd/user/rclone-backup@archive-vaults.timer.d ]]'
  done
  runc "$BACKUP" run archive-vaults
  check "backup run: DEST overlapping another job's DEST $other warns and backs up (exit 0)" \
    eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && [[ $OUT == *"warning: archive-vaults: DEST"*"overlaps DEST"*"other-job"*"; continuing"* ]] && grep -qx exit=0 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'
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

# A hung FUSE mount (see the bisync tests): other jobs' DEST and pairs' LOCAL
# in it are never resolved; a run completes; validate and setup still refuse.
fresh
hung_mount
job archive-vaults
bk_dest other-job "~/Mnt/hung/b"
other_pair vault-B "~/Mnt/hung/x"
runhung "$BACKUP" run archive-vaults
check "backup run: other jobs' DEST and pairs' LOCAL in a hung FUSE mount are never resolved, the backup completes" \
  eval 'rc_is 0 && grep -q "^rclone copyto " "$FAKE_LOG/rclone" && ! resolved_under "$HOME/Mnt" && resolved_under "$HOME/Backups/vaults" && [[ $OUT != *warning:* ]] && grep -qx exit=0 "$XDG_STATE_HOME/rclone-backup/archive-vaults.state"'
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
rm "$XDG_CONFIG_HOME/rclone-bisync/vault-B.conf"
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

# A CRLF conf is invalid.
fresh
job j
sed -i 's/$/\r/' "$XDG_CONFIG_HOME/rclone-backup/j.conf"
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

echo
if ((FAILURES)); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
