// Pure model for the Cloud Mounts bar widget: every parse, validation, argv,
// state aggregation and formatted string the QML shows comes out of a function
// here, so tests/model-test.js can cover it under node without a running shell.
//
// Written as a QML JS module (bare declarations, no exports). The node test
// evaluates the source and lifts the names out, as power-watch's and omavnc's
// model tests do.
//
// What it controls (and never changes): rclone remotes, each mounted by the
// systemd user template unit rclone-mount@<remote>.service at
// /mnt/cloud/<remote>, linked from ~/Cloud/<remote>; offline folders, one
// rclone-bisync@<pair>.{service,timer,path} per ~/.config/rclone-bisync/<pair>.conf;
// and backups, one rclone-backup@<job>.{service,timer} per
// ~/.config/rclone-backup/<job>.conf. No instance name is written here: all
// of them are discovered (unit globs, config file names) and validated.
//
// Every command is an argv array; a remote, pair or job name reaches one only
// after isValidRemote. The three shell scripts (PENDING_SCRIPT, FUSER_SCRIPT,
// SCAN_SCRIPT) are constants and take their values as positional parameters;
// all run under `timeout -k`, so a hung FUSE mount or a FIFO cannot leave them
// behind.

// ---------------------------------------------------------------- constants

// A remote, pair or job name: the one pattern the helper scripts and the TUI
// validate with too, exactly. No leading dash (an option to whatever receives
// it) or dot, no "/" (so "." and ".." can never be a path segment, and ".."
// inside a name is just two dots), no glob or shell metacharacter, no
// whitespace, nothing outside ASCII.
var REMOTE_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/

var UNIT_PREFIX = "rclone-mount@"
var UNIT_SUFFIX = ".service"
// Passed to systemctl as one literal argument (no shell expands it):
// systemctl matches it against the units it has loaded, which is how remotes
// with no env file are found.
var UNIT_GLOB = "rclone-mount@*.service"
var MOUNT_ROOT = "/mnt/cloud"

// Relative to $HOME.
var CLOUD_LINKS = "Cloud"
var ENV_DIR = ".config/rclone-mount"
var CACHE_DIR = ".cache/rclone/vfs"
var META_DIR = ".cache/rclone/vfsMeta"
var BISYNC_CONF_DIR = ".config/rclone-bisync"
var BACKUP_CONF_DIR = ".config/rclone-backup"
// The omarchy-cloud TUI, as install.sh installs it.
var APP_BIN = ".local/bin/omarchy-cloud"
// Under ${XDG_STATE_HOME:-~/.local/state}, as bin/rclone-bisync and
// bin/rclone-backup write them: <dir>/<name>.state.
var STATE_DEFAULT = ".local/state"
var BISYNC_STATE_DIR = "rclone-bisync"
var BACKUP_STATE_DIR = "rclone-backup"

// Offline folders (bisync pairs) and backup jobs: template instances, found by
// the same literal globs (systemctl matches them, no shell expands them) and
// never named one by one (see showArgv).
var BISYNC_PREFIX = "rclone-bisync@"
var BACKUP_PREFIX = "rclone-backup@"
var BISYNC_KINDS = ["service", "timer", "path"]
var BACKUP_KINDS = ["service", "timer"]
var BISYNC_GLOBS = ["rclone-bisync@*.service", "rclone-bisync@*.timer", "rclone-bisync@*.path"]
var BACKUP_GLOBS = ["rclone-backup@*.service", "rclone-backup@*.timer"]
// The two service templates install.sh links, looked up by the scan with
// `systemctl --user list-unit-files` (systemctl show refuses a template name
// outright, failing the whole call): whether Sync now and the backups can work
// at all while no instance is loaded.
var BISYNC_TEMPLATE = "rclone-bisync@.service"
var BACKUP_TEMPLATE = "rclone-backup@.service"
var TEMPLATE_MAX_LINES = 8
// Always loaded in a user manager: the poll names it so that an answer
// without it is a failed poll, even on a machine with no instance at all.
var SENTINEL_UNIT = "default.target"

var SHOW_PROPS = ["Id", "LoadState", "ActiveState", "SubState", "Result", "UnitFileState",
  "ExecMainStatus", "ExecMainExitTimestamp", "InactiveEnterTimestamp", "ActiveEnterTimestamp",
  "NextElapseUSecRealtime"]

// Timings.
var POLL_MS = 5000        // systemd state, one batched systemctl show
var DU_MIN_MS = 60000     // cache sizes: only while a panel is open, at most this often
var SETTLE_MS = 1200      // re-poll this long after an action
// The stop checks run under `timeout -k CHECK_KILL_S CHECK_TIMEOUT_S`; the
// widget's own deadline (CHECK_DEADLINE_MS) is past both, so timeout answers
// first and the widget's timer only covers a process that ignores SIGKILL
// (a task stuck in D state on a hung mount).
var CHECK_TIMEOUT_S = 10
var CHECK_KILL_S = 2
var CHECK_DEADLINE_MS = (CHECK_TIMEOUT_S + CHECK_KILL_S + 2) * 1000

// Bounds.
var MAX_REMOTES = 32
var MAX_PAIRS = 16
var MAX_JOBS = 16
var SHOW_MAX_CHARS = 262144
var SHOW_MAX_UNITS = 256
var DU_MAX_CHARS = 65536
var FUSER_MAX_CHARS = 65536
var MAX_BUSY_SHOWN = 8
var MAX_CONFLICTS_SCANNED = 200
var MAX_CONFLICTS_SHOWN = 5
var LOG_LINES = 20
var LOG_LINE_MAX = 240
var LOG_MAX_CHARS = 4000
var NAME_MAX_CHARS = 120
var PENDING_MAX_FILES = 100000
// The config and state scan: at most SCAN_MAX_FILES files, the first
// SCAN_FILE_MAX_BYTES of each (a larger one is marked truncated), at most
// SCAN_FILE_MAX_LINES lines kept per file; output past SCAN_MAX_CHARS is
// refused whole.
var SCAN_FILE_MAX_BYTES = 8192
var SCAN_MAX_FILES = 2 * (MAX_PAIRS + MAX_JOBS)
var SCAN_FILE_MAX_LINES = 400
var SCAN_MAX_CHARS = SCAN_MAX_FILES * (SCAN_FILE_MAX_BYTES + 512) + 4096
// A state file this much older than the unit's own last exit belongs to an
// earlier run (the script writes it just before it exits).
var STATE_SKEW_S = 5

// Counts the rclone VFS cache items with an upload still pending: each cached
// file has a JSON metadata file under vfsMeta/<remote>/ whose "Dirty" field is
// true until rclone has written it back. Only the count leaves the pipeline,
// so the output is bounded whatever the cache holds. The directory is "$1";
// nothing is interpolated into the script. A cache that cannot be read (grep
// exits 2, or the pipeline dies) prints "unknown", never 0: a missing
// directory is the only "no cache, nothing pending" (0); 141 is grep cut off
// by the head bound, so the count is already at the bound.
var PENDING_SCRIPT = "[ -e \"$1\" ] || { echo 0; exit; }; "
  + "n=$(grep -rlE -e '\"Dirty\"[[:space:]]*:[[:space:]]*true' -- \"$1\" 2>/dev/null | head -n "
  + PENDING_MAX_FILES + " | wc -l; exit \"${PIPESTATUS[0]}\"); "
  + "case $? in 0|1|141) echo \"$n\";; *) echo unknown;; esac"

// Who has files open on the mount "$1". psmisc fuser (23.7) writes the PIDs
// and the "kernel" token to stdout and the rest of each -v row (the name,
// USER, ACCESS, COMMAND) to stderr, so neither stream alone is the table: 2>&1
// merges them, and psmisc flushes per field, so the merged order is the table
// the terminal shows (captured in tests/model-test.js). The exit line marks a
// run that finished: output cut by timeout (or by the size bound) has none and
// reads as "could not check".
var FUSER_EXIT_TAG = "cloud-mounts-fuser-exit"
var FUSER_SCRIPT = "fuser -v -M -m \"$1\" 2>&1; echo \"" + FUSER_EXIT_TAG + " $?\""

// The offline-folder and backup files, read in one process: the *.conf in the
// two config directories and the *.state in the two state directories (the
// directories are "$5"...), regular files only (a symlink is followed, as the
// helper scripts follow it, and read only when it ends at a regular file: a
// FIFO, device, directory or dangling link is skipped), at most "$3" files,
// the first "$2" bytes of each, each preceded by its byte size; whether the
// TUI binary "$4" is installed; and the list-unit-files lines of the two
// service templates (constants, at most TEMPLATE_MAX_LINES lines). Every
// marker line starts with "$1", a token the widget draws at random for each
// run, so no file content, file name or systemctl line can forge one; the
// "end" line marks a run that finished. Nothing is interpolated into the
// script: paths and bounds are positional parameters, and the only expansions
// are of the script's own variables.
var SCAN_SCRIPT = [
  "t=$1 c=$2 m=$3 a=$4",
  "shift 4",
  "[ -f \"$a\" ] && [ -x \"$a\" ] && printf '%s app\\n' \"$t\"",
  "systemctl --user list-unit-files --no-legend --plain -- '" + BISYNC_TEMPLATE + "' '" + BACKUP_TEMPLATE
    + "' 2>/dev/null | head -n " + TEMPLATE_MAX_LINES + " | while IFS= read -r l; do printf '%s unitfile %s\\n' \"$t\" \"$l\"; done",
  "n=0",
  "for d in \"$@\"; do",
  "  for f in \"$d\"/*.conf \"$d\"/*.state; do",
  "    [ -f \"$f\" ] || continue",
  "    n=$((n + 1))",
  "    if [ \"$n\" -gt \"$m\" ]; then printf '%s more\\n' \"$t\"; break 2; fi",
  "    s=$(wc -c <\"$f\") || continue",
  "    printf '%s file %s %s\\n' \"$t\" \"$s\" \"$f\"",
  "    head -c \"$c\" -- \"$f\"",
  "    printf '\\n%s eof\\n' \"$t\"",
  "  done",
  "done",
  "printf '%s end\\n' \"$t\""
].join("\n")

// The installed-parts check: which version install.sh last recorded against
// the plugin's own. One small process, read when the first bar attaches and
// on a panel opening, never on the poll's timer. It reads the first "$3"
// bytes of the plugin's manifest.json "$4" and the first "$2" of install.sh's
// manifest "$5" (each preceded by its byte size, -1 when it cannot be sized;
// regular files only, a symlink followed), says whether the legacy record
// "$6" and the plugin's install.sh "$7" are regular files,
// and ends with an "end" line. Marker lines start with the token "$1", as in
// SCAN_SCRIPT; nothing is interpolated into the script.
var INSTALLED_FILES = "omarchy-cloud/installed-files"
var INSTALLED_LEGACY = "omarchy-cloud/installed-binary.sha256"
var INSTALL_HEADER_MAX_BYTES = 4096
var INSTALL_HEADER_LINE_MAX = 1024
var PLUGIN_MANIFEST_MAX_BYTES = 16384
var VERSIONS_MAX_CHARS = INSTALL_HEADER_MAX_BYTES + PLUGIN_MANIFEST_MAX_BYTES + 2048
// install.sh refuses any other shape (the shared contract).
var VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+$/
var VERSIONS_SCRIPT = [
  "t=$1 c=$2 d=$3 p=$4 m=$5 l=$6 i=$7",
  "r() {",
  "  [ -f \"$2\" ] || return 0",
  "  s=$(wc -c <\"$2\" 2>/dev/null) || s=-1",
  "  printf '%s %s %s\\n' \"$t\" \"$1\" \"$s\"",
  "  head -c \"$3\" -- \"$2\" 2>/dev/null",
  "  printf '\\n%s eof\\n' \"$t\"",
  "}",
  "r plugin \"$p\" \"$d\"",
  "r installed \"$m\" \"$c\"",
  "[ -f \"$l\" ] && printf '%s legacy\\n' \"$t\"",
  "[ -f \"$i\" ] && printf '%s installer\\n' \"$t\"",
  "printf '%s end\\n' \"$t\""
].join("\n")

// Update installed parts: install.sh in a floating terminal that stays open
// once it exits, so its output can be read. The path is "$1", never part of
// the script; bash runs it, so it needs no execute bit.
var INSTALL_SCRIPT = [
  "printf 'Running %s\\n\\n' \"$1\"",
  "bash -- \"$1\"",
  "s=$?",
  "echo",
  "if [ \"$s\" -eq 0 ]; then echo 'install.sh finished (exit status 0).'; else echo \"install.sh failed (exit status $s).\"; fi",
  "printf 'Press Enter to close. '",
  "read -r _"
].join("\n")

// Nerd Font (Material Design) glyphs, the bar's own icon font.
var ICON = {
  all: "󰅠",      // md-cloud_check
  some: "󰅟",     // md-cloud
  none: "󰅤",     // md-cloud_off_outline
  error: "󰧠",    // md-cloud_alert
  unknown: "󰨹",  // md-cloud_question
  busy: "󰘿",     // md-cloud_sync
  folder: "󰝰",   // md-folder_open
  log: "󰧮",      // md-file_document_outline
  sync: "󰓦",     // md-sync
  backup: "󰁯",   // md-backup_restore
  settings: "󰒓", // md-cog
  update: "󰚰",   // md-update
  close: "󰅖"     // md-close
}

// ------------------------------------------------------------- validation

function isValidRemote(name) {
  return typeof name === "string" && REMOTE_RE.test(name)
}

// A usable $HOME: absolute, no "." or ".." segment, no control character.
function isSafeHome(home) {
  if (typeof home !== "string" || home.length < 2 || home.charAt(0) !== "/") return false
  if (/[\u0000-\u001f\u007f]/.test(home)) return false
  var parts = home.split("/")
  for (var i = 1; i < parts.length; i++) {
    if (parts[i] === "." || parts[i] === "..") return false
    if (parts[i] === "" && i !== parts.length - 1) return false
  }
  return true
}

function cleanHome(home) {
  if (!isSafeHome(home)) return ""
  return home.length > 1 && home.charAt(home.length - 1) === "/" ? home.slice(0, -1) : home
}

// The remote of "rclone-mount@<remote>.service", or "".
function remoteFromUnit(id) {
  var s = String(id === undefined || id === null ? "" : id)
  if (s.indexOf(UNIT_PREFIX) !== 0) return ""
  if (s.length <= UNIT_PREFIX.length + UNIT_SUFFIX.length) return ""
  if (s.slice(-UNIT_SUFFIX.length) !== UNIT_SUFFIX) return ""
  var name = s.slice(UNIT_PREFIX.length, -UNIT_SUFFIX.length)
  return isValidRemote(name) ? name : ""
}

// The remote of "<remote>.env", or "".
function remoteFromEnvFile(fileName) {
  var s = String(fileName === undefined || fileName === null ? "" : fileName)
  if (s.length <= 4 || s.slice(-4) !== ".env") return ""
  var name = s.slice(0, -4)
  return isValidRemote(name) ? name : ""
}

function unitName(remote) {
  return isValidRemote(remote) ? UNIT_PREFIX + remote + UNIT_SUFFIX : ""
}

// The name of "<prefix><name>.<kind>" for one of `kinds`, or "".
function instanceFromUnit(id, prefix, kinds) {
  var s = String(id === undefined || id === null ? "" : id)
  if (s.indexOf(prefix) !== 0) return ""
  var dot = s.lastIndexOf(".")
  if (dot <= prefix.length || kinds.indexOf(s.slice(dot + 1)) === -1) return ""
  var name = s.slice(prefix.length, dot)
  return isValidRemote(name) ? name : ""
}

function pairFromUnit(id) { return instanceFromUnit(id, BISYNC_PREFIX, BISYNC_KINDS) }
function jobFromUnit(id) { return instanceFromUnit(id, BACKUP_PREFIX, BACKUP_KINDS) }

// "rclone-bisync@<pair>.<kind>" / "rclone-backup@<job>.<kind>", or "".
function pairUnit(pair, kind) {
  return isValidRemote(pair) && BISYNC_KINDS.indexOf(kind) !== -1 ? BISYNC_PREFIX + pair + "." + kind : ""
}
function jobUnit(job, kind) {
  return isValidRemote(job) && BACKUP_KINDS.indexOf(kind) !== -1 ? BACKUP_PREFIX + job + "." + kind : ""
}

// Every valid name in any of the lists (the arguments after `cap`), sorted,
// de-duplicated and capped. Anything invalid is dropped, never repaired.
function mergeNames(cap, lists) {
  var seen = {}
  var out = []
  for (var a = 0; a < lists.length; a++) {
    var list = lists[a]
    if (!Array.isArray(list)) continue
    for (var i = 0; i < list.length && i < 1024; i++) {
      var name = list[i]
      if (!isValidRemote(name) || seen[name] === true) continue
      seen[name] = true
      out.push(name)
    }
  }
  out.sort()
  return out.slice(0, cap)
}

function mergeRemotes() { return mergeNames(MAX_REMOTES, arguments) }
function mergePairs() { return mergeNames(MAX_PAIRS, arguments) }
function mergeJobs() { return mergeNames(MAX_JOBS, arguments) }

// A loaded unit that says the instance is in use: enabled, or doing (or
// having failed) something. A disabled, inactive instance stays loaded for a
// while after something referenced it (a Sync now, a stopped timer) and is
// not discovered from the units alone, so a removed pair does not linger.
function unitInUse(unit) {
  if (!unit || String(unit.LoadState || "") !== "loaded") return false
  if (isEnabledState(unit)) return true
  var active = String(unit.ActiveState || "")
  return active !== "" && active !== "inactive"
}

// The pairs / jobs systemctl reported in use (units is parseShow's map).
function unitInstances(units, fromUnit) {
  var out = []
  if (!units || typeof units !== "object") return out
  for (var id in units) {
    if (!Object.prototype.hasOwnProperty.call(units, id)) continue
    var n = fromUnit(id)
    if (n !== "" && unitInUse(units[id])) out.push(n)
  }
  return out
}
function unitPairs(units) { return mergePairs(unitInstances(units, pairFromUnit)) }
function unitJobs(units) { return mergeJobs(unitInstances(units, jobFromUnit)) }

function envRemotes(fileNames) {
  var out = []
  if (!Array.isArray(fileNames)) return out
  for (var i = 0; i < fileNames.length && i < MAX_REMOTES * 4; i++) {
    var r = remoteFromEnvFile(fileNames[i])
    if (r !== "") out.push(r)
  }
  return out
}

// The rclone-mount remotes systemctl reported (units is parseShow's map).
function unitRemotes(units) {
  var out = []
  if (!units || typeof units !== "object") return out
  for (var id in units) {
    if (!Object.prototype.hasOwnProperty.call(units, id)) continue
    var r = remoteFromUnit(id)
    if (r !== "") out.push(r)
  }
  return out
}

// ------------------------------------------------------------------ paths

function mountPath(remote) {
  return isValidRemote(remote) ? MOUNT_ROOT + "/" + remote : ""
}

function homePath(home, rel, remote) {
  var h = cleanHome(home)
  if (h === "") return ""
  if (remote === undefined) return h + "/" + rel
  return isValidRemote(remote) ? h + "/" + rel + "/" + remote : ""
}

function linkPath(home, remote) { return homePath(home, CLOUD_LINKS, remote) }
function cacheDir(home, remote) { return homePath(home, CACHE_DIR, remote) }
function metaDir(home, remote) { return homePath(home, META_DIR, remote) }
function envDir(home) { return homePath(home, ENV_DIR) }
function appPath(home) { return homePath(home, APP_BIN) }

// ${XDG_STATE_HOME:-$HOME/.local/state}, as the helper scripts resolve it; a
// value that is not a clean absolute path is ignored (XDG says relative
// values are invalid), and "" without a usable $HOME.
function stateHome(home, xdgStateHome) {
  var x = cleanHome(xdgStateHome)
  if (x !== "") return x
  return homePath(home, STATE_DEFAULT)
}

// The four directories the scan reads; "" for each without a usable home.
function scanDirs(home, stateDir) {
  var s = cleanHome(stateDir)
  return {
    bisyncConf: homePath(home, BISYNC_CONF_DIR),
    backupConf: homePath(home, BACKUP_CONF_DIR),
    bisyncState: s !== "" ? s + "/" + BISYNC_STATE_DIR : "",
    backupState: s !== "" ? s + "/" + BACKUP_STATE_DIR : ""
  }
}

// file:// URL with each segment percent-encoded (FolderListModel.folder).
function fileUrl(path) {
  if (!path) return ""
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

// ------------------------------------------------------------------- argv

// The one batched state call: every rclone-mount, rclone-bisync and
// rclone-backup instance systemd has loaded (the globs), every remote known
// from elsewhere by name (loaded on demand, shown inactive when stopped), and
// SENTINEL_UNIT, whose block every working answer carries.
//
// Pairs and jobs are never named, only globbed. Naming a unit makes systemd
// load it, and a rclone-bisync@<pair>.path without its PathChanged= drop-in
// (written by `rclone-bisync setup`, which a new or half-set-up pair has not
// had) fails to load with "Path unit lacks path setting. Refusing." in the
// journal, once per poll. The glob alone loses nothing: it matches every
// loaded instance, an enabled one is loaded (its target wants it), and so is
// a service its timer or path names (Unit=); an instance nothing references
// is neither enabled nor running, which is what the panel shows for a pair
// or job missing from the answer. Whether the templates are installed comes
// from the scan (BISYNC_TEMPLATE). Remotes are still named: the mount
// template always loads.
function showArgv(remotes) {
  var argv = ["systemctl", "--user", "show", "--timestamp=unix", "-p", SHOW_PROPS.join(","), "--", UNIT_GLOB]
    .concat(BISYNC_GLOBS, BACKUP_GLOBS)
  var list = mergeRemotes(remotes)
  for (var i = 0; i < list.length; i++) argv.push(unitName(list[i]))
  argv.push(SENTINEL_UNIT)
  return argv
}

function startArgv(remote) {
  var unit = unitName(remote)
  return unit === "" ? [] : ["systemctl", "--user", "start", unit]
}

// The unit's own ExecStop is `fusermount3 -uz` (a lazy unmount), so a stop
// never fails on a busy mount; a separate fusermount3 would make that ExecStop
// fail on an already-detached mount. A "force" stop is therefore this same
// argv, sent after the user has seen what is still open.
function stopArgv(remote) {
  var unit = unitName(remote)
  return unit === "" ? [] : ["systemctl", "--user", "stop", unit]
}

// Sync now for one offline folder (the caller checks it is enabled).
function syncNowArgv(pair) {
  var unit = pairUnit(pair, "service")
  return unit === "" ? [] : ["systemctl", "--user", "start", "--no-block", unit]
}

// Configure…: the TUI in a terminal of Omarchy's own TUI.float class, which
// the shell's window rules float (default/hypr/apps/system.lua). Launched,
// not "launched or focused": omarchy-launch-or-focus-tui matches any window
// whose class or title contains the app id, and TUI.float is shared by every
// floating TUI (omarchy-tui-install gives it to each one it installs), so it
// would focus an unrelated one instead of opening this. The binary is named by
// its absolute path, so the terminal's PATH does not matter.
function configureArgv(home) {
  var bin = appPath(home)
  return bin === "" ? [] : ["omarchy-launch-tui", "--app-id=TUI.float", bin]
}

// The plugin's own folder from the file:// URL of a file in it (CloudState
// resolves "manifest.json"): percent-decoded, then held to the same rule as
// $HOME (absolute, no "." or ".." segment, no control character); "" for
// anything else.
function pluginDirFromUrl(url) {
  var u = String(url === undefined || url === null ? "" : url)
  var tail = "/manifest.json"
  if (u.indexOf("file://") !== 0 || u.length > 4096) return ""
  var path
  try { path = decodeURIComponent(u.slice(7)) } catch (e) { return "" }
  if (path.length <= tail.length || path.slice(-tail.length) !== tail) return ""
  return cleanHome(path.slice(0, -tail.length))
}

// Update installed parts: the plugin folder's install.sh through
// INSTALL_SCRIPT, as its "$1", in the same floating terminal as Configure….
function installArgv(pluginDir) {
  var dir = cleanHome(pluginDir)
  return dir === "" ? [] : ["omarchy-launch-tui", "--app-id=TUI.float", "bash", "-c", INSTALL_SCRIPT,
    "omarchy-cloud-install", dir + "/install.sh"]
}

// VERSIONS_SCRIPT for the plugin folder and the state dir; [] without both.
function versionsArgv(pluginDir, stateDir, token) {
  if (typeof token !== "string" || !SCAN_TOKEN_RE.test(token)) return []
  var dir = cleanHome(pluginDir)
  var st = cleanHome(stateDir)
  if (dir === "" || st === "") return []
  return timeoutArgv().concat(["sh", "-c", VERSIONS_SCRIPT, "cloud-mounts-versions", token,
    String(INSTALL_HEADER_MAX_BYTES), String(PLUGIN_MANIFEST_MAX_BYTES), dir + "/manifest.json",
    st + "/" + INSTALLED_FILES, st + "/" + INSTALLED_LEGACY, dir + "/install.sh"])
}

// A scan token: the marker prefix SCAN_SCRIPT puts on its own lines, drawn at
// random per run. Only tokens of this shape are accepted.
var SCAN_TOKEN_RE = /^cmscan-[0-9a-z]{12,40}$/

function scanToken() {
  var s = "cmscan-"
  for (var i = 0; i < 4; i++) s += (Math.floor(Math.random() * 2176782336) + 2176782336).toString(36).slice(1)
  return s
}

function scanArgv(home, stateDir, token) {
  if (typeof token !== "string" || !SCAN_TOKEN_RE.test(token)) return []
  var bin = appPath(home)
  var d = scanDirs(home, stateDir)
  if (bin === "" || d.bisyncConf === "" || d.bisyncState === "") return []
  var dirs = []
  var all = [d.bisyncConf, d.backupConf, d.bisyncState, d.backupState]
  for (var i = 0; i < all.length; i++) if (dirs.indexOf(all[i]) === -1) dirs.push(all[i])
  return timeoutArgv().concat(["sh", "-c", SCAN_SCRIPT, "cloud-mounts-scan", token,
    String(SCAN_FILE_MAX_BYTES), String(SCAN_MAX_FILES), bin]).concat(dirs)
}

function timeoutArgv() {
  return ["timeout", "-k", String(CHECK_KILL_S), String(CHECK_TIMEOUT_S)]
}

// fuser takes no "--"; the path is absolute, so it can never read as an
// option. -M: answer only if it is a mount point (a stopped remote's empty
// directory would otherwise list every process on the root filesystem).
function fuserArgv(remote) {
  return fuserPathArgv(mountPath(remote))
}

// The same for any absolute mount point (the live test uses /dev/shm).
function fuserPathArgv(path) {
  if (typeof path !== "string" || path.charAt(0) !== "/" || /[\u0000-\u001f\u007f]/.test(path)) return []
  return timeoutArgv().concat(["sh", "-c", FUSER_SCRIPT, "cloud-mounts-busy", path])
}

function pendingArgv(home, remote) {
  var dir = metaDir(home, remote)
  return dir === "" ? [] : timeoutArgv().concat(["bash", "-c", PENDING_SCRIPT, "cloud-mounts-pending", dir])
}

// -B1 without --apparent-size: the bytes allocated on disk. rclone's VFS cache
// files are sparse (a partly read file has the remote file's full length), so
// the apparent size (-b) overstates the cache, past --vfs-cache-max-size.
function duArgv(home, remotes) {
  var list = mergeRemotes(remotes)
  var argv = ["du", "-s", "-B1", "--"]
  for (var i = 0; i < list.length; i++) {
    var dir = cacheDir(home, list[i])
    if (dir !== "") argv.push(dir)
  }
  return argv.length > 4 ? argv : []
}

// The services whose journal "show log" may be asked for: a remote's mount, a
// pair's sync and a job's backup, each rebuilt from a validated name.
function isLogUnit(unit) {
  if (typeof unit !== "string" || unit === "") return false
  if (remoteFromUnit(unit) !== "") return true
  var p = pairFromUnit(unit)
  if (p !== "" && unit === pairUnit(p, "service")) return true
  var j = jobFromUnit(unit)
  return j !== "" && unit === jobUnit(j, "service")
}

function journalArgv(unit) {
  if (!isLogUnit(unit)) return []
  return ["journalctl", "--user", "-u", unit, "-n", String(LOG_LINES), "--no-pager", "-o", "short"]
}

// What Omarchy's own "File manager (cwd)" binding runs (omarchy-launch-nautilus-cwd),
// without its shell: uwsm-app starts nautilus as a scoped app.
function openFolderArgv(home, remote) {
  var path = linkPath(home, remote)
  return path === "" ? [] : ["uwsm-app", "--", "nautilus", "--new-window", path]
}

// --------------------------------------------------------------- parsing

// `systemctl show` output: blocks of Key=Value separated by blank lines.
// Returns { "<Id>": { Key: Value } }, keeping only SHOW_PROPS. A unit named
// twice (the glob and its own name) is kept once.
function parseShow(text) {
  var out = {}
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > SHOW_MAX_CHARS) s = s.slice(0, SHOW_MAX_CHARS)
  var lines = s.split("\n")
  var block = {}
  var units = 0
  function flush() {
    var id = block.Id
    if (typeof id === "string" && id !== "" && units < SHOW_MAX_UNITS
        && !Object.prototype.hasOwnProperty.call(out, id)) {
      out[id] = block
      units++
    }
    block = {}
  }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "" || line === "\r") { flush(); continue }
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    if (SHOW_PROPS.indexOf(key) === -1) continue
    block[key] = line.slice(eq + 1)
  }
  flush()
  return out
}

// "@1794686996" (systemctl --timestamp=unix) to seconds, or null.
function parseUnixTs(value) {
  var m = /^@(\d{1,12})$/.exec(String(value === undefined || value === null ? "" : value))
  if (!m) return null
  var n = Number(m[1])
  return isFinite(n) && n > 0 ? n : null
}

// `du -s -B1` lines ("<bytes>\t<path>") for the cache dirs of `remotes`:
// { remote: bytes }. Lines for any other path are ignored.
function parseDu(text, home, remotes) {
  var out = {}
  var byPath = {}
  var list = mergeRemotes(remotes)
  for (var i = 0; i < list.length; i++) {
    var dir = cacheDir(home, list[i])
    if (dir !== "") byPath[dir] = list[i]
  }
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > DU_MAX_CHARS) s = s.slice(0, DU_MAX_CHARS)
  var lines = s.split("\n")
  for (var j = 0; j < lines.length; j++) {
    var m = /^(\d{1,20})\t(.+)$/.exec(lines[j])
    if (!m || !Object.prototype.hasOwnProperty.call(byPath, m[2])) continue
    var n = Number(m[1])
    if (isFinite(n) && n >= 0) out[byPath[m[2]]] = n
  }
  return out
}

// FUSER_SCRIPT's output: fuser's -v table (stdout and stderr merged), then
// the exit line. The table is a header, then USER PID ACCESS COMMAND rows, the
// first prefixed with "<mount>:"; the kernel's own "mount" row is not a
// process. known is true only when the run finished (exit line, status 0) and
// fuser listed the mount, or when a process row was seen at all (a process on
// it is busy whatever cut the rest). Otherwise (not a mount point, fuser
// missing, killed by timeout, output over the bound) known is false: the
// caller must not read that as "not busy".
function parseFuser(text, remote) {
  return parseFuserAt(text, mountPath(remote))
}

function parseFuserAt(text, path) {
  var result = { known: false, procs: [], total: 0 }
  if (typeof path !== "string" || path === "") return result
  var s = String(text === undefined || text === null ? "" : text)
  var cut = s.length > FUSER_MAX_CHARS
  if (cut) s = s.slice(0, FUSER_MAX_CHARS)
  var lines = s.split("\n")
  var seen = {}
  var listed = false
  var exitCode = -1
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var tag = /^cloud-mounts-fuser-exit (\d{1,3})\s*$/.exec(line)
    if (tag) { exitCode = Number(tag[1]); continue }
    if (/^\s*USER\s+PID\s+ACCESS\s+COMMAND\s*$/.test(line)) continue
    var rest = line
    if (rest.indexOf(path + ":") === 0) { rest = rest.slice(path.length + 1); listed = true }
    var m = /^\s*(\S+)\s+(\d+|kernel)\s+(\S+)\s+(.*\S)\s*$/.exec(rest)
    if (!m) continue
    if (m[2] === "kernel") { listed = true; continue }
    if (seen[m[2]] === true) continue
    seen[m[2]] = true
    result.total++
    if (result.procs.length < MAX_BUSY_SHOWN)
      result.procs.push({ pid: Number(m[2]), user: safeText(m[1], 32), command: safeText(m[4], 64) })
  }
  result.known = result.total > 0 || (!cut && listed && exitCode === 0)
  return result
}

// The pending-upload count (PENDING_SCRIPT's stdout), or -1 when unknown.
function parsePendingCount(text) {
  var m = /^\s*(\d{1,9})\s*$/.exec(String(text === undefined || text === null ? "" : text))
  return m ? Number(m[1]) : -1
}

// ------------------------------------------------- config and state files

function emptyScan() {
  return { ok: false, app: false, more: false, templates: { bisync: false, backup: false },
    pairConfs: {}, jobConfs: {}, pairStates: {}, jobStates: {} }
}

// The instance name of `path` when it is exactly <dir>/<name><ext>, or "".
function nameInDir(path, dir, ext) {
  if (typeof path !== "string" || typeof dir !== "string" || dir === "") return ""
  var head = dir + "/"
  if (path.indexOf(head) !== 0 || path.length <= head.length + ext.length || path.slice(-ext.length) !== ext) return ""
  var name = path.slice(head.length, -ext.length)
  return isValidRemote(name) ? name : ""
}

// KEY=VALUE lines, as the helper scripts read them (no quoting, no
// expansion; # comments and blank lines skipped); the first of each key wins.
// Only what the panel shows is kept: LOCAL, as text (it is never used as a
// path here).
function parseConf(lines) {
  var out = { local: "" }
  var list = Array.isArray(lines) ? lines : []
  for (var i = 0; i < list.length && i < SCAN_FILE_MAX_LINES; i++) {
    var line = String(list[i]).replace(/\r$/, "")
    if (/^\s*(#|$)/.test(line)) continue
    var m = /^\s*([A-Z_]{1,32})=(.*)$/.exec(line)
    if (!m) continue
    if (m[1] === "LOCAL" && out.local === "") out.local = safeText(m[2].trim(), NAME_MAX_CHARS)
  }
  return out
}

// A state file (time=, exit=, conflict=… for a pair; time=, exit=, ok=,
// failed= for a job). Malformed lines are skipped; a number out of range is
// no number; the first time/exit/ok/failed wins. Conflicts are kept in file
// order, de-duplicated, at most MAX_CONFLICTS_SCANNED; `truncated` (the file
// was larger than the scan reads, or had more than that many) makes the
// count a lower bound.
function parseState(lines, truncated) {
  var st = { time: null, exit: null, ok: null, failed: null, conflicts: [], conflictsTruncated: truncated === true }
  var list = Array.isArray(lines) ? lines : []
  var seen = {}
  for (var i = 0; i < list.length && i < SCAN_FILE_MAX_LINES; i++) {
    var line = String(list[i]).replace(/\r$/, "")
    var m = /^(time|exit|ok|failed|conflict)=(.*)$/.exec(line)
    if (!m) continue
    var key = m[1]
    var value = m[2]
    if (key === "conflict") {
      var name = safeText(value, NAME_MAX_CHARS)
      if (name === "" || seen["$" + name] === true) continue
      if (st.conflicts.length >= MAX_CONFLICTS_SCANNED) { st.conflictsTruncated = true; continue }
      seen["$" + name] = true
      st.conflicts.push(name)
      continue
    }
    if (st[key] !== null) continue
    var n = /^\d{1,12}$/.test(value) ? Number(value) : NaN
    if (!isFinite(n)) continue
    if (key === "time" && n > 0) st.time = n
    else if (key === "exit" && n <= 255) st.exit = n
    else if ((key === "ok" || key === "failed") && n <= 1000000) st[key] = n
  }
  return st
}

// SCAN_SCRIPT's output for `token` (the one this run was given), files mapped
// to pairs and jobs by exact path under `dirs` (scanDirs). ok is true only
// for a run that finished (its "end" line) within SCAN_MAX_CHARS; the caller
// keeps its last good scan otherwise. Lines that do not start with the token
// are file content, whatever they look like.
function parseScan(text, token, dirs) {
  var res = emptyScan()
  if (typeof token !== "string" || !SCAN_TOKEN_RE.test(token) || !dirs || typeof dirs !== "object") return res
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > SCAN_MAX_CHARS) return res
  var lines = s.split("\n")
  var head = token + " "
  var cur = null
  var files = 0
  function finish() {
    var body = cur.lines
    if (body.length > 0 && body[body.length - 1] === "") body.pop()  // the script's own newline
    if (cur.truncated && body.length > 0) body.pop()                  // a line cut in half
    var name
    if ((name = nameInDir(cur.path, dirs.bisyncConf, ".conf")) !== "") {
      if (!Object.prototype.hasOwnProperty.call(res.pairConfs, name)) res.pairConfs[name] = parseConf(body)
    } else if ((name = nameInDir(cur.path, dirs.backupConf, ".conf")) !== "") {
      if (!Object.prototype.hasOwnProperty.call(res.jobConfs, name)) res.jobConfs[name] = { present: true }
    } else if ((name = nameInDir(cur.path, dirs.bisyncState, ".state")) !== "") {
      if (!Object.prototype.hasOwnProperty.call(res.pairStates, name)) res.pairStates[name] = parseState(body, cur.truncated)
    } else if ((name = nameInDir(cur.path, dirs.backupState, ".state")) !== "") {
      if (!Object.prototype.hasOwnProperty.call(res.jobStates, name)) res.jobStates[name] = parseState(body, cur.truncated)
    }
    cur = null
  }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf(head) === 0) {
      var rest = line.slice(head.length)
      if (rest === "end") { res.ok = true; break }
      if (rest === "app") { res.app = true; continue }
      if (rest === "more") { res.more = true; continue }
      if (rest === "eof") { if (cur !== null) finish(); continue }
      if (rest.indexOf("unitfile ") === 0) { templateLine(res.templates, rest.slice(9)); continue }
      var m = /^file\s*(\d{1,12}) (\/.*)$/.exec(rest)
      if (m && files < SCAN_MAX_FILES) {
        files++
        cur = { path: m[2], truncated: Number(m[1]) > SCAN_FILE_MAX_BYTES, lines: [] }
      } else {
        cur = null
      }
      continue
    }
    if (cur === null) continue
    if (cur.lines.length <= SCAN_FILE_MAX_LINES) cur.lines.push(line)
    else cur.truncated = true
  }
  return res
}

// One `systemctl list-unit-files --no-legend --plain` line ("<unit> <state>
// <preset>") for a service template: installed unless masked or broken.
function templateLine(templates, line) {
  var m = /^(\S+) ([a-z-]{1,32})(?: |$)/.exec(String(line))
  if (!m || /^(masked|masked-runtime|bad)$/.test(m[2])) return
  if (m[1] === BISYNC_TEMPLATE) templates.bisync = true
  else if (m[1] === BACKUP_TEMPLATE) templates.backup = true
}

function confNames(map) {
  var out = []
  if (!map || typeof map !== "object") return out
  for (var k in map) if (Object.prototype.hasOwnProperty.call(map, k)) out.push(k)
  return out
}
function scanPairs(scan) { return mergePairs(confNames(scan ? scan.pairConfs : null)) }
function scanJobs(scan) { return mergeJobs(confNames(scan ? scan.jobConfs : null)) }

// How many remotes there are before the MAX_REMOTES cap: the ones kept, the
// poll's units and the env files (that listing is itself read up to
// MAX_REMOTES * 4 names, so past that this is a lower bound).
function remotesFound(known, units, envFileNames) {
  return mergeNames(1048576, [known, unitRemotes(units), envRemotes(envFileNames)]).length
}

// How many pairs / jobs there are before the MAX_PAIRS / MAX_JOBS cap, so the
// panel can say it shows only some.
function pairsFound(scan, units) {
  return mergeNames(1048576, [confNames(scan ? scan.pairConfs : null), unitInstances(units, pairFromUnit)]).length
}
function jobsFound(scan, units) {
  return mergeNames(1048576, [confNames(scan ? scan.jobConfs : null), unitInstances(units, jobFromUnit)]).length
}

// "Showing 16 of 20 offline folders.", or "" when all are shown.
function capText(shown, found, what) {
  return found > shown ? "Showing " + shown + " of " + found + " " + what + "." : ""
}

// What, in the poll's answer, means a pair's or job's files may have changed:
// the instance list and each service's last exit. The scan runs again when
// this changes (each sync or backup run rewrites its state file just before
// it exits), never on a timer. Never "".
function scanKey(pairs, jobs, units) {
  var u = units && typeof units === "object" ? units : {}
  var parts = ["v1"]
  function add(unit) {
    var b = u[unit] || {}
    parts.push(unit + "=" + String(b.ExecMainExitTimestamp || "") + "/" + String(b.InactiveEnterTimestamp || "")
      + "/" + String(b.LoadState || ""))
  }
  var p = mergePairs(pairs)
  for (var i = 0; i < p.length; i++) add(pairUnit(p[i], "service"))
  var j = mergeJobs(jobs)
  for (var k = 0; k < j.length; k++) add(jobUnit(j[k], "service"))
  return parts.join("\n")
}

// ----------------------------------------------------------------- state

// One remote's unit to a display state:
//   mounted | starting | stopping | stopped | failed | unknown
// `on` says the unit is up or trying to be (the toggle's position).
function remoteState(unit) {
  if (!unit || typeof unit !== "object") return { state: "unknown", label: "unknown", on: false, mounted: false }
  var load = String(unit.LoadState || "")
  var active = String(unit.ActiveState || "")
  var sub = String(unit.SubState || "")
  if (load !== "" && load !== "loaded")
    return { state: "failed", label: "unit " + safeText(load, 24), on: false, mounted: false }
  if (active === "active" || active === "reloading" || active === "refreshing")
    return { state: "mounted", label: "mounted", on: true, mounted: true }
  if (active === "activating") {
    if (sub.indexOf("auto-restart") === 0) return { state: "failed", label: "failed, retrying", on: true, mounted: false }
    return { state: "starting", label: "starting", on: true, mounted: false }
  }
  if (active === "deactivating") return { state: "stopping", label: "stopping", on: false, mounted: false }
  if (active === "failed") {
    var why = String(unit.Result || "")
    return { state: "failed", label: why !== "" && why !== "success" ? "failed (" + safeText(why, 24) + ")" : "failed", on: false, mounted: false }
  }
  if (active === "inactive") return { state: "stopped", label: "stopped", on: false, mounted: false }
  return { state: "unknown", label: active !== "" ? safeText(active, 24) : "unknown", on: false, mounted: false }
}

// The panel's rows: one per remote, in name order.
function remoteRows(remotes, units, sizes) {
  var rows = []
  var list = mergeRemotes(remotes)
  for (var i = 0; i < list.length; i++) {
    var name = list[i]
    var unit = units ? units[unitName(name)] : null
    var st = remoteState(unit)
    var bytes = sizes && Object.prototype.hasOwnProperty.call(sizes, name) ? sizes[name] : -1
    rows.push({
      name: name,
      unit: unitName(name),
      state: st.state,
      label: st.label,
      on: st.on,
      mounted: st.mounted,
      failed: st.state === "failed",
      transitional: st.state === "starting" || st.state === "stopping",
      cacheBytes: bytes,
      detail: st.label + (bytes >= 0 ? " · cache " + formatBytes(bytes) : "")
    })
  }
  return rows
}

// The row with this name, or null. The panel's Repeater is keyed by name
// (rowNames), so a poll that changes a row's state updates its delegate in
// place instead of rebuilding every row.
function rowByName(rows, name) {
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === name) return list[i]
  return null
}

function rowNames(rows) {
  var out = []
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) if (list[i]) out.push(String(list[i].name))
  return out
}

// Two lists of strings with the same items in the same order.
function sameList(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

// ---------------------------------------------------------------- cursor

// The panel's keyboard cursor stands on one control, named by a key:
//   switch|<remote>  folder|<remote>  log|<unit>  force  cancel  sync|<pair>
//   install  configure
// The stops form groups, one per panel row, each in screen order left to
// right with the one a vertical move lands on (primary): a remote row
// [log?, folder?, switch], the confirm box [force, cancel] under its row, an
// offline-folder row [log?, sync?], a backup row [log?], the footer's
// Update installed parts [install?] and its Configure… [configure?]. Disabled controls are not stops, and a row with
// none is skipped. Up/Down step between groups, Left/Right inside one.
function cursorKey(kind, arg) {
  return arg === undefined || arg === "" ? String(kind) : String(kind) + "|" + String(arg)
}

function cursorAction(key) {
  var k = String(key === undefined || key === null ? "" : key)
  var bar = k.indexOf("|")
  var kind = bar === -1 ? k : k.slice(0, bar)
  var arg = bar === -1 ? "" : k.slice(bar + 1)
  if (["switch", "folder", "log", "force", "cancel", "sync", "install", "configure"].indexOf(kind) === -1) return { kind: "", arg: "" }
  return { kind: kind, arg: arg }
}

// o: { stopRemote, confirm, logUnit, pairs (pairRows), jobs (jobRows), canInstall, canConfigure }
function cursorGroups(rows, o) {
  var opt = o || {}
  var groups = []
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    var keys = []
    if (r.failed || opt.logUnit === r.unit) keys.push(cursorKey("log", r.unit))
    if (r.mounted) keys.push(cursorKey("folder", r.name))
    keys.push(cursorKey("switch", r.name))
    groups.push({ keys: keys, primary: keys.length - 1 })
    if (opt.confirm === true && opt.stopRemote === r.name)
      groups.push({ keys: ["force", "cancel"], primary: 1 })
  }
  var pairs = Array.isArray(opt.pairs) ? opt.pairs : []
  for (var p = 0; p < pairs.length; p++) {
    var pr = pairs[p]
    if (!pr) continue
    var pk = []
    if ((pr.failed && (!pr.watchStopped || pr.runFailed === true)) || opt.logUnit === pr.unit) pk.push(cursorKey("log", pr.unit))
    if (pr.canSync) pk.push(cursorKey("sync", pr.name))
    if (pk.length > 0) groups.push({ keys: pk, primary: pk.length - 1 })
  }
  var jobs = Array.isArray(opt.jobs) ? opt.jobs : []
  for (var j = 0; j < jobs.length; j++) {
    var jr = jobs[j]
    if (jr && (jr.failed || opt.logUnit === jr.unit)) groups.push({ keys: [cursorKey("log", jr.unit)], primary: 0 })
  }
  if (opt.canInstall === true) groups.push({ keys: ["install"], primary: 0 })
  if (opt.canConfigure === true) groups.push({ keys: ["configure"], primary: 0 })
  return groups
}

function findCursor(groups, key) {
  for (var g = 0; g < (groups || []).length; g++) {
    var c = groups[g].keys.indexOf(key)
    if (c !== -1) return { g: g, c: c }
  }
  return null
}

function primaryKey(group) {
  return group ? group.keys[Math.max(0, Math.min(group.keys.length - 1, group.primary))] : ""
}

// The key the cursor really stands on: `key` while it is a stop; a remote's
// folder or log gone (unmounted, log closed) falls back to its switch; the
// confirm box gone, to the switch of `fallbackRemote`; else the first stop.
function cursorKeyIn(groups, key, fallbackRemote) {
  if (!groups || groups.length === 0) return ""
  if (findCursor(groups, key) !== null) return key
  var a = cursorAction(key)
  var remote = a.kind === "folder" || a.kind === "switch" ? a.arg
    : (a.kind === "log" ? remoteFromUnit(a.arg) : (typeof fallbackRemote === "string" ? fallbackRemote : ""))
  if (remote && findCursor(groups, cursorKey("switch", remote)) !== null) return cursorKey("switch", remote)
  // A pair's log closed: its Sync now, when that is a stop.
  var pair = a.kind === "log" ? pairFromUnit(a.arg) : ""
  if (pair && findCursor(groups, cursorKey("sync", pair)) !== null) return cursorKey("sync", pair)
  return primaryKey(groups[0])
}

// One step from `key`. A vertical step past either end stays put (the caller
// scrolls instead); a horizontal one stops at the group's edge.
function stepCursor(groups, key, dx, dy) {
  if (!groups || groups.length === 0) return ""
  var at = findCursor(groups, key)
  if (at === null) return primaryKey(groups[0])
  if (dy !== 0) {
    var g = Math.max(0, Math.min(groups.length - 1, at.g + (dy > 0 ? 1 : -1)))
    return g === at.g ? key : primaryKey(groups[g])
  }
  if (dx !== 0) {
    var keys = groups[at.g].keys
    return keys[Math.max(0, Math.min(keys.length - 1, at.c + (dx > 0 ? 1 : -1)))]
  }
  return key
}

// Bar state: unknown (no answer yet) | error | all | some | none. error: a
// failed mount, a failed offline-folder sync or backup, or a conflict copy
// (problems(), which the hero and the tooltip spell out).
function aggregate(rows, pairs, jobs, polled) {
  if (!polled) return "unknown"
  var list = Array.isArray(rows) ? rows : []
  if (problems(list, pairs, jobs).any) return "error"
  var mounted = 0
  var moving = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i].mounted) mounted++
    else if (list[i].transitional) moving++
  }
  if (list.length > 0 && mounted === list.length) return "all"
  if (mounted > 0 || moving > 0) return "some"
  return "none"
}

// What puts the bar in the alert state, by name: failed mounts, failed
// offline-folder syncs, offline folders whose watch or timer stopped
// (`watches`; such a row is failed too, but named apart and not as a failed
// sync), failed backups (each list only names that passed isValidRemote, at
// most what the rows hold), and the conflict-copy total.
function problems(rows, pairs, jobs) {
  function failedNames(list, pick) {
    var out = []
    var l = Array.isArray(list) ? list : []
    for (var i = 0; i < l.length; i++) if (l[i] && pick(l[i]) && isValidRemote(l[i].name)) out.push(l[i].name)
    return out
  }
  function failed(r) { return !!r.failed }
  var p = { mounts: failedNames(rows, failed), syncs: failedNames(pairs, function(r) { return r.failed && (!r.watchStopped || r.runFailed === true) }),
    watches: failedNames(pairs, function(r) { return r.failed && r.watchStopped === true }),
    backups: failedNames(jobs, failed), conflicts: conflictTotal(pairs), conflictsTruncated: false, any: false }
  var pl = Array.isArray(pairs) ? pairs : []
  for (var i = 0; i < pl.length; i++) if (pl[i] && pl[i].conflictCount > 0 && pl[i].conflictsTruncated) p.conflictsTruncated = true
  p.any = p.mounts.length > 0 || p.syncs.length > 0 || p.watches.length > 0 || p.backups.length > 0 || p.conflicts > 0
  return p
}

// "1 mount failed", "2 syncs failed".
function countText(n, one, many, verb) {
  return n + " " + (n === 1 ? one : many) + (verb ? " " + verb : "")
}

function barIcon(agg) {
  return Object.prototype.hasOwnProperty.call(ICON, agg) && ["all", "some", "none", "error", "unknown"].indexOf(agg) !== -1
    ? ICON[agg] : ICON.unknown
}

function countMounted(rows) {
  var n = 0
  for (var i = 0; i < (rows || []).length; i++) if (rows[i].mounted) n++
  return n
}

// The hero line (and the tooltip's first): the mounts, then every problem
// behind an alert icon, e.g. "3 of 3 mounted · 1 sync failed".
function summary(rows, polled, pairs, jobs) {
  if (!polled) return "Checking mounts…"
  var list = Array.isArray(rows) ? rows : []
  var parts = [list.length === 0 ? "No rclone-mount units found" : countMounted(list) + " of " + list.length + " mounted"]
  var p = problems(list, pairs, jobs)
  if (p.mounts.length > 0) parts.push(countText(p.mounts.length, "mount", "mounts", "failed"))
  if (p.syncs.length > 0) parts.push(countText(p.syncs.length, "sync", "syncs", "failed"))
  if (p.watches.length > 0) parts.push(countText(p.watches.length, "sync watch", "sync watches", "stopped"))
  if (p.backups.length > 0) parts.push(countText(p.backups.length, "backup", "backups", "failed"))
  if (p.conflicts > 0) parts.push(conflictCountText({ conflictCount: p.conflicts, conflictsTruncated: p.conflictsTruncated }))
  return parts.join(" · ")
}

// The bar's tooltip. Every name in it passed isValidRemote (the tooltip is a
// shell component with no plain-text setting). notice: installNotice's line,
// or "", shortened here to installTipLine's pointer to the panel; canConfigure: right-click opens
// the TUI (BarWidget falls back to the panel without it).
function tooltipText(rows, pairs, jobs, polled, pollError, notice, canConfigure) {
  var lines = ["Cloud Mounts: " + summary(rows, polled, pairs, jobs)]
  if (pollError !== "") lines.push(pollError)
  var p = problems(rows, pairs, jobs)
  if (p.mounts.length > 0) lines.push("Mount failed: " + p.mounts.join(", "))
  if (p.syncs.length > 0) lines.push("Sync failed: " + p.syncs.join(", "))
  if (p.watches.length > 0) lines.push("Sync watch stopped: " + p.watches.join(", "))
  if (p.backups.length > 0) lines.push("Backup failed: " + p.backups.join(", "))
  var list = Array.isArray(pairs) ? pairs : []
  for (var p = 0; p < list.length; p++) {
    var pr = list[p]
    if (pr && pr.conflictCount > 0 && isValidRemote(pr.name)) lines.push(pr.name + ": " + conflictCountText(pr))
  }
  var tip = installTipLine(notice)
  if (tip !== "") lines.push(tip)
  lines.push(canConfigure === true ? "Click to manage · Right-click: Configure…" : "Click to manage")
  return lines.join("\n")
}

// What the toggle does for a row: "start", "stop" or "" (nothing right now).
function toggleAction(row) {
  if (!row || row.transitional) return ""
  return row.on ? "stop" : "start"
}

// After the busy and pending checks of a stop: "stop" straight away, or
// "confirm" (show what is open / pending and offer Force). Unknown results
// confirm: an unchecked mount is never treated as idle.
function stopDecision(busy, pending) {
  if (!busy || busy.known !== true) return "confirm"
  if (busy.total > 0) return "confirm"
  if (typeof pending !== "number" || pending !== 0) return "confirm"
  return "stop"
}

// The confirm box's go-ahead button.
function confirmLabel(busy) {
  if (!busy || busy.known !== true) return "Stop anyway"
  return busy.total === 0 ? "Unmount" : "Force unmount"
}

function busyLines(busy) {
  if (!busy || busy.known !== true)
    return ["Could not check which processes use this mount (fuser failed or timed out). Stop anyway?"]
  if (busy.total === 0) return []
  var out = [busy.total + " process" + (busy.total === 1 ? "" : "es") + " using it:"]
  for (var i = 0; i < busy.procs.length; i++)
    out.push("  " + busy.procs[i].command + " (PID " + busy.procs[i].pid + ", " + busy.procs[i].user + ")")
  if (busy.total > busy.procs.length) out.push("  … and " + (busy.total - busy.procs.length) + " more")
  return out
}

function pendingLine(pending) {
  if (typeof pending !== "number" || pending < 0) return "Pending uploads could not be counted."
  if (pending === 0) return ""
  return pending + (pending >= PENDING_MAX_FILES ? "+" : "") + " pending upload" + (pending === 1 ? "" : "s")
    + " will resume on the next mount (the cache is kept)."
}

function stopPrompt(remote, busy, pending) {
  var lines = busyLines(busy)
  var p = pendingLine(pending)
  if (p !== "") lines.push(p)
  if (busy && busy.known === true && busy.total > 0)
    lines.push("Force detaches the mount (lazy unmount) and stops rclone; nothing is killed, but open files on it stop working.")
  return lines.join("\n")
}

// ------------------------------------------------ offline folders, backups

function isEnabledState(unit) {
  var s = unit ? String(unit.UnitFileState || "") : ""
  return s === "enabled" || s === "enabled-runtime"
}

// Why an enabled .path or .timer is not doing its job, or "": enabled but not
// active means it starts no syncs (a path unit that hit its trigger limit, or
// whose service hit its start limit, fails and stops watching until it is
// restarted). The reason is systemd's Result, else the ActiveState.
function stoppedTrigger(unit) {
  if (!isEnabledState(unit)) return ""
  var active = String(unit.ActiveState || "")
  if (active === "active" || active === "activating" || active === "reloading") return ""
  var result = String(unit.Result || "")
  return safeText(result !== "" && result !== "success" ? result : (active || "not running"), 32)
}

// "" or the warning for a pair whose folder watch or timer stopped.
function watchStoppedText(name, path, timer) {
  var p = stoppedTrigger(path)
  var t = stoppedTrigger(timer)
  if (p === "" && t === "") return ""
  var parts = []
  if (p !== "") parts.push("folder watch stopped (" + p + ")")
  if (t !== "") parts.push("timer stopped (" + t + ")")
  var units = (p !== "" ? pairUnit(name, "path") : "") + (p !== "" && t !== "" ? " " : "") + (t !== "" ? pairUnit(name, "timer") : "")
  var text = parts.join(", ") + (p !== "" && t === "" ? ": edits are synced only by the timer" : "")
  return text.charAt(0).toUpperCase() + text.slice(1)
    + ". Restart it: w in omarchy-cloud, or systemctl --user reset-failed " + units + " && systemctl --user start " + units + "."
}

function isLoaded(unit) {
  return !!unit && String(unit.LoadState || "") === "loaded"
}

// A oneshot's last run as systemd saw it (only since the user manager
// started): { known, running, ok, failed, at, text }.
function lastRun(unit, nowSec) {
  var r = { known: false, running: false, ok: false, failed: false, at: null, text: "" }
  if (!isLoaded(unit)) { r.text = "not installed"; return r }
  var active = String(unit.ActiveState || "")
  if (active === "activating" || active === "deactivating") { r.running = true; r.text = "running now" }
  var at = parseUnixTs(unit.ExecMainExitTimestamp)
  if (at === null) at = parseUnixTs(unit.InactiveEnterTimestamp)
  var result = String(unit.Result || "")
  var status = String(unit.ExecMainStatus || "")
  r.failed = active === "failed" || (result !== "" && result !== "success")
  if (at === null && !r.failed) {
    if (!r.running) r.text = "no run since the session started"
    return r
  }
  r.known = true
  r.at = at
  r.ok = !r.failed && (status === "" || status === "0")
  if (!r.ok && !r.failed) r.failed = true
  var when = at !== null ? formatWhen(at, nowSec) : "time unknown"
  var outcome = r.ok ? "ok" : "failed (" + safeText(result || "error", 24) + (status !== "" && status !== "0" ? ", exit " + safeText(status, 8) : "") + ")"
  r.text = (r.running ? "running now · last " : "") + when + " · " + outcome
  return r
}

// The last run from both sources: the state file (written by the helper just
// before it exits, kept across reboots) unless systemd saw a later run (one
// that failed before it could write it, say), then systemd's view.
// counts: show the backup's ok=/failed= counts.
function runOf(unit, state, nowSec, counts) {
  var u = lastRun(unit, nowSec)
  var st = state && typeof state.time === "number" ? state : null
  if (st === null || (u.at !== null && st.time < u.at - STATE_SKEW_S)) {
    if (!u.known && !u.running && st === null) u.text = isLoaded(unit) ? "no run yet" : "never run"
    return u
  }
  var r = { known: true, running: u.running, ok: st.exit === 0, failed: st.exit !== null && st.exit !== 0, at: st.time, text: "" }
  var outcome = st.exit === null ? "result unknown" : st.exit === 0 ? "ok" : "failed (exit " + st.exit + ")"
  if (counts === true && (st.ok !== null || st.failed !== null)) {
    var parts = []
    if (st.ok !== null) parts.push(st.ok + " copied")
    if (st.failed !== null && st.failed > 0) parts.push(st.failed + " failed")
    if (parts.length > 0) outcome += " · " + parts.join(", ")
  }
  r.text = (u.running ? "running now · last " : "") + formatWhen(st.time, nowSec) + " · " + outcome
  return r
}

// Whether an instance's units can load: its service's own LoadState while
// systemd has it loaded (the poll never loads one, see showArgv), else
// whether the scan found the template installed.
function templateInstalled(service, scan, kind) {
  if (service) return isLoaded(service)
  return !!(scan && scan.templates && scan.templates[kind] === true)
}

// One row per offline folder, in name order. scan is parseScan's result.
function pairRows(pairs, units, scan, nowSec) {
  var u = units && typeof units === "object" ? units : {}
  var sc = scan && typeof scan === "object" ? scan : emptyScan()
  var rows = []
  var list = mergePairs(pairs)
  for (var i = 0; i < list.length; i++) {
    var name = list[i]
    var service = u[pairUnit(name, "service")] || null
    var conf = sc.pairConfs && Object.prototype.hasOwnProperty.call(sc.pairConfs, name) ? sc.pairConfs[name] : null
    var st = sc.pairStates && Object.prototype.hasOwnProperty.call(sc.pairStates, name) ? sc.pairStates[name] : null
    var run = runOf(service, st, nowSec, false)
    var installed = templateInstalled(service, sc, "bisync")
    var timer = u[pairUnit(name, "timer")] || null
    var path = u[pairUnit(name, "path")] || null
    var enabled = isEnabledState(timer) || isEnabledState(path)
    var watch = watchStoppedText(name, path, timer)
    var conflicts = st ? st.conflicts.slice(0, MAX_CONFLICTS_SCANNED) : []
    var row = {
      name: name,
      unit: pairUnit(name, "service"),
      local: conf ? conf.local : "",
      installed: installed,
      enabled: enabled,
      running: run.running,
      // A stopped watch is an alert too (failed), named apart (watchStopped):
      // "sync watch stopped", not "sync failed"; runFailed says the last run failed
      // too (then it counts as a failed sync and keeps Show log).
      failed: run.failed || watch !== "",
      watchStopped: watch !== "",
      runFailed: run.failed,
      watchText: watch,
      text: run.text,
      canSync: installed && enabled && !run.running,
      conflicts: conflicts,
      conflictCount: conflicts.length,
      conflictsTruncated: !!(st && st.conflictsTruncated && conflicts.length > 0)
    }
    row.blockedText = syncBlockedText(row)
    row.conflictText = conflictText(row)
    rows.push(row)
  }
  return rows
}

// One row per backup job, in name order.
function jobRows(jobs, units, scan, nowSec) {
  var u = units && typeof units === "object" ? units : {}
  var sc = scan && typeof scan === "object" ? scan : emptyScan()
  var rows = []
  var list = mergeJobs(jobs)
  for (var i = 0; i < list.length; i++) {
    var name = list[i]
    var service = u[jobUnit(name, "service")] || null
    var timer = u[jobUnit(name, "timer")] || null
    var st = sc.jobStates && Object.prototype.hasOwnProperty.call(sc.jobStates, name) ? sc.jobStates[name] : null
    var run = runOf(service, st, nowSec, true)
    var next = timer ? parseUnixTs(timer.NextElapseUSecRealtime) : null
    rows.push({
      name: name,
      unit: jobUnit(name, "service"),
      installed: templateInstalled(service, sc, "backup"),
      enabled: isEnabledState(timer),
      running: run.running,
      failed: run.failed,
      text: run.text,
      next: next !== null ? "next " + formatWhen(next, nowSec) : (isEnabledState(timer) ? "" : "timer not enabled")
    })
  }
  return rows
}

function conflictTotal(pairs) {
  var n = 0
  var list = Array.isArray(pairs) ? pairs : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].conflictCount > 0) n += list[i].conflictCount
  return n
}

// The note under an offline folder's Sync now button: why it is disabled (a
// disabled button shows no tooltip), or, while it still works, that the
// folder watch or timer stopped (watchText, with the way back); else "".
function syncBlockedText(row) {
  if (!row || typeof row !== "object") return ""
  if (!row.installed) return "Sync not enabled: the rclone-bisync@ units are not installed (run install.sh)."
  if (!row.enabled) return "Sync not enabled: " + pairUnit(row.name, "timer") + " and .path are both disabled."
  return typeof row.watchText === "string" ? row.watchText : ""
}

// "3 conflict copies", "1 conflict copy", "200+ conflict copies".
function conflictCountText(row) {
  var n = row && row.conflictCount > 0 ? row.conflictCount : 0
  return n + (row && row.conflictsTruncated ? "+" : "") + " conflict cop" + (n === 1 && !(row && row.conflictsTruncated) ? "y" : "ies")
}

// bisync --conflict-resolve none renames BOTH sides of a conflict.
var CONFLICT_HOWTO = "A file changed on both sides: bisync kept both versions as X.conflictN copies (X itself is renamed). Merge them into one file, rename it back to X, delete the other copies."

function conflictText(row) {
  if (!row || !(row.conflictCount > 0)) return ""
  var list = Array.isArray(row.conflicts) ? row.conflicts : []
  var shown = list.slice(0, MAX_CONFLICTS_SHOWN)
  var more = list.length - shown.length
  return conflictCountText(row) + ": " + shown.join(", ")
    + (more > 0 ? " and " + more + (row.conflictsTruncated ? "+" : "") + " more" : "")
    + ". " + CONFLICT_HOWTO
}

// What the footer says about Configure…, or "" (the button works).
function configureHint(scanned, appInstalled) {
  if (!scanned) return ""
  return appInstalled ? "" : "Run install.sh from the plugin folder to install omarchy-cloud."
}

// --------------------------------------------------------- installed parts

function emptyVersions() {
  return { ok: false, plugin: "", installedPresent: false, installedVersion: "", installedRepo: "",
    legacy: false, installer: false }
}

// The header lines install.sh writes before its `<sha256>  <path>` lines
// (#version=, #repo=). Only the first INSTALL_HEADER_MAX_BYTES are looked at;
// a line longer than INSTALL_HEADER_LINE_MAX is no header line. The first
// line of a key decides it, valid or not (a later duplicate is ignored).
// version: N.N.N or ""; repo: absolute, no control character, or "".
function parseInstallHeader(text) {
  var out = { version: "", repo: "" }
  var s = String(text === undefined || text === null ? "" : text).slice(0, INSTALL_HEADER_MAX_BYTES)
  var lines = s.split("\n")
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\r$/, "")
    if (line.length > INSTALL_HEADER_LINE_MAX) continue
    var m = /^#(version|repo)=(.*)$/.exec(line)
    if (!m || seen[m[1]] === true) continue
    seen[m[1]] = true
    var v = m[2]
    if (m[1] === "version") out.version = VERSION_RE.test(v) ? v : ""
    else out.repo = v.charAt(0) === "/" && !/[\u0000-\u001f\u007f-\u009f]/.test(v) ? v : ""
  }
  return out
}

// The "version" of the plugin's manifest.json, when it is N.N.N; else "".
function parsePluginVersion(text) {
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > PLUGIN_MANIFEST_MAX_BYTES) return ""
  var j
  try { j = JSON.parse(s) } catch (e) { return "" }
  var v = j && typeof j === "object" ? j.version : undefined
  return typeof v === "string" && VERSION_RE.test(v) ? v : ""
}

// VERSIONS_SCRIPT's output for `token`. ok only for a run that finished (its
// "end" line) within VERSIONS_MAX_CHARS; lines that do not start with the
// token are file content. A file larger than the bytes read loses its last,
// cut line.
function parseVersions(text, token) {
  var res = emptyVersions()
  if (typeof token !== "string" || !SCAN_TOKEN_RE.test(token)) return res
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > VERSIONS_MAX_CHARS) return res
  var lines = s.split("\n")
  var head = token + " "
  var cur = null
  var bodies = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf(head) === 0) {
      var rest = line.slice(head.length)
      if (rest === "end") { res.ok = true; break }
      if (rest === "legacy") { res.legacy = true; continue }
      if (rest === "installer") { res.installer = true; continue }
      if (rest === "eof") {
        if (cur !== null) {
          var body = cur.lines
          if (body.length > 0 && body[body.length - 1] === "") body.pop()
          if (cur.truncated && body.length > 0) body.pop()
          if (!Object.prototype.hasOwnProperty.call(bodies, cur.what)) bodies[cur.what] = body.join("\n")
        }
        cur = null
        continue
      }
      var m = /^(plugin|installed) (-1|\d{1,12})$/.exec(rest)
      cur = m ? { what: m[1], truncated: Number(m[2]) > (m[1] === "plugin" ? PLUGIN_MANIFEST_MAX_BYTES : INSTALL_HEADER_MAX_BYTES), lines: [] } : null
      if (m && m[1] === "installed") res.installedPresent = true
      continue
    }
    if (cur !== null) cur.lines.push(line)
  }
  if (!res.ok) return emptyVersions()
  if (Object.prototype.hasOwnProperty.call(bodies, "plugin")) res.plugin = parsePluginVersion(bodies.plugin)
  if (Object.prototype.hasOwnProperty.call(bodies, "installed")) {
    var h = parseInstallHeader(bodies.installed)
    res.installedVersion = h.version
    res.installedRepo = h.repo
  }
  return res
}

// none (nothing installed) | unknown (installed, no version recorded: by
// install.sh 0.3.2 or older) | mismatch (either direction) | ok; "" when the
// read failed or the plugin's own version is unknown, so nothing is claimed.
function installState(v) {
  if (!v || v.ok !== true || typeof v.plugin !== "string" || v.plugin === "") return ""
  if (!v.installedPresent && !v.legacy) return "none"
  if (!v.installedPresent || v.installedVersion === "") return "unknown"
  return v.installedVersion === v.plugin ? "ok" : "mismatch"
}

// The notice for that state (the shared contract's wording), or "".
function installNotice(v) {
  var state = installState(v)
  if (state === "mismatch") return "Installed parts are " + v.installedVersion + ", plugin is " + v.plugin + " — run install.sh"
  if (state === "unknown") return "Installed parts are older than " + v.plugin + " (no version recorded) — run install.sh"
  if (state === "none") return INSTALL_NOTICE_NONE
  return ""
}

var INSTALL_NOTICE_NONE = "Installed parts: not installed — run install.sh"

// The tooltip's short form of an installNotice line: the panel has the
// versions and the button.
function installTipLine(notice) {
  if (typeof notice !== "string" || notice === "") return ""
  if (notice === INSTALL_NOTICE_NONE) return "Installed parts: not installed — open the panel"
  return "Installed parts out of date — open the panel"
}

var INSTALL_BUTTON_TEXT = "Update installed parts"

// ------------------------------------------------------------- formatting

// Control characters removed, length capped.
function safeText(value, max) {
  var s = String(value === undefined || value === null ? "" : value).replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
  var cap = typeof max === "number" && max > 0 ? max : NAME_MAX_CHARS
  return s.length > cap ? s.slice(0, cap - 1) + "…" : s
}

// journalctl output for display: the last LOG_LINES lines, each capped,
// control characters removed (tabs become spaces), at most LOG_MAX_CHARS.
function formatLog(text) {
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > LOG_MAX_CHARS * 8) s = s.slice(-LOG_MAX_CHARS * 8)
  var lines = s.replace(/\r/g, "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\t/g, " ")
    if (line.replace(/\s/g, "") === "") continue
    out.push(safeText(line, LOG_LINE_MAX))
  }
  out = out.slice(-LOG_LINES)
  var joined = out.join("\n")
  if (joined.length > LOG_MAX_CHARS) joined = "…" + joined.slice(-(LOG_MAX_CHARS - 1))
  return joined === "" ? "(no journal entries)" : joined
}

function formatBytes(n) {
  if (typeof n !== "number") return "—"
  var v = n
  if (!isFinite(v) || v < 0) return "—"
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  if (i === 0) return Math.round(v) + " B"
  return (v >= 100 ? Math.round(v) : v >= 10 ? v.toFixed(1) : v.toFixed(2)) + " " + units[i]
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// "17:09" today, "14 Nov 17:09" on any other day (local time).
function formatClock(sec, nowSec) {
  var d = new Date(sec * 1000)
  var now = new Date(nowSec * 1000)
  var hm = pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  var sameDay = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  return sameDay ? hm : d.getDate() + " " + MONTHS[d.getMonth()] + " " + hm
}

function formatAgo(sec, nowSec) {
  var diff = Math.round(nowSec - sec)
  var future = diff < 0
  var a = Math.abs(diff)
  var text
  if (a < 60) return future ? "in under a minute" : "just now"
  if (a < 3600) text = Math.floor(a / 60) + " min"
  else if (a < 86400) text = Math.floor(a / 3600) + " h"
  else text = Math.floor(a / 86400) + " d"
  return future ? "in " + text : text + " ago"
}

function formatWhen(sec, nowSec) {
  if (typeof sec !== "number" || !isFinite(sec)) return "time unknown"
  return formatClock(sec, nowSec) + " (" + formatAgo(sec, nowSec) + ")"
}

// ---------------------------------------------------------------- timing

// Poll for as long as at least one widget reads the shared state.
function shouldPoll(attachedCount) {
  return attachedCount > 0
}

// Cache sizes: only while a panel is open, never twice within DU_MIN_MS.
function duDue(openCount, lastMs, nowMs) {
  if (!(openCount > 0)) return false
  return !(lastMs > 0) || nowMs - lastMs >= DU_MIN_MS
}
