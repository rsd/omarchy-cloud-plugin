#!/usr/bin/env node

// The busy check against the real fuser, read the way the widget reads it:
// Model.fuserPathArgv run as is (timeout, sh, FUSER_SCRIPT), stdout only, fed
// to Model.parseFuserAt. A `sleep` this test starts holds its cwd on /dev/shm
// (a tmpfs mount point every session has), so the mount is busy; the check
// must say so. A directory that is not a mount point must read as "could not
// check". Nothing else is touched: the only process stopped is that sleep, by
// the handle this test holds. Exits 77 (skipped) without fuser, timeout or a
// /dev/shm mount point.

const fs = require("fs")
const os = require("os")
const path = require("path")
const assert = require("assert")
const { spawn, spawnSync } = require("child_process")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const model = new Function(source + "\nreturn { fuserPathArgv, parseFuserAt, stopDecision }")()

const MOUNT = "/dev/shm"
const have = (cmd) => spawnSync("sh", ["-c", "command -v \"$1\"", "x", cmd]).status === 0
if (!have("fuser") || !have("timeout") || !have("mountpoint")) {
  console.log("skipped: need fuser (psmisc), timeout and mountpoint")
  process.exit(77)
}
if (spawnSync("mountpoint", ["-q", MOUNT]).status !== 0) {
  console.log("skipped: " + MOUNT + " is not a mount point here")
  process.exit(77)
}

// Like the widget: one argv, stdout collected, stderr not read.
function check(dir) {
  const argv = model.fuserPathArgv(dir)
  assert.ok(argv.length > 0, "no argv for " + dir)
  const r = spawnSync(argv[0], argv.slice(1), { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 20000 })
  return model.parseFuserAt(r.stdout, dir)
}

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) {
    failed++
    console.log("FAIL " + name + "\n     " + String(e && e.message || e).split("\n").join("\n     "))
  }
}

const holder = spawn("sleep", ["30"], { cwd: MOUNT, stdio: "ignore" })
try {
  test("a mount with a process in it reads as busy (stdout only, as the widget reads it)", () => {
    const b = check(MOUNT)
    assert.strictEqual(b.known, true, JSON.stringify(b))
    assert.ok(b.total >= 1, JSON.stringify(b))
    assert.strictEqual(model.stopDecision(b, 0), "confirm")
  })
  test("a directory that is not a mount point could not be checked", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cloud-mounts-fuser-"))
    try {
      const b = check(dir)
      assert.strictEqual(b.known, false, JSON.stringify(b))
      assert.strictEqual(model.stopDecision(b, 0), "confirm")
    } finally {
      fs.rmdirSync(dir)
    }
  })
} finally {
  holder.kill()
}

console.log(failed ? failed + " failed" : "passed all live fuser tests")
process.exit(failed ? 1 : 0)
