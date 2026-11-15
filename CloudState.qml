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
//   - scan (one `sh` over the offline-folder and backup config files, their
//     state files, and whether the omarchy-cloud TUI and the two service
//     templates are installed; see
//     Model.SCAN_SCRIPT): never on a timer. At the first answer of the poll,
//     whenever a later poll shows a pair or job service exited again (each
//     run rewrites its state file just before it exits) or the instance list
//     changed, and on a panel opening. Conflict copies the user deletes by hand
//     therefore stay listed until the next sync run rewrites the state file
//     (the timer's interval at most, while it is enabled) or a panel opens.
//   - The env-file listing is a FolderListModel: a directory listing watched
//     by Qt, no process and no timer. A directory that does not exist when the
//     shell starts is not watched until the next restart.
// No Process is ever re-armed inside the turn it went idle in: an ask that
// lands on a running one is remembered (one flag) and run through callLater.
Singleton {
  id: root

  readonly property string home: Model.cleanHome(Quickshell.env("HOME"))
  readonly property string stateDir: Model.stateHome(root.home, Quickshell.env("XDG_STATE_HOME"))

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

  function refresh() {
    if (poll.running) { root.pollPending = true; return }
    poll.command = Model.showArgv(root.remotes)
    poll.running = true
  }

  // A fresh token per run; the answer is read against the token it was armed
  // with (scan.token), so a line no file can forge marks each file.
  function rescan() {
    if (scan.running) { root.scanPending = true; return }
    var token = Model.scanToken()
    var argv = Model.scanArgv(root.home, root.stateDir, token)
    if (argv.length === 0) return
    scan.token = token
    scan.command = argv
    scan.running = true
  }

  // The poll never names a pair's or job's units (Model.showArgv), so a scan
  // that changes the instance list has nothing to ask systemd again.
  function applyScan(text, token) {
    var parsed = Model.parseScan(text, token, Model.scanDirs(root.home, root.stateDir))
    if (!parsed.ok) {
      root.scanError = "Could not read the offline-folder and backup files"
      return
    }
    if (JSON.stringify(parsed) !== JSON.stringify(root.scanData)) root.scanData = parsed
    root.scanError = ""
    root.scanned = true
  }

  function refreshSizes(force) {
    if (!force && !Model.duDue(root.openPanels.length, root.lastSizesMs, Date.now())) return
    if (root.openPanels.length === 0) return
    if (du.running) { root.sizesPending = true; return }
    var argv = Model.duArgv(root.home, root.remotes)
    if (argv.length === 0) return
    root.lastSizesMs = Date.now()
    du.command = argv
    du.running = true
  }

  function settleSoon() { settle.restart() }

  function attach(owner) {
    if (!owner || root.attached.indexOf(owner) !== -1) return
    root.attached = root.attached.concat([owner])
    root.refresh()
  }
  function detach(owner) { root.attached = without(root.attached, owner) }
  function holdOpen(owner) {
    if (!owner || root.openPanels.indexOf(owner) !== -1) return
    root.openPanels = root.openPanels.concat([owner])
    root.refresh()
    root.refreshSizes(false)
    root.rescan()
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
  // (systemctl missing, user manager unreachable); the last good state is kept.
  function applyPoll(text) {
    var parsed = Model.parseShow(text)
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
    }
  }

  function listNames(model, cap) {
    var out = []
    for (var i = 0; i < model.count && i < cap; i++) out.push(String(model.get(i, "fileName")))
    return out
  }

  Process {
    id: poll
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPoll(text)
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text, scan.token)
    }
    onRunningChanged: {
      if (scan.running || !root.scanPending) return
      root.scanPending = false
      Qt.callLater(root.rescan)
    }
  }

  // du exits 1 when a cache dir is missing and still lists the others.
  Process {
    id: du
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sizes = Model.parseDu(text, root.home, root.remotes)
    }
    onRunningChanged: {
      if (du.running || !root.sizesPending) return
      root.sizesPending = false
      Qt.callLater(function() { root.refreshSizes(true) })
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
