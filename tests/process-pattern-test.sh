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
#      timeout and refused; the mount-root setting (cloud.env) is read the
#      same way (regular file, byte bound, never sourced).
#   6. Model.VERSIONS_SCRIPT on a crafted plugin folder and state dir: the
#      plugin's manifest.json version and install.sh's header read, a FIFO
#      skipped, a symlink to a regular file followed, the legacy record and
#      install.sh found, nothing runs, a hung read cut by timeout and refused;
#      and Model.INSTALL_SCRIPT (without the terminal) runs a stand-in
#      install.sh given as "$1", prints its exit status and waits for Enter.
#   7. Model.ROOT_CHECK_SCRIPT on crafted (valid) roots: the root arrives as one
#      argument, nothing in it runs, a writable directory is ok and anything
#      else missing; Model.BOUNDED_SCRIPT around stand-in journalctl and
#      systemctl: the command's argv arrives intact, its output is capped by
#      head -c, a forged end line is content, and a hung command is cut by
#      timeout and refused.
#
# Nothing here touches the real cache, a mount, a unit or the real config.

# The single-quoted strings below carry a literal $ on purpose: crafted names,
# a HOME and file contents that must reach the code under test unexpanded.
# shellcheck disable=SC2016

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
  if [[ $out == 2 ]]; then
    pass "the count is the pipeline's output (HOME=$home)"
  else
    fail "count output '$out' (HOME=$home)"
  fi
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
if [[ $out == 0 && ! -e $STANDIN_LOG.grep ]]; then
  pass "a missing directory is 0 without running grep"
else
  fail "missing dir: out '$out'"
fi
for status in 2 3 126 127; do
  mkdir -p "$SCRATCH/failbin"
  printf '#!/bin/bash\nprintf "partial\\n"\nexit %s\n' "$status" >"$SCRATCH/failbin/grep"
  chmod +x "$SCRATCH/failbin/grep"
  mapfile -d '' -t argv < <(pending_argv "$SCRATCH/homes/tmp/x" gdrive)
  out=$(PATH=$SCRATCH/failbin:$PATH "${argv[@]}")
  if [[ $out == unknown ]]; then
    pass "grep exit $status reads as unknown"
  else
    fail "grep exit $status gave '$out'"
  fi
done
printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/failbin/grep"
out=$(PATH=$SCRATCH/failbin:$PATH "${argv[@]}")
if [[ $out == 0 ]]; then
  pass "grep exit 1 (no match) is 0"
else
  fail "grep exit 1 gave '$out'"
fi

# --- 2. crafted names build nothing ------------------------------------------
for name in 'a;rm -rf ~' '$(x)' '-x' '../x' $'a\nb' 'ドライブ' '' '..' 'a b' '`x`'; do
  n=$(pending_argv /home/u "$name" | tr -cd '\0' | wc -c)
  if ((n == 0)); then
    pass "no argv for crafted name $(printf '%q' "$name")"
  else
    fail "argv built for $(printf '%q' "$name")"
  fi
done
for home in "" "relative" "/a/../b" $'/a\nb'; do
  n=$(pending_argv "$home" gdrive | tr -cd '\0' | wc -c)
  if ((n == 0)); then
    pass "no argv for refused HOME $(printf '%q' "$home")"
  else
    fail "argv built for HOME $(printf '%q' "$home")"
  fi
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
if [[ $out =~ ^[[:space:]]*3[[:space:]]*$ ]]; then
  pass "real grep counts the 3 dirty items"
else
  fail "real grep counted '$out', want 3"
fi
mapfile -d '' -t argv < <(pending_argv "$FAKE_HOME" onedrive)
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if [[ $out =~ ^[[:space:]]*0[[:space:]]*$ ]]; then
  pass "a missing metadata directory counts 0"
else
  fail "missing dir counted '$out'"
fi
if [[ -e $SCRATCH/cwd/PWNED ]]; then
  fail "a command in the fixture HOME ran"
else
  pass "nothing in the fixture HOME ran"
fi
# Counting never changed the cache.
if [[ $(find "$META" -type f | wc -l) == 6 ]]; then
  pass "the fixture cache is untouched"
else
  fail "the fixture cache changed"
fi

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
if [[ ${argv[0]} == timeout && ${argv[4]} == sh ]]; then
  pass "fuser runs under timeout -k through sh"
else
  fail "fuser argv: ${argv[*]}"
fi
out=$(PATH=$FUSER_BIN:$PATH "${argv[@]}" 2>/dev/null)
if [[ $out == *"cloud-mounts-fuser-exit 0" ]]; then
  pass "stdout ends with the exit line"
else
  fail "no exit line: $out"
fi
got=$(parse_fuser lake-s3 <<<"$out")
if [[ $got == '{"known":true,"procs":[{"pid":4242,"user":"alice","command":"sleep"}],"total":1} confirm' ]]; then
  pass "stdout alone parses as busy (asks before stopping)"
else
  fail "parsed: $got"
fi
# The stream the widget read before the fix: stderr only, never "stop".
err=$(PATH=$FUSER_BIN:$PATH "${argv[@]}" 2>&1 >/dev/null)
got=$(parse_fuser lake-s3 <<<"$err")
if [[ $got != *" stop" ]]; then
  pass "stderr alone is not read as idle"
else
  fail "stderr parsed as idle: $got"
fi
# A hung fuser: a short timeout stands in for the 10 s one.
hung=("${argv[@]}")
hung[3]=1
start=$SECONDS
out=$(FUSER_MODE=hang PATH=$FUSER_BIN:$PATH "${hung[@]}" 2>/dev/null)
status=$?
if ((status == 124 && SECONDS - start < 5)); then
  pass "a hung fuser is cut by timeout (status $status)"
else
  fail "hung fuser: status $status after $((SECONDS - start)) s"
fi
got=$(parse_fuser lake-s3 <<<"$out")
if [[ $got == '{"known":false,"procs":[],"total":0} confirm' ]]; then
  pass "a timed-out check could not check"
else
  fail "timed out parsed: $got"
fi

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
if [[ ${argv[0]} == timeout && ${argv[4]} == sh && ${argv[5]} == -c && ${argv[8]} == "$TOKEN" && ${argv[11]} == "$SHOME/.local/bin/omarchy-cloud" ]]; then
  pass "the scan runs under timeout -k through sh, values positional"
else
  fail "scan argv: ${argv[*]}"
fi
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
if ((status == 0 && SECONDS - start < 5)); then
  pass "the scan finishes (a FIFO is skipped, not read)"
else
  fail "scan status $status after $((SECONDS - start)) s"
fi
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then
  fail "a command in the scanned HOME or files ran"
else
  pass "nothing in HOME or the files ran"
fi
got=$(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out")
want='{"ok":true,"app":false,"more":false,"pairs":["linked","vault-A"],"jobs":["archive-vaults"],"local":"~/Vaults","conflicts":["Personal.kdbx.conflict1","$(touch PWNED)"],"truncated":true,"jobOk":4,"linked":"/elsewhere","templates":{"bisync":true,"backup":false}}'
if [[ $got == "$want" ]]; then
  pass "regular files and symlinks to one read; FIFO, directory, dangling skipped; forged markers are content"
else
  fail "scan parsed"
  echo "     want: $want"
  echo "     got:  $got"
fi
if grep -q "^$TOKEN file [0-9]* .*/big.state$" <<<"$out" && (($(grep -c '^conflict=c' <<<"$out") < 1200)); then
  pass "a large file is cut at the byte bound"
else
  fail "large file not bounded"
fi
if grep -q "fifo.conf\|dir.conf\|dangling.conf" <<<"$out"; then
  fail "a FIFO, directory or dangling symlink was listed"
else
  pass "no FIFO, directory or dangling symlink listed"
fi
if grep -q "^$TOKEN file [0-9]* .*/linked.conf$" <<<"$out"; then
  pass "a symlink to a regular conf is read"
else
  fail "symlinked conf skipped"
fi
if [[ $(<"$SCRATCH/systemctl.argv") == "--user list-unit-files --no-legend --plain -- rclone-bisync@.service rclone-backup@.service" ]]; then
  pass "the templates are listed by their constant names"
else
  fail "systemctl argv: $(<"$SCRATCH/systemctl.argv")"
fi
if (($(grep -c "^$TOKEN end$" <<<"$out") == 1)) && grep -q "^$TOKEN unitfile $TOKEN end$" <<<"$out"; then
  pass "a forged end line from systemctl stays behind the unitfile marker"
else
  fail "forged systemctl line"
fi
# The TUI binary: found only when it is an executable regular file.
printf '#!/bin/sh\n' >"$SHOME/.local/bin/omarchy-cloud"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if [[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"app":false'* ]]; then
  pass "a non-executable omarchy-cloud is not installed"
else
  fail "non-executable app reported installed"
fi
chmod +x "$SHOME/.local/bin/omarchy-cloud"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if [[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"app":true'* ]]; then
  pass "an installed omarchy-cloud is found"
else
  fail "installed app not found"
fi
# More files than the bound: the rest is not read, and the scan says so.
for ((i = 0; i < 80; i++)); do printf 'LOCAL=/x\n' >"$SHOME/.config/rclone-bisync/p$i.conf"; done
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
n=$(grep -c "^$TOKEN file " <<<"$out")
max=$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");console.log(new Function(s+"\nreturn SCAN_MAX_FILES")())' "$PLUGIN_DIR/Model.js")
if ((n == max)) && grep -q "^$TOKEN more$" <<<"$out" && grep -q "^$TOKEN end$" <<<"$out"; then
  pass "at most $max files read, then 'more'"
else
  fail "file bound: $n files read (max $max)"
fi
if [[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"more":true'* ]]; then
  pass "the parsed scan reports 'more'"
else
  fail "'more' not parsed"
fi
# The mount-root setting: parsed, never sourced (a command in it never runs),
# the last line of the key wins, a forged marker inside it is content.
# parse_setting <home> <state dir> <token>: Model.rootSetting of the parsed scan.
parse_setting() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { parseScan, scanDirs, rootSetting }")()
    const r = m.parseScan(fs.readFileSync(0, "utf8"), process.argv[4], m.scanDirs(process.argv[2], process.argv[3]))
    process.stdout.write(JSON.stringify(m.rootSetting(r, process.argv[2])))
  ' "$PLUGIN_DIR/Model.js" "$1" "$2" "$3"
}
mkdir -p "$SHOME/.config/omarchy-cloud"
SETTING=$SHOME/.config/omarchy-cloud/cloud.env
if [[ $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == '{"state":"absent","path":"/mnt/cloud","value":""}' ]]; then
  pass "no cloud.env: the setting is absent, the default root"
else
  fail "absent setting: $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out")"
fi
printf '# by install.sh\r\nOMARCHY_CLOUD_ROOT=/srv/$(touch PWNED)\nOMARCHY_CLOUD_ROOT=/srv/cloud\r\ncmscan-zzzzzzzzzzzz setting 9\n' >"$SETTING"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if [[ $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == '{"state":"valid","path":"/srv/cloud","value":"/srv/cloud"}' ]]; then
  pass "cloud.env parsed: the last line wins, CRLF stripped, a forged marker is content"
else
  fail "setting: $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out")"
fi
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then
  fail "a command in cloud.env ran"
else
  pass "nothing in cloud.env ran"
fi
{ printf 'OMARCHY_CLOUD_ROOT=/srv/first\n'; for ((i = 0; i < 200; i++)); do printf '# padding padding padding\n'; done; printf 'OMARCHY_CLOUD_ROOT=/srv/past-the-bound\n'; } >"$SETTING"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if grep -q "^$TOKEN setting $(wc -c <"$SETTING")$" <<<"$out" && ! grep -q past-the-bound <<<"$out" &&
  [[ $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"path":"/srv/first"'* ]]; then
  pass "cloud.env is read up to its byte bound only"
else
  fail "setting bound: $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out")"
fi
rm "$SETTING"
mkfifo "$SETTING"
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
if ((status == 0 && SECONDS - start < 5)) && [[ $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"state":"absent"'* ]]; then
  pass "a FIFO cloud.env is skipped, not read"
else
  fail "FIFO setting: status $status"
fi
rm "$SETTING"
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
if ((status == 124 && SECONDS - start < 5)); then
  pass "a hung read is cut by timeout (status $status)"
else
  fail "hung scan: status $status after $((SECONDS - start)) s"
fi
if [[ $(parse_scan "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == *'"ok":false'* ]]; then
  pass "a scan without its end line is refused"
else
  fail "a cut scan was accepted"
fi
# A key line cut by the byte bound is kept, as bash and Rust keep it (C1).
{ printf 'OMARCHY_CLOUD_ROOT=/srv/first\n'; for ((i = 0; i < 4039; i++)); do printf '\n'; done; printf 'OMARCHY_CLOUD_ROOT=/srv/cut-here-past-the-bound\n'; } >"$SETTING"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if [[ $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out") == '{"state":"valid","path":"/srv/cut","value":"/srv/cut"}' ]]; then
  pass "a key line cut by the byte bound is kept, and wins"
else
  fail "cut line: $(parse_setting "$SHOME" "$SSTATE" "$TOKEN" <<<"$out")"
fi
rm "$SETTING"

# The setting read alone (Model.SETTING_SCRIPT, on a poll while the root is
# not set up): the same read, the crafted HOME's path one argument, nothing in
# it or in the file runs, a FIFO skipped, a hung read cut and refused.
# setting_read <home> <token>: Model.settingArgv, NUL-separated.
setting_read_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { settingArgv }")()
    process.stdout.write(m.settingArgv(process.argv[2], process.argv[3]).map(a => a + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$1" "$2"
}
# parse_setting_read <home> <token>: rootSetting of Model.parseSettingRead over stdin, or "refused".
parse_setting_read() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { parseSettingRead, withSetting, rootSetting, emptyScan }")()
    const r = m.parseSettingRead(fs.readFileSync(0, "utf8"), process.argv[3])
    const scan = m.emptyScan(); scan.ok = true
    process.stdout.write(r.ok ? JSON.stringify(m.rootSetting(m.withSetting(scan, r.setting), process.argv[2])) : "refused")
  ' "$PLUGIN_DIR/Model.js" "$1" "$2"
}
mapfile -d '' -t argv < <(setting_read_argv "$SHOME" "$TOKEN")
if [[ ${argv[0]} == timeout && ${argv[4]} == sh && ${argv[5]} == -c && ${argv[8]} == "$TOKEN" && ${argv[9]} == "$SETTING" && ${#argv[@]} == 11 ]]; then
  pass "the setting read runs under timeout -k through sh, the path one argument"
else
  fail "setting read argv: ${argv[*]}"
fi
[[ ${argv[6]} == *"$SHOME"* ]] && fail "the home is inside the setting script"
if [[ $(cd "$SCRATCH/cwd" && "${argv[@]}" | parse_setting_read "$SHOME" "$TOKEN") == '{"state":"absent","path":"/mnt/cloud","value":""}' ]]; then
  pass "setting read: no cloud.env is absent"
else
  fail "setting read absent"
fi
printf 'OMARCHY_CLOUD_ROOT=/srv/$(touch PWNED)\nOMARCHY_CLOUD_ROOT=/srv/cloud\r\ncmscan-zzzzzzzzzzzz end\n' >"$SETTING"
if [[ $(cd "$SCRATCH/cwd" && "${argv[@]}" | parse_setting_read "$SHOME" "$TOKEN") == '{"state":"valid","path":"/srv/cloud","value":"/srv/cloud"}' ]]; then
  pass "setting read: Set up's file is read on the next poll, a forged end line is content"
else
  fail "setting read valid"
fi
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then
  fail "a command in the setting read ran"
else
  pass "nothing in the setting read ran"
fi
rm "$SETTING"
mkfifo "$SETTING"
start=$SECONDS
got=$(cd "$SCRATCH/cwd" && "${argv[@]}" | parse_setting_read "$SHOME" "$TOKEN")
if ((SECONDS - start < 5)) && [[ $got == *'"state":"absent"'* ]]; then
  pass "setting read: a FIFO is skipped, not read"
else
  fail "setting read FIFO: $got"
fi
rm "$SETTING"
printf 'OMARCHY_CLOUD_ROOT=/srv/cloud\n' >"$SETTING"
cut=("${argv[@]}")
cut[3]=1
start=$SECONDS
got=$(cd "$SCRATCH/cwd" && PATH=$HANGBIN:$PATH "${cut[@]}" 2>/dev/null | parse_setting_read "$SHOME" "$TOKEN")
if ((SECONDS - start < 5)) && [[ $got == refused ]]; then
  pass "setting read: a hung read is cut by timeout and refused"
else
  fail "hung setting read: $got after $((SECONDS - start)) s"
fi
rm "$SETTING"

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
if [[ ${argv[0]} == timeout && ${argv[4]} == sh && ${argv[5]} == -c && ${argv[8]} == "$TOKEN" && ${argv[11]} == "$VPLUG/manifest.json" &&
  ${argv[12]} == "$VSTATE/omarchy-cloud/installed-files" && ${argv[14]} == "$VPLUG/install.sh" ]]; then
  pass "the versions read runs under timeout -k through sh, paths positional"
else
  fail "versions argv: ${argv[*]}"
fi
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then
  fail "a command in the plugin or state path ran"
else
  pass "nothing in the plugin or state path ran"
fi
got=$(parse_versions "$TOKEN" <<<"$out")
want='{"ok":true,"plugin":"0.3.4","installedPresent":true,"installedVersion":"0.3.2","installedRepo":"/src/x","legacy":false,"installer":false,"state":"mismatch"}'
if ((status == 0)) && [[ $got == "$want" ]]; then
  pass "manifest.json and the header read through a symlink: mismatch"
else
  fail "versions parsed (status $status)"
  echo "     want: $want"
  echo "     got:  $got"
fi
printf 'x\n' >"$VSTATE/omarchy-cloud/installed-binary.sha256"
printf '#!/bin/sh\n' >"$VPLUG/install.sh"
rm "$VSTATE/omarchy-cloud/installed-files"
mkfifo "$VSTATE/omarchy-cloud/installed-files"
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
status=$?
got=$(parse_versions "$TOKEN" <<<"$out")
if ((status == 0 && SECONDS - start < 5)) && [[ $got == *'"installedPresent":false,'*'"legacy":true,"installer":true,"state":"unknown"}' ]]; then
  pass "a FIFO manifest is skipped; the legacy record and install.sh are found: unknown"
else
  fail "FIFO / legacy: status $status, $got"
fi
rm "$VSTATE/omarchy-cloud/installed-files" "$VSTATE/omarchy-cloud/installed-binary.sha256"
out=$(cd "$SCRATCH/cwd" && "${argv[@]}")
if [[ $(parse_versions "$TOKEN" <<<"$out") == *'"state":"none"}' ]]; then
  pass "nothing installed: none"
else
  fail "none: $(parse_versions "$TOKEN" <<<"$out")"
fi
cut=("${argv[@]}")
cut[3]=1
start=$SECONDS
out=$(cd "$SCRATCH/cwd" && PATH=$HANGBIN:$PATH "${cut[@]}" 2>/dev/null)
status=$?
if ((status == 124 && SECONDS - start < 5)) && [[ $(parse_versions "$TOKEN" <<<"$out") == *'"ok":false'* ]]; then
  pass "a hung versions read is cut by timeout and refused"
else
  fail "hung versions read: status $status after $((SECONDS - start)) s"
fi
# The install terminal's script, run as the terminal would run it (the argv
# after omarchy-launch-tui --app-id=TUI.float), Enter on stdin.
printf 'echo "stand-in install.sh ran with $# args"\nexit "${CM_EXIT:-0}"\n' >"$VPLUG/install.sh"
mapfile -d '' -t argv < <(install_argv "$VPLUG")
if [[ ${argv[0]} == omarchy-launch-tui && ${argv[1]} == --app-id=TUI.float && ${argv[2]} == bash && ${argv[3]} == -c && ${argv[6]} == "$VPLUG/install.sh" && ${#argv[@]} == 7 ]]; then
  pass "install argv: the floating terminal, a fixed script, install.sh as its own argument"
else
  fail "install argv: ${argv[*]}"
fi
out=$(cd "$SCRATCH/cwd" && printf '\n' | "${argv[@]:2}")
status=$?
if ((status == 0)) && grep -q '^stand-in install.sh ran with 0 args$' <<<"$out" && grep -q 'finished (exit status 0)' <<<"$out" && grep -q 'Press Enter to close' <<<"$out"; then
  pass "install.sh runs from \"\$1\", its exit status is shown, then Enter closes"
else
  fail "install script: status $status, $out"
fi
out=$(cd "$SCRATCH/cwd" && printf '\n' | CM_EXIT=3 "${argv[@]:2}")
if grep -q 'failed (exit status 3)' <<<"$out"; then
  pass "a failed install.sh shows its exit status"
else
  fail "failed install: $out"
fi
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then
  fail "a command in the plugin path ran"
else
  pass "nothing in the plugin path ran"
fi
# Without Enter the terminal stays: the script is still waiting.
# WAITER is the coproc's name; only the WAITER_PID it sets is read.
# shellcheck disable=SC2034
coproc WAITER { cd "$SCRATCH/cwd" && "${argv[@]:2}"; }
sleep 1
if kill -0 "$WAITER_PID" 2>/dev/null; then
  pass "the script waits for Enter after install.sh exits"
else
  fail "the script did not wait"
fi
kill "$WAITER_PID" 2>/dev/null
wait "$WAITER_PID" 2>/dev/null

# --- 7. the mount-root check and the bounded commands ------------------------
# model_argv <expr>: the argv a Model expression builds (process.argv[2...] as
# a, b, c), NUL-separated.
model_argv() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { rootCheckArgv, logArgv, pollArgv, parseRootCheck, parseBounded, logView, journalArgv, showArgv }")()
    const [a, b, c] = process.argv.slice(3)
    process.stdout.write(new Function("m", "a", "b", "c", "return " + process.argv[2])(m, a, b, c).map(x => x + "\0").join(""))
  ' "$PLUGIN_DIR/Model.js" "$@"
}
# model_eval <expr> < stdin: a Model expression over stdin (as s), printed.
model_eval() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const m = new Function(src + "\nreturn { parseRootCheck, parseBounded, logView }")()
    const s = fs.readFileSync(0, "utf8")
    const [a] = process.argv.slice(3)
    process.stdout.write(String(new Function("m", "s", "a", "return " + process.argv[2])(m, s, a)))
  ' "$PLUGIN_DIR/Model.js" "$@"
}
RHOME=$SCRATCH/roothome
mkdir -p "$RHOME" "$SCRATCH/roots"
for r in "$SCRATCH/roots/a;id>PWNED" "$SCRATCH/roots/(id)>PWNED|x&y" "$SCRATCH/roots/-n" "$SCRATCH/roots/ok"; do
  [[ $r == */ok ]] && mkdir -p "$r"
  mapfile -d '' -t argv < <(model_argv 'm.rootCheckArgv(a, b)' "$r" "$RHOME")
  if [[ ${argv[0]} != timeout || ${argv[4]} != sh || ${argv[5]} != -c || ${argv[-1]} != "$r" || ${#argv[@]} != 9 ]]; then
    fail "root check argv for $r: ${argv[*]}"
    continue
  fi
  [[ ${argv[6]} == *"$r"* ]] && fail "the root is inside the script: $r"
  got=$(cd "$SCRATCH/cwd" && "${argv[@]}" | model_eval 'm.parseRootCheck(s)')
  want=missing
  [[ $r == */ok ]] && want=ok
  if [[ $got == "$want" ]]; then
    pass "root check: $want for $(basename -- "$r")"
  else
    fail "root check for $r: $got"
  fi
done
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED || -n $(find "$SCRATCH/roots" -name PWNED) ]]; then
  fail "a command in a root ran"
else
  pass "nothing in a root ran"
fi
mapfile -d '' -t argv < <(model_argv 'm.rootCheckArgv(a, b)' "$RHOME/inside" "$RHOME")
if ((${#argv[@]} == 0)); then
  pass "a root inside HOME is never checked"
else
  fail "root inside HOME: ${argv[*]}"
fi
# BOUNDED_SCRIPT around a stand-in journalctl: argv intact, a forged end line
# (another token's, and this run's own mid-stream) is content, output capped.
BBIN=$SCRATCH/boundbin
mkdir -p "$BBIN"
cat >"$BBIN/journalctl" <<EOF2
#!/bin/sh
printf '%s\n' "\$@" >"$SCRATCH/journalctl.argv"
printf 'line one\ncmscan-zzzzzzzzzzzz end\n'
[ -n "\$CM_FLOOD" ] && yes 'flood flood flood'
[ -n "\$CM_HANG" ] && exec sleep 60
exit 0
EOF2
chmod +x "$BBIN/journalctl"
mapfile -d '' -t argv < <(model_argv 'm.logArgv(a, b)' "rclone-mount@gdrive.service" "$TOKEN")
mapfile -d '' -t want < <(model_argv 'm.journalArgv(a)' "rclone-mount@gdrive.service")
if [[ ${argv[0]} == timeout && ${argv[4]} == sh && ${argv[5]} == -c && ${argv[8]} == "$TOKEN" && "${argv[*]:10}" == "${want[*]}" ]]; then
  pass "the journal runs under timeout -k through the bounded script"
else
  fail "log argv: ${argv[*]}"
fi
# The output goes to a file: $(...) would drop the end line's newline.
BOUT=$SCRATCH/bounded.out
(cd "$SCRATCH/cwd" && PATH=$BBIN:$PATH "${argv[@]}") >"$BOUT"
if [[ $(<"$SCRATCH/journalctl.argv") == "$(printf '%s\n' "${want[@]:1}")" ]]; then
  pass "journalctl gets its argv intact"
else
  fail "journalctl argv: $(<"$SCRATCH/journalctl.argv")"
fi
got=$(model_eval 'm.logView(s, a)' "$TOKEN" <"$BOUT")
if [[ $got == $'line one\ncmscan-zzzzzzzzzzzz end' ]]; then
  pass "a finished journal is shown; another token's end line is content"
else
  fail "log view: $got"
fi
start=$SECONDS
(cd "$SCRATCH/cwd" && CM_FLOOD=1 PATH=$BBIN:$PATH "${argv[@]}") >"$BOUT"
cap=$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");console.log(new Function(s+"\nreturn LOG_READ_MAX_BYTES")())' "$PLUGIN_DIR/Model.js")
n=$(($(wc -c <"$BOUT") - ${#TOKEN} - 6))
if ((SECONDS - start < 5 && n == cap)) && [[ $(model_eval 'm.parseBounded(s, a, '"$cap"').ok' "$TOKEN" <"$BOUT") == true ]]; then
  pass "a flooding journal is cut at $cap bytes at the source"
else
  fail "flood: $n bytes (cap $cap) after $((SECONDS - start)) s"
fi
cut=("${argv[@]}")
cut[3]=1
start=$SECONDS
(cd "$SCRATCH/cwd" && CM_HANG=1 PATH=$BBIN:$PATH "${cut[@]}") >"$BOUT"
status=$?
got=$(model_eval 'm.logView(s, a)' "$TOKEN" <"$BOUT")
if ((status == 124 && SECONDS - start < 5)) && [[ $got == "Log timed out" ]]; then
  pass "a hung journalctl is cut by timeout: Log timed out"
else
  fail "hung journal: status $status, $got"
fi
# The poll the same way: a hung systemctl leaves no answer to apply.
cat >"$BBIN/systemctl" <<EOF2
#!/bin/sh
printf 'Id=default.target\n\n'
exec sleep 60
EOF2
chmod +x "$BBIN/systemctl"
mapfile -d '' -t argv < <(model_argv 'm.pollArgv([a], b)' "gdrive" "$TOKEN")
cut=("${argv[@]}")
cut[3]=1
start=$SECONDS
(cd "$SCRATCH/cwd" && PATH=$BBIN:$PATH "${cut[@]}") >"$BOUT"
status=$?
if ((status == 124 && SECONDS - start < 5)) && [[ $(model_eval 'm.parseBounded(s, a, 262144).ok' "$TOKEN" <"$BOUT") == false ]]; then
  pass "a hung systemctl show is cut by timeout and its answer refused"
else
  fail "hung poll: status $status"
fi
if [[ -e $SCRATCH/cwd/PWNED || -e PWNED ]]; then
  fail "a command ran"
else
  pass "nothing ran"
fi

if ((FAILURES)); then
  echo "FAILED $FAILURES shell-string tests"
  exit 1
fi
echo "passed all shell-string tests"
