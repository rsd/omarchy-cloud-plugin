#!/bin/bash

# Everything that can be checked without the running shell: manifest
# validation, QML syntax and type checks against the shell's own qs.Ui /
# qs.Commons modules, loading the components in a throwaway Quickshell (skipped
# outside a Wayland session), one real read-only poll through the singleton,
# the model logic, the three shell strings run through a real shell, the busy
# check against the real fuser, and the plugin folder's layout. Then, when
# they exist, the helper scripts' suite (tests/scripts-test.sh), install.sh's
# (tests/install-test.sh), shellcheck over install.sh, bin/* and tests/*.sh
# (with a self-test that it can fail; skipped when no working shellcheck is
# found) and the omarchy-cloud app's `cargo test` and `cargo clippy`, built
# under ${XDG_CACHE_HOME:-~/.cache}/omarchy-cloud/target, never inside the repo.
#
# Nothing here starts, stops or enables a unit, touches the live shell, or
# writes under ~/.config. The scratch Quickshell runs are stopped by the PID
# this script started, never by name or pattern.

set -o pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SHELL_DIR=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
QMLLINT=/usr/lib/qt6/bin/qmllint
FAILURES=0

SKIPPED=0
SKIP=77   # a suite function returns this when it cannot run here

run() {
  local name=$1 status
  shift
  echo "== $name"
  "$@"
  status=$?
  if ((status == 0)); then
    echo "-- $name passed"
  elif ((status == SKIP)); then
    echo "-- $name SKIPPED (not checked)"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "-- $name FAILED"
    FAILURES=$((FAILURES + 1))
  fi
  echo
}

have_qt_lint() {
  [[ -x $QMLLINT && -d $SHELL_DIR/Ui && -d $SHELL_DIR/Commons ]]
}

skip_qt_lint() {
  echo "skipped: need $QMLLINT and the shell sources in $SHELL_DIR (OMARCHY_SHELL_DIR overrides)"
}

# Qt6's linter (/usr/bin/qmllint is Qt5's and rejects valid Qt6 QML) against
# a throwaway shim laid out as <root>/qs/Ui, built outside the plugin because a
# symlink inside a plugin folder is grounds for the shell to refuse it. Judged
# from --json by tests/qmllint-check.js (Qt 6.12's text output drops [import]
# and [unresolved-type] from files with a loop). Fatal: a non-zero exit, any
# syntax / import / unresolved-type warning anywhere, and any other warning in
# a file other than BarWidget.qml except block-scope-var-declaration.
#
# qml_lint [dir] lints the *.qml in dir (default: the plugin).
qml_lint() {
  local dir=${1:-$PLUGIN_DIR}
  if ! have_qt_lint || ! command -v node >/dev/null; then
    skip_qt_lint
    return $SKIP
  fi

  local shim json status
  shim=$(mktemp -d) || return 1
  mkdir -p "$shim/qs"
  ln -s "$SHELL_DIR/Ui" "$shim/qs/Ui"
  ln -s "$SHELL_DIR/Commons" "$shim/qs/Commons"

  local files=("$dir"/*.qml)
  json=$("$QMLLINT" --json - -I "$shim" -I /usr/lib/qt6/qml "${files[@]}" 2>"$shim/stderr")
  status=$?
  if ((status != 0)); then
    head -10 "$shim/stderr"
    echo "qmllint exit status $status"
    rm -rf "$shim"
    return 1
  fi
  rm -rf "$shim"
  node "$PLUGIN_DIR/tests/qmllint-check.js" <<<"$json"
}

# The lint check must be able to fail: an unknown type injected into
# BarWidget.qml and then into CloudState.qml must each be caught, while the
# untouched copy passes.
qml_lint_selftest() {
  if ! have_qt_lint || ! command -v node >/dev/null; then
    skip_qt_lint
    return $SKIP
  fi

  local scratch ok=0 out case
  scratch=$(mktemp -d) || return 1
  for case in clean bar state; do
    mkdir "$scratch/$case"
    cp "$PLUGIN_DIR"/*.qml "$PLUGIN_DIR"/Model.js "$PLUGIN_DIR"/qmldir "$scratch/$case/"
  done
  if out=$(qml_lint "$scratch/clean"); then
    echo "ok   untouched copy passes"
  else
    echo "FAIL untouched copy should pass:"
    echo "$out"
    ok=1
  fi

  sed -i 's/^  BarIconButton {/  BarIconButtonX {/' "$scratch/bar/BarWidget.qml"
  sed -i 's/^  Timer {/  TimerX {/' "$scratch/state/CloudState.qml"
  if cmp -s "$PLUGIN_DIR/BarWidget.qml" "$scratch/bar/BarWidget.qml" ||
    cmp -s "$PLUGIN_DIR/CloudState.qml" "$scratch/state/CloudState.qml"; then
    echo "FAIL the self-test could not inject its unknown type (source changed?)"
    ok=1
  fi
  for case in bar state; do
    if out=$(qml_lint "$scratch/$case"); then
      echo "FAIL unknown type in the $case copy was not caught"
      ok=1
    elif ! grep -q 'X.*\[\(import\|unresolved-type\)\]' <<<"$out"; then
      echo "FAIL the $case copy failed, but not on its unknown type:"
      echo "$out"
      ok=1
    else
      echo "ok   unknown type in the $case copy fails: $(head -1 <<<"$out")"
    fi
  done
  rm -rf "$scratch"
  return $ok
}

# qmllint passes files the engine refuses, so load the widget the way the shell
# does, by absolute file:// URL, in a throwaway Quickshell (a temporary config:
# shell.qml plus symlinks to the shell's Commons and Ui, outside the plugin)
# that creates no windows, calls Qt.createComponent on BarWidget.qml (which
# pulls CloudState through the directory's qmldir), logs READY or ERROR and
# quits. Fatal: an ERROR, any qt.qml warning, no report, or no "done" line
# within LOAD_TIMEOUT_S.
LOAD_TIMEOUT_S=20

have_qs_load() {
  command -v qs >/dev/null && [[ -n ${WAYLAND_DISPLAY:-} && -d $SHELL_DIR/Ui && -d $SHELL_DIR/Commons ]]
}

skip_qs_load() {
  echo "skipped: need qs on PATH, a Wayland session (WAYLAND_DISPLAY) and the shell sources in $SHELL_DIR"
}

# scratch_qs <cfg dir> <marker> [env assignments...]: runs qs on cfg in the
# background, waits for "<marker> DONE" or the timeout, then stops it by PID.
scratch_qs() {
  local cfg=$1 marker=$2 pid i
  shift 2
  env "$@" qs --no-color -p "$cfg" >"$cfg/log" 2>&1 &
  pid=$!
  # A background job of a non-interactive shell ignores SIGINT: stop it here.
  trap 'kill "$pid" 2>/dev/null; rm -rf "$cfg"; exit 130' INT TERM
  for ((i = 0; i < LOAD_TIMEOUT_S * 10; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    grep -q "$marker DONE" "$cfg/log" && break
    sleep 0.1
  done
  for ((i = 0; i < 20; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    sleep 0.5
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  trap - INT TERM
}

qml_load() {
  local dir=${1:-$PLUGIN_DIR}
  if ! have_qs_load; then
    skip_qs_load
    return $SKIP
  fi

  local cfg ok=0
  cfg=$(mktemp -d) || return 1
  ln -s "$SHELL_DIR/Commons" "$cfg/Commons"
  ln -s "$SHELL_DIR/Ui" "$cfg/Ui"
  cat >"$cfg/shell.qml" <<'EOF'
import QtQuick
import Quickshell
ShellRoot {
  Component.onCompleted: {
    var f = Quickshell.env("CM_LOAD_FILE")
    var url = "file://" + f.split("/").map(encodeURIComponent).join("/")
    var c = Qt.createComponent(url, Component.PreferSynchronous)
    var ready = c.status === Component.Ready
    console.log("CMLOAD " + (ready ? "READY " : "ERROR ") + f
      + (ready ? "" : " :: " + c.errorString().replace(/\n/g, " | ")))
    console.log("CMLOAD DONE")
    Qt.callLater(Qt.quit)
  }
}
EOF
  scratch_qs "$cfg" CMLOAD "CM_LOAD_FILE=$dir/BarWidget.qml"

  if ! grep -q 'CMLOAD DONE' "$cfg/log"; then
    echo "FAIL qs did not report within ${LOAD_TIMEOUT_S} s; its log:"
    tail -15 "$cfg/log"
    ok=1
  fi
  if grep -q 'WARN.*qt\.qml' "$cfg/log"; then
    grep 'WARN.*qt\.qml' "$cfg/log" | sed 's/^ *WARN */FAIL engine warning: /' | cut -c1-300
    ok=1
  fi
  if grep -qF "CMLOAD READY $dir/BarWidget.qml" "$cfg/log"; then
    echo "ok   BarWidget.qml loads (with CloudState.qml through qmldir)"
  elif grep -qF "CMLOAD ERROR $dir/BarWidget.qml" "$cfg/log"; then
    echo "FAIL BarWidget.qml: $(grep -F "CMLOAD ERROR" "$cfg/log" | sed 's/.* :: //' | cut -c1-400)"
    ok=1
  else
    echo "FAIL BarWidget.qml was not reported"
    ok=1
  fi
  rm -rf "$cfg"
  return $ok
}

# The load check must be able to fail: a copy whose BarWidget.qml declares a
# property twice (an engine refusal qmllint does not flag as fatal) and one
# whose CloudState.qml has a syntax error must both fail.
qml_load_selftest() {
  if ! have_qs_load; then
    skip_qs_load
    return $SKIP
  fi
  local scratch out ok=0 case
  scratch=$(mktemp -d) || return 1
  for case in dup state; do
    mkdir "$scratch/$case"
    cp "$PLUGIN_DIR"/*.qml "$PLUGIN_DIR"/Model.js "$PLUGIN_DIR"/qmldir "$scratch/$case/"
  done
  sed -i 's/^  property string logText: ""$/&\n  property string logText: ""/' "$scratch/dup/BarWidget.qml"
  sed -i 's/^  function refresh() {$/  function refresh() {{/' "$scratch/state/CloudState.qml"
  if cmp -s "$PLUGIN_DIR/BarWidget.qml" "$scratch/dup/BarWidget.qml" ||
    cmp -s "$PLUGIN_DIR/CloudState.qml" "$scratch/state/CloudState.qml"; then
    echo "FAIL the self-test could not inject its fault (source changed?)"
    rm -rf "$scratch"
    return 1
  fi
  for case in dup state; do
    if out=$(qml_load "$scratch/$case"); then
      echo "FAIL the $case fault was not caught"
      ok=1
    else
      echo "ok   the $case fault fails: $(grep FAIL <<<"$out" | head -1 | cut -c1-200)"
    fi
  done
  rm -rf "$scratch"
  return $ok
}

# The widget and its singleton running for real, read-only: a scratch
# Quickshell creates BarWidget.qml (its panel is never opened, so no window is
# shown), which attaches to CloudState and so runs one `systemctl --user show`
# and one scan (the offline-folder and backup config and state files, read
# only); the script also takes a panel hold on the same singleton through a
# stand-in owner, which runs one `du -s -B1` over the VFS cache dirs. Nothing
# is started, stopped or written. Checks that the singleton the script imports
# is the widget's (one instance), that the poll answers (its sentinel unit),
# that every remote, pair and job passes the name check, that the scan
# finished, that the cache sizes arrive, and that no binding throws
# (TypeError / ReferenceError) or the engine warns. Skipped without a systemd
# user manager.
widget_live() {
  local dir=${1:-$PLUGIN_DIR}
  if ! have_qs_load; then
    skip_qs_load
    return $SKIP
  fi
  if ! systemctl --user show -p Version --value >/dev/null 2>&1; then
    echo "skipped: no systemd user manager reachable"
    return $SKIP
  fi
  # The path goes into generated QML; a quote or backslash would break it.
  if [[ $dir == *[\"\\]* ]]; then
    echo "skipped: plugin path contains a quote or backslash"
    return $SKIP
  fi
  local cfg ok=0 line
  cfg=$(mktemp -d) || return 1
  ln -s "$SHELL_DIR/Commons" "$cfg/Commons"
  ln -s "$SHELL_DIR/Ui" "$cfg/Ui"
  cat >"$cfg/shell.qml" <<EOF
import QtQuick
import Quickshell
import "file://$dir" as Plugin
import "file://$dir/Model.js" as Model
ShellRoot {
  id: shell
  QtObject { id: holder }
  property var widget: null
  property bool reported: false
  property bool sized: false
  Component.onCompleted: {
    var c = Qt.createComponent("file://$dir/BarWidget.qml", Component.PreferSynchronous)
    if (c.status !== Component.Ready) {
      console.log("CMLIVE ERROR " + c.errorString().replace(/\n/g, " | "))
      console.log("CMLIVE DONE")
      Qt.callLater(Qt.quit)
      return
    }
    shell.widget = c.createObject(shell, {})
    console.log("CMLIVE instance " + (typeof Plugin.CloudState.attach === "function")
      + " shared " + (Plugin.CloudState.attached.indexOf(shell.widget) !== -1))
    Plugin.CloudState.holdOpen(holder)
  }
  Connections {
    target: Plugin.CloudState
    // Later: this handler was connected before the widget's bindings were.
    function onSizesChanged() { shell.sized = true; shell.maybeReport() }
    function onScannedChanged() { shell.maybeReport() }
  }
  function maybeReport() {
    var s = Plugin.CloudState
    if (s.polled && s.scanned && (shell.sized || s.remotes.length === 0)) Qt.callLater(shell.report)
  }
  function report() {
    if (shell.reported) return
    shell.reported = true
    var s = Plugin.CloudState
    var w = shell.widget
    var bad = s.remotes.concat(s.pairs, s.jobs).filter(function(r) { return !Model.isValidRemote(r) })
    var sized = w.rows.filter(function(r) { return r.cacheBytes >= 0 }).length
    console.log("CMLIVE polled " + s.polled + " remotes " + s.remotes.length + " bad " + bad.length
      + " sentinel " + (s.units[Model.SENTINEL_UNIT] !== undefined)
      + " scanned " + s.scanned + " pairs " + w.pairRows.length + " jobs " + w.jobRows.length
      + " rows " + w.rows.length + " sized " + sized + " agg " + w.agg)
    // The cursor walks (never activates: that would start or stop a unit).
    var first = w.cursorAt
    w.cursorActive = true
    w.moveCursor(0, 1)
    console.log("CMLIVE cursor names " + (w.rowNames.length === w.rows.length)
      + " first " + (w.rows.length === 0 || first === Model.cursorKey("switch", w.rows[0].name))
      + " moved " + (w.cursorGroups.length < 2 || w.cursorAt !== first))
    s.releaseOpen(holder)
    w.destroy()
    console.log("CMLIVE DONE")
    Qt.callLater(Qt.quit)
  }
  Timer { interval: 10000; running: true; onTriggered: shell.report() }
}
EOF
  scratch_qs "$cfg" CMLIVE
  if ! grep -q 'CMLIVE instance true shared true' "$cfg/log"; then
    echo "FAIL the script's CloudState is not the widget's singleton instance:"
    grep 'CMLIVE' "$cfg/log" | head -3
    ok=1
  fi
  line=$(grep -o 'CMLIVE polled.*' "$cfg/log" | head -1)
  if [[ $line =~ polled\ true\ remotes\ ([0-9]+)\ bad\ 0\ sentinel\ true\ scanned\ true\ pairs\ ([0-9]+)\ jobs\ ([0-9]+)\ rows\ ([0-9]+)\ sized\ ([0-9]+)\ agg\ ([a-z]+) ]] &&
    [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[4]}" ]] && ((BASH_REMATCH[5] > 0 || BASH_REMATCH[4] == 0)); then
    echo "ok   one real poll: ${BASH_REMATCH[1]} remote(s), all names valid, the sentinel unit answered"
    echo "ok   one scan: ${BASH_REMATCH[2]} offline folder(s), ${BASH_REMATCH[3]} backup(s)"
    echo "ok   one du: cache size for ${BASH_REMATCH[5]} of ${BASH_REMATCH[4]} remote(s); bar state '${BASH_REMATCH[6]}'"
  else
    echo "FAIL report: ${line:-none}"
    tail -10 "$cfg/log"
    ok=1
  fi
  if grep -q 'CMLIVE cursor names true first true moved true' "$cfg/log"; then
    echo "ok   rows keyed by name; the cursor starts on the first switch and Down moves it"
  else
    echo "FAIL cursor: $(grep -o 'CMLIVE cursor.*' "$cfg/log" | head -1)"
    ok=1
  fi
  if grep -q 'WARN.*qt\.qml\|TypeError\|ReferenceError\|CMLIVE ERROR' "$cfg/log"; then
    grep 'WARN.*qt\.qml\|TypeError\|ReferenceError\|CMLIVE ERROR' "$cfg/log" | head -5 | sed 's/^ */FAIL /' | cut -c1-300
    ok=1
  else
    echo "ok   no binding threw and the engine did not warn"
  fi
  rm -rf "$cfg"
  return $ok
}

run "manifest validation" omarchy plugin validate "$PLUGIN_DIR"
run "qmllint (qt6)" qml_lint
run "qmllint self-test (injected unknown type)" qml_lint_selftest
run "QML load (scratch qs)" qml_load
run "QML load self-test (injected faults)" qml_load_selftest
run "widget and singleton live, read-only (scratch qs)" widget_live
run "model" node "$PLUGIN_DIR/tests/model-test.js"
run "shell strings through a real shell" bash "$PLUGIN_DIR/tests/process-pattern-test.sh"
run "busy check against the real fuser (own sleep on /dev/shm)" node "$PLUGIN_DIR/tests/fuser-live-test.js"
run "manifest and layout" node "$PLUGIN_DIR/tests/manifest-test.js"

# --- the other parts of the repo: each skipped, with its reason, when absent.

scripts_suite() {
  local t=$PLUGIN_DIR/tests/scripts-test.sh
  if [[ ! -e $t ]]; then
    echo "skipped: tests/scripts-test.sh does not exist"
    return $SKIP
  fi
  if [[ ! -x $t ]]; then
    echo "skipped: tests/scripts-test.sh is not executable"
    return $SKIP
  fi
  "$t"
}

install_suite() {
  local t=$PLUGIN_DIR/tests/install-test.sh
  if [[ ! -e $t ]]; then
    echo "skipped: tests/install-test.sh does not exist"
    return $SKIP
  fi
  if [[ ! -x $t ]]; then
    echo "skipped: tests/install-test.sh is not executable"
    return $SKIP
  fi
  "$t"
}

# cargo from PATH, else ~/.cargo/bin (rustup's default, often not on a
# non-login PATH).
find_cargo() {
  if command -v cargo >/dev/null; then
    command -v cargo
  elif [[ -x $HOME/.cargo/bin/cargo ]]; then
    echo "$HOME/.cargo/bin/cargo"
  else
    return 1
  fi
}

# app_cargo <test|clippy>: the app's suite or its lints (warnings fatal).
# --locked: the lock file is the source of truth (install.sh builds with it);
# without one, cargo would write it into the repo, so the suite is skipped.
app_cargo() {
  local what=$1 cargo manifest=$PLUGIN_DIR/app/Cargo.toml
  if [[ ! -f $manifest ]]; then
    echo "skipped: app/Cargo.toml does not exist"
    return $SKIP
  fi
  if [[ ! -f $PLUGIN_DIR/app/Cargo.lock ]]; then
    echo "skipped: app/Cargo.lock does not exist (cargo would create it in the repo)"
    return $SKIP
  fi
  if ! cargo=$(find_cargo); then
    echo "skipped: cargo not found on PATH or in ~/.cargo/bin"
    return $SKIP
  fi
  local -x CARGO_TARGET_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-cloud/target"
  local -x PATH="${cargo%/*}:$PATH"
  case $what in
    test)
      "$cargo" test --locked --manifest-path "$manifest"
      ;;
    clippy)
      if ! "$cargo" clippy --version >/dev/null 2>&1; then
        echo "skipped: cargo clippy is not installed (rustup component add clippy)"
        return $SKIP
      fi
      "$cargo" clippy --locked --manifest-path "$manifest" --all-targets -- -D warnings
      ;;
  esac
}

# Finds a working shellcheck and sets SHELLCHECK_BIN: $SHELLCHECK if set, else
# `shellcheck` on PATH, else the newest mise install. A candidate counts only if
# `--version` exits 0 (a mise shim with no version set is on PATH and fails).
# Returns 1, with what was tried on stdout, when none works.
SHELLCHECK_BIN=
find_shellcheck() {
  local c tried=() installs=()
  SHELLCHECK_BIN=
  if [[ -n ${SHELLCHECK:-} ]]; then
    if "$SHELLCHECK" --version >/dev/null 2>&1; then
      SHELLCHECK_BIN=$SHELLCHECK
      return 0
    fi
    echo "skipped: \$SHELLCHECK=$SHELLCHECK does not run (--version failed)"
    return 1
  fi
  if c=$(command -v shellcheck); then
    if "$c" --version >/dev/null 2>&1; then
      SHELLCHECK_BIN=$c
      return 0
    fi
    tried+=("$c (--version failed)")
  else
    tried+=("shellcheck not on PATH")
  fi
  mapfile -t installs < <(printf '%s\n' \
    "$HOME"/.local/share/mise/installs/shellcheck/*/shellcheck*/shellcheck \
    "$HOME"/.local/share/mise/installs/shellcheck/*/shellcheck | sort -V -r)
  for c in "${installs[@]}"; do
    [[ -x $c ]] || continue
    if "$c" --version >/dev/null 2>&1; then
      SHELLCHECK_BIN=$c
      return 0
    fi
    tried+=("$c (--version failed)")
  done
  tried+=("no runnable ~/.local/share/mise/installs/shellcheck/*/shellcheck*/shellcheck")
  local IFS=';'
  echo "skipped: no working shellcheck (set SHELLCHECK to one); tried: ${tried[*]}"
  return 1
}

# Usage: shellcheck_check [dir]. Checks install.sh, bin/* and tests/*.sh of dir
# (default: the plugin), globbed now so a new script is included, at default
# severity. Any finding is printed (gcc format) and fails.
shellcheck_check() {
  local dir=${1:-$PLUGIN_DIR} f out status
  local files=()
  find_shellcheck || return $SKIP
  for f in "$dir/install.sh" "$dir"/bin/* "$dir"/tests/*.sh; do
    [[ -f $f ]] && files+=("$f")
  done
  if ((${#files[@]} == 0)); then
    echo "FAIL no scripts found to check under $dir"
    return 1
  fi
  out=$("$SHELLCHECK_BIN" -f gcc "${files[@]}" 2>&1)
  status=$?
  if ((status != 0)); then
    echo "$out"
    echo "shellcheck exit status $status in ${#files[@]} file(s)"
    return 1
  fi
  echo "ok   $("$SHELLCHECK_BIN" --version | sed -n 's/^version: /shellcheck /p'): ${#files[@]} file(s) clean"
}

# The check must be able to fail: a clean scratch copy passes, then an unquoted
# `echo $1` injected into one script must be reported (SC2086).
shellcheck_selftest() {
  local scratch out ok=0
  find_shellcheck || return $SKIP
  scratch=$(mktemp -d) || return 1
  mkdir "$scratch/tests"
  cp "$PLUGIN_DIR/tests/run.sh" "$scratch/tests/run.sh"
  if out=$(shellcheck_check "$scratch"); then
    echo "ok   untouched copy passes"
  else
    echo "FAIL untouched copy should pass:"
    echo "$out"
    ok=1
  fi
  # The literal, unquoted $1 is the injected finding.
  # shellcheck disable=SC2016
  printf '\necho $1\n' >>"$scratch/tests/run.sh"
  if out=$(shellcheck_check "$scratch"); then
    echo "FAIL an injected unquoted \$1 was not caught"
    ok=1
  elif grep -q 'SC2086' <<<"$out"; then
    echo "ok   an injected unquoted \$1 fails: $(grep SC2086 <<<"$out" | head -1 | sed "s|$scratch/||")"
  else
    echo "FAIL the injected copy failed, but not on SC2086:"
    echo "$out"
    ok=1
  fi
  rm -rf "$scratch"
  return $ok
}

run "helper scripts (tests/scripts-test.sh)" scripts_suite
run "install.sh (tests/install-test.sh)" install_suite
run "shellcheck (install.sh, bin/*, tests/*.sh)" shellcheck_check
run "shellcheck self-test (injected unquoted variable)" shellcheck_selftest
run "omarchy-cloud app: cargo test" app_cargo test
run "omarchy-cloud app: cargo clippy -D warnings" app_cargo clippy

if ((FAILURES)); then
  echo "$FAILURES suite(s) failed"
  exit 1
fi
if ((SKIPPED)); then
  echo "all suites that could run passed; $SKIPPED skipped (not checked)"
else
  echo "all suites passed"
fi
