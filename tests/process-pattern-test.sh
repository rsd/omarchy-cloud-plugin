#!/bin/bash

# The plugin's shell strings, Model.PENDING_SCRIPT (the pending-upload
# count) and Model.FUSER_SCRIPT (who uses a mount), run through a real shell
# exactly as the widget runs them, under `timeout -k`: the argv comes from
# Model.pendingArgv / Model.fuserArgv via node, so this tests the shipped
# strings, not copies.
#
#   1. With printf stand-ins for grep, head and wc first on PATH, the argv each
#      receives after bash has expanded the script is recorded and compared:
#      the metadata directory arrives as one literal argument whatever $HOME
#      holds ($(...), backticks, ;, quotes, spaces, a leading dash, unicode),
#      and nothing in it runs (a canary file is never created).
#   2. Crafted remote names build no argv at all.
#   3. With the real grep, a fixture vfsMeta tree in rclone's on-disk format is
#      counted: only items whose "Dirty" is true; a missing directory is 0.
#   4. With a fuser stand-in that splits its table across stdout and stderr the
#      way psmisc does, the widget's one stream (stdout) carries the whole
#      table and the exit line, and Model.parseFuser reads it as busy; a
#      stand-in that hangs is cut by timeout and reads as "could not check".
#   5. Model.SCAN_SCRIPT on a fixture home whose path is crafted: regular
#      files only (a symlink to a regular file is read, as the helper scripts
#      read it; a FIFO, a directory, a dangling symlink and symlinks to a FIFO
#      or a directory are skipped), each cut at the byte bound, at most
#      SCAN_MAX_FILES of them, a forged marker line inside a file or in
#      systemctl's template listing (a stand-in) is content, the TUI binary
#      found only when executable, nothing runs, and a hung read is cut by
#      timeout and refused.
#   6. Model.VERSIONS_SCRIPT on a crafted plugin folder and state dir: the
#      plugin's manifest.json version and install.sh's header read, a FIFO
#      skipped, a symlink to a regular file followed, the legacy record and
#      install.sh found, nothing runs, a hung read cut by timeout and refused;
#      and Model.INSTALL_SCRIPT (without the terminal) runs a stand-in
#      install.sh given as "$1", prints its exit status and waits for Enter.
#
# Nothing here touches the real cache, a mount, a unit or the real config.

set -o pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FAILURES=0
SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }

command -v node >/dev/null || { echo "skipped: node not found"; exit 77; }

# pending_argv <home> <remote>: Model.pendingArgv, NUL-separated.
pending_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { pendingArgv, PENDING_SCRIPT, PENDING_MAX_FILES }")()
    const argv = m.pendingArgv(process.argv[2], process.argv[3])
    process.stdout.write(argv.map(a => a + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$1" "$2"
}

# Stand-ins: each appends one line to $STANDIN_LOG.<tool> (one file per tool:
# the pipeline's stages run at once), its name and then every
# argument through printf %q (so a space, quote or newline inside one argument
# stays inside it), and grep prints two lines for wc to count.
STANDINS=$SCRATCH/bin
mkdir -p "$STANDINS"
for tool in grep head wc; do
  cat >"$STANDINS/$tool" <<'EOF'
#!/bin/bash
{ printf '%s' "${0##*/}"; printf ' %q' "$@"; printf '\n'; } >>"$STANDIN_LOG.${0##*/}"
case ${0##*/} in
  grep) printf 'one\ntwo\n' ;;
  head) cat ;;
  wc) printf '2\n' ;;
esac
EOF
  chmod +x "$STANDINS/$tool"
done

# recorded <tool>: that tool's logged argv (the %q form).
recorded() {
  [[ -f $STANDIN_LOG.$1 ]] && sed "s/^$1 //" "$STANDIN_LOG.$1"
}

expect_args() {
  local name=$1 tool=$2
  shift 2
  local want got
  want=$(printf '%q ' "$@")
  want=${want% }
  got=$(recorded "$tool")
  if [[ $want == "$got" ]]; then pass "$name"; else
    fail "$name"
    echo "     want: $want"
    echo "     got:  $got"
  fi
}

run_argv() {
  local -a argv=()
  mapfile -d '' -t argv < <(pending_argv "$1" "$2")
  ((${#argv[@]} == 9)) || { echo "argv has ${#argv[@]} fields"; return 1; }
  [[ ${argv[0]} == timeout && ${argv[1]} == -k && ${argv[4]} == bash && ${argv[5]} == -c ]] || { echo "not timeout -k … bash -c"; return 1; }
  (cd "$SCRATCH/cwd" && PATH=$STANDINS:$PATH STANDIN_LOG=$STANDIN_LOG "${argv[@]}")
}

mkdir -p "$SCRATCH/cwd"

# --- 1. post-shell argv, plain and crafted $HOME --------------------------
HOMES=(
  "/home/u"
  "/tmp/x/\$(touch PWNED)"
  "/tmp/\`touch PWNED\`"
  "/tmp/a b;touch PWNED"
  "/tmp/a'b\"c"
  "/tmp/-rf *"
  "/tmp/\$HOME/\${PATH}"
  "/tmp/naïve/ドライブ"
  "/tmp/a|b&c>d<e"
  "/tmp/back\\slash\\n"
)
PATTERN='"Dirty"[[:space:]]*:[[:space:]]*true'
# The script returns 0 before grep when the directory is missing, so each
# crafted HOME is rooted in the scratch tree with its metadata directory made.
for h in "${HOMES[@]}"; do
  home=$SCRATCH/homes$h
  mkdir -p -- "$home/.cache/rclone/vfsMeta/gdrive"
  STANDIN_LOG=$SCRATCH/log.$RANDOM
  : >"$STANDIN_LOG"
  out=$(run_argv "$home" gdrive)
  expect_args "grep gets the directory as one literal argument (HOME=$home)" grep \
    -rlE -e "$PATTERN" -- "$home/.cache/rclone/vfsMeta/gdrive"
  expect_args "head and wc get only constants (HOME=$home)" head -n 100000
  [[ $out == 2 ]] && pass "the count is the pipeline's output (HOME=$home)" || fail "count output '$out' (HOME=$home)"
  if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then fail "a command in HOME ran (HOME=$home)"; rm -f "$SCRATCH/cwd/PWNED"; fi
done
mkdir -p "$SCRATCH/homes/tmp/x/.cache/rclone/vfsMeta/gdrive"
STANDIN_LOG=$SCRATCH/log.wc
: >"$STANDIN_LOG"
run_argv "$SCRATCH/homes/tmp/x" gdrive >/dev/null
expect_args "wc counts lines" wc -l

# Missing directory: 0, and grep is never called. Unreadable (grep status 2 or
# more, other than SIGPIPE 141): "unknown", never a count. No match (1): 0.
STANDIN_LOG=$SCRATCH/log.missing
: >"$STANDIN_LOG"
out=$(run_argv "$SCRATCH/homes/nonexistent" gdrive)
[[ $out == 0 && ! -e $STANDIN_LOG.grep ]] && pass "a missing directory is 0 without running grep" || fail "missing dir: out '$out'"
for status in 2 3 126 127; do
  mkdir -p "$SCRATCH/failbin"
  printf '#!/bin/bash\nprintf "partial\\n"\nexit %s\n' "$status" >"$SCRATCH/failbin/grep"
  chmod +x "$SCRATCH/failbin/grep"
  mapfile -d '' -t argv < <(pending_argv "$SCRATCH/homes/tmp/x" gdrive)
  out=$(PATH=$SCRATCH/failbin:$PATH "${argv[@]}")
  [[ $out == unknown ]] && pass "grep exit $status reads as unknown" || fail "grep exit $status gave '$out'"
done
printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/failbin/grep"
out=$(PATH=$SCRATCH/failbin:$PATH "${argv[@]}")
[[ $out == 0 ]] && pass "grep exit 1 (no match) is 0" || fail "grep exit 1 gave '$out'"

# --- 2. crafted names build nothing ------------------------------------------
for name in 'a;rm -rf ~' '$(x)' '-x' '../x' $'a\nb' 'ドライブ' '' '..' 'a b' '`x`'; do
  n=$(pending_argv /home/u "$name" | tr -cd '\0' | wc -c)
  ((n == 0)) && pass "no argv for crafted name $(printf '%q' "$name")" || fail "argv built for $(printf '%q' "$name")"
done
for home in "" "relative" "/a/../b" $'/a\nb'; do
  n=$(pending_argv "$home" gdrive | tr -cd '\0' | wc -c)
  ((n == 0)) && pass "no argv for refused HOME $(printf '%q' "$home")" || fail "argv built for HOME $(printf '%q' "$home")"
done

# --- 3. real grep on rclone's metadata format --------------------------------
# rclone writes one JSON file per cached item under vfsMeta/<remote>/, mirroring
# the remote's tree, tab-indented: {"ModTime": ..., "Dirty": true, ...}.
FAKE_HOME="$SCRATCH/home/\$(touch PWNED) x"
META="$FAKE_HOME/.cache/rclone/vfsMeta/gdrive"
mkdir -p "$META/docs/deep" "$META/-n" "$META/other"
printf '{\n\t"ModTime": "2026-11-14T17:00:00-03:00",\n\t"Size": 10,\n\t"Dirty": true\n}\n' >"$META/docs/a.txt"
printf '{"ModTime":"2026-11-14T17:00:00-03:00","Dirty":true}' >"$META/docs/deep/b.txt"
printf '{\n\t"Dirty": true\n}\n' >"$META/-n/dash.txt"
printf '{\n\t"Size": 10,\n\t"Dirty": false\n}\n' >"$META/other/c.txt"
printf '{\n\t"Size": 10\n}\n' >"$META/other/d.txt"
printf 'Dirty: true but not json key\n' >"$META/other/e.txt"
mapfile -d '' -t argv < <(pending_argv "$FAKE_HOME" gdrive)
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
[[ $out =~ ^[[:space:]]*3[[:space:]]*$ ]] && pass "real grep counts the 3 dirty items" || fail "real grep counted '$out', want 3"
mapfile -d '' -t argv < <(pending_argv "$FAKE_HOME" onedrive)
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
[[ $out =~ ^[[:space:]]*0[[:space:]]*$ ]] && pass "a missing metadata directory counts 0" || fail "missing dir counted '$out'"
[[ -e $SCRATCH/cwd/PWNED ]] && fail "a command in the fixture HOME ran" || pass "nothing in the fixture HOME ran"
# Counting never changed the cache.
[[ $(find "$META" -type f | wc -l) == 6 ]] && pass "the fixture cache is untouched" || fail "the fixture cache changed"

# --- 4. fuser's split streams arrive merged on stdout --------------------------
# parse_fuser <remote>: Model.parseFuser over stdin, as JSON.
parse_fuser() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { parseFuser, stopDecision }")()
    const b = m.parseFuser(fs.readFileSync(0, "utf8"), process.argv[2])
    process.stdout.write(JSON.stringify(b) + " " + m.stopDecision(b, 0))
  ' "$PLUGIN_DIR/Model.js" "$1"
}
# fuser_argv <remote> [timeout seconds]: Model.fuserArgv, NUL-separated.
fuser_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { fuserArgv }")()
    process.stdout.write(m.fuserArgv(process.argv[2]).map(a => a + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$1"
}
FUSER_BIN=$SCRATCH/fuserbin
mkdir -p "$FUSER_BIN"
# psmisc 23.7's split, from a real run: PIDs and "kernel" on stdout, the rest
# of each row on stderr, flushed field by field.
cat >"$FUSER_BIN/fuser" <<'EOF'
#!/bin/bash
[[ $FUSER_MODE == hang ]] && exec sleep 60
p=${!#}
printf '%21s%-8s%6s %s\n' "" USER PID "ACCESS COMMAND" >&2
printf '%-21s' "$p:" >&2; printf '%-9s' root >&2; printf 'kernel'; printf ' mount %s\n' "$p" >&2
printf '%21s%-9s' "" alice >&2; printf ' 4242'; printf ' ..c.. sleep\n' >&2
EOF
chmod +x "$FUSER_BIN/fuser"
mapfile -d '' -t argv < <(fuser_argv lake-s3)
[[ ${argv[0]} == timeout && ${argv[4]} == sh ]] && pass "fuser runs under timeout -k through sh" || fail "fuser argv: ${argv[*]}"
out=$(PATH=$FUSER_BIN:$PATH "${argv[@]}" 2>/dev/null)
[[ $out == *"cloud-mounts-fuser-exit 0" ]] && pass "stdout ends with the exit line" || fail "no exit line: $out"
got=$(parse_fuser lake-s3 <<<"$out")
[[ $got == '{"known":true,"procs":[{"pid":4242,"user":"alice","command":"sleep"}],"total":1} confirm' ]] &&
  pass "stdout alone parses as busy (asks before stopping)" || fail "parsed: $got"
# The stream the widget read before the fix: stderr only, never "stop".
err=$(PATH=$FUSER_BIN:$PATH "${argv[@]}" 2>&1 >/dev/null)
got=$(parse_fuser lake-s3 <<<"$err")
[[ $got != *" stop" ]] && pass "stderr alone is not read as idle" || fail "stderr parsed as idle: $got"
# A hung fuser: a short timeout stands in for the 10 s one.
hung=("${argv[@]}")
hung[3]=1
start=$SECONDS
out=$(FUSER_MODE=hang PATH=$FUSER_BIN:$PATH "${hung[@]}" 2>/dev/null)
status=$?
((status == 124 && SECONDS - start < 5)) && pass "a hung fuser is cut by timeout (status $status)" || fail "hung fuser: status $status after $((SECONDS - start)) s"
got=$(parse_fuser lake-s3 <<<"$out")
[[ $got == '{"known":false,"procs":[],"total":0} confirm' ]] && pass "a timed-out check could not check" || fail "timed out parsed: $got"

# --- 5. the config and state scan, through a real sh --------------------------
# scan_argv <home> <state dir> <token>: Model.scanArgv, NUL-separated.
scan_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { scanArgv }")()
    process.stdout.write(m.scanArgv(process.argv[2], process.argv[3], process.argv[4]).map(a => a + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$1" "$2" "$3"
}
# parse_scan <home> <state dir> <token>: Model.parseScan over stdin, as JSON.
parse_scan() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { parseScan, scanDirs, scanPairs, scanJobs }")()
    const r = m.parseScan(fs.readFileSync(0, "utf8"), process.argv[4], m.scanDirs(process.argv[2], process.argv[3]))
    process.stdout.write(JSON.stringify({ ok: r.ok, app: r.app, more: r.more, pairs: m.scanPairs(r), jobs: m.scanJobs(r),
      local: r.pairConfs["vault-A"] ? r.pairConfs["vault-A"].local : null,
      conflicts: r.pairStates["vault-A"] ? r.pairStates["vault-A"].conflicts : null,
      truncated: r.pairStates.big ? r.pairStates.big.conflictsTruncated : null,
      jobOk: r.jobStates["archive-vaults"] ? r.jobStates["archive-vaults"].ok : null,
      linked: r.pairConfs.linked ? r.pairConfs.linked.local : null, templates: r.templates }))
  ' "$PLUGIN_DIR/Model.js" "$1" "$2" "$3"
}
TOKEN=cmscan-abcdefghijkl0123
SHOME="$SCRATCH/scan/\$(touch PWNED) a'b \"c\" \`touch PWNED\`"
SSTATE="$SHOME/.local/state"
mkdir -p "$SHOME/.config/rclone-bisync/dir.conf" "$SHOME/.config/rclone-backup" "$SSTATE/rclone-bisync" "$SSTATE/rclone-backup" "$SHOME/.local/bin"
printf 'LOCAL=~/Vaults\nREMOTE=onedrive:Backup/Vaults\ncmscan-zzzzzzzzzzzz end\n' >"$SHOME/.config/rclone-bisync/vault-A.conf"
printf 'LOCAL=/elsewhere\n' >"$SCRATCH/target.conf"
ln -s "$SCRATCH/target.conf" "$SHOME/.config/rclone-bisync/linked.conf"
mkfifo "$SHOME/.config/rclone-bisync/fifo.conf" "$SCRATCH/target.fifo"
mkdir -p "$SCRATCH/target.dir"
ln -s "$SCRATCH/nowhere.conf" "$SHOME/.config/rclone-bisync/dangling.conf"
ln -s "$SCRATCH/target.fifo" "$SHOME/.config/rclone-bisync/tofifo.conf"
ln -s "$SCRATCH/target.dir" "$SHOME/.config/rclone-bisync/todir.conf"
# systemctl stand-in for the template listing (never the real user manager):
# one template installed, one masked, and a line forging the end marker.
SYSBIN=$SCRATCH/sysbin
mkdir -p "$SYSBIN"
cat >"$SYSBIN/systemctl" <<EOF2
#!/bin/sh
printf '%s\n' "\$*" >"$SCRATCH/systemctl.argv"
printf 'rclone-bisync@.service linked enabled\n$TOKEN end\nrclone-backup@.service masked enabled\n'
EOF2
chmod +x "$SYSBIN/systemctl"
PATH=$SYSBIN:$PATH
printf 'REMOTE=work_drive:\n' >"$SHOME/.config/rclone-backup/archive-vaults.conf"
printf 'time=1794699700\nexit=0\nconflict=Personal.kdbx.conflict1\nconflict=$(touch PWNED)\n' >"$SSTATE/rclone-bisync/vault-A.state"
printf 'time=1794686996\nexit=0\nok=4\nfailed=0\n' >"$SSTATE/rclone-backup/archive-vaults.state"
# Larger than the scan reads: cut, and marked truncated.
{ printf 'time=1794699700\nexit=0\n'; for ((i = 0; i < 1200; i++)); do printf 'conflict=c%04d\n' "$i"; done; } >"$SSTATE/rclone-bisync/big.state"

mapfile -d '' -t argv < <(scan_argv "$SHOME" "$SSTATE" "$TOKEN")
[[ ${argv[0]} == timeout && ${argv[4]} == sh && ${argv[5]} == -c && ${argv[8]} == "$TOKEN" && ${argv[11]} == "$SHOME/.local/bin/omarchy-cloud" ]] &&
  pass "the scan runs under timeout -k through sh, values positional" || fail "scan argv: ${argv[*]}"
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
((status == 0 && SECONDS - start < 5)) && pass "the scan finishes (a FIFO is skipped, not read)" || fail "scan status $status after $((SECONDS - start)) s"
[[ -e $SCRATCH/cwd/PWNED || -e PWNED ]] && fail "a command in the scanned HOME or files ran" || pass "nothing in HOME or the files ran"
got=$(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out")
want='{"ok":true,"app":false,"more":false,"pairs":["linked","vault-A"],"jobs":["archive-vaults"],"local":"~/Vaults","conflicts":["Personal.kdbx.conflict1","$(touch PWNED)"],"truncated":true,"jobOk":4,"linked":"/elsewhere","templates":{"bisync":true,"backup":false}}'
[[ $got == "$want" ]] && pass "regular files and symlinks to one read; FIFO, directory, dangling skipped; forged markers are content" || {
  fail "scan parsed"
  echo "     want: $want"
  echo "     got:  $got"
}
grep -q "^$TOKEN file [0-9]* .*/big.state$" <<<"$out" && (($(grep -c '^conflict=c' <<<"$out") < 1200)) &&
  pass "a large file is cut at the byte bound" || fail "large file not bounded"
grep -q "fifo.conf\|dir.conf\|dangling.conf" <<<"$out" && fail "a FIFO, directory or dangling symlink was listed" || pass "no FIFO, directory or dangling symlink listed"
grep -q "^$TOKEN file [0-9]* .*/linked.conf$" <<<"$out" && pass "a symlink to a regular conf is read" || fail "symlinked conf skipped"
[[ $(<"$SCRATCH/systemctl.argv") == "--user list-unit-files --no-legend --plain -- rclone-bisync@.service rclone-backup@.service" ]] &&
  pass "the templates are listed by their constant names" || fail "systemctl argv: $(<"$SCRATCH/systemctl.argv")"
(($(grep -c "^$TOKEN end$" <<<"$out") == 1)) && grep -q "^$TOKEN unitfile $TOKEN end$" <<<"$out" &&
  pass "a forged end line from systemctl stays behind the unitfile marker" || fail "forged systemctl line"
# The TUI binary: found only when it is an executable regular file.
printf '#!/bin/sh\n' >"$SHOME/.local/bin/omarchy-cloud"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
[[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"app":false'* ]] && pass "a non-executable omarchy-cloud is not installed" || fail "non-executable app reported installed"
chmod +x "$SHOME/.local/bin/omarchy-cloud"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
[[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"app":true'* ]] && pass "an installed omarchy-cloud is found" || fail "installed app not found"
# More files than the bound: the rest is not read, and the scan says so.
for ((i = 0; i < 80; i++)); do printf 'LOCAL=/x\n' >"$SHOME/.config/rclone-bisync/p$i.conf"; done
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
n=$(grep -c "^$TOKEN file " <<<"$out")
max=$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");console.log(new Function(s+"\nreturn SCAN_MAX_FILES")())' "$PLUGIN_DIR/Model.js")
((n == max)) && grep -q "^$TOKEN more$" <<<"$out" && grep -q "^$TOKEN end$" <<<"$out" &&
  pass "at most $max files read, then 'more'" || fail "file bound: $n files read (max $max)"
[[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"more":true'* ]] && pass "the parsed scan reports 'more'" || fail "'more' not parsed"
# A read that hangs (a stand-in head) is cut by timeout; without its end line
# the scan is refused.
HANGBIN=$SCRATCH/hangbin
mkdir -p "$HANGBIN"
printf '#!/bin/sh\nexec sleep 60\n' >"$HANGBIN/head"
chmod +x "$HANGBIN/head"
cut=("${argv[@]}")
cut[3]=1
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && PATH=$HANGBIN:$PATH "${cut[@]}" 2>/dev/null)
status=$?
((status == 124 && SECONDS - start < 5)) && pass "a hung read is cut by timeout (status $status)" || fail "hung scan: status $status after $((SECONDS - start)) s"
[[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"ok":false'* ]] && pass "a scan without its end line is refused" || fail "a cut scan was accepted"

# --- 6. the installed-parts read and the install terminal script -------------
# versions_argv <plugin dir> <state dir> <token>: Model.versionsArgv, NUL-separated.
versions_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { versionsArgv }")()
    process.stdout.write(m.versionsArgv(process.argv[2], process.argv[3], process.argv[4]).map(a => a + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$1" "$2" "$3"
}
# parse_versions <token>: Model.parseVersions over stdin, with its state, as JSON.
parse_versions() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { parseVersions, installState }")()
    const r = m.parseVersions(fs.readFileSync(0, "utf8"), process.argv[2])
    r.state = m.installState(r)
    process.stdout.write(JSON.stringify(r))
  ' "$PLUGIN_DIR/Model.js" "$1"
}
# install_argv <plugin dir>: Model.installArgv, NUL-separated.
install_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { installArgv }")()
    process.stdout.write(m.installArgv(process.argv[2]).map(a => a + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$1"
}
VPLUG="$SCRATCH/ver/\$(touch PWNED) a'b \"c\" \`touch PWNED\`/plugin"
VSTATE="$SCRATCH/ver/state \$(touch PWNED)"
mkdir -p "$VPLUG" "$VSTATE/omarchy-cloud" "$SCRATCH/cwd"
printf '{\n  "id": "x",\n  "version": "0.3.4"\n}\n' >"$VPLUG/manifest.json"
printf '#version=0.3.2\n#repo=/src/x\n%064d  /home/u/.local/bin/x\n' 0 >"$SCRATCH/installed-target"
ln -s "$SCRATCH/installed-target" "$VSTATE/omarchy-cloud/installed-files"
mapfile -d '' -t argv < <(versions_argv "$VPLUG" "$VSTATE" "$TOKEN")
[[ ${argv[0]} == timeout && ${argv[4]} == sh && ${argv[5]} == -c && ${argv[8]} == "$TOKEN" && ${argv[11]} == "$VPLUG/manifest.json" &&
  ${argv[12]} == "$VSTATE/omarchy-cloud/installed-files" && ${argv[14]} == "$VPLUG/install.sh" ]] &&
  pass "the versions read runs under timeout -k through sh, paths positional" || fail "versions argv: ${argv[*]}"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
[[ -e $SCRATCH/cwd/PWNED || -e PWNED ]] && fail "a command in the plugin or state path ran" || pass "nothing in the plugin or state path ran"
got=$(parse_versions "$TOKEN" <<<"$out")
want='{"ok":true,"plugin":"0.3.4","installedPresent":true,"installedVersion":"0.3.2","installedRepo":"/src/x","legacy":false,"installer":false,"state":"mismatch"}'
((status == 0)) && [[ $got == "$want" ]] && pass "manifest.json and the header read through a symlink: mismatch" || {
  fail "versions parsed (status $status)"
  echo "     want: $want"
  echo "     got:  $got"
}
printf 'x\n' >"$VSTATE/omarchy-cloud/installed-binary.sha256"
printf '#!/bin/sh\n' >"$VPLUG/install.sh"
rm "$VSTATE/omarchy-cloud/installed-files"
mkfifo "$VSTATE/omarchy-cloud/installed-files"
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
got=$(parse_versions "$TOKEN" <<<"$out")
((status == 0 && SECONDS - start < 5)) && [[ $got == *'"installedPresent":false,'*'"legacy":true,"installer":true,"state":"unknown"}' ]] &&
  pass "a FIFO manifest is skipped; the legacy record and install.sh are found: unknown" || fail "FIFO / legacy: status $status, $got"
rm "$VSTATE/omarchy-cloud/installed-files" "$VSTATE/omarchy-cloud/installed-binary.sha256"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
[[ $(parse_versions "$TOKEN" <<<"$out") == *'"state":"none"}' ]] && pass "nothing installed: none" || fail "none: $(parse_versions "$TOKEN" <<<"$out")"
cut=("${argv[@]}")
cut[3]=1
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && PATH=$HANGBIN:$PATH "${cut[@]}" 2>/dev/null)
status=$?
((status == 124 && SECONDS - start < 5)) && [[ $(parse_versions "$TOKEN" <<<"$out") == *'"ok":false'* ]] &&
  pass "a hung versions read is cut by timeout and refused" || fail "hung versions read: status $status after $((SECONDS - start)) s"
# The install terminal's script, run as the terminal would run it (the argv
# after omarchy-launch-tui --app-id=TUI.float), Enter on stdin.
printf 'echo "stand-in install.sh ran with $# args"\nexit "${CM_EXIT:-0}"\n' >"$VPLUG/install.sh"
mapfile -d '' -t argv < <(install_argv "$VPLUG")
[[ ${argv[0]} == omarchy-launch-tui && ${argv[1]} == --app-id=TUI.float && ${argv[2]} == bash && ${argv[3]} == -c && ${argv[6]} == "$VPLUG/install.sh" && ${#argv[@]} == 7 ]] &&
  pass "install argv: the floating terminal, a fixed script, install.sh as its own argument" || fail "install argv: ${argv[*]}"
out=$(cd "$SCRATCH/cwd" && printf '\n' | "${argv[@]:2}")
status=$?
((status == 0)) && grep -q '^stand-in install.sh ran with 0 args$' <<<"$out" && grep -q 'finished (exit status 0)' <<<"$out" && grep -q 'Press Enter to close' <<<"$out" &&
  pass "install.sh runs from \"\$1\", its exit status is shown, then Enter closes" || fail "install script: status $status, $out"
out=$(cd "$SCRATCH/cwd" && printf '\n' | CM_EXIT=3 "${argv[@]:2}")
grep -q 'failed (exit status 3)' <<<"$out" && pass "a failed install.sh shows its exit status" || fail "failed install: $out"
[[ -e $SCRATCH/cwd/PWNED || -e PWNED ]] && fail "a command in the plugin path ran" || pass "nothing in the plugin path ran"
# Without Enter the terminal stays: the script is still waiting.
coproc WAITER { cd "$SCRATCH/cwd" && "${argv[@]:2}"; }
sleep 1
kill -0 "$WAITER_PID" 2>/dev/null && pass "the script waits for Enter after install.sh exits" || fail "the script did not wait"
kill "$WAITER_PID" 2>/dev/null
wait "$WAITER_PID" 2>/dev/null

if ((FAILURES)); then
  echo "FAILED $FAILURES shell-string tests"
  exit 1
fi
echo "passed all shell-string tests"
