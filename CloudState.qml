pragma Singleton
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one systemd poll every bar reads, and the only place it is started.
//
// A bar surface exists per monitor, so BarWidget.qml exists once per output,
// and the state it shows is the same for all of them. Kept here, it is one
// `systemctl --user show` every Model.POLL_MS for the whole shell however many
// monitors there are (omavnc's ServerProbe.qml is the pattern; qmldir declares
// this file a singleton, which is load-bearing: without that line the name
// resolves to the component type and every property read off it is undefined).
//
// What runs, and when:
//   - poll (systemctl show, one batched call over every unit): every POLL_MS
//     while at least one widget is attached; at once on attach, on a panel
//     opening and SETTLE_MS after an action.
//   - sizes (du -s -B1 over the remotes' VFS cache dirs, one call): only while a
//     panel is open, and never twice within Model.DU_MIN_MS.
//     Both run through Model.BOUNDED_SCRIPT under `timeout -k` with a `head -c`
//     cap (Model.pollArgv, Model.sizesArgv); an answer without its end line
//     (cut by the timeout) is dropped and the last good state kept.
//   - scan (one `sh` over the offline-folder and backup config files, their
//     state files, the mount-root setting ~/.config/omarchy-cloud/cloud.env,
//     and whether the omarchy-cloud TUI and the two service
//     templates are installed; see
//     Model.SCAN_SCRIPT): never on a timer. At the first answer of the poll,
//     whenever a later poll shows a pair or job service exited again (each
//     run rewrites its state file just before it exits) or the instance list
//     changed, and on a panel opening. Conflict copies the user deletes by hand
//     therefore stay listed until the next sync run rewrites the state file
//     (the timer's interval at most, while it is enabled) or a panel opens.
//   - root check (one `sh` asking whether the mount root is a writable
//     directory; Model.ROOT_CHECK_SCRIPT, the root as "$1"): after each good
//     scan or setting read whose setting is a valid root, never otherwise.
//   - setting read (one `sh` reading only cloud.env; Model.SETTING_SCRIPT):
//     on a poll that starts no scan, and only while the root is not set up
//     (Model.rootNeedsReread: absent, invalid or missing), followed by the
//     root check; so Set up or the one-time sudo command clears the notice on
//     the next poll. Nothing extra runs while the root is ready. A scan can
//     start while a setting read runs, so each read of the setting (scan or
//     setting read) is numbered when it starts and an older answer never
//     overwrites a newer one's setting (Model.nextSettingSeq).
//   - versions (one `sh` reading the plugin's own manifest.json version, the
//     header of install.sh's installed-files manifest and whether the legacy
//     installed-binary.sha256 and the plugin's install.sh exist; see
//     Model.VERSIONS_SCRIPT): never on a timer. When the first widget
//     attaches and on a panel opening, so a run of "Update installed parts"
//     shows on the next opening.
//   - The env-file listing is a FolderListModel: a directory listing watched
//     by Qt, no process and no timer. A directory that does not exist when the
//     shell starts is not watched until the next restart.
// No Process is ever re-armed inside the turn it went idle in: an ask that
// lands on a running one is remembered (one flag) and run through callLater.
Singleton {
  id: root

  readonly property string home: Model.cleanHome(Quickshell.env("HOME"))
  // HOME-fixed, as the scripts and the TUI write it (XDG_STATE_HOME is never read).
  readonly property string stateDir: Model.stateHome(root.home)
  // This file's own folder, the plugin's (manifest.json, install.sh).
  readonly property string pluginDir: Model.pluginDirFromUrl(Qt.resolvedUrl("manifest.json"))

  // parseShow's map of the last good poll, and whether one arrived. units is
  // reassigned only when the answer changed, so a quiet poll wakes no
  // binding; polls counts every good answer (for relative times).
  property var units: ({})
  property bool polled: false
  property int polls: 0
  // Non-empty when the last poll brought no answer (see applyPoll).
  property string pollError: ""

  // Every remote seen this session: the poll's rclone-mount@ units and the env
  // files. Kept once seen, so a stopped, disabled remote without an env file
  // (which systemd unloads) stays on the panel until the shell restarts.
  property var knownRemotes: []
  property var envFiles: []
  // { remote: bytes } from the last du; lastSizesMs when it ran.
  property var sizes: ({})
  property real lastSizesMs: 0

  readonly property var remotes: Model.mergeRemotes(root.knownRemotes, Model.envRemotes(root.envFiles))
  // Before the MAX_REMOTES cap, so the panel can say it shows only some.
  readonly property int remotesFound: Model.remotesFound(root.knownRemotes, root.units, root.envFiles)

  // The last good scan (Model.parseScan), whether one arrived, and why the
  // last one failed (""). Offline folders and backups are their config files
  // plus the instances systemd reports in use; not kept once gone, so a pair
  // removed in the TUI leaves the panel.
  property var scanData: Model.emptyScan()
  property bool scanned: false
  property string scanError: ""
  property string scanKey: ""
  // The last good versions read (Model.parseVersions); its ok stays false
  // until one arrives, so nothing is claimed before that.
  property var versions: Model.emptyVersions()
  // The mount root: the setting from the last good scan (Model.rootSetting,
  // null before one), the root mounts use (the default without a valid
  // setting), the last root check ({ path, result }) and what the notice
  // makes of them (Model.rootStatus: "" until known).
  readonly property var rootSetting: root.scanned ? Model.rootSetting(root.scanData, root.home) : null
  readonly property string mountRoot: Model.mountRoot(root.rootSetting)
  property var rootCheck: ({ path: "", result: "" })
  readonly property string rootStatus: Model.rootStatus(root.rootSetting, root.rootCheck)
  readonly property var pairs: Model.mergePairs(Model.scanPairs(root.scanData), Model.unitPairs(root.units))
  readonly property var jobs: Model.mergeJobs(Model.scanJobs(root.scanData), Model.unitJobs(root.units))
  // A panel opened before the first answer had no remotes to size; the slot
  // is only spent on a du that ran, so the first remotes size at once.
  onRemotesChanged: root.refreshSizes(false)

  property var attached: []
  property var openPanels: []
  readonly property bool polling: Model.shouldPoll(root.attached.length)

  property bool pollPending: false
  property bool sizesPending: false
  property bool scanPending: false
  property bool versionsPending: false
  property bool rootPending: false
  // The setting's reads: the number of the last one started (scan or setting
  // read, one counter) and of the last one whose setting was applied.
  property int settingSeq: 0
  property int settingApplied: 0

  // Each bounded run gets a fresh token, read back against the token it was
  // armed with (Model.parseBounded), like the scan's.
  function refresh() {
    if (poll.running) { root.pollPending = true; return }
    var token = Model.scanToken()
    var argv = Model.pollArgv(root.remotes, token)
    if (argv.length === 0) return
    poll.token = token
    poll.command = argv
    poll.running = true
  }

  // Only for a valid setting (Model.rootCheckArgv refuses anything else); the
  // answer is kept with the path it was asked about.
  function recheckRoot() {
    var setting = Model.rootSetting(root.scanData, root.home)
    if (!setting || setting.state !== "valid") return
    if (rootProc.running) { root.rootPending = true; return }
    var argv = Model.rootCheckArgv(setting.path, root.home)
    if (argv.length === 0) return
    rootProc.path = setting.path
    rootProc.command = argv
    rootProc.running = true
  }

  function applyRootCheck(text, path) {
    var result = Model.parseRootCheck(text)
    if (result === "") return
    if (root.rootCheck.path !== path || root.rootCheck.result !== result) root.rootCheck = { path: path, result: result }
  }

  // Skipped while the scan (which reads the setting too) or an earlier read
  // is running: the next poll asks again, so nothing is re-armed.
  function rereadSetting() {
    if (scan.running || settingProc.running) return
    var token = Model.scanToken()
    var argv = Model.settingArgv(root.home, token)
    if (argv.length === 0) return
    settingProc.token = token
    root.settingSeq = Model.nextSettingSeq(root.settingSeq)
    settingProc.seq = root.settingSeq
    settingProc.command = argv
    settingProc.running = true
  }

  // A read cut by the timeout keeps the last setting; so does one older than
  // the last applied (Model.scanWithSettingRead).
  function applySetting(text, token, seq) {
    var parsed = Model.parseSettingRead(text, token)
    if (!parsed.ok) return
    var r = Model.scanWithSettingRead(root.scanData, parsed.setting, seq, root.settingApplied)
    root.settingApplied = r.applied
    var next = r.scan
    if (JSON.stringify(next) !== JSON.stringify(root.scanData)) root.scanData = next
    root.recheckRoot()
  }

  // A fresh token per run; the answer is read against the token it was armed
  // with (scan.token), so a line no file can forge marks each file.
  function rescan() {
    if (scan.running) { root.scanPending = true; return }
    var token = Model.scanToken()
    var argv = Model.scanArgv(root.home, root.stateDir, token)
    if (argv.length === 0) return
    scan.token = token
    root.settingSeq = Model.nextSettingSeq(root.settingSeq)
    scan.seq = root.settingSeq
    scan.command = argv
    scan.running = true
  }

  // Same token scheme as the scan.
  function recheckVersions() {
    if (versionsProc.running) { root.versionsPending = true; return }
    var token = Model.scanToken()
    var argv = Model.versionsArgv(root.pluginDir, root.stateDir, token)
    if (argv.length === 0) return
    versionsProc.token = token
    versionsProc.command = argv
    versionsProc.running = true
  }

  // A failed read keeps the last good one.
  function applyVersions(text, token) {
    var parsed = Model.parseVersions(text, token)
    if (!parsed.ok) return
    if (JSON.stringify(parsed) !== JSON.stringify(root.versions)) root.versions = parsed
  }

  // The poll never names a pair's or job's units (Model.showArgv), so a scan
  // that changes the instance list has nothing to ask systemd again. A scan
  // older than the last applied setting read keeps that read's setting
  // (Model.scanWithFreshSetting).
  function applyScan(text, token, seq) {
    var parsed = Model.parseScan(text, token, Model.scanDirs(root.home, root.stateDir))
    if (!parsed.ok) {
      root.scanError = "Could not read the offline-folder and backup files"
      return
    }
    var r = Model.scanWithFreshSetting(root.scanData, parsed, seq, root.settingApplied)
    root.settingApplied = r.applied
    var next = r.scan
    if (JSON.stringify(next) !== JSON.stringify(root.scanData)) root.scanData = next
    root.scanError = ""
    root.scanned = true
    root.recheckRoot()
  }

  function refreshSizes(force) {
    if (!force && !Model.duDue(root.openPanels.length, root.lastSizesMs, Date.now())) return
    if (root.openPanels.length === 0) return
    if (du.running) { root.sizesPending = true; return }
    var token = Model.scanToken()
    var argv = Model.sizesArgv(root.home, root.remotes, token)
    if (argv.length === 0) return
    root.lastSizesMs = Date.now()
    du.token = token
    du.command = argv
    du.running = true
  }

  // A du cut by the timeout keeps the last sizes.
  function applySizes(text, token) {
    var b = Model.parseBounded(text, token, Model.DU_MAX_CHARS)
    if (!b.ok) return
    root.sizes = Model.parseDu(b.text, root.home, root.remotes)
  }

  function settleSoon() { settle.restart() }

  function attach(owner) {
    if (!owner || root.attached.indexOf(owner) !== -1) return
    var first = root.attached.length === 0
    root.attached = root.attached.concat([owner])
    root.refresh()
    if (first) root.recheckVersions()
  }
  function detach(owner) { root.attached = without(root.attached, owner) }
  function holdOpen(owner) {
    if (!owner || root.openPanels.indexOf(owner) !== -1) return
    root.openPanels = root.openPanels.concat([owner])
    root.refresh()
    root.refreshSizes(false)
    root.rescan()
    root.recheckVersions()
  }
  function releaseOpen(owner) { root.openPanels = without(root.openPanels, owner) }
  function without(list, owner) {
    var index = list.indexOf(owner)
    if (index === -1) return list
    var next = list.slice()
    next.splice(index, 1)
    return next
  }

  // A working systemctl always answers with a block for Model.SENTINEL_UNIT,
  // which every poll names, so an answer without it is a failed poll
  // (systemctl missing, user manager unreachable); so is one cut by the
  // timeout (no end line). Either way the last good state is kept.
  function applyPoll(text, token) {
    var answer = Model.parseBounded(text, token, Model.SHOW_MAX_CHARS)
    if (!answer.ok) {
      root.pollError = "systemctl --user show timed out"
      return
    }
    var parsed = Model.parseShow(answer.text)
    if (!Object.prototype.hasOwnProperty.call(parsed, Model.SENTINEL_UNIT)) {
      root.pollError = "No answer from systemctl --user show"
      return
    }
    // Remotes first: a binding woken by `polled` sees every remote it found.
    var merged = Model.mergeRemotes(root.knownRemotes, Model.unitRemotes(parsed))
    if (merged.join("\n") !== root.knownRemotes.join("\n")) root.knownRemotes = merged
    if (JSON.stringify(parsed) !== JSON.stringify(root.units)) root.units = parsed
    root.pollError = ""
    root.polled = true
    root.polls++
    // A run finished (or the instances changed) since the last scan: read
    // the state files again. The first answer always differs from "".
    var key = Model.scanKey(root.pairs, root.jobs, root.units)
    if (key !== root.scanKey) {
      root.scanKey = key
      root.rescan()
    } else if (Model.rootNeedsReread(root.rootStatus)) {
      root.rereadSetting()
    }
  }

  function listNames(model, cap) {
    var out = []
    for (var i = 0; i < model.count && i < cap; i++) out.push(String(model.get(i, "fileName")))
    return out
  }

  // Bounded at the source: Model.pollArgv (timeout -k, head -c
  // Model.SHOW_MAX_CHARS, an end line).
  Process {
    id: poll
    property string token: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPoll(text, poll.token)
    }
    onRunningChanged: {
      if (poll.running || !root.pollPending) return
      root.pollPending = false
      Qt.callLater(root.refresh)
    }
  }

  // Bounded at the source: at most Model.SCAN_MAX_FILES files, the first
  // Model.SCAN_FILE_MAX_BYTES of each, under `timeout -k`; parseScan refuses
  // an answer over Model.SCAN_MAX_CHARS or without its end line.
  Process {
    id: scan
    property string token: ""
    property int seq: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text, scan.token, scan.seq)
    }
    onRunningChanged: {
      if (scan.running || !root.scanPending) return
      root.scanPending = false
      Qt.callLater(root.rescan)
    }
  }

  // Bounded like the scan: two files, the first Model.INSTALL_HEADER_MAX_BYTES
  // and Model.PLUGIN_MANIFEST_MAX_BYTES of each, under `timeout -k`;
  // parseVersions refuses an answer over Model.VERSIONS_MAX_CHARS or without
  // its end line.
  Process {
    id: versionsProc
    property string token: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyVersions(text, versionsProc.token)
    }
    onRunningChanged: {
      if (versionsProc.running || !root.versionsPending) return
      root.versionsPending = false
      Qt.callLater(root.recheckVersions)
    }
  }

  // du exits 1 when a cache dir is missing and still lists the others.
  // Bounded like the poll: Model.sizesArgv (head -c Model.DU_MAX_CHARS).
  Process {
    id: du
    property string token: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySizes(text, du.token)
    }
    onRunningChanged: {
      if (du.running || !root.sizesPending) return
      root.sizesPending = false
      Qt.callLater(function() { root.refreshSizes(true) })
    }
  }

  // Bounded like the scan: cloud.env's first Model.ROOT_SETTING_MAX_BYTES,
  // under `timeout -k`; parseSettingRead refuses an answer over
  // Model.SETTING_MAX_CHARS or without its end line.
  Process {
    id: settingProc
    property string token: ""
    property int seq: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySetting(text, settingProc.token, settingProc.seq)
    }
  }

  // One constant word on stdout, under `timeout -k`; no answer claims nothing.
  Process {
    id: rootProc
    property string path: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRootCheck(text, rootProc.path)
    }
    onRunningChanged: {
      if (rootProc.running || !root.rootPending) return
      root.rootPending = false
      Qt.callLater(root.recheckRoot)
    }
  }

  Timer {
    interval: Model.POLL_MS
    running: root.polling
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: Model.DU_MIN_MS
    running: root.openPanels.length > 0
    repeat: true
    onTriggered: root.refreshSizes(false)
  }

  Timer {
    id: settle
    interval: Model.SETTLE_MS
    repeat: false
    onTriggered: root.refresh()
  }

  FolderListModel {
    id: envListing
    folder: root.home !== "" ? Model.fileUrl(Model.envDir(root.home)) : ""
    nameFilters: ["*.env"]
    showDirs: false
    showDotAndDotDot: false
    showHidden: false
    onCountChanged: root.envFiles = root.listNames(envListing, Model.MAX_REMOTES * 4)
    onStatusChanged: if (envListing.status === FolderListModel.Ready) root.envFiles = root.listNames(envListing, Model.MAX_REMOTES * 4)
  }
}
