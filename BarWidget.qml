import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Cloud Mounts: the rclone-mount@<remote> systemd user mounts, the offline
// folders (rclone-bisync@<pair>) and the backups (rclone-backup@<job>), as a
// cloud in the bar and a panel on click.
//
// State comes from CloudState.qml, a singleton shared by every bar (one
// systemctl poll for the whole shell; see that file for what runs when). This
// file lays the state out and runs the user's actions; every parse, argv and
// string is in Model.js.
//
// Actions, all argv arrays through Quickshell.execDetached or a Process (no
// shell string carries a remote name; Model.isValidRemote gates every name):
//   - toggle on:  systemctl --user start rclone-mount@<r>.service
//   - toggle off: first, only then, `fuser -v -M -m /mnt/cloud/<r>` (who has
//     files open; Model.FUSER_SCRIPT) and the pending-upload count
//     (Model.PENDING_SCRIPT), each under `timeout -k`, the path as "$1".
//     Nothing open and nothing pending: stop at once. Otherwise the row says
//     what is open / pending and offers Force (Unmount when only uploads are
//     pending, Stop anyway when the check could not answer), which sends the
//     same stop: the unit's ExecStop is already a lazy `fusermount3 -uz`. No
//     process is ever killed, no cache file deleted.
//   - open folder: uwsm-app -- nautilus --new-window ~/Cloud/<r>
//   - show log (failed units): journalctl --user -u <unit> -n 20, bounded.
//   - Sync now: systemctl --user start --no-block rclone-bisync@<pair>.service,
//     only while that pair's timer or path unit is enabled.
//   - Configure… (also a right-click on the bar icon): omarchy-launch-tui
//     --app-id=TUI.float ~/.local/bin/omarchy-cloud (Model.configureArgv says
//     why not launch-or-focus), only once the scan has found the binary
//     installed; until then a right-click opens the panel, which says why.
//   - Update installed parts (shown while the parts install.sh installed are
//     missing, unversioned or of another version than the plugin;
//     Model.installState): omarchy-launch-tui --app-id=TUI.float bash -c
//     Model.INSTALL_SCRIPT with the plugin folder's install.sh as "$1", in a
//     visible terminal that stays open on the result until Enter. The panel
//     closes; the next opening reads the versions again.
//
// Every Text in this file declares textFormat: Text.PlainText (journal output
// and file names are shown here); the model test counts them.
Panel {
  id: root
  moduleName: "io.github.rsd.cloud-mounts"
  ipcTarget: "io.github.rsd.cloud-mounts"

  // ------------------------------------------------------------- state

  // The bar glyph's size, for the installed-parts badge. Style.bar.iconSize
  // is missing from older shells (reading it gives undefined, and a badge
  // sized from that is NaN, so invisible): 12 is the shell's default.
  readonly property real barIconSize: {
    var s = Number(Style.bar.iconSize)
    return isFinite(s) && s > 0 ? s : 12
  }
  readonly property string home: CloudState.home
  readonly property bool polled: CloudState.polled
  readonly property var rows: Model.remoteRows(CloudState.remotes, CloudState.units, CloudState.sizes)
  // The Repeater's model: names only, reassigned only when the list of names
  // changes, so a poll updates each row's delegate in place (row, tooltip and
  // a click in progress survive it) instead of rebuilding them all.
  property var rowNames: []
  onRowsChanged: {
    var names = Model.rowNames(root.rows)
    if (!Model.sameList(names, root.rowNames)) root.rowNames = names
  }
  // Moved on every poll (CloudState.polls), so the relative times follow
  // without a timer here.
  property real now: Date.now() / 1000
  readonly property var pairRows: Model.pairRows(CloudState.pairs, CloudState.units, CloudState.scanData, root.now)
  readonly property var jobRows: Model.jobRows(CloudState.jobs, CloudState.units, CloudState.scanData, root.now)
  // Keyed by name like rowNames, for the same reason.
  property var pairNames: []
  property var jobNames: []
  onPairRowsChanged: {
    var names = Model.rowNames(root.pairRows)
    if (!Model.sameList(names, root.pairNames)) root.pairNames = names
  }
  onJobRowsChanged: {
    var names = Model.rowNames(root.jobRows)
    if (!Model.sameList(names, root.jobNames)) root.jobNames = names
  }
  // Failed syncs and backups and conflict copies alert the bar like a failed
  // mount (Model.problems).
  readonly property string agg: Model.aggregate(root.rows, root.pairRows, root.jobRows, root.polled)
  readonly property bool appInstalled: CloudState.scanned && CloudState.scanData.app === true
  // The installed parts against the plugin (Model.installState): "" until
  // read, else none | unknown | mismatch | ok. Anything but ok puts a quiet
  // mark on the bar icon; an error still shows as the error.
  readonly property string installState: Model.installState(CloudState.versions)
  readonly property string installNotice: Model.installNotice(CloudState.versions)
  readonly property bool canInstall: root.installNotice !== "" && CloudState.versions.installer === true && CloudState.pluginDir !== ""
  readonly property bool nothingSetUp: root.polled && root.rows.length === 0 && root.pairRows.length === 0 && root.jobRows.length === 0

  // The stop in progress (one at a time): which remote, "checking" or
  // "confirm", and what the two checks found.
  property string stopRemote: ""
  property string stopPhase: ""
  property var stopBusy: null
  property int stopPending: -1
  property bool busyDone: false
  property bool pendingDone: false
  // Which stop a check's answer belongs to. A check left running by an
  // earlier stop (fuser stuck on a hung mount) answers into nothing, and a
  // later stop does not wait for it: that stop's busy answer is "could not
  // check", which asks before stopping.
  property int checkGen: 0
  readonly property bool busyChecking: busyCheck.running && busyCheck.gen === root.checkGen
  readonly property bool pendingChecking: pendingCheck.running && pendingCheck.gen === root.checkGen

  // Keyboard cursor (see Model.cursorGroups): off until the first key press
  // after opening, as in the shell's own panels; the mouse moves it too, so
  // one control is highlighted at a time.
  property bool cursorActive: false
  property string cursorKey: ""
  readonly property var cursorGroups: Model.cursorGroups(root.rows, {
    stopRemote: root.stopRemote,
    confirm: root.stopPhase === "confirm",
    logUnit: root.logUnit,
    pairs: root.pairRows,
    jobs: root.jobRows,
    canInstall: root.canInstall,
    canConfigure: root.appInstalled
  })
  readonly property string cursorAt: Model.cursorKeyIn(root.cursorGroups, root.cursorKey, root.stopRemote)

  // The journal shown in the panel, if any (one unit at a time).
  property string logUnit: ""
  property string logText: ""

  // ------------------------------------------------------------- style

  readonly property color foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color urgent: root.bar ? root.bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(root.foreground, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- actions

  function run(argv) {
    if (!argv || argv.length === 0) return
    Quickshell.execDetached(argv)
    CloudState.settleSoon()
  }

  function toggleRemote(row) {
    var action = Model.toggleAction(row)
    if (action === "start") {
      if (root.stopRemote === row.name) root.cancelStop()
      root.run(Model.startArgv(row.name))
    } else if (action === "stop") {
      root.beginStop(row)
    }
  }

  // Not mounted (a unit failing and retrying) has nothing open to check.
  // Only a check phase in progress blocks a stop: a check process still
  // running from an earlier one is skipped (its answer is ignored), never
  // waited on.
  function beginStop(row) {
    if (root.stopPhase === "checking") return
    if (!row.mounted) {
      root.cancelStop()
      root.run(Model.stopArgv(row.name))
      return
    }
    root.checkGen++
    root.stopRemote = row.name
    root.stopPhase = "checking"
    root.stopBusy = null
    root.stopPending = -1
    root.busyDone = false
    root.pendingDone = false
    var busyArgv = Model.fuserArgv(row.name)
    if (busyArgv.length > 0 && !busyCheck.running) {
      busyCheck.gen = root.checkGen
      busyCheck.command = busyArgv
      busyCheck.running = true
    } else {
      root.busyDone = true
    }
    var pendingArgv = Model.pendingArgv(root.home, row.name)
    if (pendingArgv.length > 0 && !pendingCheck.running) {
      pendingCheck.gen = root.checkGen
      pendingCheck.command = pendingArgv
      pendingCheck.running = true
    } else {
      root.pendingDone = true
    }
    checkTimeout.restart()
    root.checkDone()
  }

  function checkDone() {
    if (root.stopPhase !== "checking" || !root.busyDone || !root.pendingDone) return
    checkTimeout.stop()
    if (Model.stopDecision(root.stopBusy, root.stopPending) === "stop") {
      var remote = root.stopRemote
      root.cancelStop()
      root.run(Model.stopArgv(remote))
    } else {
      root.stopPhase = "confirm"
    }
  }

  function forceStop() {
    if (root.stopPhase !== "confirm") return
    var remote = root.stopRemote
    root.cancelStop()
    root.run(Model.stopArgv(remote))
  }

  function cancelStop() {
    var a = Model.cursorAction(root.cursorKey)
    if ((a.kind === "force" || a.kind === "cancel") && root.stopRemote !== "")
      root.cursorKey = Model.cursorKey("switch", root.stopRemote)
    root.stopRemote = ""
    root.stopPhase = ""
    root.stopBusy = null
    root.stopPending = -1
  }

  function toggleLog(unit) {
    if (root.logUnit === unit) {
      root.logUnit = ""
      root.logText = ""
      return
    }
    var argv = Model.journalArgv(unit)
    if (argv.length === 0 || logProc.running) return
    root.logUnit = unit
    root.logText = "Loading…"
    logProc.command = argv
    logProc.running = true
  }

  function openFolder(remote) {
    var argv = Model.openFolderArgv(root.home, remote)
    if (argv.length > 0) Quickshell.execDetached(argv)
  }

  // Only for a pair the poll shows enabled and not already running.
  function syncNow(pair) {
    var row = Model.rowByName(root.pairRows, pair)
    if (!row || !row.canSync) return
    root.run(Model.syncNowArgv(row.name))
  }

  // The TUI floats over the desktop; the panel closes so it gets the focus.
  function configure() {
    if (!root.appInstalled) return
    var argv = Model.configureArgv(root.home)
    if (argv.length === 0) return
    Quickshell.execDetached(argv)
    root.close()
  }

  // install.sh runs in a terminal that stays open on its result; the panel
  // closes so the terminal gets the focus.
  function updateInstalled() {
    if (!root.canInstall) return
    var argv = Model.installArgv(CloudState.pluginDir)
    if (argv.length === 0) return
    Quickshell.execDetached(argv)
    root.close()
  }

  // Right-click: the TUI once installed; until then the panel, which says why.
  function pressButton(b) {
    if (b === Qt.RightButton) {
      if (root.appInstalled) root.configure()
      else if (!root.opened) root.open()
      return
    }
    root.toggle()
  }

  // --------------------------------------------------------------- cursor

  function pointAt(key) {
    root.cursorActive = true
    root.cursorKey = key
  }

  function moveCursor(dx, dy) {
    var from = root.cursorAt
    var next = Model.stepCursor(root.cursorGroups, from, dx, dy)
    // Past the first or last stop, Up/Down still scrolls (a long log).
    if (next === from && dy !== 0) root.scrollBy(dy)
    root.cursorKey = next
  }

  function activateCursor() {
    var a = Model.cursorAction(root.cursorAt)
    var row = a.kind === "switch" ? Model.rowByName(root.rows, a.arg) : null
    if (a.kind === "switch") {
      if (row) root.toggleRemote(row)
    } else if (a.kind === "folder") root.openFolder(a.arg)
    else if (a.kind === "log") root.toggleLog(a.arg)
    else if (a.kind === "force") root.forceStop()
    else if (a.kind === "cancel") root.cancelStop()
    else if (a.kind === "sync") root.syncNow(a.arg)
    else if (a.kind === "install") root.updateInstalled()
    else if (a.kind === "configure") root.configure()
  }

  // The Dropbox panel's scroll-into-view: the control under the cursor is
  // kept inside the visible part of the panel.
  function scrollItemIntoView(item) {
    if (!item) return
    Qt.callLater(function() {
      if (!item || !item.visible) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // The box opens with the cursor on Cancel, the safe choice.
  onStopPhaseChanged: if (root.stopPhase === "confirm") root.cursorKey = "cancel"

  Component.onCompleted: {
    root.rowNames = Model.rowNames(root.rows)
    root.pairNames = Model.rowNames(root.pairRows)
    root.jobNames = Model.rowNames(root.jobRows)
    CloudState.attach(root)
  }

  onOpenedChanged: {
    if (root.opened) {
      root.cursorActive = false
      panelFlick.contentY = 0
      CloudState.holdOpen(root)
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }
    CloudState.releaseOpen(root)
    if (root.stopPhase === "confirm") root.cancelStop()
    root.logUnit = ""
    root.logText = ""
  }

  // A widget torn down with its panel open gets no close; both holds go back.
  Component.onDestruction: {
    CloudState.releaseOpen(root)
    CloudState.detach(root)
  }

  Connections {
    target: CloudState
    function onPollsChanged() { root.now = Date.now() / 1000 }
  }

  // ------------------------------------------------------------ processes

  // Both checks answer on stdout (Model.FUSER_SCRIPT merges fuser's two
  // streams). A run that never reports (fuser missing, killed by timeout)
  // leaves stopBusy null or unknown: "could not check", which asks before
  // stopping. An answer for an earlier stop (gen) is dropped.
  Process {
    id: busyCheck
    property int gen: -1
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (busyCheck.gen !== root.checkGen || root.stopPhase !== "checking") return
        root.stopBusy = Model.parseFuser(text, root.stopRemote)
        root.busyDone = true
        root.checkDone()
      }
    }
    onRunningChanged: if (!busyCheck.running && busyCheck.gen === root.checkGen) settleChecks.restart()
  }

  Process {
    id: pendingCheck
    property int gen: -1
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (pendingCheck.gen !== root.checkGen || root.stopPhase !== "checking") return
        root.stopPending = Model.parsePendingCount(text)
        root.pendingDone = true
        root.checkDone()
      }
    }
    onRunningChanged: if (!pendingCheck.running && pendingCheck.gen === root.checkGen) settleChecks.restart()
  }

  // A check whose stream never finished counts as done with no answer.
  Timer {
    id: settleChecks
    interval: 1000
    repeat: false
    onTriggered: {
      if (root.stopPhase !== "checking" || root.busyChecking || root.pendingChecking) return
      root.busyDone = true
      root.pendingDone = true
      root.checkDone()
    }
  }

  // Both checks run under `timeout -k`, which answers first; this covers a
  // process that outlives even SIGKILL (D state on a hung mount). It asks
  // instead of waiting: the late answer is dropped by gen, and the next stop
  // does not wait for the stuck process either.
  Timer {
    id: checkTimeout
    interval: Model.CHECK_DEADLINE_MS
    repeat: false
    onTriggered: {
      if (root.stopPhase !== "checking") return
      if (root.busyChecking) busyCheck.running = false
      if (root.pendingChecking) pendingCheck.running = false
      root.busyDone = true
      root.pendingDone = true
      root.checkDone()
    }
  }

  Process {
    id: logProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.logUnit !== "") root.logText = Model.formatLog(text)
    }
  }

  // ------------------------------------------------------------ bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barIcon(root.agg)
    active: root.agg === "error"
    dimmed: root.agg === "none" || root.agg === "unknown"
    tooltipText: Model.tooltipText(root.rows, root.pairRows, root.jobRows, root.polled, CloudState.pollError,
      root.installNotice, root.appInstalled)
    onPressed: function(b) { root.pressButton(b) }

    // The installed-parts mark: a small badge in the glyph's own colour
    // (button.foreground, which follows the bar's transparency) with a 1 px
    // ring in the surface colour, as the shell's Tailscale badge. It sits on
    // the glyph box's upper-right corner, clear of the cloud, clamped inside
    // the slot so a vertical bar does not clip it. Quieter than the error's
    // urgent colour, which wins.
    BorderSurface {
      readonly property real size: Math.max(7, Math.round(root.barIconSize * 0.42))
      visible: root.installNotice !== "" && root.agg !== "error"
      width: size
      height: size
      radius: size / 2
      color: button.foreground
      borderSpec: Border.flat(Commons.Color.popups.background, 1)
      x: Math.max(0, Math.min(button.width - size, Math.round(button.width / 2 + root.barIconSize / 2 - size / 2)))
      y: Math.max(0, Math.min(button.height - size, Math.round(button.height / 2 - root.barIconSize / 2 - size / 2)))
    }
  }

  // ----------------------------------------------------------------- panel

  function scrollBy(dy) {
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY + dy * Style.space(48)))
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    // As tall as the content, capped only by the screen the panel can use
    // (as the shell's network panel); past that the content scrolls, with
    // the scroll bar in a strip of its own (see the Column's width).
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The first key press only shows the cursor, as in the Dropbox panel.
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          id: panelScroll
          policy: ScrollBar.AsNeeded
        }

        Column {
          id: column
          // When the panel scrolls, the bar gets its own strip rather than
          // sitting on top of the right-aligned switches and buttons.
          width: panelFlick.width - (panelFlick.interactive ? panelScroll.width + Style.space(6) : 0)
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Cloud Mounts"
            meta: Model.summary(root.rows, root.polled, root.pairRows, root.jobRows)
            foreground: root.foreground
            fontFamily: root.fontFamily
            // Dimmed like the bar glyph when nothing is mounted or known.
            iconOpacity: root.agg === "none" || root.agg === "unknown" ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                text: Model.barIcon(root.agg)
                textFormat: Text.PlainText
                color: root.agg === "error" ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: CloudState.pollError !== ""
            width: parent.width
            text: CloudState.pollError
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "REMOTES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.polled && root.rows.length === 0
            width: parent.width
            text: root.nothingSetUp
              ? "Nothing set up yet: no mounts, offline folders or backups. Configure… below sets them up."
              : "No rclone-mount@ units or ~/.config/rclone-mount/*.env files found."
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.rowNames
            RemoteRow {
              required property var modelData
              width: column.width
              row: Model.rowByName(root.rows, modelData)
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: Model.capText(root.rows.length, CloudState.remotesFound, "remotes")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Offline folders: hidden while there is none.
          Column {
            visible: root.pairNames.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "OFFLINE FOLDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.pairNames
              PairRow {
                required property var modelData
                width: column.width
                row: Model.rowByName(root.pairRows, modelData)
              }
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: Model.capText(root.pairRows.length, Model.pairsFound(CloudState.scanData, CloudState.units), "offline folders")
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Backups: hidden while there is none.
          Column {
            visible: root.jobNames.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "BACKUPS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.jobNames
              JobRow {
                required property var modelData
                width: column.width
                row: Model.rowByName(root.jobRows, modelData)
              }
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: Model.capText(root.jobRows.length, Model.jobsFound(CloudState.scanData, CloudState.units), "backups")
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            visible: CloudState.scanError !== "" || CloudState.scanData.more === true
            width: parent.width
            text: CloudState.scanError !== "" ? CloudState.scanError
              : "More configuration and state files than the panel reads (" + Model.SCAN_MAX_FILES + "); some are not shown."
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: CloudState.scanError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.foreground }

          // The installed parts are missing, unversioned or of another
          // version: the line on its own, full width, and beneath it, on the
          // right, the button that runs install.sh (hidden, not disabled,
          // without the plugin's install.sh).
          Column {
            visible: root.installNotice !== ""
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.installNotice
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              id: installButton
              visible: root.canInstall
              anchors.right: parent.right
              text: Model.INSTALL_BUTTON_TEXT
              iconText: Model.ICON.update
              tooltipText: "Runs install.sh from the plugin folder in a terminal"
              hasCursor: root.cursorActive && root.cursorAt === "install"
              onHasCursorChanged: if (installButton.hasCursor) root.scrollItemIntoView(installButton)
              onHovered: function(isHovered) { if (isHovered) root.pointAt("install") }
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.updateInstalled()
            }
          }

          // Footer: Configure… opens the omarchy-cloud TUI. Disabled (and so
          // not a cursor stop) until the scan has found it installed; the
          // reason is the text beside it, since a disabled button shows no
          // tooltip.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              visible: text !== ""
              text: root.installNotice !== "" ? "" : Model.configureHint(CloudState.scanned, root.appInstalled)
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Item { Layout.fillWidth: true; visible: root.installNotice !== "" || Model.configureHint(CloudState.scanned, root.appInstalled) === "" }

            Button {
              id: configureButton
              text: "Configure…"
              iconText: Model.ICON.settings
              tooltipText: "Mounts, offline folders and backups (omarchy-cloud)"
              enabled: root.appInstalled
              opacity: enabled ? 1 : 0.45
              hasCursor: root.cursorActive && root.cursorAt === "configure"
              onHasCursorChanged: if (configureButton.hasCursor) root.scrollItemIntoView(configureButton)
              onHovered: function(isHovered) { if (isHovered && configureButton.enabled) root.pointAt("configure") }
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.configure()
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  // The journal of root.logUnit, plain text, already bounded by Model.formatLog.
  component LogView: Rectangle {
    implicitHeight: logLabel.implicitHeight + Style.space(12)
    color: Style.normalFillFor(root.foreground, Commons.Color.accent)
    radius: Style.cornerRadius

    Text {
      id: logLabel
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(6)
      text: root.logText
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One offline folder: name, LOCAL (from its .conf), last sync, Sync now,
  // the log of a failed run, why Sync now is disabled, its conflict copies.
  component PairRow: Column {
    id: pairRow
    property var row: null
    readonly property string name: pairRow.row ? pairRow.row.name : ""
    readonly property string unit: pairRow.row ? pairRow.row.unit : ""
    spacing: Style.space(4)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: pairRow.row && pairRow.row.running ? Model.ICON.busy : Model.ICON.sync
        textFormat: Text.PlainText
        color: pairRow.row && (pairRow.row.failed || pairRow.row.conflictCount > 0) ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: pairRow.name
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: pairRow.row ? pairRow.row.local : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        Text {
          Layout.fillWidth: true
          text: pairRow.row ? pairRow.row.text : ""
          textFormat: Text.PlainText
          color: pairRow.row && pairRow.row.failed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }

      PanelActionButton {
        id: pairLog
        readonly property string key: Model.cursorKey("log", pairRow.unit)
        // A stopped watch is not a failed run: its note says how to restart it.
        visible: pairRow.row !== null && ((pairRow.row.failed && (!pairRow.row.watchStopped || pairRow.row.runFailed === true)) || root.logUnit === pairRow.unit)
        iconText: Model.ICON.log
        tooltipText: root.logUnit === pairRow.unit ? "Hide log" : "Show log"
        hasCursor: root.cursorActive && root.cursorAt === pairLog.key
        onHasCursorChanged: if (pairLog.hasCursor) root.scrollItemIntoView(pairRow)
        onHovered: function(isHovered) { if (isHovered) root.pointAt(pairLog.key) }
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.toggleLog(pairRow.unit)
      }

      // Disabled, it shows no tooltip; the reason is the text below.
      Button {
        id: pairSync
        readonly property string key: Model.cursorKey("sync", pairRow.name)
        text: pairRow.row && pairRow.row.running ? "Syncing…" : "Sync now"
        iconText: Model.ICON.sync
        tooltipText: "systemctl --user start " + pairRow.unit
        enabled: pairRow.row !== null && pairRow.row.canSync
        opacity: enabled ? 1 : 0.45
        hasCursor: root.cursorActive && root.cursorAt === pairSync.key
        onHasCursorChanged: if (pairSync.hasCursor) root.scrollItemIntoView(pairRow)
        onHovered: function(isHovered) { if (isHovered && pairSync.enabled) root.pointAt(pairSync.key) }
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        bordered: true
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.syncNow(pairRow.name)
      }
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: pairRow.row ? pairRow.row.blockedText : ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: pairRow.row ? pairRow.row.conflictText : ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    LogView {
      visible: pairRow.row !== null && root.logUnit === pairRow.unit
      width: parent.width
    }
  }

  // One backup job: name, last run, next run, the log of a failed run.
  component JobRow: Column {
    id: jobRow
    property var row: null
    readonly property string name: jobRow.row ? jobRow.row.name : ""
    readonly property string unit: jobRow.row ? jobRow.row.unit : ""
    spacing: Style.space(4)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: jobRow.row && jobRow.row.running ? Model.ICON.busy : Model.ICON.backup
        textFormat: Text.PlainText
        color: jobRow.row && jobRow.row.failed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: jobRow.name
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: jobRow.row ? jobRow.row.text + (jobRow.row.next !== "" ? " · " + jobRow.row.next : "") : ""
          textFormat: Text.PlainText
          color: jobRow.row && jobRow.row.failed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }

      PanelActionButton {
        id: jobLog
        readonly property string key: Model.cursorKey("log", jobRow.unit)
        visible: jobRow.row !== null && (jobRow.row.failed || root.logUnit === jobRow.unit)
        iconText: Model.ICON.log
        tooltipText: root.logUnit === jobRow.unit ? "Hide log" : "Show log"
        hasCursor: root.cursorActive && root.cursorAt === jobLog.key
        onHasCursorChanged: if (jobLog.hasCursor) root.scrollItemIntoView(jobRow)
        onHovered: function(isHovered) { if (isHovered) root.pointAt(jobLog.key) }
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.toggleLog(jobRow.unit)
      }
    }

    LogView {
      visible: jobRow.row !== null && root.logUnit === jobRow.unit
      width: parent.width
    }
  }

  component RemoteRow: Column {
    id: remoteRow
    property var row: null
    readonly property string name: remoteRow.row ? remoteRow.row.name : ""
    readonly property string unit: remoteRow.row ? remoteRow.row.unit : ""
    readonly property bool stopping: root.stopRemote !== "" && root.stopRemote === remoteRow.name
    spacing: Style.space(4)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: remoteRow.row && remoteRow.row.failed ? Model.ICON.error
          : remoteRow.row && remoteRow.row.mounted ? Model.ICON.all
          : remoteRow.row && remoteRow.row.transitional ? Model.ICON.busy : Model.ICON.none
        textFormat: Text.PlainText
        color: remoteRow.row && remoteRow.row.failed ? root.urgent : root.foreground
        opacity: remoteRow.row && (remoteRow.row.mounted || remoteRow.row.failed) ? 1 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: remoteRow.name
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: remoteRow.stopping && root.stopPhase === "checking" ? "checking open files…"
            : remoteRow.row ? remoteRow.row.detail : ""
          textFormat: Text.PlainText
          color: remoteRow.row && remoteRow.row.failed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: rowLog
        readonly property string key: Model.cursorKey("log", remoteRow.unit)
        visible: remoteRow.row !== null && (remoteRow.row.failed || root.logUnit === remoteRow.unit)
        iconText: Model.ICON.log
        tooltipText: root.logUnit === remoteRow.unit ? "Hide log" : "Show log"
        hasCursor: root.cursorActive && root.cursorAt === rowLog.key
        onHasCursorChanged: if (rowLog.hasCursor) root.scrollItemIntoView(remoteRow)
        onHovered: function(isHovered) { if (isHovered) root.pointAt(rowLog.key) }
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.toggleLog(remoteRow.unit)
      }

      // Only while mounted: there is no folder to open otherwise, and the
      // row's state text ("stopped", "failed") already says why.
      PanelActionButton {
        id: rowFolder
        readonly property string key: Model.cursorKey("folder", remoteRow.name)
        visible: remoteRow.row !== null && remoteRow.row.mounted
        iconText: Model.ICON.folder
        tooltipText: "Open ~/" + Model.CLOUD_LINKS + "/" + remoteRow.name
        hasCursor: root.cursorActive && root.cursorAt === rowFolder.key
        onHasCursorChanged: if (rowFolder.hasCursor) root.scrollItemIntoView(remoteRow)
        onHovered: function(isHovered) { if (isHovered) root.pointAt(rowFolder.key) }
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.openFolder(remoteRow.name)
      }

      ToggleSwitch {
        id: mountSwitch
        readonly property string key: Model.cursorKey("switch", remoteRow.name)
        checked: remoteRow.row !== null && remoteRow.row.on
        busy: remoteRow.row === null || remoteRow.row.transitional || (remoteRow.stopping && root.stopPhase === "checking")
        hasCursor: root.cursorActive && root.cursorAt === mountSwitch.key
        onHasCursorChanged: if (mountSwitch.hasCursor) root.scrollItemIntoView(remoteRow)
        onHovered: function(isHovered) { if (isHovered) root.pointAt(mountSwitch.key) }
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: root.toggleRemote(remoteRow.row)

        PanelToolTip {
          visible: mountSwitch.containsMouse
          text: remoteRow.row && remoteRow.row.on ? "Unmount " + remoteRow.name : "Mount " + remoteRow.name
          fontFamily: root.fontFamily
        }
      }
    }

    // What is still open / pending, and the choice.
    Rectangle {
      id: confirmBox
      visible: remoteRow.stopping && root.stopPhase === "confirm"
      width: parent.width
      implicitHeight: confirmColumn.implicitHeight + Style.space(12)
      color: Style.hoverFillFor(root.urgent, root.urgent)
      radius: Style.cornerRadius

      Column {
        id: confirmColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(6)
        spacing: Style.space(6)

        Text {
          width: parent.width
          text: remoteRow.stopping ? Model.stopPrompt(remoteRow.name, root.stopBusy, root.stopPending) : ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(8)

          Button {
            id: forceButton
            text: Model.confirmLabel(root.stopBusy)
            hasCursor: root.cursorActive && root.cursorAt === "force"
            onHasCursorChanged: if (forceButton.hasCursor) root.scrollItemIntoView(confirmBox)
            onHovered: function(isHovered) { if (isHovered) root.pointAt("force") }
            foreground: root.urgent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: root.forceStop()
          }

          Button {
            id: cancelButton
            text: "Cancel"
            hasCursor: root.cursorActive && root.cursorAt === "cancel"
            onHasCursorChanged: if (cancelButton.hasCursor) root.scrollItemIntoView(confirmBox)
            onHovered: function(isHovered) { if (isHovered) root.pointAt("cancel") }
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: root.cancelStop()
          }
        }
      }
    }

    LogView {
      visible: remoteRow.row !== null && root.logUnit === remoteRow.unit
      width: parent.width
    }
  }
}
