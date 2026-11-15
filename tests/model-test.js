#!/usr/bin/env node

// Exercises ../Model.js, which is written as a QML JS module (bare function
// declarations, no exports) and so is loaded here by evaluating it and lifting
// the names out, the same approach as power-watch's and omavnc's model tests.
// Also checks the QML sources against the model (every Model.<name> exists,
// every Text is plain text, no shell string, no rclone, no network).
//
// Times are local; the suite pins TZ before the first Date is built.

process.env.TZ = "UTC"

const fs = require("fs")
const path = require("path")
const assert = require("assert")

const pluginDir = path.join(__dirname, "..")
const source = fs.readFileSync(path.join(pluginDir, "Model.js"), "utf8")
// Every top-level name, so nothing the QML uses can be missed by the lift.
const NAMES = [...new Set([...source.matchAll(/^(?:function\s+(\w+)\s*\(|var\s+(\w+)\s*=)/gm)]
  .map(m => m[1] || m[2]))]
const model = new Function(source + "\nreturn {" + NAMES.join(",") + "}")()

const tests = []
const test = (name, fn) => tests.push([name, fn])

const HOME = "/home/u"
const NOW = 1794700000  // 2026-11-14 23:46:40 UTC

// Names a hostile env file, unit or script could carry.
const CRAFTED = [
  "a;rm -rf ~", "$(x)", "`x`", "-x", "--help", "../x", "x/../y", "..", ".hidden", "a b",
  "a\nb", "a\tb", "x\u0000y", "gdrive\n", " gdrive", "naïve", "‮gdrive", "ドライブ", "a*", "a?",
  "a[1]", "a|b", "a&b", "a>b", "a'b", "a\"b", "a\\b", "", "x".repeat(65), "_x", "a,b", "a=b",
  "a:b", "a@b", "a/b", "/abs", "~", "%h", "a\rb"
]
const VALID = ["gdrive", "personal_drive", "work_drive", "onedrive", "lake-s3", "media-s3", "a", "A1", "x.y", "a-b_c.d",
  // The contract pattern exactly: dots anywhere after the first character
  // (a name never holds "/", so ".." inside one is no path segment).
  "a..b", "x..", "a.", "A" + "b".repeat(63)]

// A block of `systemctl show --timestamp=unix` output.
const block = (over) => Object.entries(Object.assign({
  Id: "rclone-mount@gdrive.service", LoadState: "loaded", ActiveState: "active", SubState: "running",
  UnitFileState: "enabled", ActiveEnterTimestamp: "@1794686440", InactiveEnterTimestamp: "",
  Result: "success", ExecMainExitTimestamp: "", ExecMainStatus: "0"
}, over || {})).map(([k, v]) => k + "=" + v).join("\n")
const show = (...blocks) => blocks.join("\n\n") + "\n"
// One offline folder's three units and one backup job's two, as systemctl
// shows template instances (the service is static, the timer and path carry
// the enablement), plus the sentinel.
const pairBlocks = (pair, over) => {
  const o = over || {}
  return [
    block(Object.assign({ Id: "rclone-bisync@" + pair + ".service", ActiveState: "inactive", SubState: "dead", UnitFileState: "static" }, o.service)),
    block(Object.assign({ Id: "rclone-bisync@" + pair + ".path", ActiveState: "inactive", SubState: "dead", UnitFileState: "disabled" }, o.path)),
    block(Object.assign({ Id: "rclone-bisync@" + pair + ".timer", ActiveState: "inactive", SubState: "dead", UnitFileState: "disabled", NextElapseUSecRealtime: "" }, o.timer))
  ]
}
const jobBlocks = (job, over) => {
  const o = over || {}
  return [
    block(Object.assign({ Id: "rclone-backup@" + job + ".service", ActiveState: "inactive", SubState: "dead", UnitFileState: "static",
      InactiveEnterTimestamp: "@1794686996", ExecMainExitTimestamp: "@1794686996" }, o.service)),
    block(Object.assign({ Id: "rclone-backup@" + job + ".timer", ActiveState: "active", SubState: "waiting", UnitFileState: "enabled",
      NextElapseUSecRealtime: "@1794712159" }, o.timer))
  ]
}
const sentinel = () => block({ Id: "default.target", UnitFileState: "static" })

// SCAN_SCRIPT's output for `files` ({ path: content }), as the script prints
// it: the token's marker lines, each file's byte size, its content, then end.
const TOKEN = "cmscan-abcdefghijkl0123"
const DIRS = { bisyncConf: "/home/u/.config/rclone-bisync", backupConf: "/home/u/.config/rclone-backup",
  bisyncState: "/home/u/.local/state/rclone-bisync", backupState: "/home/u/.local/state/rclone-backup" }
const scanOut = (files, o) => {
  const opt = o || {}
  let out = opt.app === false ? "" : TOKEN + " app\n"
  for (const [p, content] of Object.entries(files)) {
    const size = opt.sizes && opt.sizes[p] !== undefined ? opt.sizes[p] : Buffer.byteLength(content)
    out += TOKEN + " file " + size + " " + p + "\n" + content + "\n" + TOKEN + " eof\n"
  }
  return out + (opt.end === false ? "" : TOKEN + " end\n")
}
const clean = (s, what) => assert.ok(!/NaN|null|undefined|Infinity|\[object/.test(s), (what || "text") + ": " + JSON.stringify(s))

// Every argv builder, fed one remote name.
const argvsFor = (name) => [
  model.startArgv(name), model.stopArgv(name), model.fuserArgv(name), model.pendingArgv(HOME, name),
  model.duArgv(HOME, [name]), model.journalArgv("rclone-mount@" + name + ".service"),
  model.journalArgv(name), model.openFolderArgv(HOME, name), model.showArgv([name], [name], [name]),
  model.syncNowArgv(name), model.journalArgv("rclone-bisync@" + name + ".service"),
  model.journalArgv("rclone-backup@" + name + ".service")
]

// ------------------------------------------------------------ validation

test("valid remote names pass", () => {
  for (const n of VALID) assert.ok(model.isValidRemote(n), n)
})

test("crafted remote names are rejected", () => {
  for (const n of CRAFTED) assert.ok(!model.isValidRemote(n), JSON.stringify(n))
  for (const v of [null, undefined, 1, {}, ["gdrive"], true]) assert.ok(!model.isValidRemote(v), String(v))
})

test("crafted names never reach an argv", () => {
  for (const n of CRAFTED) {
    for (const argv of argvsFor(n)) {
      for (const arg of argv) {
        if (n === "") continue
        assert.ok(!arg.includes(n), JSON.stringify(n) + " reached " + JSON.stringify(argv))
      }
    }
    // The builders that name a remote return nothing for an invalid one.
    for (const argv of [model.startArgv(n), model.stopArgv(n), model.fuserArgv(n), model.pendingArgv(HOME, n),
      model.duArgv(HOME, [n]), model.journalArgv("rclone-mount@" + n + ".service"), model.openFolderArgv(HOME, n),
      model.syncNowArgv(n), model.journalArgv("rclone-bisync@" + n + ".service"), model.journalArgv("rclone-backup@" + n + ".service")]) {
      assert.deepStrictEqual(argv, [], JSON.stringify(n) + " built " + JSON.stringify(argv))
    }
    // The batched poll still runs, without it.
    const poll = model.showArgv([n, "gdrive"], [n], [n, "admin"])
    assert.deepStrictEqual(poll.slice(13), ["rclone-mount@gdrive.service", "default.target"])
  }
})

test("unit, env and du paths are parsed back to valid names only", () => {
  assert.strictEqual(model.remoteFromUnit("rclone-mount@gdrive.service"), "gdrive")
  assert.strictEqual(model.remoteFromUnit("rclone-mount@lake-s3.service"), "lake-s3")
  for (const n of CRAFTED) assert.strictEqual(model.remoteFromUnit("rclone-mount@" + n + ".service"), "", JSON.stringify(n))
  // systemd's own escaping of a bad name never comes back as a name either.
  assert.strictEqual(model.remoteFromUnit("rclone-mount@a\\x3brm.service"), "")
  for (const bad of ["", "rclone-mount@.service", "rclone-mount@gdrive", "xrclone-mount@gdrive.service",
    "rclone-mount@gdrive.timer", "legacy-bisync.service", null, undefined, 7]) assert.strictEqual(model.remoteFromUnit(bad), "", String(bad))
  assert.strictEqual(model.remoteFromEnvFile("gdrive.env"), "gdrive")
  assert.strictEqual(model.remoteFromEnvFile("x.y.env"), "x.y")
  for (const n of CRAFTED) assert.strictEqual(model.remoteFromEnvFile(n + ".env"), "", JSON.stringify(n))
  for (const bad of [".env", "gdrive", "gdrive.env.bak", null]) assert.strictEqual(model.remoteFromEnvFile(bad), "", String(bad))
})

test("pair and job units are parsed back to valid names only", () => {
  for (const k of ["service", "timer", "path"]) assert.strictEqual(model.pairFromUnit("rclone-bisync@vault-A." + k), "vault-A")
  for (const k of ["service", "timer"]) assert.strictEqual(model.jobFromUnit("rclone-backup@archive-vaults." + k), "archive-vaults")
  assert.strictEqual(model.pairFromUnit("rclone-bisync@x.y.service"), "x.y")
  for (const n of CRAFTED) {
    assert.strictEqual(model.pairFromUnit("rclone-bisync@" + n + ".service"), "", JSON.stringify(n))
    assert.strictEqual(model.jobFromUnit("rclone-backup@" + n + ".timer"), "", JSON.stringify(n))
    assert.strictEqual(model.pairUnit(n, "service"), "", JSON.stringify(n))
    assert.strictEqual(model.jobUnit(n, "service"), "", JSON.stringify(n))
  }
  for (const bad of ["rclone-bisync@.service", "rclone-bisync@p.socket", "rclone-bisync@p", "rclone-backup@j.path",
    "rclone-bisync@*.service", "legacy-bisync.service", "xrclone-bisync@p.service", null, undefined, 3])
    assert.strictEqual(model.pairFromUnit(bad) + model.jobFromUnit(bad), "", String(bad))
  assert.strictEqual(model.pairUnit("p", "socket"), "")
  assert.strictEqual(model.jobUnit("j", "path"), "")
})

test("pairs and jobs from the units: only instances in use", () => {
  const units = model.parseShow(show(...pairBlocks("idle"), ...pairBlocks("on", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" } }),
    ...pairBlocks("busy", { service: { ActiveState: "activating" } }), ...pairBlocks("$(x)", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" } }),
    ...jobBlocks("daily"), ...jobBlocks("off", { timer: { UnitFileState: "disabled", ActiveState: "inactive" } }),
    block({ Id: "rclone-bisync@gone.timer", LoadState: "not-found", UnitFileState: "enabled" }), sentinel()))
  // "idle" is only loaded because a poll named it; without its .conf it is gone.
  assert.deepStrictEqual(model.unitPairs(units), ["busy", "on"])
  assert.deepStrictEqual(model.unitJobs(units), ["daily"])
  assert.deepStrictEqual(model.unitPairs(null), [])
  const many = Array.from({ length: 40 }, (_, i) => "p" + String(i).padStart(2, "0"))
  assert.strictEqual(model.mergePairs(many).length, model.MAX_PAIRS)
  assert.strictEqual(model.mergeJobs(many).length, model.MAX_JOBS)
  assert.deepStrictEqual(model.mergePairs(["b", "a;b", "a"], ["a"]), ["a", "b"])
})

test("mergeRemotes keeps valid names only, sorted, unique, capped", () => {
  assert.deepStrictEqual(model.mergeRemotes(["onedrive", "gdrive"], ["gdrive", "$(x)", "lake-s3"], null, "gdrive"),
    ["gdrive", "lake-s3", "onedrive"])
  const many = Array.from({ length: 50 }, (_, i) => "r" + String(i).padStart(2, "0"))
  assert.strictEqual(model.mergeRemotes(many).length, model.MAX_REMOTES)
  assert.deepStrictEqual(model.envRemotes(["gdrive.env", "a;b.env", "x.txt", "onedrive.env"]), ["gdrive", "onedrive"])
})

test("HOME is refused unless absolute and clean", () => {
  assert.strictEqual(model.cleanHome("/home/u"), "/home/u")
  assert.strictEqual(model.cleanHome("/home/u/"), "/home/u")
  for (const bad of ["", "home/u", "/home/../etc", "/home/./u", "/home//u", "/home/u\n", "/", null, undefined])
    assert.strictEqual(model.cleanHome(bad), "", String(bad))
  assert.deepStrictEqual(model.pendingArgv("relative", "gdrive"), [])
  assert.deepStrictEqual(model.openFolderArgv("", "gdrive"), [])
  assert.deepStrictEqual(model.duArgv("/a/../b", ["gdrive"]), [])
})

// ------------------------------------------------------------------ argv

test("argv shapes", () => {
  assert.deepStrictEqual(model.startArgv("gdrive"), ["systemctl", "--user", "start", "rclone-mount@gdrive.service"])
  assert.deepStrictEqual(model.stopArgv("lake-s3"), ["systemctl", "--user", "stop", "rclone-mount@lake-s3.service"])
  assert.deepStrictEqual(model.syncNowArgv("vault-A"), ["systemctl", "--user", "start", "--no-block", "rclone-bisync@vault-A.service"])
  assert.deepStrictEqual(model.configureArgv(HOME), ["omarchy-launch-tui", "--app-id=TUI.float", "/home/u/.local/bin/omarchy-cloud"])
  for (const bad of ["", "relative", "/a/../b", null]) assert.deepStrictEqual(model.configureArgv(bad), [], String(bad))
  assert.deepStrictEqual(model.fuserArgv("gdrive"),
    ["timeout", "-k", "2", "10", "sh", "-c", model.FUSER_SCRIPT, "cloud-mounts-busy", "/mnt/cloud/gdrive"])
  // fuser's PIDs go to stdout and the rest of its table to stderr: the script
  // merges them, and the widget reads that one stream.
  assert.ok(/^fuser -v -M -m "\$1" 2>&1; echo "cloud-mounts-fuser-exit \$\?"$/.test(model.FUSER_SCRIPT), model.FUSER_SCRIPT)
  for (const bad of ["", "relative", "/a\nb", null]) assert.deepStrictEqual(model.fuserPathArgv(bad), [], String(bad))
  assert.deepStrictEqual(model.openFolderArgv(HOME, "gdrive"), ["uwsm-app", "--", "nautilus", "--new-window", "/home/u/Cloud/gdrive"])
  assert.deepStrictEqual(model.journalArgv("rclone-mount@gdrive.service"),
    ["journalctl", "--user", "-u", "rclone-mount@gdrive.service", "-n", "20", "--no-pager", "-o", "short"])
  assert.deepStrictEqual(model.journalArgv("rclone-bisync@vault-A.service").slice(0, 4), ["journalctl", "--user", "-u", "rclone-bisync@vault-A.service"])
  assert.deepStrictEqual(model.journalArgv("rclone-backup@archive-vaults.service")[3], "rclone-backup@archive-vaults.service")
  for (const other of ["legacy-bisync.service", "legacy-bisync.timer", "sshd.service", "rclone-mount@*.service", "rclone-bisync@vault-A.timer",
    "rclone-bisync@vault-A.path", "rclone-backup@archive-vaults.timer", "rclone-bisync@*.service", "-x", "", null])
    assert.deepStrictEqual(model.journalArgv(other), [], other)
  // Allocated bytes, not apparent size: rclone's cache files are sparse.
  assert.deepStrictEqual(model.duArgv(HOME, ["onedrive", "gdrive"]),
    ["du", "-s", "-B1", "--", "/home/u/.cache/rclone/vfs/gdrive", "/home/u/.cache/rclone/vfs/onedrive"])
  assert.ok(!model.duArgv(HOME, ["gdrive"]).some(a => /^-\w*b|--apparent-size|--bytes/.test(a)), "du never counts apparent size")
  assert.deepStrictEqual(model.duArgv(HOME, []), [])
})

test("the poll is one batched systemctl show over every unit", () => {
  const argv = model.showArgv(["onedrive", "gdrive"])
  assert.deepStrictEqual(argv.slice(0, 7), ["systemctl", "--user", "show", "--timestamp=unix", "-p", model.SHOW_PROPS.join(","), "--"])
  assert.deepStrictEqual(argv.slice(7), ["rclone-mount@*.service", "rclone-bisync@*.service", "rclone-bisync@*.timer",
    "rclone-bisync@*.path", "rclone-backup@*.service", "rclone-backup@*.timer",
    "rclone-mount@gdrive.service", "rclone-mount@onedrive.service", "default.target"])
  assert.ok(argv.indexOf("--") < argv.indexOf(model.UNIT_GLOB))
  // No instance name is hardcoded: with nothing known, only globs and the sentinel.
  assert.deepStrictEqual(model.showArgv().slice(7), [model.UNIT_GLOB].concat(model.BISYNC_GLOBS, model.BACKUP_GLOBS, [model.SENTINEL_UNIT]))
  assert.ok(!/vault-A|work_drive|personal_drive|onedrive|gdrive/i.test(source.replace(/\/\/.*$/gm, "")), "no instance name in Model.js code")
  // Bounded: every cap at once stays under what parseShow keeps.
  const many = n => Array.from({ length: 50 }, (_, i) => n + i)
  assert.ok(model.showArgv(many("r"), many("p"), many("j")).length - 7 < model.SHOW_MAX_UNITS)
})

test("the poll never names a pair's or job's unit, so it loads none", () => {
  // Naming rclone-bisync@<p>.path loads it, and without the setup drop-in
  // systemd refuses it in the journal ("lacks path setting") on every poll.
  // Only the globs reach them, whatever the caller knows: config files, or
  // the instances the last poll's globs returned.
  const units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" } }),
    ...jobBlocks("archive-vaults"), sentinel()))
  for (const argv of [model.showArgv(["gdrive"], ["vault-A", "notes"], ["archive-vaults"]),
    model.showArgv(["gdrive"], model.unitPairs(units), model.unitJobs(units)), model.showArgv(["gdrive"])]) {
    const named = argv.slice(7).filter(a => /^rclone-(bisync|backup)@/.test(a) && !a.includes("*"))
    assert.deepStrictEqual(named, [], JSON.stringify(argv))
    assert.deepStrictEqual(argv.slice(7).filter(a => a.includes("*")), [model.UNIT_GLOB].concat(model.BISYNC_GLOBS, model.BACKUP_GLOBS))
  }
  // A template name is never in the poll: systemctl show refuses one and
  // fails the whole call.
  assert.ok(!model.showArgv(["gdrive"]).some(a => /@\./.test(a)))
})

test("the only shells are the three constant scripts under timeout, values positional", () => {
  const argv = model.pendingArgv(HOME, "gdrive")
  assert.deepStrictEqual(argv, ["timeout", "-k", "2", "10", "bash", "-c", model.PENDING_SCRIPT, "cloud-mounts-pending",
    "/home/u/.cache/rclone/vfsMeta/gdrive"])
  for (const script of [model.PENDING_SCRIPT, model.FUSER_SCRIPT]) {
    // "$?" is the exit status of the command just run; the pending script's own
    // variable n and PIPESTATUS are the only others.
    assert.ok(!/\$\{|\$[0-9A-Za-z_]/.test(script.replace(/"\$1"/g, "").replace(/ \$\?"/, "\"")
      .replace(/"\$\{PIPESTATUS\[0\]\}"/g, "").replace(/\$\(grep/, "(grep").replace(/case \$\? in/, "case x in").replace(/"\$n"/, "")), script)
    assert.ok(!script.includes("gdrive"))
  }
  // Every other builder is argv only, never a shell; both shells are timed.
  for (const argv2 of argvsFor("gdrive")) {
    if (argv2.length === 0) continue
    if (argv2[0] === "timeout") {
      assert.deepStrictEqual(argv2.slice(0, 4), ["timeout", "-k", String(model.CHECK_KILL_S), String(model.CHECK_TIMEOUT_S)])
      assert.ok((argv2[4] === "bash" && argv2[6] === model.PENDING_SCRIPT) || (argv2[4] === "sh" && argv2[6] === model.FUSER_SCRIPT), JSON.stringify(argv2))
      assert.strictEqual(argv2[5], "-c")
      continue
    }
    assert.ok(["systemctl", "du", "journalctl", "uwsm-app"].includes(argv2[0]), JSON.stringify(argv2))
    assert.ok(!argv2.includes("-c"), JSON.stringify(argv2))
  }
  assert.ok(model.CHECK_DEADLINE_MS > (model.CHECK_TIMEOUT_S + model.CHECK_KILL_S) * 1000, "timeout answers before the widget gives up")
})

test("the scan: constant script, paths and bounds as positional arguments, token checked", () => {
  const argv = model.scanArgv(HOME, model.stateHome(HOME, ""), TOKEN)
  assert.deepStrictEqual(argv, ["timeout", "-k", "2", "10", "sh", "-c", model.SCAN_SCRIPT, "cloud-mounts-scan", TOKEN,
    String(model.SCAN_FILE_MAX_BYTES), String(model.SCAN_MAX_FILES), "/home/u/.local/bin/omarchy-cloud",
    "/home/u/.config/omarchy-cloud/cloud.env", String(model.ROOT_SETTING_MAX_BYTES),
    DIRS.bisyncConf, DIRS.backupConf, DIRS.bisyncState, DIRS.backupState])
  assert.strictEqual(model.ROOT_SETTING_MAX_BYTES, 4096)
  // The script expands only its own variables and positional parameters.
  const vars = new Set([...model.SCAN_SCRIPT.matchAll(/\$\{?([A-Za-z_]\w*|[0-9@#?])/g)].map(m => m[1]))
  assert.deepStrictEqual([...vars].sort(), ["1", "2", "3", "4", "5", "6", "@", "a", "c", "d", "e", "f", "l", "m", "n", "r", "s", "t"])
  for (const v of ["a", "c", "d", "e", "f", "l", "m", "r", "s", "t"]) assert.ok(new RegExp("(^|\\s)" + v + "=|for " + v + " in|read -r " + v + ";").test(model.SCAN_SCRIPT), v + " is assigned")
  // Every expansion of a value is quoted, except the first line's assignments
  // (no word splitting there) and the arithmetic on the counter.
  const body = model.SCAN_SCRIPT.split("\n")
  assert.strictEqual(body[0], "t=$1 c=$2 m=$3 a=$4 e=$5 r=$6")
  assert.ok(!/[^"(]\$[a-z@1-6]/.test(body.slice(1).join("\n").replace(/\$\(\(n \+ 1\)\)/, "").replace(/\$\(wc -c <"\$[fe]"\)/g, "")), model.SCAN_SCRIPT)
  // The mount-root setting: a regular file, bounded like the others.
  assert.ok(/if \[ -f "\$e" \] && s=\$\(wc -c <"\$e"\); then/.test(model.SCAN_SCRIPT), "the setting: regular file only")
  assert.ok(/head -c "\$r" -- "\$e"/.test(model.SCAN_SCRIPT), "the setting read bounded")
  // Regular files only; a symlink is followed to one (the helper scripts
  // follow it too), a FIFO, device, directory or dangling link is skipped.
  assert.ok(/\[ -f "\$f" \] \|\| continue/.test(model.SCAN_SCRIPT), "regular files only")
  assert.ok(!/-L "\$f"/.test(model.SCAN_SCRIPT), "a symlinked conf is read like the scripts read it")
  // The templates: constant unit names, bounded, every line behind the token.
  assert.ok(model.SCAN_SCRIPT.includes("systemctl --user list-unit-files --no-legend --plain -- 'rclone-bisync@.service' 'rclone-backup@.service' 2>/dev/null | head -n " + model.TEMPLATE_MAX_LINES + " | while IFS= read -r l; do printf '%s unitfile %s\\n' \"$t\" \"$l\"; done"))
  for (const u of [model.BISYNC_TEMPLATE, model.BACKUP_TEMPLATE]) assert.ok(/^[a-z-]+@\.service$/.test(u), u)
  assert.ok(/head -c "\$c" -- "\$f"/.test(model.SCAN_SCRIPT), "each file read bounded")
  // State is HOME-fixed: an XDG_STATE_HOME value is never used; state and
  // config directories are listed once each.
  for (const x of ["/x/state", "", "relative", "/a/../b", "/a\nb", null, undefined]) assert.strictEqual(model.stateHome(HOME, x), "/home/u/.local/state", String(x))
  assert.strictEqual(model.stateHome("", ""), "")
  assert.deepStrictEqual(model.scanArgv(HOME, "/home/u/.config", TOKEN).slice(14), [DIRS.bisyncConf, DIRS.backupConf])
  // No argv without a usable home or with a token not of the expected shape.
  for (const bad of ["", "relative", "/a/../b"]) assert.deepStrictEqual(model.scanArgv(bad, "/x", TOKEN), [], String(bad))
  for (const bad of ["", "x", "cmscan-short", "cmscan-ABCDEFGHIJKLMN", "cmscan-abcdefghijkl0123 end", null])
    assert.deepStrictEqual(model.scanArgv(HOME, "/x", bad), [], String(bad))
  // A crafted $HOME stays inside its own arguments.
  const weird = "/tmp/$(touch x) `y`; z"
  const w = model.scanArgv(weird, model.stateHome(weird, ""), TOKEN)
  assert.strictEqual(w[6], model.SCAN_SCRIPT)
  assert.ok([w[11], w[12]].concat(w.slice(14)).every(a => a.indexOf(weird) === 0))
  assert.strictEqual(w[13], String(model.ROOT_SETTING_MAX_BYTES))
  // Tokens are drawn fresh and match the accepted shape.
  const t1 = model.scanToken(), t2 = model.scanToken()
  assert.ok(model.SCAN_TOKEN_RE.test(t1) && model.SCAN_TOKEN_RE.test(t2) && t1 !== t2, t1 + " " + t2)
})

test("stop and force send the same plain stop (the unit's ExecStop is a lazy unmount)", () => {
  const unit = fs.readFileSync(path.join(pluginDir, "Model.js"), "utf8")
  assert.ok(/ExecStop is `fusermount3 -uz`/.test(unit))
  const bar = fs.readFileSync(path.join(pluginDir, "BarWidget.qml"), "utf8")
  assert.ok(!/fusermount/.test(bar.replace(/\/\/.*$/gm, "")), "the widget never runs fusermount itself")
  assert.ok(/function forceStop\(\)[\s\S]{0,200}Model\.stopArgv\(remote\)/.test(bar))
})

// --------------------------------------------------------------- parsing

test("parseShow: blocks by Id, only known props, duplicates kept once", () => {
  const text = show(block(), block({ Id: "rclone-mount@onedrive.service", ActiveState: "failed", Result: "exit-code" }),
    block({ ActiveState: "inactive" }), "Bogus=1\nId=", "Id=x.service\nEvil=$(rm)\nActiveState=active")
  const u = model.parseShow(text)
  assert.deepStrictEqual(Object.keys(u).sort(), ["rclone-mount@gdrive.service", "rclone-mount@onedrive.service", "x.service"])
  assert.strictEqual(u["rclone-mount@gdrive.service"].ActiveState, "active", "the first block of a duplicate wins")
  assert.strictEqual(u["x.service"].Evil, undefined)
  assert.deepStrictEqual(model.parseShow(""), {})
  assert.deepStrictEqual(model.parseShow(null), {})
  // A value may contain "=".
  assert.strictEqual(model.parseShow("Id=a.service\nResult=a=b\n").a ? 1 : model.parseShow("Id=a.service\nResult=a=b\n")["a.service"].Result, "a=b")
  // Bounded.
  const huge = Array.from({ length: 400 }, (_, i) => block({ Id: "u" + i + ".service" })).join("\n\n")
  assert.strictEqual(Object.keys(model.parseShow(huge)).length <= model.SHOW_MAX_UNITS, true)
  assert.ok(Object.keys(model.parseShow("x".repeat(model.SHOW_MAX_CHARS * 2))).length === 0)
})

test("parseUnixTs", () => {
  assert.strictEqual(model.parseUnixTs("@1794686996"), 1794686996)
  for (const bad of ["", "1794686996", "@", "@-1", "@0", "@1.5", "Sat 2026-11-14 17:09:56 -03", null, undefined])
    assert.strictEqual(model.parseUnixTs(bad), null, String(bad))
})

test("parseDu maps exact cache paths to remotes and ignores the rest", () => {
  const text = "1048576\t/home/u/.cache/rclone/vfs/gdrive\n12\t/home/u/.cache/rclone/vfs/onedrive\n99\t/etc\nbad line\n5\t/home/u/.cache/rclone/vfs/gdrive/sub\n"
  assert.deepStrictEqual(model.parseDu(text, HOME, ["gdrive", "onedrive", "lake-s3"]), { gdrive: 1048576, onedrive: 12 })
  assert.deepStrictEqual(model.parseDu("", HOME, ["gdrive"]), {})
  assert.deepStrictEqual(model.parseDu(text, "", ["gdrive"]), {})
})

// Captured with psmisc fuser 23.7 through FUSER_SCRIPT exactly as the widget
// runs it (stdout, both streams merged), on a live rclone mount with a `sleep`
// holding its cwd there, then on the same mount idle, then on a path that is
// not a mount point.
const REAL_BUSY = "                     USER        PID ACCESS COMMAND\n"
  + "/mnt/cloud/lake-s3: root     kernel mount /mnt/cloud/lake-s3\n"
  + "                     alice      3161757 ..c.. sleep\n"
  + "cloud-mounts-fuser-exit 0\n"
const REAL_IDLE = "                     USER        PID ACCESS COMMAND\n"
  + "/mnt/cloud/lake-s3: root     kernel mount /mnt/cloud/lake-s3\n"
  + "cloud-mounts-fuser-exit 0\n"
const REAL_NOT_MOUNTED = "Specified filename /mnt/cloud/lake-s3 does not exist.\n"
  + "Specified filename /mnt/cloud/lake-s3 is not a mountpoint.\n"
  + "cloud-mounts-fuser-exit 1\n"
// The same busy run split by stream: what the widget read before the fix
// (stderr only) and the other half (stdout only).
const REAL_BUSY_STDERR = "                     USER        PID ACCESS COMMAND\n"
  + "/mnt/cloud/lake-s3: root      mount /mnt/cloud/lake-s3\n                     alice      ..c.. sleep\n"
const REAL_BUSY_STDOUT = "kernel 3161757"

test("parseFuser on real fuser output: a busy mount is busy, an idle one idle", () => {
  assert.deepStrictEqual(model.parseFuser(REAL_BUSY, "lake-s3"),
    { known: true, procs: [{ pid: 3161757, user: "alice", command: "sleep" }], total: 1 })
  assert.strictEqual(model.stopDecision(model.parseFuser(REAL_BUSY, "lake-s3"), 0), "confirm")
  assert.deepStrictEqual(model.parseFuser(REAL_IDLE, "lake-s3"), { known: true, procs: [], total: 0 })
  assert.strictEqual(model.stopDecision(model.parseFuser(REAL_IDLE, "lake-s3"), 0), "stop")
  assert.strictEqual(model.parseFuser(REAL_NOT_MOUNTED, "lake-s3").known, false)
})

test("parseFuser: one stream alone is never read as idle", () => {
  // Before the fix the widget read stderr only and this parsed to known, 0
  // processes: a busy mount was stopped without asking.
  for (const half of [REAL_BUSY_STDERR, REAL_BUSY_STDOUT]) {
    const b = model.parseFuser(half, "lake-s3")
    assert.notStrictEqual(model.stopDecision(b, 0), "stop", JSON.stringify(half))
  }
})

test("parseFuser: a run cut short (timeout, bound) could not check", () => {
  // No exit line: killed by timeout after the kernel row, before the scan.
  const killed = REAL_IDLE.replace(/cloud-mounts-fuser-exit 0\n$/, "")
  assert.deepStrictEqual(model.parseFuser(killed, "lake-s3"), { known: false, procs: [], total: 0 })
  assert.strictEqual(model.stopDecision(model.parseFuser(killed, "lake-s3"), 0), "confirm")
  assert.strictEqual(model.parseFuser(REAL_IDLE.replace("exit 0", "exit 124"), "lake-s3").known, false)
  assert.strictEqual(model.parseFuser("", "lake-s3").known, false)
  assert.strictEqual(model.parseFuser("sh: line 1: fuser: command not found\ncloud-mounts-fuser-exit 127\n", "lake-s3").known, false)
  // Over the size bound the exit line is cut off, but a process seen is busy.
  const huge = REAL_BUSY.replace("cloud-mounts-fuser-exit 0\n", " ".repeat(model.FUSER_MAX_CHARS) + "\ncloud-mounts-fuser-exit 0\n")
  const h = model.parseFuser(huge, "lake-s3")
  assert.strictEqual(h.known, true)
  assert.strictEqual(h.total, 1)
  assert.strictEqual(model.parseFuser(REAL_IDLE.replace("cloud-mounts-fuser-exit 0\n", " ".repeat(model.FUSER_MAX_CHARS) + "\ncloud-mounts-fuser-exit 0\n"), "lake-s3").known, false)
  // The could-not-check box says so and asks.
  assert.strictEqual(model.confirmLabel(model.parseFuser(killed, "lake-s3")), "Stop anyway")
  assert.ok(/timed out\)\. Stop anyway\?$/.test(model.stopPrompt("lake-s3", model.parseFuser(killed, "lake-s3"), 0)))
  assert.strictEqual(model.confirmLabel(model.parseFuser(REAL_BUSY, "lake-s3")), "Force unmount")
  assert.strictEqual(model.confirmLabel(model.parseFuser(REAL_IDLE, "lake-s3")), "Unmount")
  assert.strictEqual(model.confirmLabel(null), "Stop anyway")
})

test("parseFuser: duplicates once, bounded, other mounts and crafted names refused, text cleaned", () => {
  const head = "                     USER        PID ACCESS COMMAND\n/mnt/cloud/gdrive:   root     kernel mount /mnt/cloud/gdrive\n"
  const busy = head + "                     alice       1764 f.... libreoffice\n                     alice       1877 ..c.. bash\n"
    + "                     alice       1877 ..c.. bash\ncloud-mounts-fuser-exit 0\n"
  const b = model.parseFuser(busy, "gdrive")
  assert.strictEqual(b.known, true)
  assert.strictEqual(b.total, 2)
  assert.deepStrictEqual(b.procs, [{ pid: 1764, user: "alice", command: "libreoffice" }, { pid: 1877, user: "alice", command: "bash" }])
  const many = Array.from({ length: 30 }, (_, i) => "   alice   " + (100 + i) + " f.... p" + i).join("\n")
  const m = model.parseFuser(head + many + "\ncloud-mounts-fuser-exit 0\n", "gdrive")
  assert.strictEqual(m.total, 30)
  assert.strictEqual(m.procs.length, model.MAX_BUSY_SHOWN)
  // Another mount's listing does not answer for this one.
  assert.strictEqual(model.parseFuser(REAL_IDLE, "gdrive").known, false)
  assert.strictEqual(model.parseFuser(head + "cloud-mounts-fuser-exit 0\n", "$(x)").known, false)
  const ctl = model.parseFuser(head + "   alice  7 f.... ev\u001b[31mil\ncloud-mounts-fuser-exit 0\n", "gdrive")
  assert.ok(!/\u001b/.test(ctl.procs[0].command))
})

test("parsePendingCount", () => {
  assert.strictEqual(model.parsePendingCount("0\n"), 0)
  assert.strictEqual(model.parsePendingCount("  12\n"), 12)
  for (const bad of ["", "x", "1 2", "-1", null]) assert.strictEqual(model.parsePendingCount(bad), -1, String(bad))
})

test("parseState: time, exit, counts, conflicts; malformed lines skipped", () => {
  const st = model.parseState(["time=1794699700", "exit=0", "conflict=Personal.kdbx.conflict1", "conflict=sub/x.conflict2",
    "conflict=Personal.kdbx.conflict1", "time=5", "exit=9", "bogus", "conflict=", "EXIT=3", " time=7"])
  assert.deepStrictEqual(st, { time: 1794699700, exit: 0, ok: null, failed: null,
    conflicts: ["Personal.kdbx.conflict1", "sub/x.conflict2"], conflictsTruncated: false })
  const job = model.parseState(["time=1794686996", "exit=1", "ok=3", "failed=2"])
  assert.deepStrictEqual([job.time, job.exit, job.ok, job.failed], [1794686996, 1, 3, 2])
  // Out of range or not a number: no value.
  const bad = model.parseState(["time=0", "exit=256", "ok=-1", "failed=1e3", "time=abc"])
  assert.deepStrictEqual([bad.time, bad.exit, bad.ok, bad.failed], [null, null, null, null])
  assert.strictEqual(model.parseState(["time=" + "9".repeat(13)]).time, null)
  // Control characters out, length capped; CRLF tolerated.
  const ctl = model.parseState(["exit=0\r", "conflict=a\u001b[31mb\u0007", "conflict=" + "z".repeat(500)])
  assert.strictEqual(ctl.exit, 0)
  assert.strictEqual(ctl.conflicts[0], "a[31mb")
  assert.ok(ctl.conflicts[1].length <= model.NAME_MAX_CHARS)
  // Bounded: at most MAX_CONFLICTS_SCANNED kept, the rest only flagged.
  const lots = model.parseState(Array.from({ length: 300 }, (_, i) => "conflict=c" + i))
  assert.strictEqual(lots.conflicts.length, model.MAX_CONFLICTS_SCANNED)
  assert.strictEqual(lots.conflictsTruncated, true)
  assert.deepStrictEqual(model.parseState(null).conflicts, [])
  assert.strictEqual(model.parseState([], true).conflictsTruncated, true)
})

test("parseConf: LOCAL as text only, comments and other keys ignored", () => {
  assert.deepStrictEqual(model.parseConf(["# LOCAL=/nope", "", "REMOTE=onedrive:Backup/Vaults", "LOCAL=~/Vaults ", "LOCAL=/second"]),
    { local: "~/Vaults" })
  assert.strictEqual(model.parseConf(["LOCAL=<img src='http://x/y'>"]).local, "<img src='http://x/y'>", "kept as text; the Text is plain")
  assert.strictEqual(model.parseConf(["LOCAL=a\u0000b"]).local, "ab")
  assert.deepStrictEqual(model.parseConf(null), { local: "" })
})

test("parseScan: files mapped by exact path, token lines only, end required", () => {
  const out = scanOut({
    "/home/u/.config/rclone-bisync/vault-A.conf": "LOCAL=~/Vaults\nREMOTE=onedrive:Backup/Vaults\n",
    "/home/u/.config/rclone-bisync/notes.conf": "LOCAL=~/Notes",
    "/home/u/.config/rclone-backup/archive-vaults.conf": "REMOTE=work_drive:\n",
    "/home/u/.local/state/rclone-bisync/vault-A.state": "time=1794699700\nexit=0\nconflict=Personal.kdbx.conflict1\n",
    "/home/u/.local/state/rclone-backup/archive-vaults.state": "time=1794686996\nexit=0\nok=4\nfailed=0\n",
    // Invalid names, wrong extension, wrong directory, a nested path: ignored.
    "/home/u/.config/rclone-bisync/a;b.conf": "LOCAL=/x",
    "/home/u/.config/rclone-bisync/-x.conf": "LOCAL=/x",
    "/home/u/.config/rclone-bisync/x.state": "time=1",
    "/home/u/.config/rclone-bisync/sub/y.conf": "LOCAL=/x",
    "/etc/rclone-bisync/z.conf": "LOCAL=/x"
  })
  const r = model.parseScan(out, TOKEN, DIRS)
  assert.strictEqual(r.ok, true)
  assert.strictEqual(r.app, true)
  assert.deepStrictEqual(Object.keys(r.pairConfs).sort(), ["notes", "vault-A"])
  assert.strictEqual(r.pairConfs["vault-A"].local, "~/Vaults")
  assert.strictEqual(r.pairConfs.notes.local, "~/Notes")
  assert.deepStrictEqual(Object.keys(r.jobConfs), ["archive-vaults"])
  assert.deepStrictEqual(r.pairStates["vault-A"].conflicts, ["Personal.kdbx.conflict1"])
  assert.strictEqual(r.jobStates["archive-vaults"].ok, 4)
  assert.deepStrictEqual(model.scanPairs(r), ["notes", "vault-A"])
  assert.deepStrictEqual(model.scanJobs(r), ["archive-vaults"])
  assert.deepStrictEqual(r.templates, { bisync: false, backup: false }, "no unitfile line: templates unknown, not installed")
  // No app line: not installed.
  assert.strictEqual(model.parseScan(scanOut({}, { app: false }), TOKEN, DIRS).app, false)
  // Without the end line (killed by timeout, sh missing) the scan is refused.
  for (const bad of [scanOut({}, { end: false }), "", "sh: not found\n", null])
    assert.strictEqual(model.parseScan(bad, TOKEN, DIRS).ok, false, String(bad))
  // Another token's lines are content, never markers: a file cannot forge one.
  const forged = scanOut({ "/home/u/.local/state/rclone-bisync/vault-A.state":
    "time=1794699700\nexit=0\ncmscan-zzzzzzzzzzzz eof\ncmscan-zzzzzzzzzzzz file 1 /home/u/.config/rclone-bisync/evil.conf\n" + TOKEN.toUpperCase() + " end" })
  const f = model.parseScan(forged, TOKEN, DIRS)
  assert.strictEqual(f.ok, true)
  assert.deepStrictEqual(Object.keys(f.pairConfs), [])
  assert.strictEqual(f.pairStates["vault-A"].exit, 0)
  assert.strictEqual(model.parseScan(out, "cmscan-zzzzzzzzzzzz", DIRS).ok, false, "the answer of another run")
  assert.strictEqual(model.parseScan(out, "bad token", DIRS).ok, false)
  // Over the size bound: refused whole.
  assert.strictEqual(model.parseScan(out + "x".repeat(model.SCAN_MAX_CHARS), TOKEN, DIRS).ok, false)
  // A file larger than the scan reads: its cut last line dropped, conflicts a lower bound.
  const big = scanOut({ "/home/u/.local/state/rclone-bisync/vault-A.state": "time=1794699700\nexit=0\nconflict=a\nconflict=b-cut-in-ha" },
    { sizes: { "/home/u/.local/state/rclone-bisync/vault-A.state": model.SCAN_FILE_MAX_BYTES + 1 } })
  const bs = model.parseScan(big, TOKEN, DIRS).pairStates["vault-A"]
  assert.deepStrictEqual(bs.conflicts, ["a"])
  assert.strictEqual(bs.conflictsTruncated, true)
  // The first of two sections for one path wins; "more" is reported.
  const two = scanOut({ "/home/u/.config/rclone-bisync/p.conf": "LOCAL=/one" }) .replace(TOKEN + " end\n",
    TOKEN + " file 10 /home/u/.config/rclone-bisync/p.conf\nLOCAL=/two\n" + TOKEN + " eof\n" + TOKEN + " more\n" + TOKEN + " end\n")
  const t = model.parseScan(two, TOKEN, DIRS)
  assert.strictEqual(t.pairConfs.p.local, "/one")
  assert.strictEqual(t.more, true)
  // Names that are Object.prototype members are plain names.
  const proto = model.parseScan(scanOut({ "/home/u/.config/rclone-bisync/hasOwnProperty.conf": "LOCAL=/h",
    "/home/u/.config/rclone-bisync/constructor.conf": "LOCAL=/c" }), TOKEN, DIRS)
  assert.deepStrictEqual(model.scanPairs(proto), ["constructor", "hasOwnProperty"])
})

test("parseScan: absurd input returns fast", () => {
  const lines = Array.from({ length: 20000 }, (_, i) => "conflict=c" + i).join("\n")
  const huge = scanOut({ "/home/u/.local/state/rclone-bisync/p.state": lines })
  const t0 = Date.now()
  const r = model.parseScan(huge.slice(0, model.SCAN_MAX_CHARS - 100) + "\n" + TOKEN + " eof\n" + TOKEN + " end\n", TOKEN, DIRS)
  assert.ok(Date.now() - t0 < 200, "took " + (Date.now() - t0) + " ms")
  assert.strictEqual(r.ok, true)
  assert.ok(r.pairStates.p.conflicts.length <= model.MAX_CONFLICTS_SCANNED)
  assert.strictEqual(r.pairStates.p.conflictsTruncated, true)
})

test("more pairs or jobs than the cap: the panel says how many it shows", () => {
  const confs = {}
  for (let i = 0; i < 20; i++) confs["p" + String(i).padStart(2, "0")] = { local: "" }
  const scan = scanWith({ pairConfs: confs, jobConfs: { j: {} } })
  const units = model.parseShow(show(...pairBlocks("zz", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" } }), sentinel()))
  assert.strictEqual(model.mergePairs(model.scanPairs(scan), model.unitPairs(units)).length, model.MAX_PAIRS)
  assert.strictEqual(model.pairsFound(scan, units), 21)
  assert.strictEqual(model.capText(model.MAX_PAIRS, 21, "offline folders"), "Showing 16 of 21 offline folders.")
  assert.strictEqual(model.jobsFound(scan, units), 1)
  assert.strictEqual(model.capText(1, 1, "backups"), "")
})

test("remotes past the cap: the panel says how many it shows", () => {
  const known = Array.from({ length: 32 }, (_, i) => "r" + String(i).padStart(2, "0"))
  const units = model.parseShow(show(...Array.from({ length: 5 }, (_, i) => block({ Id: "rclone-mount@u" + i + ".service" })), sentinel()))
  const env = ["r00.env", "e1.env", "e2.env", "bad name.env", "notes.txt"]
  assert.strictEqual(model.mergeRemotes(known, model.unitRemotes(units), model.envRemotes(env)).length, model.MAX_REMOTES)
  assert.strictEqual(model.remotesFound(known, units, env), 39)
  assert.strictEqual(model.capText(model.MAX_REMOTES, 39, "remotes"), "Showing 32 of 39 remotes.")
  assert.strictEqual(model.remotesFound(["a"], {}, []), 1)
  assert.strictEqual(model.capText(1, 1, "remotes"), "")
  // Bounded on absurd input.
  const t0 = Date.now()
  model.remotesFound(Array.from({ length: 100000 }, (_, i) => "x" + i), {}, Array.from({ length: 100000 }, (_, i) => "y" + i + ".env"))
  assert.ok(Date.now() - t0 < 200)
})

test("templates: from the scan's list-unit-files lines, behind the token only", () => {
  const lines = (...l) => l.map(x => TOKEN + " unitfile " + x + "\n").join("")
  let r = model.parseScan(lines("rclone-bisync@.service linked enabled", "rclone-backup@.service disabled enabled") + TOKEN + " end\n", TOKEN, DIRS)
  assert.deepStrictEqual(r.templates, { bisync: true, backup: true })
  r = model.parseScan(lines("rclone-bisync@.service masked enabled", "rclone-backup@.service bad -", "rclone-mount@.service indirect enabled")
    + TOKEN + " end\n", TOKEN, DIRS)
  assert.deepStrictEqual(r.templates, { bisync: false, backup: false }, "masked or broken is not installed; other units ignored")
  // A line without the token, or a forged one inside a unitfile line, is nothing.
  r = model.parseScan("rclone-bisync@.service enabled -\n" + lines(TOKEN + " end", "rclone-backup@.service<b> enabled -") + TOKEN + " end\n", TOKEN, DIRS)
  assert.deepStrictEqual(r.templates, { bisync: false, backup: false })
  assert.strictEqual(r.ok, true)
  // Installed when systemd has no instance loaded: from the templates.
  const scan = scanWith({ templates: { bisync: true, backup: true }, pairConfs: { p: { local: "" } }, jobConfs: { j: {} } })
  const [pr] = model.pairRows(["p"], {}, scan, NOW)
  assert.deepStrictEqual([pr.installed, pr.enabled, pr.canSync, pr.text], [true, false, false, "never run"])
  assert.strictEqual(pr.blockedText, "Sync not enabled: rclone-bisync@p.timer and .path are both disabled.")
  const [jr] = model.jobRows(["j"], {}, scan, NOW)
  assert.deepStrictEqual([jr.installed, jr.next], [true, "timer not enabled"])
  // Without the templates: not installed.
  assert.ok(/not installed/.test(model.pairRows(["p"], {}, scanWith(), NOW)[0].blockedText))
  assert.strictEqual(model.jobRows(["j"], {}, scanWith(), NOW)[0].installed, false)
  // A loaded service answers for itself.
  const units = model.parseShow(show(...pairBlocks("p", { service: { LoadState: "not-found" } }), sentinel()))
  assert.strictEqual(model.pairRows(["p"], units, scan, NOW)[0].installed, false)
})

test("scanKey: changes when a run ends or the instances change, not otherwise", () => {
  const u1 = model.parseShow(show(...pairBlocks("p"), ...jobBlocks("j"), sentinel()))
  const k1 = model.scanKey(["p"], ["j"], u1)
  assert.notStrictEqual(k1, "")
  assert.strictEqual(model.scanKey(["p"], ["j"], model.parseShow(show(...pairBlocks("p"), ...jobBlocks("j"), sentinel()))), k1)
  // A timer's next elapse moving does not rescan.
  assert.strictEqual(model.scanKey(["p"], ["j"], model.parseShow(show(...pairBlocks("p"),
    ...jobBlocks("j", { timer: { NextElapseUSecRealtime: "@1794799999" } }), sentinel()))), k1)
  assert.notStrictEqual(model.scanKey(["p"], ["j"], model.parseShow(show(...pairBlocks("p", { service: { ExecMainExitTimestamp: "@1794700001" } }),
    ...jobBlocks("j"), sentinel()))), k1)
  assert.notStrictEqual(model.scanKey(["p", "q"], ["j"], u1), k1)
  assert.notStrictEqual(model.scanKey([], [], {}), "")
})

// ----------------------------------------------------------------- state

test("remoteState maps ActiveState/SubState", () => {
  const st = (o) => model.remoteState(Object.assign({ LoadState: "loaded", ActiveState: "active", SubState: "running", Result: "success" }, o))
  assert.strictEqual(st({}).state, "mounted")
  assert.strictEqual(st({}).on, true)
  assert.strictEqual(st({ ActiveState: "inactive", SubState: "dead" }).state, "stopped")
  assert.strictEqual(st({ ActiveState: "activating", SubState: "start" }).state, "starting")
  assert.strictEqual(st({ ActiveState: "deactivating", SubState: "stop-sigterm" }).state, "stopping")
  assert.strictEqual(st({ ActiveState: "failed", SubState: "failed", Result: "exit-code" }).label, "failed (exit-code)")
  const retry = st({ ActiveState: "activating", SubState: "auto-restart" })
  assert.deepStrictEqual([retry.state, retry.on, retry.mounted], ["failed", true, false])
  assert.strictEqual(st({ LoadState: "not-found" }).state, "failed")
  assert.strictEqual(model.remoteState(null).state, "unknown")
  assert.strictEqual(st({ ActiveState: "weird<b>" }).state, "unknown")
})

test("rows, aggregate state, icon and tooltip", () => {
  const units = model.parseShow(show(block(), block({ Id: "rclone-mount@onedrive.service" }), sentinel()))
  let rows = model.remoteRows(["onedrive", "gdrive"], units, { gdrive: 2048 })
  assert.deepStrictEqual(rows.map(r => r.name), ["gdrive", "onedrive"])
  assert.strictEqual(rows[0].detail, "mounted · cache 2.00 KiB")
  assert.strictEqual(rows[1].detail, "mounted")
  assert.strictEqual(model.aggregate(rows, [], [], true), "all")
  assert.strictEqual(model.aggregate(rows, [], [], false), "unknown")
  assert.strictEqual(model.aggregate(rows, [{ name: "p", conflictCount: 1 }], [], true), "error", "a conflict copy is an error")
  // A failed offline-folder sync or backup alerts the bar like a failed mount.
  assert.strictEqual(model.aggregate(rows, [{ name: "p", failed: true, conflictCount: 0 }], [], true), "error", "a failed sync is an error")
  assert.strictEqual(model.aggregate(rows, [], [{ name: "j", failed: true }], true), "error", "a failed backup is an error")
  assert.strictEqual(model.aggregate([], [], [{ name: "j", failed: true }], true), "error", "with no mount at all too")
  assert.strictEqual(model.aggregate(rows, [{ name: "p", failed: false, conflictCount: 0 }], [{ name: "j", failed: false }], true), "all")
  assert.strictEqual(model.summary(rows, true, [{ name: "p", failed: true, conflictCount: 0 }], []), "2 of 2 mounted · 1 sync failed")
  rows = model.remoteRows(["gdrive", "lake-s3"], units, {})
  assert.strictEqual(rows[1].state, "unknown")
  assert.strictEqual(model.aggregate(rows, [], [], true), "some")
  const stopped = model.parseShow(show(block({ ActiveState: "inactive", SubState: "dead" })))
  assert.strictEqual(model.aggregate(model.remoteRows(["gdrive"], stopped, {}), [], [], true), "none")
  assert.strictEqual(model.aggregate([], [], [], true), "none")
  assert.strictEqual(model.aggregate([], null, undefined, true), "none")
  const failed = model.parseShow(show(block(), block({ Id: "rclone-mount@onedrive.service", ActiveState: "failed", Result: "exit-code" })))
  rows = model.remoteRows(["gdrive", "onedrive"], failed, {})
  assert.strictEqual(model.aggregate(rows, [], [], true), "error")
  assert.strictEqual(model.barIcon("error"), model.ICON.error)
  assert.strictEqual(model.barIcon("toString"), model.ICON.unknown)
  assert.strictEqual(model.barIcon("folder"), model.ICON.unknown)
  const pairs = [{ name: "vault-A", conflictCount: 1, conflictsTruncated: false }, { name: "notes", conflictCount: 0 },
    { name: "big", conflictCount: 200, conflictsTruncated: true }, { name: "a;b", conflictCount: 3 }]
  const tip = model.tooltipText(rows, pairs, [], true, "")
  assert.strictEqual(tip, "Omarchy Cloud: 1 of 2 mounted · 1 mount failed · 204+ conflict copies\nMount failed: onedrive\n"
    + "vault-A: 1 conflict copy\nbig: 200+ conflict copies\nClick to manage")
  assert.strictEqual(model.tooltipText([], null, null, true, ""), "Omarchy Cloud: No rclone-mount units found\nClick to manage")
  assert.strictEqual(model.summary([], true), "No rclone-mount units found")
  assert.strictEqual(model.summary([], false), "Checking mounts…")
  // Failed offline folders and backups are named in the tooltip and counted
  // in the hero, like failed mounts; an invalid name is counted nowhere.
  const fp = [{ name: "vault-A", failed: true, conflictCount: 0 }, { name: "notes", failed: true, conflictCount: 0 },
    { name: "ok", failed: false, conflictCount: 0 }, { name: "a;b", failed: true }]
  const fj = [{ name: "archive-vaults", failed: true }, { name: "fine", failed: false }]
  const ok3 = model.remoteRows(["gdrive"], units, {})
  assert.strictEqual(model.summary(ok3, true, fp, fj), "1 of 1 mounted · 2 syncs failed · 1 backup failed")
  assert.strictEqual(model.tooltipText(ok3, fp, fj, true, ""),
    "Omarchy Cloud: 1 of 1 mounted · 2 syncs failed · 1 backup failed\nSync failed: vault-A, notes\nBackup failed: archive-vaults\nClick to manage")
  assert.strictEqual(model.summary([], true, [{ name: "p", conflictCount: 1 }], []), "No rclone-mount units found · 1 conflict copy")
  assert.strictEqual(model.summary(rows, true, [], [{ name: "a", failed: true }, { name: "b", failed: true }]),
    "1 of 2 mounted · 1 mount failed · 2 backups failed")
  // Consistent with the icon: an alert state always says why in the hero.
  for (const [r, p, j] of [[rows, [], []], [ok3, fp, []], [ok3, [], fj], [ok3, [{ name: "p", conflictCount: 2 }], []], [[], [], fj]])
    assert.ok(model.aggregate(r, p, j, true) === "error" && / · /.test(model.summary(r, true, p, j)), model.summary(r, true, p, j))
  assert.ok(!/ · /.test(model.summary(ok3, true, [{ name: "ok", failed: false, conflictCount: 0 }], [{ name: "fine", failed: false }])))
  for (const r of rows) clean(r.detail)
})

test("toggle action and the stop decision", () => {
  assert.strictEqual(model.toggleAction({ on: true, transitional: false }), "stop")
  assert.strictEqual(model.toggleAction({ on: false, transitional: false }), "start")
  assert.strictEqual(model.toggleAction({ on: false, transitional: true }), "")
  assert.strictEqual(model.toggleAction(null), "")
  const idle = { known: true, procs: [], total: 0 }
  const busy = { known: true, procs: [{ pid: 1, user: "u", command: "vim" }], total: 1 }
  assert.strictEqual(model.stopDecision(idle, 0), "stop")
  assert.strictEqual(model.stopDecision(idle, 3), "confirm", "pending uploads are warned about")
  assert.strictEqual(model.stopDecision(idle, -1), "confirm", "an uncounted cache is not assumed clean")
  assert.strictEqual(model.stopDecision(busy, 0), "confirm")
  assert.strictEqual(model.stopDecision({ known: false, procs: [], total: 0 }, 0), "confirm", "an unchecked mount is not idle")
  assert.strictEqual(model.stopDecision(null, 0), "confirm")
  const p = model.stopPrompt("gdrive", busy, 3)
  assert.strictEqual(p, "1 process using it:\n  vim (PID 1, u)\n3 pending uploads will resume on the next mount (the cache is kept).\n"
    + "Force detaches the mount (lazy unmount) and stops rclone; nothing is killed, but open files on it stop working.")
  assert.strictEqual(model.stopPrompt("gdrive", idle, 1), "1 pending upload will resume on the next mount (the cache is kept).")
  assert.ok(/^Could not check/.test(model.stopPrompt("gdrive", null, 0)))
  const many = { known: true, total: 12, procs: Array.from({ length: 8 }, (_, i) => ({ pid: i, user: "u", command: "p" })) }
  assert.ok(/… and 4 more/.test(model.stopPrompt("gdrive", many, 0)))
})

const scanWith = (o) => Object.assign(model.emptyScan(), { ok: true }, o || {})

test("offline folders: last sync, disabled sync, Sync now, conflicts", () => {
  // Disabled timer and path: Sync now is off, and the row says why.
  let units = model.parseShow(show(...pairBlocks("vault-A"), sentinel()))
  let scan = scanWith({ pairConfs: { "vault-A": { local: "~/Vaults" } } })
  let [r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.unit, "rclone-bisync@vault-A.service")
  assert.strictEqual(r.local, "~/Vaults")
  assert.strictEqual(r.enabled, false)
  assert.strictEqual(r.canSync, false, "Sync now is disabled while neither timer nor path is enabled")
  assert.strictEqual(r.text, "no run yet")
  assert.strictEqual(r.blockedText, "Sync not enabled: rclone-bisync@vault-A.timer and .path are both disabled.")
  assert.strictEqual(r.conflictText, "")

  // Timer enabled, a good run in the state file: Sync now on, last sync shown.
  units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" } }), sentinel()))
  scan.pairStates = { "vault-A": model.parseState(["time=1794699700", "exit=0"]) }
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.canSync, true)
  assert.strictEqual(r.blockedText, "")
  assert.strictEqual(r.text, "23:41 (5 min ago) · ok")

  // The path alone counts as enabled; a failed run in the state file.
  units = model.parseShow(show(...pairBlocks("vault-A", { path: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" } }), sentinel()))
  scan.pairStates = { "vault-A": model.parseState(["time=1794699000", "exit=2"]) }
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.canSync, true)
  assert.strictEqual(r.failed, true)
  assert.strictEqual(r.text, "23:30 (16 min ago) · failed (exit 2)")

  // systemd saw a later run that failed before writing the state: its view wins.
  units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" },
    service: { ActiveState: "failed", Result: "exit-code", ExecMainStatus: "64", ExecMainExitTimestamp: "@1794699900" } }), sentinel()))
  scan.pairStates = { "vault-A": model.parseState(["time=1794699000", "exit=0"]) }
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.failed, true)
  assert.strictEqual(r.text, "23:45 (1 min ago) · failed (exit-code, exit 64)")
  // The same run (state written a moment before the exit): the state file's view.
  scan.pairStates = { "vault-A": model.parseState(["time=1794699898", "exit=64"]) }
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.text, "23:44 (1 min ago) · failed (exit 64)")

  // Running: no second start.
  units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" }, service: { ActiveState: "activating", SubState: "start" } }), sentinel()))
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.running, true)
  assert.strictEqual(r.canSync, false, "no second start while one runs")
  assert.ok(/^running now · last /.test(r.text), r.text)

  // An enabled path unit that failed (trigger or start limit) no longer
  // watches: a problem, named, with the way back; the timer still syncs.
  units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" },
    path: { UnitFileState: "enabled", ActiveState: "failed", SubState: "failed", Result: "trigger-limit-hit" } }), sentinel()))
  scan.pairStates = { "vault-A": model.parseState(["time=1794699700", "exit=0"]) }
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.enabled, true)
  assert.strictEqual(r.watchStopped, true)
  assert.strictEqual(r.failed, true, "a stopped watch puts the bar in the alert state")
  assert.strictEqual(r.canSync, true, "Sync now still works")
  assert.strictEqual(r.blockedText, "Folder watch stopped (trigger-limit-hit): edits are synced only by the timer. Restart it: w in omarchy-cloud, "
    + "or systemctl --user reset-failed rclone-bisync@vault-A.path && systemctl --user start rclone-bisync@vault-A.path.")
  // Named as a stopped watch, not a failed sync; still the alert state.
  assert.deepStrictEqual(model.problems([], [r], []).syncs, [])
  assert.deepStrictEqual(model.problems([], [r], []).watches, ["vault-A"])
  assert.strictEqual(model.problems([], [r], []).any, true)
  assert.strictEqual(model.aggregate([], [r], [], true), "error")
  assert.strictEqual(model.summary([], true, [r], []), "No rclone-mount units found · 1 sync watch stopped")
  assert.strictEqual(model.tooltipText([], [r], [], true, ""),
    "Omarchy Cloud: No rclone-mount units found · 1 sync watch stopped\nSync watch stopped: vault-A\nClick to manage")
  assert.ok(!/sync failed|Sync failed/.test(model.tooltipText([], [r], [], true, "")))
  assert.strictEqual(model.summary([], true, [r, Object.assign({}, r, { name: "notes" })], []), "No rclone-mount units found · 2 sync watches stopped")
  // No Show log for it (its note says how to restart); a failed run keeps one.
  assert.ok(!model.cursorGroups([], { pairs: [r] }).some(x => x.keys.includes("log|rclone-bisync@vault-A.service")))
  assert.ok(model.cursorGroups([], { pairs: [Object.assign({}, r, { watchStopped: false })] }).some(x => x.keys.includes("log|rclone-bisync@vault-A.service")))
  // The service's start limit, propagated to the path; and a failed timer.
  units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "failed", Result: "unit-start-limit-hit" },
    path: { UnitFileState: "enabled", ActiveState: "failed", Result: "unit-start-limit-hit" } }), sentinel()))
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.ok(/^Folder watch stopped \(unit-start-limit-hit\), timer stopped \(unit-start-limit-hit\)\. /.test(r.blockedText), r.blockedText)
  assert.ok(r.blockedText.includes("reset-failed rclone-bisync@vault-A.path rclone-bisync@vault-A.timer && systemctl --user start rclone-bisync@vault-A.path rclone-bisync@vault-A.timer."), r.blockedText)
  // Enabled but stopped by hand (inactive, Result success) is stopped too.
  units = model.parseShow(show(...pairBlocks("vault-A", { path: { UnitFileState: "enabled", ActiveState: "inactive", Result: "success" } }), sentinel()))
  assert.ok(/^Folder watch stopped \(inactive\)/.test(model.pairRows(["vault-A"], units, scan, NOW)[0].blockedText))
  // A disabled unit is never "stopped"; an active one is fine.
  units = model.parseShow(show(...pairBlocks("vault-A", { timer: { UnitFileState: "enabled", ActiveState: "active" },
    path: { UnitFileState: "disabled", ActiveState: "failed", Result: "trigger-limit-hit" } }), sentinel()))
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.watchStopped, false)
  assert.strictEqual(r.blockedText, "")

  // Template units not installed.
  units = model.parseShow(show(...pairBlocks("vault-A", { service: { LoadState: "not-found" }, timer: { LoadState: "not-found" },
    path: { LoadState: "not-found" } }), sentinel()))
  ;[r] = model.pairRows(["vault-A"], units, scanWith(), NOW)
  assert.strictEqual(r.installed, false)
  assert.strictEqual(r.text, "never run")
  assert.ok(/not installed \(run install\.sh\)/.test(r.blockedText))
  assert.strictEqual(model.pairRows(["vault-A"], {}, null, NOW)[0].canSync, false)

  // Conflicts: at most 5 named, then a count; the bar alerts on any.
  const names = Array.from({ length: 8 }, (_, i) => "Personal.kdbx.conflict" + (i + 1))
  scan = scanWith({ pairStates: { "vault-A": model.parseState(["time=1794699700", "exit=0"].concat(names.map(n => "conflict=" + n))) } })
  ;[r] = model.pairRows(["vault-A"], units, scan, NOW)
  assert.strictEqual(r.conflictCount, 8)
  assert.strictEqual(r.conflictText, "8 conflict copies: " + names.slice(0, 5).join(", ") + " and 3 more. " + model.CONFLICT_HOWTO)
  assert.strictEqual(model.CONFLICT_HOWTO, "A file changed on both sides: bisync kept both versions as X.conflictN copies (X itself is renamed). Merge them into one file, rename it back to X, delete the other copies.")
  assert.ok(!/conflict1|conflict2|local|remote/.test(model.CONFLICT_HOWTO), "no claim which copy is which")
  assert.strictEqual(model.conflictTotal([r, { conflictCount: 2 }, null]), 10)
  assert.strictEqual(model.aggregate([], [r], [], true), "error", "a conflict copy is an error")
  scan.pairStates["vault-A"] = model.parseState(["conflict=one"])
  assert.ok(/^1 conflict copy: one\. /.test(model.pairRows(["vault-A"], units, scan, NOW)[0].conflictText))
  scan.pairStates["vault-A"] = model.parseState(["conflict=one"], true)
  assert.ok(/^1\+ conflict copies: one\. /.test(model.pairRows(["vault-A"], units, scan, NOW)[0].conflictText))
  // Invalid names never become a row.
  assert.deepStrictEqual(model.pairRows(["$(x)", "ok"], {}, null, NOW).map(x => x.name), ["ok"])
  for (const row of model.pairRows(["vault-A"], units, scan, NOW)) for (const v of Object.values(row)) if (typeof v === "string") clean(v)
})

test("backups: last run with counts, next run, failure, timer disabled", () => {
  let units = model.parseShow(show(...jobBlocks("archive-vaults"), sentinel()))
  // From systemd alone (no state file yet).
  let [j] = model.jobRows(["archive-vaults"], units, scanWith(), NOW)
  assert.strictEqual(j.unit, "rclone-backup@archive-vaults.service")
  assert.strictEqual(j.text, "20:09 (3 h ago) · ok")
  assert.strictEqual(j.next, "next 15 Nov 03:09 (in 3 h)")
  assert.strictEqual(j.failed, false)
  // From the state file, kept across reboots, with its counts.
  const scan = scanWith({ jobStates: { "archive-vaults": model.parseState(["time=1794686996", "exit=1", "ok=3", "failed=2"]) } })
  ;[j] = model.jobRows(["archive-vaults"], units, scan, NOW)
  assert.strictEqual(j.failed, true)
  assert.strictEqual(j.text, "20:09 (3 h ago) · failed (exit 1) · 3 copied, 2 failed")
  scan.jobStates["archive-vaults"] = model.parseState(["time=1794686996", "exit=0", "ok=5", "failed=0"])
  assert.strictEqual(model.jobRows(["archive-vaults"], units, scan, NOW)[0].text, "20:09 (3 h ago) · ok · 5 copied")
  scan.jobStates["archive-vaults"] = model.parseState(["time=1794686996"])
  assert.strictEqual(model.jobRows(["archive-vaults"], units, scan, NOW)[0].text, "20:09 (3 h ago) · result unknown")
  // Timer disabled, units missing.
  units = model.parseShow(show(...jobBlocks("archive-vaults", { timer: { NextElapseUSecRealtime: "", UnitFileState: "disabled", ActiveState: "inactive" } }), sentinel()))
  assert.strictEqual(model.jobRows(["archive-vaults"], units, scanWith(), NOW)[0].next, "timer not enabled")
  ;[j] = model.jobRows(["archive-vaults"], {}, null, NOW)
  assert.deepStrictEqual([j.installed, j.text, j.next], [false, "never run", "timer not enabled"])
  for (const v of Object.values(j)) if (typeof v === "string") clean(v)
  // static / masked / linked do not count as enabled.
  for (const st of ["static", "masked", "linked", "disabled", "", "indirect"])
    assert.strictEqual(model.isEnabledState({ UnitFileState: st }), false, st)
  assert.strictEqual(model.isEnabledState({ UnitFileState: "enabled-runtime" }), true)
})

test("Configure…: hint only once the scan answered and the binary is missing", () => {
  assert.strictEqual(model.configureHint(false, false), "")
  assert.strictEqual(model.configureHint(true, true), "")
  assert.strictEqual(model.configureHint(true, false), "Run install.sh from the plugin folder to install omarchy-cloud.")
})

// ------------------------------------------------------------- formatting

test("formatBytes", () => {
  assert.strictEqual(model.formatBytes(0), "0 B")
  assert.strictEqual(model.formatBytes(1023), "1023 B")
  assert.strictEqual(model.formatBytes(1536), "1.50 KiB")
  assert.strictEqual(model.formatBytes(10 * 1048576), "10.0 MiB")
  assert.strictEqual(model.formatBytes(150 * 1073741824), "150 GiB")
  for (const bad of [-1, NaN, Infinity, "x", null]) assert.strictEqual(model.formatBytes(bad), "—", String(bad))
})

test("formatWhen / formatAgo", () => {
  assert.strictEqual(model.formatWhen(NOW - 30, NOW), "23:46 (just now)")
  assert.strictEqual(model.formatWhen(NOW - 7200, NOW), "21:46 (2 h ago)")
  assert.strictEqual(model.formatWhen(NOW - 3 * 86400, NOW), "11 Nov 23:46 (3 d ago)")
  assert.strictEqual(model.formatAgo(NOW + 30, NOW), "in under a minute")
  assert.strictEqual(model.formatWhen(null, NOW), "time unknown")
})

test("formatLog: bounded, last lines, no control characters", () => {
  const lines = Array.from({ length: 50 }, (_, i) => "Nov 14 17:0" + (i % 10) + " host rclone[1]: line " + i)
  const out = model.formatLog(lines.join("\n") + "\n")
  assert.strictEqual(out.split("\n").length, model.LOG_LINES)
  assert.ok(/line 49$/.test(out))
  const evil = model.formatLog("a\u001b[31mred\u0007\tb\r\n<b>bold</b>\n" + "x".repeat(1000))
  assert.ok(!/[\u0000-\u0008\u000b-\u001f\u007f]/.test(evil))
  assert.ok(evil.split("\n").every(l => l.length <= model.LOG_LINE_MAX), "lines capped")
  assert.ok(model.formatLog("y".repeat(100000)).length <= model.LOG_MAX_CHARS)
  const wide = Array.from({ length: 20 }, () => "z".repeat(400)).join("\n")
  assert.ok(model.formatLog(wide).length <= model.LOG_MAX_CHARS)
  assert.strictEqual(model.formatLog(""), "(no journal entries)")
})

test("timing helpers", () => {
  assert.strictEqual(model.shouldPoll(0), false)
  assert.strictEqual(model.shouldPoll(2), true)
  assert.strictEqual(model.duDue(0, 0, 1e9), false, "no du without an open panel")
  assert.strictEqual(model.duDue(1, 0, 1e9), true)
  assert.strictEqual(model.duDue(1, 1e9, 1e9 + model.DU_MIN_MS - 1), false)
  assert.strictEqual(model.duDue(1, 1e9, 1e9 + model.DU_MIN_MS), true)
  assert.ok(model.POLL_MS >= 2000 && model.POLL_MS <= 10000)
})

test("icons are single Nerd Font glyphs", () => {
  for (const [k, v] of Object.entries(model.ICON)) {
    const cps = [...v]
    assert.strictEqual(cps.length, 1, k)
    assert.ok(cps[0].codePointAt(0) >= 0xf0000, k)
  }
})

// ---------------------------------------------------------------- QML source

const qmlFiles = fs.readdirSync(pluginDir).filter(f => f.endsWith(".qml"))
const qmlCode = file => fs.readFileSync(path.join(pluginDir, file), "utf8").replace(/\/\/.*$/gm, "")

// --------------------------------------------------------- installed parts

// VERSIONS_SCRIPT's answer, built the way the script prints it.
const versionsOut = (o) => {
  const t = o.token || TOKEN
  const out = []
  const file = (what, body, size) => {
    if (body === undefined) return
    out.push(t + " " + what + " " + (size !== undefined ? size : Buffer.byteLength(body)))
    out.push(body + "\n" + t + " eof")
  }
  file("plugin", o.plugin, o.pluginSize)
  file("installed", o.installed, o.installedSize)
  if (o.legacy) out.push(t + " legacy")
  if (o.installer !== false) out.push(t + " installer")
  if (o.end !== false) out.push(t + " end")
  return out.join("\n") + "\n"
}
const MANIFEST = (v) => JSON.stringify({ schemaVersion: 1, id: "io.github.rsd.cloud-mounts", version: v }, null, 2) + "\n"
const SHA = "0".repeat(64) + "  /home/u/.local/bin/rclone-bisync\n"

test("installed parts: header lines, first of each key wins, bounded", () => {
  const h = model.parseInstallHeader
  assert.deepStrictEqual(h("#version=0.3.3\n#repo=/src/omarchy-cloud-plugin\n" + SHA), { version: "0.3.3", repo: "/src/omarchy-cloud-plugin" })
  // Missing: a 0.3.2 manifest has no header lines.
  assert.deepStrictEqual(h(SHA), { version: "", repo: "" })
  assert.deepStrictEqual(h(""), { version: "", repo: "" })
  assert.deepStrictEqual(h(null), { version: "", repo: "" })
  // Malformed versions and repos.
  for (const bad of ["0.3", "0.3.3.1", "v0.3.3", "0.3.3 ", " 0.3.3", "0.3.x", "", "0.3.3\u0000", "0..3", "1.2.3-rc1", "１.２.３"])
    assert.strictEqual(h("#version=" + bad + "\n").version, "", JSON.stringify(bad))
  for (const bad of ["relative/path", "", "/a\u001bb", "/a\tb", "/a\u0085b", "~/x"])
    assert.strictEqual(h("#repo=" + bad + "\n").repo, "", JSON.stringify(bad))
  assert.strictEqual(h("# version=0.3.3\n#Version=0.3.3\nversion=0.3.3\n").version, "", "only the exact key")
  assert.strictEqual(h("#version=0.3.3\r\n").version, "0.3.3", "a CRLF line")
  // Duplicates: the first line of a key decides, even when it is malformed.
  assert.strictEqual(h("#version=0.3.3\n#version=9.9.9\n").version, "0.3.3")
  assert.strictEqual(h("#version=bad\n#version=0.3.3\n").version, "")
  assert.strictEqual(h("#repo=/a\n#repo=/b\n").repo, "/a")
  // Only the first INSTALL_HEADER_MAX_BYTES count; an oversized line is no header.
  assert.strictEqual(h(SHA.repeat(80) + "#version=0.3.3\n").version, "")
  assert.strictEqual(h("#repo=/" + "x".repeat(model.INSTALL_HEADER_LINE_MAX) + "\n#version=0.3.3\n").repo, "")
  assert.strictEqual(h("#repo=/" + "x".repeat(model.INSTALL_HEADER_LINE_MAX) + "\n#version=0.3.3\n").version, "0.3.3")
  // The boundary: a line of exactly INSTALL_HEADER_LINE_MAX chars is read, one more is
  // skipped (and, skipped, does not count as the key's first line). app/src/version.rs
  // has the same cases.
  const LIM = model.INSTALL_HEADER_LINE_MAX
  const repoLine = n => "#repo=/" + "a".repeat(n - 7)
  assert.strictEqual(LIM, 1024)
  assert.strictEqual(h(repoLine(LIM) + "\n").repo, repoLine(LIM).slice(6))
  assert.strictEqual(h(repoLine(LIM) + "\r\n").repo, repoLine(LIM).slice(6), "the CR does not count")
  assert.strictEqual(h(repoLine(LIM + 1) + "\n").repo, "")
  assert.strictEqual(h(repoLine(LIM + 1) + "\n#repo=/b\n").repo, "/b", "a skipped line is not seen")
  assert.strictEqual(h("#version=1.2.3" + "9".repeat(LIM) + "\n#version=4.5.6\n").version, "4.5.6")
  assert.ok(model.INSTALL_HEADER_MAX_BYTES <= 4096)
})

test("installed parts: the plugin's manifest.json version", () => {
  const v = model.parsePluginVersion
  assert.strictEqual(v(MANIFEST("0.3.3")), "0.3.3")
  assert.strictEqual(v(fs.readFileSync(path.join(pluginDir, "manifest.json"), "utf8")), JSON.parse(fs.readFileSync(path.join(pluginDir, "manifest.json"), "utf8")).version)
  for (const bad of ["", "{", "null", "[]", '"0.3.3"', '{"version":3}', '{"version":"0.3"}', '{"version":"0.3.3\\n"}', '{"Version":"0.3.3"}', null])
    assert.strictEqual(v(bad), "", String(bad))
  assert.strictEqual(v('{"version":"0.3.3","pad":"' + "x".repeat(model.PLUGIN_MANIFEST_MAX_BYTES) + '"}'), "", "oversized")
})

test("installed parts: the read, its bounds and its token", () => {
  const p = model.parseVersions
  const r = p(versionsOut({ plugin: MANIFEST("0.3.3"), installed: "#version=0.3.3\n#repo=/src/x\n" + SHA }), TOKEN)
  assert.deepStrictEqual(r, { ok: true, plugin: "0.3.3", installedPresent: true, installedVersion: "0.3.3", installedRepo: "/src/x", legacy: false, installer: true })
  // No end line, another token, too long, a bad token: nothing at all.
  assert.deepStrictEqual(p(versionsOut({ plugin: MANIFEST("0.3.3"), end: false }), TOKEN), model.emptyVersions())
  assert.deepStrictEqual(p(versionsOut({ plugin: MANIFEST("0.3.3") }), "cmscan-zzzzzzzzzzzz"), model.emptyVersions())
  assert.deepStrictEqual(p(versionsOut({ plugin: MANIFEST("0.3.3") }), "bad"), model.emptyVersions())
  assert.strictEqual(p("x".repeat(model.VERSIONS_MAX_CHARS + 1) + "\n" + TOKEN + " end\n", TOKEN).ok, false)
  // Marker lines of any other token inside a file are content (each run
  // draws a fresh token, so a file cannot carry the live one).
  const other = "cmscan-zzzzzzzzzzzz"
  const forged = p(versionsOut({ plugin: MANIFEST("0.3.3"), installed: "#version=0.3.3\n" + other + " legacy\n" + other + " end", installer: false }), TOKEN)
  assert.strictEqual(forged.ok, true)
  assert.strictEqual(forged.legacy, false)
  assert.strictEqual(forged.installer, false)
  assert.strictEqual(forged.installedVersion, "0.3.3")
  // Missing files; a manifest that could not be sized still counts as present.
  assert.deepStrictEqual(p(versionsOut({ plugin: MANIFEST("0.3.3") }), TOKEN).installedPresent, false)
  const unsized = p(versionsOut({ plugin: MANIFEST("0.3.3"), installed: "", installedSize: -1 }), TOKEN)
  assert.strictEqual(unsized.installedPresent, true)
  assert.strictEqual(unsized.installedVersion, "")
  assert.strictEqual(p(versionsOut({ plugin: MANIFEST("0.3.3"), legacy: true }), TOKEN).legacy, true)
  // A file larger than the read loses its cut last line.
  const big = p(versionsOut({ plugin: MANIFEST("0.3.3"), installed: "#version=0.3.3\n#repo=/src/x", installedSize: 99999 }), TOKEN)
  assert.strictEqual(big.installedVersion, "0.3.3")
  assert.strictEqual(big.installedRepo, "", "the cut line is dropped")
  // Control characters in a file never reach a field.
  const ctl = p(versionsOut({ plugin: MANIFEST("0.3.3"), installed: "#version=0.3.3\u001b[2J\n#repo=/a\u0007b\n" }), TOKEN)
  assert.strictEqual(ctl.installedVersion, "")
  assert.strictEqual(ctl.installedRepo, "")
})

test("installed parts: none, unknown, mismatch both ways, ok; the notice texts", () => {
  const v = (o) => model.parseVersions(versionsOut(Object.assign({ plugin: MANIFEST("0.3.3") }, o)), TOKEN)
  const cases = [
    [{}, "none", "Installed parts: not installed — run install.sh"],
    [{ legacy: true }, "unknown", "Installed parts are older than 0.3.3 (no version recorded) — run install.sh"],
    [{ installed: SHA }, "unknown", "Installed parts are older than 0.3.3 (no version recorded) — run install.sh"],
    [{ installed: "#version=garbage\n" + SHA }, "unknown", "Installed parts are older than 0.3.3 (no version recorded) — run install.sh"],
    [{ installed: "#version=0.3.2\n" + SHA }, "mismatch", "Installed parts are 0.3.2, plugin is 0.3.3 — run install.sh"],
    [{ installed: "#version=0.4.0\n" + SHA }, "mismatch", "Installed parts are 0.4.0, plugin is 0.3.3 — run install.sh"],
    [{ installed: "#version=0.3.3\n" + SHA }, "ok", ""],
    [{ installed: "#version=0.3.3\n" + SHA, legacy: true }, "ok", ""]
  ]
  for (const [o, state, text] of cases) {
    assert.strictEqual(model.installState(v(o)), state, JSON.stringify(o))
    assert.strictEqual(model.installNotice(v(o)), text, JSON.stringify(o))
  }
  // Nothing is claimed before a read, after a failed one, or without the
  // plugin's own version.
  for (const bad of [null, undefined, model.emptyVersions(), v({ plugin: '{"version":"x"}', installed: "#version=0.3.2\n" }), v({ plugin: undefined })]) {
    assert.strictEqual(model.installState(bad), "")
    assert.strictEqual(model.installNotice(bad), "")
  }
  assert.strictEqual(model.INSTALL_BUTTON_TEXT, "Update installed parts")
})

test("installed parts: the plugin folder, the read argv and the install argv", () => {
  assert.strictEqual(model.pluginDirFromUrl("file:///opt/plugins/cloud/manifest.json"), "/opt/plugins/cloud")
  assert.strictEqual(model.pluginDirFromUrl("file:///opt/my%20plugins/cloud/manifest.json"), "/opt/my plugins/cloud")
  for (const bad of ["", null, "/opt/cloud/manifest.json", "qrc:/cloud/manifest.json", "file:///opt/cloud/other.json",
    "file:///opt/../cloud/manifest.json", "file:///opt/./cloud/manifest.json", "file://relative/manifest.json",
    "file:///opt/a%0Ab/manifest.json", "file:///opt/%E0%A4%A/manifest.json", "file:///manifest.json", "file:///opt//x/manifest.json"])
    assert.strictEqual(model.pluginDirFromUrl(bad), "", String(bad))

  const argv = model.versionsArgv("/opt/cloud", "/home/u/.local/state", TOKEN)
  assert.deepStrictEqual(argv, ["timeout", "-k", "2", "10", "sh", "-c", model.VERSIONS_SCRIPT, "cloud-mounts-versions", TOKEN,
    String(model.INSTALL_HEADER_MAX_BYTES), String(model.PLUGIN_MANIFEST_MAX_BYTES), "/opt/cloud/manifest.json",
    "/home/u/.local/state/omarchy-cloud/installed-files", "/home/u/.local/state/omarchy-cloud/installed-binary.sha256", "/opt/cloud/install.sh"])
  for (const [dir, st, tok] of [["", "/s", TOKEN], ["/opt/cloud", "", TOKEN], ["/a/../b", "/s", TOKEN], ["/opt/cloud", "/s", "bad"]])
    assert.deepStrictEqual(model.versionsArgv(dir, st, tok), [], dir + " " + st + " " + tok)
  // Bounded at the source; values positional, nothing interpolated.
  assert.ok(/head -c "\$3" -- "\$2"/.test(model.VERSIONS_SCRIPT))
  assert.ok(/\[ -f "\$2" \] \|\| return 0/.test(model.VERSIONS_SCRIPT), "regular files only")

  // Install: the same floating terminal as Configure…, install.sh's path as
  // its own argument after a fixed script.
  const weird = "/tmp/$(touch x) `y`; z'q"
  const ia = model.installArgv(weird)
  assert.deepStrictEqual(ia, ["omarchy-launch-tui", "--app-id=TUI.float", "bash", "-c", model.INSTALL_SCRIPT, "omarchy-cloud-install", weird + "/install.sh"])
  assert.deepStrictEqual(ia.slice(0, 2), model.configureArgv(HOME).slice(0, 2))
  assert.ok(!model.INSTALL_SCRIPT.includes(weird))
  assert.ok(/bash -- "\$1"/.test(model.INSTALL_SCRIPT) && /read -r _/.test(model.INSTALL_SCRIPT), "runs $1, then waits for Enter")
  assert.ok(/exit status \$s/.test(model.INSTALL_SCRIPT), "prints the exit status")
  for (const bad of ["", null, "relative", "/a/../b", "/a\nb"]) assert.deepStrictEqual(model.installArgv(bad), [], String(bad))
})

test("installed parts: the tooltip carries the notice and the right-click hint", () => {
  const notice = "Installed parts are 0.3.2, plugin is 0.3.3 — run install.sh"
  assert.strictEqual(model.tooltipText([], null, null, true, "", notice, true),
    "Omarchy Cloud: No rclone-mount units found\nInstalled parts out of date — open the panel\nClick to manage · Right-click: Configure…")
  assert.strictEqual(model.tooltipText([], null, null, true, "", "Installed parts are older than 0.3.3 (no version recorded) — run install.sh", false),
    "Omarchy Cloud: No rclone-mount units found\nInstalled parts out of date — open the panel\nClick to manage")
  assert.strictEqual(model.tooltipText([], null, null, true, "", model.installNotice({ ok: true, plugin: "0.3.3", installedPresent: false, legacy: false, installedVersion: "" }), false),
    "Omarchy Cloud: No rclone-mount units found\nInstalled parts: not installed — open the panel\nClick to manage")
  assert.strictEqual(model.installTipLine(""), "")
  assert.strictEqual(model.installTipLine(undefined), "")
  // Without the TUI a right-click opens the panel: no hint.
  assert.strictEqual(model.tooltipText([], null, null, true, "", "", false), "Omarchy Cloud: No rclone-mount units found\nClick to manage")
  assert.strictEqual(model.tooltipText([], null, null, true, ""), "Omarchy Cloud: No rclone-mount units found\nClick to manage")
  // The cursor: Update installed parts is a footer stop before Configure….
  assert.deepStrictEqual(model.cursorGroups([], { canInstall: true, canConfigure: true }).map(x => x.keys), [["install"], ["configure"]])
  assert.ok(!model.cursorGroups([], { canInstall: false }).some(x => x.keys.includes("install")))
  assert.deepStrictEqual(model.cursorAction("install"), { kind: "install", arg: "" })
})

test("installed parts: read on attach and opening only, launched visibly, quiet mark", () => {
  const state = qmlCode("CloudState.qml")
  const bar = qmlCode("BarWidget.qml")
  assert.ok(/readonly property string pluginDir: Model\.pluginDirFromUrl\(Qt\.resolvedUrl\("manifest\.json"\)\)/.test(state))
  assert.ok(/if \(versionsProc\.running\) \{ root\.versionsPending = true; return \}/.test(state))
  assert.ok(/onStreamFinished: root\.applyVersions\(text, versionsProc\.token\)/.test(state))
  assert.ok(/function attach\(owner\) \{[\s\S]{0,250}if \(first\) root\.recheckVersions\(\)/.test(state), "on the first attach")
  assert.ok(/function holdOpen[\s\S]{0,300}root\.recheckVersions\(\)/.test(state), "on a panel opening")
  assert.strictEqual((state.match(/recheckVersions\(\)/g) || []).length, 3, "the definition, attach and holdOpen only")
  assert.ok(!/function (applyPoll|refresh|refreshSizes)\([^)]*\) \{[^}]*recheckVersions/.test(state), "never from the poll")
  // Launched like Configure…: detached, the panel closes.
  assert.ok(/function updateInstalled\(\) \{\s*if \(!root\.canInstall\) return\s*var argv = Model\.installArgv\(CloudState\.pluginDir\)\s*if \(argv\.length === 0\) return\s*Quickshell\.execDetached\(argv\)\s*root\.close\(\)/.test(bar))
  assert.ok(/else if \(a\.kind === "install"\) root\.updateInstalled\(\)/.test(bar))
  assert.ok(/text: root\.installButtonText\n/.test(bar) && /hasCursor: root\.cursorActive && root\.cursorAt === "install"/.test(bar))
  assert.ok(/canInstall: root\.canInstall,/.test(bar))
  // Right-click: Configure… once installed, else the panel; left toggles.
  assert.ok(/onPressed: function\(b\) \{ root\.pressButton\(b\) \}/.test(bar))
  assert.ok(/function pressButton\(b\) \{\s*if \(b === Qt\.RightButton\) \{\s*if \(root\.appInstalled\) root\.configure\(\)\s*else if \(!root\.opened\) root\.open\(\)\s*return\s*\}\s*root\.toggle\(\)/.test(bar))
  // The mark never replaces the error, and is not the urgent colour.
  assert.ok(/visible: root\.installNotice !== "" && root\.agg !== "error"\s*width: size\s*height: size\s*radius: size \/ 2\s*color: button\.foreground\s*borderSpec: Border\.flat\(Commons\.Color\.popups\.background, 1\)/.test(bar))
  assert.ok(/readonly property real size: Math\.max\(7, /.test(bar), "a legible badge")
  assert.ok(/x: Math\.max\(0, Math\.min\(button\.width - size, /.test(bar) && /y: Math\.max\(0, Math\.min\(button\.height - size, /.test(bar), "kept inside the slot")
  // The notice is its own line; the button beneath it, right-aligned; the
  // Configure hint does not repeat "run install.sh" beside it.
  assert.ok(/text: root\.installNotice\s*textFormat: Text\.PlainText\s*wrapMode: Text\.Wrap/.test(bar))
  assert.ok(/id: installButton\s*visible: root\.canInstall\s*anchors\.right: parent\.right/.test(bar))
  assert.ok(/text: root\.installNotice !== "" \? "" : Model\.configureHint\(/.test(bar))
  assert.ok(/active: root\.agg === "error"\n/.test(bar), "only an error turns the glyph urgent")
})


test("every Model.<name> the QML calls exists in Model.js", () => {
  for (const file of qmlFiles) {
    const qml = qmlCode(file).replace(/^import\s+.*$/gm, "")
    for (const m of qml.matchAll(/\bModel\.([A-Za-z_]\w*)/g))
      assert.ok(NAMES.includes(m[1]), file + " uses Model." + m[1] + ", not in Model.js")
  }
})

test("every CloudState.<name> the widget uses exists in CloudState.qml", () => {
  const state = qmlCode("CloudState.qml")
  const defined = new Set([...state.matchAll(/^\s*(?:readonly\s+)?property\s+\w+\s+(\w+)|^\s*function\s+(\w+)\s*\(/gm)].map(m => m[1] || m[2]))
  const bar = qmlCode("BarWidget.qml")
  for (const m of bar.matchAll(/\bCloudState\.([A-Za-z_]\w*)/g)) assert.ok(defined.has(m[1]), "CloudState." + m[1])
  assert.ok(/^singleton CloudState 1\.0 CloudState\.qml$/m.test(fs.readFileSync(path.join(pluginDir, "qmldir"), "utf8")))
  assert.ok(/^pragma Singleton$/m.test(fs.readFileSync(path.join(pluginDir, "CloudState.qml"), "utf8")))
})

// The body of the QML block whose "{" is at `open`, with every nested block
// and string literal blanked out: what is left are the block's own
// properties.
const ownBody = (qml, open) => {
  let depth = 0, out = ""
  for (let i = open; i < qml.length; i++) {
    const c = qml[i]
    if (c === '"' || c === "'") {
      let j = i + 1
      while (j < qml.length && qml[j] !== c) j += qml[j] === "\\" ? 2 : 1
      if (depth === 1) out += c + c
      i = j
      continue
    }
    if (c === "{") { depth++; if (depth === 1) continue }
    if (c === "}") { depth--; if (depth === 0) return out; continue }
    if (depth === 1) out += c
  }
  throw new Error("unbalanced block at " + open)
}
// Every Text block in a QML source: [line, own body].
const textBlocks = (qml) => [...qml.matchAll(/(^|[\s:])Text\s*\{/gm)].map(m => {
  const open = m.index + m[0].length - 1
  return [qml.slice(0, open).split("\n").length, ownBody(qml, open)]
})

test("every Text declares textFormat: Text.PlainText, each in its own block", () => {
  let total = 0
  for (const file of qmlFiles) {
    const qml = qmlCode(file)
    for (const [line, body] of textBlocks(qml)) {
      total++
      const own = (body.match(/(^|[\s;])textFormat:\s*Text\.PlainText\b/g) || []).length
      assert.strictEqual(own, 1, file + ":" + line + ": a Text with " + own + " own textFormat: Text.PlainText")
      assert.ok(!/textFormat:\s*Text\.(AutoText|StyledText|RichText|MarkdownText)/.test(body), file + ":" + line)
    }
  }
  assert.ok(total >= 20, "Text blocks found: " + total)
  // The check is per block: a Text with two declarations does not cover one
  // with none, and a nested child's declaration is not its parent's.
  const doubled = "Item {\n  Text {\n    textFormat: Text.PlainText\n    textFormat: Text.PlainText\n  }\n  Text {\n    text: \"{ }\"\n  }\n}"
  assert.deepStrictEqual(textBlocks(doubled).map(([, b]) => (b.match(/textFormat:\s*Text\.PlainText/g) || []).length), [2, 0])
  const nested = "Text {\n  text: \"a\"\n  Item { Text { textFormat: Text.PlainText } }\n}"
  assert.deepStrictEqual(textBlocks(nested).map(([, b]) => (b.match(/textFormat:\s*Text\.PlainText/g) || []).length), [0, 1])
})

test("theme colours are read as Commons.Color, never a bare Color", () => {
  for (const file of qmlFiles) {
    const qml = qmlCode(file)
    assert.ok(!/(^|[^.\w])Color\.\w/m.test(qml), file + " reads a bare Color.<role>")
  }
})

test("processes: argv from the model only, polling in the singleton, nothing banned", () => {
  for (const file of qmlFiles) {
    const qml = qmlCode(file)
    // Every execDetached / command is handed a Model argv, never a literal.
    for (const m of qml.matchAll(/execDetached\(([^)]*)\)/g)) assert.ok(/^argv$/.test(m[1].trim()), file + ": execDetached(" + m[1] + ")")
    for (const m of qml.matchAll(/\.command\s*=\s*([^\n]+)/g)) assert.ok(/^(Model\.\w+\(|argv$|pendingArgv$|busyArgv$)/.test(m[1].trim()), file + ": command = " + m[1])
    assert.ok(!/\bcommand:\s/.test(qml), file + ": a static command binding")
    assert.ok(!/bash -c|"-c"|bar\.run\(|Util\.execDetached|openUrlExternally|XMLHttpRequest|WebSocket|\brclone\s/.test(qml), file + " uses a banned call")
    assert.ok(!/\.config\/rclone["/]/.test(qml), file + " names the rclone config")
  }
  assert.ok(!/\.config\/rclone["/]/.test(source), "Model.js names the rclone config")
  assert.ok(!/\["rclone"|"rclone",/.test(source), "Model.js runs rclone")
  assert.ok(!/\b(rm|kill|pkill|killall)\b"/.test(source), "Model.js deletes or kills")
  const bar = qmlCode("BarWidget.qml")
  const state = qmlCode("CloudState.qml")
  assert.strictEqual((bar.match(/repeat:\s*true/g) || []).length, 0, "BarWidget.qml has no repeating timer")
  assert.strictEqual((state.match(/repeat:\s*true/g) || []).length, 2, "CloudState: the poll and the du timer")
  assert.ok(/interval:\s*Model\.POLL_MS\s*\n\s*running:\s*root\.polling/.test(state))
  assert.ok(/interval:\s*Model\.DU_MIN_MS\s*\n\s*running:\s*root\.openPanels\.length > 0/.test(state))
  // Never re-armed while running.
  assert.ok(/if \(poll\.running\) \{ root\.pollPending = true; return \}/.test(state))
  assert.ok(/if \(du\.running\) \{ root\.sizesPending = true; return \}/.test(state))
  assert.ok(/if \(argv\.length === 0 \|\| logProc\.running\) return/.test(bar))
  // A stop is gated by its own check phase only, never by a check process
  // still running from an earlier stop (a fuser hung on a hung mount).
  const begin = /function beginStop\(row\) \{([\s\S]*?)\n  \}/.exec(bar)[1]
  assert.ok(/if \(root\.stopPhase === "checking"\) return/.test(begin))
  assert.ok(!/busyCheck\.running \|\||pendingCheck\.running\) return/.test(begin), "beginStop waits on a stale check")
  assert.ok(/!busyCheck\.running\) \{\s*busyCheck\.gen = root\.checkGen/.test(begin))
  assert.ok(/!pendingCheck\.running\) \{\s*pendingCheck\.gen = root\.checkGen/.test(begin))
  // Late answers are dropped by generation; the checks read stdout.
  assert.ok(/id: busyCheck[\s\S]{0,120}stdout: StdioCollector[\s\S]{0,120}busyCheck\.gen !== root\.checkGen/.test(bar))
  assert.ok(!/stderr:/.test(bar), "fuser's answer is on stdout (FUSER_SCRIPT merges the streams)")
  assert.ok(/id: pendingCheck[\s\S]{0,120}stdout: StdioCollector[\s\S]{0,120}pendingCheck\.gen !== root\.checkGen/.test(bar))
  assert.ok(/interval: Model\.CHECK_DEADLINE_MS/.test(bar))
})

test("panel: stable rows, theme tokens, capped height, dim hero, no dead tooltips", () => {
  const bar = qmlCode("BarWidget.qml")
  assert.ok(/Repeater \{\s*model: root\.rowNames/.test(bar), "the Repeater is keyed by name")
  assert.ok(/if \(!Model\.sameList\(names, root\.rowNames\)\) root\.rowNames = names/.test(bar))
  assert.ok(!/Qt\.rgba\(/.test(bar), "fills come from Style, not literals")
  assert.ok(!/radius:\s*Style\.space/.test(bar), "radius follows Style.cornerRadius")
  assert.strictEqual((bar.match(/radius:\s*Style\.cornerRadius/g) || []).length, 2)
  assert.ok(/contentHeight: panel\.fittedContentHeight\(column\.implicitHeight\)\s*$/m.test(bar),
    "panel height follows the content, capped only by the screen (no constant cap)")
  assert.ok(!/fittedContentHeight\([^)]*,/.test(bar), "no fixed height cap")
  // The scroll bar has a strip of its own while the panel scrolls, not the controls' right edge.
  assert.ok(/ScrollBar\.vertical: ScrollBar \{\s*id: panelScroll\b/.test(bar))
  assert.ok(/id: column\s*width: panelFlick\.width - \(panelFlick\.interactive \? panelScroll\.width \+ Style\.space\(\d+\) : 0\)/.test(bar),
    "the column's width reserves the scroll bar gutter when the panel scrolls")
  assert.ok(!/width: panelFlick\.width\s*$/m.test(bar), "nothing is sized from the full flickable width")
  // The badge's size does not depend on a Style token older shells lack.
  assert.strictEqual((bar.match(/Style\.bar\.iconSize/g) || []).length, 1, "read once, through barIconSize")
  assert.ok(/readonly property real barIconSize: \{\s*var s = Number\(Style\.bar\.iconSize\)\s*return isFinite\(s\) && s > 0 \? s : \d+/.test(bar), "with a fallback")
  assert.strictEqual((bar.match(/root\.barIconSize/g) || []).length, 3)
  assert.ok(/iconOpacity: root\.agg === "none" \|\| root\.agg === "unknown"/.test(bar))
  // A disabled control shows no tooltip, so none carries a "why disabled".
  assert.ok(!/tooltipText:[^\n]*(canSyncNow|syncDisabledText|not installed)/.test(bar))
  assert.ok(!/^\s*enabled:\s*remoteRow/m.test(bar), "the folder button is hidden, not disabled, while unmounted")
  assert.ok(/onActivateRequested: if \(root\.cursorActive\) root\.activateCursor\(\)/.test(bar))
  // Every cursor stop kind is rendered by some control's hasCursor.
  for (const k of ['"configure"', '"force"', '"cancel"', 'cursorKey("switch"', 'cursorKey("folder"', 'cursorKey("log"', 'cursorKey("sync"'])
    assert.ok(bar.includes(k), k)
  // Offline folders and backups: keyed by name, each section hidden when empty.
  assert.ok(/Repeater \{\s*model: root\.pairNames/.test(bar) && /Repeater \{\s*model: root\.jobNames/.test(bar))
  assert.ok(/visible: root\.pairNames\.length > 0/.test(bar) && /visible: root\.jobNames\.length > 0/.test(bar))
  assert.ok(/agg: Model\.aggregate\(root\.rows, root\.pairRows, root\.jobRows, root\.polled\)/.test(bar), "failed syncs, backups and conflicts alert the bar")
  assert.ok(/tooltipText: Model\.tooltipText\(root\.rows, root\.pairRows, root\.jobRows, root\.polled, CloudState\.pollError,\s*root\.installNotice, root\.appInstalled\)/.test(bar))
  assert.ok(/meta: Model\.summary\(root\.rows, root\.polled, root\.pairRows, root\.jobRows\)/.test(bar), "the hero counts the same problems")
  // Remotes are capped like the other sections, and say so.
  assert.ok(/Repeater \{\s*model: root\.rowNames[\s\S]{0,300}\}\s*\}\s*Text \{\s*visible: text !== ""\s*width: parent\.width\s*text: Model\.capText\(root\.rows\.length, CloudState\.remotesFound, "remotes"\)/.test(bar),
    "Showing N of M remotes under the remote rows")
  assert.ok(/readonly property int remotesFound: Model\.remotesFound\(root\.knownRemotes, root\.units, root\.envFiles\)/.test(qmlCode("CloudState.qml")))
  // The install hint is a hint, not an alarm.
  assert.ok(/text: root\.installNotice !== "" \? "" : Model\.configureHint\(CloudState\.scanned, root\.appInstalled\)\s*textFormat: Text\.PlainText\s*wrapMode: Text\.Wrap\s*color: root\.dim/.test(bar), "install hint in the dim colour")
  // The poll is armed with the remotes only (pairs and jobs are globbed).
  assert.ok(/var argv = Model\.pollArgv\(root\.remotes, token\)[\s\S]{0,80}poll\.command = argv/.test(qmlCode("CloudState.qml")))
  assert.ok(/function configure\(\) \{\s*if \(!root\.appInstalled\) return/.test(bar))
  assert.ok(/function syncNow\(pair\) \{[\s\S]{0,120}if \(!row \|\| !row\.canSync\) return/.test(bar), "Sync now only while enabled")
  assert.ok(!/KeePass|vault-A|KEEPASS/i.test(bar.replace(/\/\/.*$/gm, "")), "no hardcoded KeePass section")
  const state = qmlCode("CloudState.qml")
  assert.ok(/if \(JSON\.stringify\(parsed\) !== JSON\.stringify\(root\.units\)\) root\.units = parsed/.test(state))
  // The scan: never on a timer; on a changed key after a poll, and on a panel opening.
  assert.ok(/if \(scan\.running\) \{ root\.scanPending = true; return \}/.test(state))
  assert.ok(/Qt\.callLater\(root\.rescan\)/.test(state))
  assert.ok(/root\.polls\+\+[\s\S]{0,300}if \(key !== root\.scanKey\) \{\s*root\.scanKey = key\s*root\.rescan\(\)/.test(state))
  assert.ok(/function holdOpen[\s\S]{0,250}root\.rescan\(\)/.test(state))
  assert.ok(/onStreamFinished: root\.applyScan\(text, scan\.token, scan\.seq\)/.test(state), "read against the token it was armed with")
  assert.ok(/!Object\.prototype\.hasOwnProperty\.call\(parsed, Model\.SENTINEL_UNIT\)/.test(state), "a poll without the sentinel failed")
  assert.ok(!/FileView|conflictListing/.test(state + bar), "no whole-file reads, no conflict listing")
})

test("rowByName, rowNames, sameList", () => {
  const rows = model.remoteRows(["onedrive", "gdrive"], {}, {})
  assert.deepStrictEqual(model.rowNames(rows), ["gdrive", "onedrive"])
  assert.strictEqual(model.rowByName(rows, "onedrive").name, "onedrive")
  assert.strictEqual(model.rowByName(rows, "x"), null)
  assert.strictEqual(model.rowByName(null, "x"), null)
  assert.ok(model.sameList(["a", "b"], ["a", "b"]))
  assert.ok(!model.sameList(["a", "b"], ["b", "a"]))
  assert.ok(!model.sameList(["a"], ["a", "b"]))
  assert.ok(!model.sameList(null, []))
})

test("syncBlockedText: the reason Sync now is disabled, as text", () => {
  assert.ok(/not installed/.test(model.syncBlockedText({ name: "p", installed: false, enabled: false })))
  assert.strictEqual(model.syncBlockedText({ name: "p", installed: true, enabled: false }), "Sync not enabled: rclone-bisync@p.timer and .path are both disabled.")
  assert.strictEqual(model.syncBlockedText({ name: "p", installed: true, enabled: true }), "")
  assert.strictEqual(model.syncBlockedText(null), "")
})

test("cursor: groups in screen order, steps, activation keys, fallbacks", () => {
  const units = {
    "rclone-mount@gdrive.service": block({ Id: "rclone-mount@gdrive.service", ActiveState: "active" }),
    "rclone-mount@onedrive.service": block({ Id: "rclone-mount@onedrive.service", ActiveState: "failed", Result: "exit-code" })
  }
  const parsed = model.parseShow(Object.values(units).join("\n\n"))
  const rows = model.remoteRows(["gdrive", "onedrive"], parsed, {})
  const pairs = [{ name: "vault-A", unit: "rclone-bisync@vault-A.service", canSync: true, failed: false },
    { name: "off", unit: "rclone-bisync@off.service", canSync: false, failed: false },
    { name: "bad", unit: "rclone-bisync@bad.service", canSync: true, failed: true }]
  const jobs = [{ name: "ok", unit: "rclone-backup@ok.service", failed: false }, { name: "admin", unit: "rclone-backup@admin.service", failed: true }]
  let g = model.cursorGroups(rows, { pairs: pairs, jobs: jobs, canConfigure: true })
  assert.deepStrictEqual(g.map(x => x.keys), [
    ["folder|gdrive", "switch|gdrive"],
    ["log|rclone-mount@onedrive.service", "switch|onedrive"],
    ["sync|vault-A"],
    ["log|rclone-bisync@bad.service", "sync|bad"],
    ["log|rclone-backup@admin.service"],
    ["configure"]])
  // A pair's log, open while it is not failed, is a stop until closed.
  assert.ok(model.cursorGroups(rows, { pairs: pairs, logUnit: "rclone-bisync@off.service" }).some(x => x.keys.includes("log|rclone-bisync@off.service")))
  // A closed log of a pair falls back to its Sync now.
  assert.strictEqual(model.cursorKeyIn(g, "log|rclone-bisync@vault-A.service", ""), "sync|vault-A")
  assert.strictEqual(model.stepCursor(g, "sync|vault-A", 0, 1), "sync|bad", "Down lands on the row's primary (Sync now)")
  assert.strictEqual(model.stepCursor(g, "sync|bad", -1, 0), "log|rclone-bisync@bad.service")
  assert.strictEqual(model.stepCursor(g, "log|rclone-backup@admin.service", 0, 1), "configure")
  assert.strictEqual(model.stepCursor(g, "configure", 0, 1), "configure")
  // Configure… is a stop only when the TUI is installed; nothing else: still reachable.
  assert.ok(!model.cursorGroups(rows, { canConfigure: false }).some(x => x.keys.includes("configure")))
  assert.deepStrictEqual(model.cursorGroups([], { canConfigure: true }).map(x => x.keys), [["configure"]])
  assert.strictEqual(model.cursorKeyIn(model.cursorGroups([], { canConfigure: true }), "", ""), "configure")
  g = model.cursorGroups(rows, { canConfigure: true })
  // Up/Down land on a row's switch; Left/Right walk the row.
  let k = model.cursorKeyIn(g, "", "")
  assert.strictEqual(k, "switch|gdrive")
  assert.strictEqual(model.stepCursor(g, k, 0, 1), "switch|onedrive")
  assert.strictEqual(model.stepCursor(g, k, -1, 0), "folder|gdrive")
  assert.strictEqual(model.stepCursor(g, "folder|gdrive", -1, 0), "folder|gdrive")
  assert.strictEqual(model.stepCursor(g, k, 0, -1), k, "past the top stays (the widget scrolls)")
  assert.strictEqual(model.stepCursor(g, "switch|onedrive", 0, 1), "configure")
  // The confirm box sits under its row; Force and Cancel are both stops.
  g = model.cursorGroups(rows, { stopRemote: "gdrive", confirm: true })
  assert.deepStrictEqual(g[1].keys, ["force", "cancel"])
  assert.strictEqual(model.stepCursor(g, "switch|gdrive", 0, 1), "cancel")
  assert.strictEqual(model.stepCursor(g, "cancel", -1, 0), "force")
  // Disabled controls are not stops: no Sync now while it cannot run, no folder unmounted.
  g = model.cursorGroups(rows, { pairs: [{ name: "off", unit: "rclone-bisync@off.service", canSync: false }] })
  assert.ok(!g.some(x => x.keys.some(k => /^sync/.test(k))))
  assert.ok(!g.some(x => x.keys.includes("folder|onedrive")))
  // Gone stops fall back to their row's switch, then to the first stop.
  assert.strictEqual(model.cursorKeyIn(g, "folder|onedrive", ""), "switch|onedrive")
  assert.strictEqual(model.cursorKeyIn(g, "cancel", "onedrive"), "switch|onedrive")
  assert.strictEqual(model.cursorKeyIn(g, "sync|off", ""), "switch|gdrive")
  assert.strictEqual(model.cursorKeyIn([], "sync", ""), "")
  assert.strictEqual(model.stepCursor([], "sync", 0, 1), "")
  assert.deepStrictEqual(model.cursorAction("switch|gdrive"), { kind: "switch", arg: "gdrive" })
  assert.deepStrictEqual(model.cursorAction("log|rclone-bisync@p.service"), { kind: "log", arg: "rclone-bisync@p.service" })
  assert.deepStrictEqual(model.cursorAction("sync|vault-A"), { kind: "sync", arg: "vault-A" })
  assert.deepStrictEqual(model.cursorAction("configure"), { kind: "configure", arg: "" })
  assert.deepStrictEqual(model.cursorAction("force"), { kind: "force", arg: "" })
  assert.deepStrictEqual(model.cursorAction("rm|x"), { kind: "", arg: "" })
  assert.strictEqual(model.cursorKey("switch", "gdrive"), "switch|gdrive")
  assert.strictEqual(model.cursorKey("sync", "vault-A"), "sync|vault-A")
  assert.strictEqual(model.cursorKey("configure"), "configure")
})

test("#8 a watch-stopped pair whose last run failed still counts as a failed sync and keeps Show log", () => {
  const scan = { ok: true, app: true, more: false, templates: { bisync: true, backup: true }, pairConfs: {}, jobConfs: {}, pairStates: {}, jobStates: {} }
  const watchDown = { timer: { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" },
    path: { UnitFileState: "enabled", ActiveState: "failed", SubState: "failed", Result: "trigger-limit-hit" } }
  const rowFor = (st) => {
    scan.pairStates = { p: model.parseState(st) }
    return model.pairRows(["p"], model.parseShow(show(...pairBlocks("p", watchDown), sentinel())), scan, NOW)[0]
  }
  const okRow = rowFor(["time=1794699700", "exit=0"])
  assert.strictEqual(okRow.watchStopped, true)
  assert.deepStrictEqual(model.problems([], [okRow], []).syncs, [])
  assert.ok(!model.cursorGroups([], { pairs: [okRow] }).some(x => x.keys.includes("log|rclone-bisync@p.service")))
  const bad = rowFor(["time=1794699700", "exit=1"])
  assert.strictEqual(bad.watchStopped, true)
  assert.strictEqual(bad.runFailed, true)
  assert.deepStrictEqual(model.problems([], [bad], []).syncs, ["p"])
  assert.deepStrictEqual(model.problems([], [bad], []).watches, ["p"])
  assert.ok(model.cursorGroups([], { pairs: [bad] }).some(x => x.keys.includes("log|rclone-bisync@p.service")))
})

test("#10 names: every line of tests/fixtures/names.tsv; pair enabled is either unit", () => {
  let n = 0
  for (const line of fs.readFileSync(path.join(pluginDir, "tests/fixtures/names.tsv"), "utf8").split("\n")) {
    if (line === "" || line.startsWith("#")) continue
    const tab = line.indexOf("\t")
    const kind = line.slice(0, tab), name = line.slice(tab + 1)
    assert.ok(kind === "valid" || kind === "invalid", line)
    assert.strictEqual(model.isValidRemote(name), kind === "valid", JSON.stringify(line))
    n++
  }
  assert.ok(n >= 20, "fixture read")
  const scan = { ok: true, app: true, more: false, templates: { bisync: true, backup: true }, pairConfs: {}, jobConfs: {}, pairStates: {}, jobStates: {} }
  const on = { UnitFileState: "enabled", ActiveState: "active", SubState: "waiting" }
  const off = { UnitFileState: "disabled", ActiveState: "inactive", SubState: "dead" }
  const enabled = (o) => model.pairRows(["p"], model.parseShow(show(...pairBlocks("p", o), sentinel())), scan, NOW)[0].enabled
  assert.strictEqual(enabled({ timer: on, path: off }), true)
  assert.strictEqual(enabled({ timer: off, path: on }), true)
  assert.strictEqual(enabled({ timer: off, path: off }), false)
})

test("#14 the pending script says unknown, never 0, when the cache cannot be read", () => {
  const cp = require("child_process")
  const os = require("os")
  const run = (dir) => cp.spawnSync("bash", ["-c", model.PENDING_SCRIPT, "x", dir], { encoding: "utf8" }).stdout
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pend-"))
  try {
    assert.strictEqual(model.parsePendingCount(run(path.join(tmp, "missing"))), 0, "no cache directory: nothing pending")
    const d = path.join(tmp, "ok")
    fs.mkdirSync(d)
    assert.strictEqual(model.parsePendingCount(run(d)), 0)
    fs.writeFileSync(path.join(d, "a"), '{"Dirty": true}')
    fs.writeFileSync(path.join(d, "b"), '{"Dirty": false}')
    assert.strictEqual(model.parsePendingCount(run(d)), 1)
    if (process.getuid && process.getuid() !== 0) {
      const u = path.join(tmp, "locked")
      fs.mkdirSync(u)
      fs.writeFileSync(path.join(u, "a"), '{"Dirty": true}')
      fs.chmodSync(u, 0)
      const out = run(u)
      fs.chmodSync(u, 0o700)
      assert.strictEqual(model.parsePendingCount(out), -1, out)
    }
  } finally { fs.rmSync(tmp, { recursive: true, force: true }) }
  // Unknown is asked about, never stopped silently.
  const idle = { known: true, total: 0, procs: [] }
  assert.strictEqual(model.stopDecision(idle, model.parsePendingCount("unknown")), "confirm")
  assert.strictEqual(model.stopDecision(idle, 0), "stop")
  assert.ok(/could not be counted/.test(model.stopPrompt("gdrive", idle, -1)))
})

// ------------------------------------------------------- 0.3.5: mount root

// tests/fixtures/roots.tsv, read as BYTES (some cases are not UTF-8): each
// case's verdict, its raw bytes, and the text a Quickshell FileView/Process
// gives for them (a non-fatal UTF-8 decode, a bad byte becoming U+FFFD).
const rootCases = () => {
  const raw = fs.readFileSync(path.join(pluginDir, "tests/fixtures/roots.tsv"))
  const out = []
  let start = 0
  while (start < raw.length) {
    let end = raw.indexOf(0x0a, start)
    if (end < 0) end = raw.length
    const line = raw.subarray(start, end)
    start = end + 1
    if (line.length === 0 || line[0] === 0x23) continue
    const tab = line.indexOf(0x09)
    assert.ok(tab > 0, JSON.stringify(line.toString("latin1")))
    const kind = line.subarray(0, tab).toString("latin1")
    assert.ok(kind === "valid" || kind === "invalid", kind)
    const bytes = line.subarray(tab + 1)
    out.push({ kind, bytes, text: new TextDecoder("utf-8").decode(bytes) })
  }
  return out
}

// The bytes of a scan (or, `alone`, a SETTING_SCRIPT run) whose cloud.env is
// `content` (a Buffer), exactly as the scripts print it, decoded as the
// panel's Process decodes its stdout.
const settingOutput = (content, alone) => new TextDecoder("utf-8").decode(Buffer.concat([
  Buffer.from((alone ? "" : TOKEN + " app\n") + TOKEN + " setting " + content.length + "\n"),
  content, Buffer.from("\n" + TOKEN + " eof\n" + TOKEN + " end\n")]))

test("D1 roots: every line of tests/fixtures/roots.tsv, HOME=/home/tester", () => {
  let n = 0, valid = 0, nonUtf8 = 0
  for (const c of rootCases()) {
    const want = c.kind === "valid"
    const shown = JSON.stringify(c.text)
    assert.strictEqual(model.isValidRoot(c.text, "/home/tester"), want, shown)
    assert.strictEqual(model.isValidRoot(c.text, "/home/tester/"), want, "trailing slash on HOME: " + shown)
    // The panel's real path: cloud.env's bytes through the scan, and through
    // the setting re-read, to rootSetting. Nothing trimmed.
    const env = Buffer.concat([Buffer.from("OMARCHY_CLOUD_ROOT="), c.bytes, Buffer.from("\n")])
    const dirs = model.scanDirs("/home/tester", "/home/tester/.local/state")
    const scan = model.parseScan(settingOutput(env, false), TOKEN, dirs)
    assert.ok(scan.ok, shown)
    const fromScan = model.rootSetting(scan, "/home/tester")
    assert.strictEqual(fromScan.state, want ? "valid" : "invalid", "scan " + shown)
    if (want) assert.strictEqual(fromScan.path, c.text, shown)
    else assert.strictEqual(fromScan.path, model.DEFAULT_MOUNT_ROOT, shown)
    const read = model.parseSettingRead(settingOutput(env, true), TOKEN)
    assert.ok(read.ok, shown)
    assert.strictEqual(read.setting.value, c.text, "verbatim " + shown)
    const fromRead = model.rootSetting(model.withSetting(scan, read.setting), "/home/tester")
    assert.deepStrictEqual(fromRead, fromScan, "re-read " + shown)
    if (!Buffer.from(c.text, "utf8").equals(c.bytes)) {
      assert.ok(!want, "a non-UTF-8 case must be invalid: " + shown)
      nonUtf8++
    }
    if (want) valid++
    n++
  }
  assert.ok(n >= 49 && valid >= 13 && n - valid >= 36 && nonUtf8 >= 5,
    "fixture read: " + n + " (" + valid + " valid, " + nonUtf8 + " non-UTF-8)")
  // A lone surrogate has no UTF-8 form; U+FFFD is a bad byte, decoded.
  for (const bad of ["/mnt/\ud800", "/mnt/a\udc00b", "/mnt/\ud800\ud800", "/mnt/\udc00\ud800", "/mnt/\ufffd", "/\ufffd"])
    assert.strictEqual(model.isValidRoot(bad, "/home/tester"), false, JSON.stringify(bad))
  assert.ok(model.isValidRoot("/mnt/\ud83d\ude00", "/home/tester"), "a paired surrogate (U+1F600) is fine")
  for (const v of [null, undefined, 1, {}, ["/mnt/cloud"]]) assert.strictEqual(model.isValidRoot(v, "/home/tester"), false, String(v))
  // Byte length, not characters; non-ASCII allowed; every control byte refused.
  assert.ok(model.isValidRoot("/mnt/é", "/home/tester"))
  assert.ok(model.isValidRoot("/" + "é".repeat(127), "/home/tester"), "255 bytes")
  assert.ok(!model.isValidRoot("/" + "é".repeat(127) + "a", "/home/tester"), "256 bytes")
  for (let c = 0; c <= 0x20; c++) assert.ok(!model.isValidRoot("/mnt/a" + String.fromCharCode(c) + "b", "/home/tester"), "byte " + c)
  assert.ok(!model.isValidRoot("/mnt/a\u007fb", "/home/tester"))
  // Without a usable HOME only the home rule is skipped (the scripts' rule).
  assert.ok(model.isValidRoot("/home/tester/cloud", ""))
  for (const h of ["", "/", "//"]) {
    assert.strictEqual(model.isValidRoot("/mnt/x", h), true, "HOME " + JSON.stringify(h))
    assert.strictEqual(model.isValidRoot("/mnt/../x", h), false, "HOME " + JSON.stringify(h))
  }
  assert.ok(!model.isValidRoot("/", ""))
})

// The lines of a tab-separated fixture, "#" lines and empty lines skipped.
const tsvCases = (name) => fs.readFileSync(path.join(pluginDir, "tests/fixtures", name), "utf8")
  .split("\n").filter(l => l !== "" && l[0] !== "#").map(l => l.split("\t"))

test("D1 homes: every line of tests/fixtures/homes.tsv, the home normalised the same everywhere", () => {
  let n = 0
  for (const [kind, home, root] of tsvCases("homes.tsv")) {
    assert.ok(kind === "valid" || kind === "invalid", kind)
    const want = kind === "valid"
    const shown = JSON.stringify([home, root])
    assert.strictEqual(model.isValidRoot(root, home), want, shown)
    // The panel's real path: the setting through rootSetting, and the check
    // run only for a valid one.
    const env = Buffer.from("OMARCHY_CLOUD_ROOT=" + root + "\n")
    const scan = model.parseScan(settingOutput(env, false), TOKEN, model.scanDirs("/home/tester", "/home/tester/.local/state"))
    assert.strictEqual(model.rootSetting(scan, home).state, want ? "valid" : "invalid", "scan " + shown)
    assert.strictEqual(model.rootCheckArgv(root, home).length > 0, want, "check " + shown)
    n++
  }
  assert.ok(n >= 17, "fixture read: " + n)
  assert.strictEqual(model.normaliseHome("/home//u/./"), "/home/u")
  assert.strictEqual(model.normaliseHome("/home/../u"), "/home/../u", ".. kept as written")
  for (const none of ["", "/", "//", "/./", "/.", null, undefined, 1]) assert.strictEqual(model.normaliseHome(none), "", String(none))
})

test("D1 resolved roots: every line of tests/fixtures/resolved-roots.tsv through the real ROOT_CHECK_SCRIPT", () => {
  const cp = require("child_process")
  const os = require("os")
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "resolved-")))
  let n = 0, valid = 0
  try {
    for (const [kind, setup, rel] of tsvCases("resolved-roots.tsv")) {
      assert.ok(kind === "valid" || kind === "invalid", kind)
      const t = path.join(base, "case" + n)
      fs.mkdirSync(t)
      const steps = setup === "-" ? [] : setup.split(";")
      if (!steps.some(s => s.startsWith("link:home="))) fs.mkdirSync(path.join(t, "home"))
      for (const step of steps) {
        if (step.startsWith("dir:")) fs.mkdirSync(path.join(t, step.slice(4)), { recursive: true })
        else if (step.startsWith("link:")) {
          const eq = step.indexOf("=")
          const at = path.join(t, step.slice(5, eq))
          const target = step.slice(eq + 1)
          fs.mkdirSync(path.dirname(at), { recursive: true })
          fs.symlinkSync(target.startsWith("@/") ? path.join(t, target.slice(2)) : target, at)
        } else assert.fail("bad fixture step " + step)
      }
      const home = path.join(t, "home"), root = path.join(t, rel)
      const shown = JSON.stringify([kind, setup, rel])
      assert.ok(model.isValidRoot(root, home), "T must pass valid_root: " + shown)
      const a = model.rootCheckArgv(root, home)
      const got = model.parseRootCheck(cp.spawnSync(a[0], a.slice(1), { encoding: "utf8" }).stdout)
      if (kind === "valid") {
        assert.ok(got === "ok" || got === "missing", shown + ": " + got)
        valid++
      } else assert.strictEqual(got, "inhome", shown)
      n++
    }
    // A realpath that fails: refused as unresolved, not judged ok.
    const stub = path.join(base, "stub")
    fs.mkdirSync(stub)
    fs.writeFileSync(path.join(stub, "realpath"), "#!/bin/sh\nexit 1\n", { mode: 0o755 })
    fs.mkdirSync(path.join(base, "plain"))
    const a = model.rootCheckArgv(path.join(base, "plain"), path.join(base, "case0", "home"))
    const env = Object.assign({}, process.env, { PATH: stub + ":" + process.env.PATH })
    assert.strictEqual(model.parseRootCheck(cp.spawnSync(a[0], a.slice(1), { encoding: "utf8", env }).stdout), "unresolved")
    // The home as written counts on its own: a resolver that puts the home
    // elsewhere still refuses a root resolving under the written one.
    const stub2 = path.join(base, "stub2")
    fs.mkdirSync(stub2)
    fs.writeFileSync(path.join(stub2, "realpath"), "#!/bin/sh\ncase $3 in */home) echo /elsewhere;; *) exec /usr/bin/realpath \"$@\";; esac\n", { mode: 0o755 })
    fs.mkdirSync(path.join(base, "h", "home", "Cloud"), { recursive: true })
    fs.symlinkSync(path.join(base, "h", "home", "Cloud"), path.join(base, "ln"))
    const c = model.rootCheckArgv(path.join(base, "ln"), path.join(base, "h", "home"))
    const env2 = Object.assign({}, process.env, { PATH: stub2 + ":" + process.env.PATH })
    assert.strictEqual(model.parseRootCheck(cp.spawnSync(c[0], c.slice(1), { encoding: "utf8", env: env2 }).stdout), "inhome")
    // No home: nothing resolved, the directory check only.
    const b = model.rootCheckArgv(path.join(base, "plain"), "/")
    assert.strictEqual(model.parseRootCheck(cp.spawnSync(b[0], b.slice(1), { encoding: "utf8", env }).stdout), "ok")
  } finally { fs.rmSync(base, { recursive: true, force: true }) }
  assert.ok(n >= 16 && valid >= 6 && n - valid >= 10, "fixture read: " + n + " (" + valid + " valid)")
  // The verdict reaches the notice.
  const setting = { state: "valid", path: "/mnt/cloud", value: "/mnt/cloud" }
  assert.strictEqual(model.rootStatus(setting, { path: "/mnt/cloud", result: "inhome" }), "inhome")
  assert.ok(model.rootNotice("inhome", setting).startsWith("Mount root not set up: /mnt/cloud resolves inside your home"))
})

// A scan with the setting file `content` (undefined: no file).
const scanWithSetting = (content, o) => {
  const opt = o || {}
  let out = TOKEN + " app\n"
  if (content !== undefined) {
    const size = opt.size !== undefined ? opt.size : Buffer.byteLength(content)
    out += TOKEN + " setting " + size + "\n" + content + "\n" + TOKEN + " eof\n"
  }
  return model.parseScan(out + TOKEN + " end\n", TOKEN, model.scanDirs("/home/tester", "/home/tester/.local/state"))
}

test("D1 the root is parsed from cloud.env (never sourced) and mountPath follows it", () => {
  const setting = (content, o) => model.rootSetting(scanWithSetting(content, o), "/home/tester")
  assert.deepStrictEqual(setting("OMARCHY_CLOUD_ROOT=/srv/cloud\n"), { state: "valid", path: "/srv/cloud", value: "/srv/cloud" })
  assert.deepStrictEqual(setting(undefined), { state: "absent", path: "/mnt/cloud", value: "" })
  assert.deepStrictEqual(setting("# nothing\n\nOTHER=/srv/x\n"), { state: "absent", path: "/mnt/cloud", value: "" })
  // CRLF, comments, blank lines; the last line of the key wins (systemd).
  assert.strictEqual(setting("# root\r\n\r\nOMARCHY_CLOUD_ROOT=/srv/a\r\nOMARCHY_CLOUD_ROOT=/srv/b\r\n").path, "/srv/b")
  // Verbatim: no quote stripping, no trimming, no expansion, so these are invalid.
  for (const raw of ['"/srv/cloud"', "'/srv/cloud'", "/srv/cloud ", " /srv/cloud", "$HOME/cloud", "~/cloud", "/home/tester/Cloud", "", "/srv/cloud/"]) {
    const s = setting("OMARCHY_CLOUD_ROOT=" + raw + "\n")
    assert.deepStrictEqual(s, { state: "invalid", path: "/mnt/cloud", value: raw }, JSON.stringify(raw))
  }
  // Only a line that starts with the key counts.
  assert.strictEqual(setting(" OMARCHY_CLOUD_ROOT=/srv/a\nexport OMARCHY_CLOUD_ROOT=/srv/b\n#OMARCHY_CLOUD_ROOT=/srv/c\n").state, "absent")
  // A file larger than the read keeps its cut last line, as the bash and Rust
  // readers do (C1): the partial line is a line like any other.
  assert.strictEqual(setting("OMARCHY_CLOUD_ROOT=/srv/a\nOMARCHY_CLOUD_ROOT=/srv/cut", { size: 99999 }).path, "/srv/cut")
  // Every line within the byte bound counts: no line cap (a key line after
  // 1000 short comment lines still wins).
  assert.strictEqual(setting("OMARCHY_CLOUD_ROOT=/srv/a\n" + "#\n".repeat(1000) + "OMARCHY_CLOUD_ROOT=/srv/late\n").path, "/srv/late")
  assert.strictEqual(setting("\n".repeat(4000) + "OMARCHY_CLOUD_ROOT=/srv/late\n").path, "/srv/late")
  assert.deepStrictEqual(model.parseRootSetting(Array(500).fill("#").concat(["OMARCHY_CLOUD_ROOT=/srv/late"])), { found: true, value: "/srv/late" })
  // The marker is the token's: a forged one inside a conf is content.
  const forged = model.parseScan(TOKEN + " file 40 /home/tester/.config/rclone-bisync/p.conf\ncmscan-zzzzzzzzzzzz setting 30\nOMARCHY_CLOUD_ROOT=/srv/evil\n"
    + TOKEN + " eof\n" + TOKEN + " end\n", TOKEN, model.scanDirs("/home/tester", "/home/tester/.local/state"))
  assert.strictEqual(model.rootSetting(forged, "/home/tester").state, "absent")
  // A HOME that is "" or "/" skips only the home rule (bash and Rust agree).
  for (const h of ["", "/"]) {
    assert.deepStrictEqual(model.rootSetting(scanWithSetting("OMARCHY_CLOUD_ROOT=/mnt/x\n"), h), { state: "valid", path: "/mnt/x", value: "/mnt/x" }, "HOME " + JSON.stringify(h))
    assert.strictEqual(model.rootSetting(scanWithSetting("OMARCHY_CLOUD_ROOT=/mnt/x/\n"), h).state, "invalid")
  }
  // Nothing is claimed before a good scan.
  assert.strictEqual(model.rootSetting(model.emptyScan(), "/home/tester"), null)
  assert.strictEqual(model.rootSetting(null, "/home/tester"), null)
  // mountPath and the stop checks follow the root in use; the default without one.
  const valid = setting("OMARCHY_CLOUD_ROOT=/srv/cloud\n")
  assert.strictEqual(model.mountRoot(valid), "/srv/cloud")
  assert.strictEqual(model.mountPath("gdrive", model.mountRoot(valid)), "/srv/cloud/gdrive")
  assert.deepStrictEqual(model.fuserArgv("gdrive", model.mountRoot(valid)).slice(-1), ["/srv/cloud/gdrive"])
  assert.strictEqual(model.parseFuser("/srv/cloud/gdrive:  kernel mount /srv/cloud/gdrive\ncloud-mounts-fuser-exit 0\n", "gdrive", "/srv/cloud").known, true)
  for (const none of [null, setting(undefined), setting("OMARCHY_CLOUD_ROOT=relative\n")]) {
    assert.strictEqual(model.mountRoot(none), "/mnt/cloud")
    assert.strictEqual(model.mountPath("gdrive", model.mountRoot(none)), "/mnt/cloud/gdrive")
  }
  assert.strictEqual(model.mountPath("gdrive"), "/mnt/cloud/gdrive")
  assert.strictEqual(model.mountPath("gdrive", "/a/../b"), "/mnt/cloud/gdrive", "an invalid root is never used")
  assert.strictEqual(model.mountPath("../x", "/srv/cloud"), "")
  assert.strictEqual(model.DEFAULT_MOUNT_ROOT, "/mnt/cloud")
  assert.ok(!/\/mnt\/cloud/.test(source.replace(/\/\/.*$/gm, "").replace(/var DEFAULT_MOUNT_ROOT = "\/mnt\/cloud"/, "")), "no other literal /mnt/cloud in Model.js code")
})

test("D1 the root check: the root as its own argument, never in the script", () => {
  const argv = model.rootCheckArgv("/srv/cloud", "/home/tester")
  assert.deepStrictEqual(argv, ["timeout", "-k", "2", "10", "sh", "-c", model.ROOT_CHECK_SCRIPT, "cloud-mounts-root", "/srv/cloud", "/home/tester"])
  assert.ok(/^r=\$1 h=\$2\n/.test(model.ROOT_CHECK_SCRIPT), model.ROOT_CHECK_SCRIPT)
  assert.ok(/\nif \[ -d "\$r" \] && \[ -w "\$r" \] && \[ -x "\$r" \]; then echo root-ok; else echo root-missing; fi$/.test(model.ROOT_CHECK_SCRIPT), model.ROOT_CHECK_SCRIPT)
  // The helpers' own resolver, for the root and the home.
  assert.strictEqual((model.ROOT_CHECK_SCRIPT.match(/timeout -k 1 5 realpath -m -- /g) || []).length, 2)
  // The home as its own argument, normalised; "" for none.
  assert.deepStrictEqual(model.rootCheckArgv("/srv/cloud", "/home//tester/./").slice(-2), ["/srv/cloud", "/home/tester"])
  // Only a valid root (the home rule included) is ever checked.
  for (const c of rootCases()) {
    const root = c.text
    const a = model.rootCheckArgv(root, "/home/tester")
    if (c.kind === "valid") {
      assert.strictEqual(a[a.length - 2], root, root)
      assert.strictEqual(a.filter(x => x.includes(root)).length, 1, "the root is one element: " + root)
      assert.ok(!model.ROOT_CHECK_SCRIPT.includes(root))
    } else assert.deepStrictEqual(a, [], JSON.stringify(root))
  }
  // A HOME that is "" or "/" skips only the home rule, as bash and Rust do.
  for (const h of ["", "/"]) {
    assert.deepStrictEqual(model.rootCheckArgv("/srv/cloud", h).slice(-2), ["/srv/cloud", ""], "HOME " + JSON.stringify(h))
    assert.deepStrictEqual(model.rootCheckArgv("/srv/a/../b", h), [], "still the other rules")
  }
  // Through a real sh: a writable dir is ok, a missing or read-only one is
  // missing, and a crafted (valid) root runs nothing.
  const cp = require("child_process")
  const os = require("os")
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "root-"))
  const check = (root) => {
    const a = model.rootCheckArgv(root, "/home/tester")
    return model.parseRootCheck(cp.spawnSync(a[0], a.slice(1), { encoding: "utf8", cwd: tmp }).stdout)
  }
  try {
    assert.strictEqual(check(tmp), "ok")
    assert.strictEqual(check(tmp + "/missing"), "missing")
    fs.writeFileSync(path.join(tmp, "file"), "")
    assert.strictEqual(check(tmp + "/file"), "missing", "a file is not a root")
    if (process.getuid && process.getuid() !== 0) {
      fs.mkdirSync(path.join(tmp, "ro"), { mode: 0o500 })
      assert.strictEqual(check(tmp + "/ro"), "missing", "not writable")
    }
    const crafted = tmp + "/a;touch.PWNED;(id)>PWNED2|x&y"
    assert.ok(model.isValidRoot(crafted, "/home/tester"), crafted)
    assert.strictEqual(check(crafted), "missing")
    assert.ok(!fs.existsSync(path.join(tmp, "PWNED2")) && !fs.readdirSync(tmp).some(f => /PWNED/.test(f)), "nothing in the root ran")
  } finally { fs.rmSync(tmp, { recursive: true, force: true }) }
  for (const bad of ["", "root-ok", "root-ok\nroot-ok\n", "ok\n", null, "root-missing \n", "root-inhome", "inhome\n", "root-inhome\nroot-ok\n", "root-unresolved \n"]) assert.strictEqual(model.parseRootCheck(bad), "", String(bad))
  assert.strictEqual(model.parseRootCheck("root-ok\n"), "ok")
  assert.strictEqual(model.parseRootCheck("root-missing\n"), "missing")
  assert.strictEqual(model.parseRootCheck("root-inhome\n"), "inhome")
  assert.strictEqual(model.parseRootCheck("root-unresolved\n"), "unresolved")
  // The status: absent / invalid from the setting; a valid one by its check,
  // and only the check of that path.
  const valid = { state: "valid", path: "/srv/cloud", value: "/srv/cloud" }
  assert.strictEqual(model.rootStatus(null, null), "")
  assert.strictEqual(model.rootStatus({ state: "absent", path: "/mnt/cloud" }, null), "absent")
  assert.strictEqual(model.rootStatus({ state: "invalid", path: "/mnt/cloud" }, { path: "/mnt/cloud", result: "ok" }), "invalid")
  assert.strictEqual(model.rootStatus(valid, null), "")
  assert.strictEqual(model.rootStatus(valid, { path: "/srv/old", result: "ok" }), "")
  assert.strictEqual(model.rootStatus(valid, { path: "/srv/cloud", result: "missing" }), "missing")
  assert.strictEqual(model.rootStatus(valid, { path: "/srv/cloud", result: "ok" }), "ok")
  assert.strictEqual(model.rootStatus(valid, { path: "/srv/cloud", result: "inhome" }), "inhome")
  assert.strictEqual(model.rootStatus(valid, { path: "/srv/cloud", result: "unresolved" }), "unresolved")
  assert.strictEqual(model.rootStatus(valid, { path: "/srv/cloud", result: "bogus" }), "")
})

test("D5 the notice: not installed, mount root not set up, out of date; Set up… while not installed", () => {
  const vNone = { ok: true, plugin: "0.3.5", installedPresent: false, legacy: false, installedVersion: "" }
  const vOk = { ok: true, plugin: "0.3.5", installedPresent: true, legacy: false, installedVersion: "0.3.5" }
  const vOld = { ok: true, plugin: "0.3.5", installedPresent: true, legacy: false, installedVersion: "0.3.4" }
  const absent = { state: "absent", path: "/mnt/cloud", value: "" }
  const invalid = { state: "invalid", path: "/mnt/cloud", value: "~/my\u0007cloud" }
  const valid = { state: "valid", path: "/srv/cloud", value: "/srv/cloud" }
  const NOT_SET = "Mount root not set up: "
  assert.strictEqual(model.setupNotice(vOk, "absent", absent),
    "Mount root not set up: no root chosen yet (the default is /mnt/cloud) — run Set up…")
  assert.strictEqual(model.setupNotice(vOk, "invalid", invalid),
    "Mount root not set up: the setting ~/mycloud in ~/.config/omarchy-cloud/cloud.env is not a valid root — run Set up…")
  assert.strictEqual(model.setupNotice(vOk, "invalid", { state: "invalid", path: "/mnt/cloud", value: "" }),
    "Mount root not set up: the setting (empty) in ~/.config/omarchy-cloud/cloud.env is not a valid root — run Set up…")
  assert.strictEqual(model.setupNotice(vOk, "missing", valid),
    "Mount root not set up: /srv/cloud does not exist or is not writable — run Set up…, or create it once with: sudo install -d -o \"$USER\" -m 755 '/srv/cloud'")
  assert.strictEqual(model.setupNotice(vOk, "inhome", valid),
    "Mount root not set up: /srv/cloud resolves inside your home (through a symbolic link): programs that crawl the home (file search, indexers, backups) would follow it into the cloud drive — run Set up… and choose a real folder outside your home")
  assert.strictEqual(model.setupNotice(vOk, "unresolved", valid),
    "Mount root not set up: /srv/cloud could not be resolved, so it cannot be checked against your home — run Set up…")
  assert.strictEqual(model.installTipLine(model.setupNotice(vOk, "inhome", valid)), "Mount root not set up — open the panel")
  assert.strictEqual(model.setupNotice(vOk, "ok", valid), "")
  assert.strictEqual(model.setupNotice(vOk, "", null), "", "nothing claimed before the scan")
  // Nothing installed comes first; then the root; then the version.
  assert.strictEqual(model.setupNotice(vNone, "absent", absent), model.INSTALL_NOTICE_NONE)
  assert.ok(model.setupNotice(vOld, "missing", valid).startsWith(NOT_SET))
  assert.strictEqual(model.setupNotice(vOld, "ok", valid), "Installed parts are 0.3.4, plugin is 0.3.5 — run install.sh")
  assert.ok(model.setupNotice(model.emptyVersions(), "absent", absent).startsWith(NOT_SET), "the root notice does not wait for the versions")
  // The label: Set up… while nothing is installed or the root is not set up.
  assert.strictEqual(model.SETUP_BUTTON_TEXT, "Set up…")
  assert.strictEqual(model.installButtonText(vNone, ""), "Set up…")
  assert.strictEqual(model.installButtonText(vNone, "ok"), "Set up…")
  for (const st of ["absent", "invalid", "missing", "inhome", "unresolved"]) assert.strictEqual(model.installButtonText(vOk, st), "Set up…", st)
  assert.strictEqual(model.installButtonText(vOld, "ok"), "Update installed parts")
  assert.strictEqual(model.installButtonText(vOld, ""), "Update installed parts")
  // The tooltip (a shell component with no plain-text setting) gets a fixed
  // line, never the root or the raw setting.
  const hostile = { state: "valid", path: "/mnt/<b>x</b>", value: "/mnt/<b>x</b>" }
  assert.ok(model.isValidRoot(hostile.path, "/home/tester"))
  const tip = model.tooltipText([], null, null, true, "", model.setupNotice(vOk, "missing", hostile), false)
  assert.strictEqual(tip, "Omarchy Cloud: No rclone-mount units found\nMount root not set up — open the panel\nClick to manage")
  assert.strictEqual(model.installTipLine(model.setupNotice(vOk, "invalid", { state: "invalid", path: "/mnt/cloud", value: "<img src=x>" })),
    "Mount root not set up — open the panel")
  // The one-time command, as the user's shell reads it: "$USER" expanded
  // there, the path one argument whatever it holds.
  const cp = require("child_process")
  for (const p of ["/srv/cloud", "/mnt/a'b", "/mnt/a b;$(id)`x`"]) {
    const out = cp.spawnSync("bash", ["-c", 'sudo() { printf "%s\\n" "$@"; }; USER=tester; eval "$1"', "_", model.setupCommand(p)], { encoding: "utf8" }).stdout
    assert.strictEqual(out, ["install", "-d", "-o", "tester", "-m", "755", p].join("\n") + "\n", p)
  }
})

test("backups are described as dated copies of important files, never folders", () => {
  const bar = qmlCode("BarWidget.qml")
  assert.strictEqual(model.BACKUPS_BLURB, "Dated copies of important files (single files, not folders)")
  assert.strictEqual(model.NOTHING_SET_UP_TEXT,
    "Nothing set up yet: no mounts, offline folders or backups (dated copies of important files). Configure… below sets them up.")
  assert.strictEqual(model.CONFIGURE_TOOLTIP, "Mounts, offline folders and backups, dated copies of important files (omarchy-cloud)")
  // The section keeps its name, the blurb right under its header.
  assert.ok(/text: "BACKUPS"[\s\S]{0,120}\}\s*Text \{\s*width: parent\.width\s*text: Model\.BACKUPS_BLURB\s*textFormat: Text\.PlainText/.test(bar))
  assert.ok(/\? Model\.NOTHING_SET_UP_TEXT/.test(bar) && /tooltipText: Model\.CONFIGURE_TOOLTIP/.test(bar))
  // No other backup wording in the panel's strings.
  const strings = (bar + model.BACKUPS_BLURB).match(/"[^"\n]*[Bb]ackup[^"\n]*"/g) || []
  assert.deepStrictEqual(strings.filter(x => !/^"(BACKUPS|backups|backup)"$/.test(x)), [], "every backup string is one of the constants")
})

test("D5 the panel: the same button, its label from the model, run only on a click", () => {
  const bar = qmlCode("BarWidget.qml")
  const state = qmlCode("CloudState.qml")
  assert.ok(/readonly property string installNotice: Model\.setupNotice\(CloudState\.versions, CloudState\.rootStatus, CloudState\.rootSetting\)/.test(bar))
  assert.ok(/readonly property string installButtonText: Model\.installButtonText\(CloudState\.versions, CloudState\.rootStatus\)/.test(bar))
  assert.ok(/id: installButton[\s\S]{0,200}text: root\.installButtonText\s*iconText: Model\.ICON\.update\s*tooltipText: "Runs install\.sh from the plugin folder in a terminal"/.test(bar), "label from the model, tooltip kept")
  // install.sh only from the button or the cursor on it, never on its own.
  assert.strictEqual((bar.match(/root\.updateInstalled\(\)/g) || []).length, 2)
  assert.ok(/onClicked: root\.updateInstalled\(\)/.test(bar) && /a\.kind === "install"\) root\.updateInstalled\(\)/.test(bar))
  assert.strictEqual((bar.match(/Model\.installArgv\(/g) || []).length, 1)
  assert.ok(!/installArgv/.test(state))
  // The singleton: the setting from the scan, the root in use, the check.
  assert.ok(/readonly property var rootSetting: root\.scanned \? Model\.rootSetting\(root\.scanData, root\.rootHome\) : null/.test(state))
  // The root rule's home is $HOME normalised, not cleanHome's (which is ""
  // for a HOME with "//" in it and would skip the home rule).
  assert.ok(/readonly property string rootHome: Model\.normaliseHome\(Quickshell\.env\("HOME"\)\)/.test(state))
  assert.ok(/var setting = Model\.rootSetting\(root\.scanData, root\.rootHome\)/.test(state))
  assert.ok(!/Model\.(rootSetting|rootCheckArgv)\([^)]*root\.home\)/.test(state), "no root rule with cleanHome's home")
  assert.ok(/readonly property string mountRoot: Model\.mountRoot\(root\.rootSetting\)/.test(state))
  assert.ok(/readonly property string rootStatus: Model\.rootStatus\(root\.rootSetting, root\.rootCheck\)/.test(state))
  assert.ok(/root\.scanned = true\s*root\.recheckRoot\(\)/.test(state), "checked after each good scan")
  assert.ok(/if \(!setting \|\| setting\.state !== "valid"\) return/.test(state))
  assert.ok(/var argv = Model\.rootCheckArgv\(setting\.path, root\.rootHome\)\s*if \(argv\.length === 0\) return\s*rootProc\.path = setting\.path\s*rootProc\.command = argv/.test(state))
  assert.ok(/if \(rootProc\.running\) \{ root\.rootPending = true; return \}/.test(state))
  // The stop checks use the root in use.
  assert.ok(/Model\.fuserArgv\(row\.name, CloudState\.mountRoot\)/.test(bar))
  assert.ok(/Model\.parseFuser\(text, root\.stopRemote, CloudState\.mountRoot\)/.test(bar))
})

test("D5 the root notice clears on the next poll after Set up or the sudo command", () => {
  // Only a root that is not set up costs a poll anything extra.
  for (const s of ["absent", "invalid", "missing", "inhome", "unresolved"]) assert.strictEqual(model.rootNeedsReread(s), true, s)
  for (const s of ["ok", "", undefined, null]) assert.strictEqual(model.rootNeedsReread(s), false, String(s))
  // The read is SCAN_SCRIPT's own, the path its own argument.
  const argv = model.settingArgv("/home/tester", TOKEN)
  assert.deepStrictEqual(argv, ["timeout", "-k", "2", "10", "sh", "-c", model.SETTING_SCRIPT, "cloud-mounts-setting", TOKEN,
    "/home/tester/.config/omarchy-cloud/cloud.env", "4096"])
  for (const line of model.SETTING_READ_LINES) {
    assert.ok(model.SCAN_SCRIPT.split("\n").includes(line), line)
    assert.ok(model.SETTING_SCRIPT.split("\n").includes(line), line)
  }
  assert.ok(/^t=\$1 e=\$2 r=\$3\n[\s\S]*\nprintf '%s end\\n' "\$t"$/.test(model.SETTING_SCRIPT), model.SETTING_SCRIPT)
  assert.deepStrictEqual(model.settingArgv("", TOKEN), [])
  assert.deepStrictEqual(model.settingArgv("/home/tester", "bad token"), [])
  // Its answer: refused without its end line, over the bound or with another token.
  const ans = (body, tok) => (body === undefined ? "" : TOKEN + " setting " + Buffer.byteLength(body) + "\n" + body + "\n" + TOKEN + " eof\n") + (tok || TOKEN) + " end\n"
  assert.deepStrictEqual(model.parseSettingRead(ans("OMARCHY_CLOUD_ROOT=/srv/c\n"), TOKEN), { ok: true, setting: { found: true, value: "/srv/c" } })
  assert.deepStrictEqual(model.parseSettingRead(ans(undefined), TOKEN), { ok: true, setting: { found: false, value: "" } })
  assert.strictEqual(model.parseSettingRead(ans("OMARCHY_CLOUD_ROOT=/srv/c\n").replace(/[^\n]*end\n$/, ""), TOKEN).ok, false)
  assert.strictEqual(model.parseSettingRead(ans("OMARCHY_CLOUD_ROOT=/srv/c\n", "cmscan-zzzzzzzzzzzz"), TOKEN).ok, false)
  assert.strictEqual(model.parseSettingRead(ans("#".repeat(model.SETTING_MAX_CHARS)), TOKEN).ok, false)
  // withSetting: only over a good scan, the rest of the scan untouched.
  assert.strictEqual(model.withSetting(model.emptyScan(), { found: true, value: "/srv/c" }).setting.found, false)
  // Through a real sh, as the poll runs it: Set up writes cloud.env, the
  // user creates the root; each clears the notice on the next poll.
  const cp = require("child_process")
  const os = require("os")
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "home-"))
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "root-")) + "/cloud"
  const run = a => cp.spawnSync(a[0], a.slice(1), { encoding: "utf8" }).stdout
  const reread = scan => {
    const r = model.parseSettingRead(run(model.settingArgv(home, TOKEN)), TOKEN)
    assert.strictEqual(r.ok, true)
    return model.withSetting(scan, r.setting)
  }
  const status = scan => {
    const setting = model.rootSetting(scan, home)
    const a = setting.state === "valid" ? model.rootCheckArgv(setting.path, home) : []
    return model.rootStatus(setting, { path: setting.path, result: a.length ? model.parseRootCheck(run(a)) : "" })
  }
  try {
    let scan = model.parseScan(TOKEN + " app\n" + TOKEN + " end\n", TOKEN, model.scanDirs(home, home + "/.local/state"))
    scan.pairConfs = { vault: { local: "~/V" } }
    assert.strictEqual(status(scan), "absent")
    assert.ok(model.rootNeedsReread(status(scan)))
    fs.mkdirSync(path.join(home, ".config/omarchy-cloud"), { recursive: true })
    fs.writeFileSync(path.join(home, ".config/omarchy-cloud/cloud.env"), "OMARCHY_CLOUD_ROOT=" + rootDir + "\n")
    scan = reread(scan)
    assert.strictEqual(status(scan), "missing", "Set up wrote the setting: now the root itself")
    assert.deepStrictEqual(scan.pairConfs, { vault: { local: "~/V" } }, "the rest of the scan kept")
    fs.mkdirSync(rootDir)
    scan = reread(scan)
    assert.strictEqual(status(scan), "ok", "the root created: the notice clears")
    assert.strictEqual(model.rootNeedsReread(status(scan)), false, "and the polls go back to their normal cost")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
    fs.rmSync(path.dirname(rootDir), { recursive: true, force: true })
  }
  // The singleton: a poll that starts no scan re-reads the setting while the
  // root is not set up, and the read is followed by the root check.
  const state = qmlCode("CloudState.qml")
  assert.ok(/root\.rescan\(\)\s*\} else if \(Model\.rootNeedsReread\(root\.rootStatus\)\) \{\s*root\.rereadSetting\(\)\s*\}/.test(state), "applyPoll re-reads while not set up")
  assert.ok(/function rereadSetting\(\) \{\s*if \(scan\.running \|\| settingProc\.running\) return\s*var token = Model\.scanToken\(\)\s*var argv = Model\.settingArgv\(root\.home, token\)/.test(state))
  assert.ok(/var parsed = Model\.parseSettingRead\(text, token\)\s*if \(!parsed\.ok\) return\s*var r = Model\.scanWithSettingRead\(root\.scanData, parsed\.setting, seq, root\.settingApplied\)[\s\S]{0,200}root\.recheckRoot\(\)/.test(state))
  assert.ok(/id: settingProc[\s\S]{0,200}onStreamFinished: root\.applySetting\(text, settingProc\.token, settingProc\.seq\)/.test(state))
  assert.strictEqual((state.match(/root\.rereadSetting\(\)/g) || []).length, 1, "only from the poll")
})

test("D5 an older read of the setting never overwrites a newer one (scan and re-read, one counter)", () => {
  const dirs = model.scanDirs("/home/tester", "/home/tester/.local/state")
  const scanOf = (value, extra) => {
    const sc = model.parseScan(settingOutput(Buffer.from("OMARCHY_CLOUD_ROOT=" + value + "\n"), false), TOKEN, dirs)
    assert.ok(sc.ok)
    return Object.assign(sc, extra || {})
  }
  const readOf = value => {
    const r = model.parseSettingRead(settingOutput(Buffer.from("OMARCHY_CLOUD_ROOT=" + value + "\n"), true), TOKEN)
    assert.ok(r.ok)
    return r.setting
  }
  // A small model of the singleton: start() numbers a read when it starts,
  // the answers go through the same two functions applyScan/applySetting call.
  const panel = () => {
    const st = { seq: 0, applied: 0, scan: model.emptyScan() }
    st.start = () => (st.seq = model.nextSettingSeq(st.seq))
    st.scanAnswers = (seq, parsed) => {
      const r = model.scanWithFreshSetting(st.scan, parsed, seq, st.applied)
      st.scan = r.scan; st.applied = r.applied
    }
    st.readAnswers = (seq, setting) => {
      const r = model.scanWithSettingRead(st.scan, setting, seq, st.applied)
      st.scan = r.scan; st.applied = r.applied
    }
    st.value = () => st.scan.setting.value
    return st
  }
  assert.strictEqual(model.nextSettingSeq(0), 1)
  assert.strictEqual(model.nextSettingSeq(41), 42)
  for (const bad of [undefined, null, -3, NaN, "7"]) assert.strictEqual(model.nextSettingSeq(bad), 1, String(bad))

  // Two re-reads: A starts, B starts, B answers, A answers late: A dropped.
  let p = panel()
  p.scanAnswers(p.start(), scanOf("/old"))
  let a = p.start(), b = p.start()
  p.readAnswers(b, readOf("/srv/new"))
  p.readAnswers(a, readOf("/srv/stale"))
  assert.strictEqual(p.value(), "/srv/new", "the later read wins")
  assert.strictEqual(model.rootSetting(p.scan, "/home/tester").path, "/srv/new")
  // In order, each one counts.
  p.readAnswers(p.start(), readOf("/srv/third"))
  assert.strictEqual(p.value(), "/srv/third")

  // A re-read started, then a scan started (the scan does not wait for it);
  // the scan answers first, the re-read late: the scan's setting stays.
  p = panel()
  p.scanAnswers(p.start(), scanOf("/srv/a"))
  a = p.start()
  b = p.start()
  p.scanAnswers(b, scanOf("/srv/b", { more: true }))
  p.readAnswers(a, readOf("/srv/stale"))
  assert.strictEqual(p.value(), "/srv/b", "the newer scan's setting kept")
  assert.strictEqual(p.scan.more, true)

  // A scan older than the last applied re-read: everything else it read is
  // taken, its setting is not.
  p = panel()
  p.scanAnswers(p.start(), scanOf("/srv/a"))
  a = p.start()
  b = p.start()
  p.readAnswers(b, readOf("/srv/new"))
  p.scanAnswers(a, scanOf("/srv/stale", { app: false, more: true }))
  assert.strictEqual(p.value(), "/srv/new", "the stale scan's setting dropped")
  assert.strictEqual(p.scan.more, true, "the rest of the stale scan taken")
  assert.strictEqual(p.scan.app, false)
  assert.strictEqual(p.applied, b)

  // Two scans out of order: the newer one's setting stays.
  p = panel()
  a = p.start(); b = p.start()
  p.scanAnswers(b, scanOf("/srv/new"))
  p.scanAnswers(a, scanOf("/srv/stale"))
  assert.strictEqual(p.value(), "/srv/new")

  // A re-read before any good scan holds nothing and claims no number.
  p = panel()
  p.readAnswers(p.start(), readOf("/srv/early"))
  assert.strictEqual(p.applied, 0)
  assert.strictEqual(p.scan.ok, false)
  p.scanAnswers(p.start(), scanOf("/srv/scan"))
  assert.strictEqual(p.value(), "/srv/scan")

  // The singleton: one counter, numbered at the start of each read, the
  // number carried to the answer.
  const state = qmlCode("CloudState.qml")
  assert.strictEqual((state.match(/root\.settingSeq = Model\.nextSettingSeq\(root\.settingSeq\)/g) || []).length, 2, "both readers share one counter")
  assert.ok(/root\.settingSeq = Model\.nextSettingSeq\(root\.settingSeq\)\s*scan\.seq = root\.settingSeq\s*scan\.command = argv\s*scan\.running = true/.test(state), "the scan numbered when it starts")
  assert.ok(/root\.settingSeq = Model\.nextSettingSeq\(root\.settingSeq\)\s*settingProc\.seq = root\.settingSeq\s*settingProc\.command = argv\s*settingProc\.running = true/.test(state), "the re-read numbered when it starts")
  assert.ok(/var r = Model\.scanWithFreshSetting\(root\.scanData, parsed, seq, root\.settingApplied\)\s*root\.settingApplied = r\.applied\s*var next = r\.scan\s*if \(JSON\.stringify\(next\) !== JSON\.stringify\(root\.scanData\)\) root\.scanData = next/.test(state))
  assert.ok(/root\.settingApplied = r\.applied\s*var next = r\.scan\s*if \(JSON\.stringify\(next\) !== JSON\.stringify\(root\.scanData\)\) root\.scanData = next\s*root\.recheckRoot\(\)/.test(state))
  // Nothing else writes scanData.
  assert.strictEqual((state.match(/root\.scanData = /g) || []).length, 2)
  assert.ok(!/Model\.withSetting\(/.test(state), "only through the guard")
})

// --------------------------------------------------- 0.3.5: bounded processes

test("D8 the poll, du and journal argv start with the timeout and end in a byte cap", () => {
  const T = model.timeoutArgv()
  assert.deepStrictEqual(T, ["timeout", "-k", "2", "10"])
  const cases = [
    [model.pollArgv(["gdrive"], TOKEN), model.showArgv(["gdrive"]), model.SHOW_MAX_CHARS],
    [model.sizesArgv(HOME, ["gdrive"], TOKEN), model.duArgv(HOME, ["gdrive"]), model.DU_MAX_CHARS],
    [model.logArgv("rclone-mount@gdrive.service", TOKEN), model.journalArgv("rclone-mount@gdrive.service"), model.LOG_READ_MAX_BYTES]
  ]
  for (const [argv, inner, cap] of cases) {
    assert.deepStrictEqual(argv.slice(0, 4), T, JSON.stringify(argv))
    assert.deepStrictEqual(argv.slice(4, 10), ["sh", "-c", model.BOUNDED_SCRIPT, "cloud-mounts-bounded", TOKEN, String(cap)])
    assert.deepStrictEqual(argv.slice(10), inner)
  }
  // The pipeline ends in `head -c` at the cap, then the end line.
  assert.deepStrictEqual(model.BOUNDED_SCRIPT.split("\n"), ["t=$1 c=$2", "shift 2", '"$@" 2>/dev/null | head -c "$c"', "printf '\\n%s end\\n' \"$t\""])
  assert.strictEqual(model.LOG_READ_MAX_BYTES, model.LOG_MAX_CHARS * 8)
  // Nothing to run, a bad token or a bad cap: no argv.
  assert.deepStrictEqual(model.sizesArgv(HOME, [], TOKEN), [])
  assert.deepStrictEqual(model.logArgv("sshd.service", TOKEN), [])
  for (const bad of ["", "x", null, TOKEN + " end"]) assert.deepStrictEqual(model.pollArgv(["gdrive"], bad), [], String(bad))
  for (const cap of [0, -1, 1.5, NaN, Infinity, "10"]) assert.deepStrictEqual(model.boundedArgv(["true"], cap, TOKEN), [], String(cap))
  // The widget arms exactly these, and reads the answer against the token.
  const state = qmlCode("CloudState.qml")
  const bar = qmlCode("BarWidget.qml")
  assert.ok(/var argv = Model\.pollArgv\(root\.remotes, token\)[\s\S]{0,80}poll\.token = token\s*poll\.command = argv/.test(state))
  assert.ok(/var argv = Model\.sizesArgv\(root\.home, root\.remotes, token\)[\s\S]{0,120}du\.token = token\s*du\.command = argv/.test(state))
  assert.ok(/var argv = Model\.logArgv\(unit, token\)[\s\S]{0,200}logProc\.token = token\s*logProc\.command = argv/.test(bar))
  assert.ok(/onStreamFinished: root\.applyPoll\(text, poll\.token\)/.test(state))
  assert.ok(/onStreamFinished: root\.applySizes\(text, du\.token\)/.test(state))
  assert.ok(/onStreamFinished: if \(root\.logUnit !== ""\) root\.logText = Model\.logView\(text, logProc\.token\)/.test(bar))
  for (const raw of ["showArgv", "duArgv", "journalArgv", "parseDu(text", "formatLog("])
    assert.ok(!(state + bar).includes("Model." + raw), "an unbounded " + raw + " in the QML")
  // A cut answer keeps the last good state.
  assert.ok(/var answer = Model\.parseBounded\(text, token, Model\.SHOW_MAX_CHARS\)\s*if \(!answer\.ok\) \{\s*root\.pollError = "[^"]+"\s*return\s*\}\s*var parsed = Model\.parseShow\(answer\.text\)/.test(state))
  assert.ok(/var b = Model\.parseBounded\(text, token, Model\.DU_MAX_CHARS\)\s*if \(!b\.ok\) return\s*root\.sizes = /.test(state))
})

test("D8 through a real sh: output capped, a hung command cut, Log timed out", () => {
  const cp = require("child_process")
  // The widget's own argv with the timeout shortened and a stand-in command.
  const run = (inner, cap, secs) => {
    const argv = model.boundedArgv(inner, cap, TOKEN)
    const short = ["timeout", "-k", "1", String(secs)].concat(argv.slice(4))
    const t0 = Date.now()
    const r = cp.spawnSync(short[0], short.slice(1), { encoding: "utf8" })
    return { out: r.stdout, status: r.status, ms: Date.now() - t0 }
  }
  const big = run(["sh", "-c", "yes x | head -c 100000"], 1000, 5)
  const b = model.parseBounded(big.out, TOKEN, 1000)
  assert.ok(b.ok && b.text.length === 1000, "capped at the source: " + b.text.length)
  const fine = run(["printf", "a\\nb\\n"], 1000, 5)
  assert.deepStrictEqual(model.parseBounded(fine.out, TOKEN, 1000), { ok: true, text: "a\nb\n" })
  assert.strictEqual(model.logView(fine.out, TOKEN), "a\nb")
  // Hung after some output: killed with its group, no end line, refused.
  const hung = run(["sh", "-c", "echo partial; exec sleep 30"], 1000, 1)
  assert.ok(hung.ms < 5000, "cut by the timeout: " + hung.ms + " ms")
  assert.strictEqual(hung.status, 124)
  assert.deepStrictEqual(model.parseBounded(hung.out, TOKEN, 1000), { ok: false, text: "" })
  assert.strictEqual(model.logView(hung.out, TOKEN), "Log timed out")
  assert.strictEqual(model.LOG_TIMED_OUT, "Log timed out")
  // Another token's end line, or an end line inside the output, is not this run's.
  assert.strictEqual(model.parseBounded("x\ncmscan-zzzzzzzzzzzz end\n", TOKEN, 1000).ok, false)
  assert.strictEqual(model.parseBounded("\n" + TOKEN + " end\ncut", TOKEN, 1000).ok, false)
  assert.strictEqual(model.parseBounded("x".repeat(1001) + "\n" + TOKEN + " end\n", TOKEN, 1000).ok, false, "over the cap")
  // An empty journal still reads as such, not as timed out.
  assert.strictEqual(model.logView("\n" + TOKEN + " end\n", TOKEN), "(no journal entries)")
})

// ---------------------------------------------------- 0.3.5: HOME-fixed paths

test("D6 paths are HOME-fixed: XDG variables set elsewhere change nothing", () => {
  const saved = {}
  for (const k of ["XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"]) { saved[k] = process.env[k]; process.env[k] = "/elsewhere/" + k }
  try {
    const m = new Function(source + "\nreturn {" + NAMES.join(",") + "}")()
    const st = m.stateHome("/home/tester", process.env.XDG_STATE_HOME)
    assert.strictEqual(st, "/home/tester/.local/state")
    assert.deepStrictEqual(m.scanDirs("/home/tester", st), {
      bisyncConf: "/home/tester/.config/rclone-bisync", backupConf: "/home/tester/.config/rclone-backup",
      bisyncState: "/home/tester/.local/state/rclone-bisync", backupState: "/home/tester/.local/state/rclone-backup",
      setting: "/home/tester/.config/omarchy-cloud/cloud.env" })
    assert.strictEqual(m.envDir("/home/tester"), "/home/tester/.config/rclone-mount")
    assert.strictEqual(m.cacheDir("/home/tester", "gdrive"), "/home/tester/.cache/rclone/vfs/gdrive")
    assert.strictEqual(m.rootSettingPath("/home/tester"), "/home/tester/.config/omarchy-cloud/cloud.env")
    assert.deepStrictEqual(m.versionsArgv("/opt/cloud", st, TOKEN).slice(12, 14),
      ["/home/tester/.local/state/omarchy-cloud/installed-files", "/home/tester/.local/state/omarchy-cloud/installed-binary.sha256"])
  } finally {
    for (const k of Object.keys(saved)) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k] }
  }
  // No code reads an XDG variable: not the model, not the QML.
  assert.ok(!/XDG_/.test(source.replace(/\/\/.*$/gm, "")), "Model.js code names an XDG variable")
  for (const file of qmlFiles) assert.ok(!/XDG_|Quickshell\.env\("(?!HOME")/.test(qmlCode(file)), file + " reads an XDG variable")
  assert.ok(/readonly property string stateDir: Model\.stateHome\(root\.home\)\n/.test(qmlCode("CloudState.qml")))
})

let failed = 0
for (const [name, fn] of tests) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (e) {
    failed++
    console.log("FAIL " + name + "\n     " + String(e && e.message || e).split("\n").join("\n     "))
  }
}
console.log((tests.length - failed) + "/" + tests.length + " passed")
process.exit(failed ? 1 : 0)
