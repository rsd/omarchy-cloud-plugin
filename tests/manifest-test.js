#!/usr/bin/env node

// Checks the plugin folder as a whole: the manifest, the entry points, the
// relative imports between its files, the folder name against the id, and
// that nothing in it is a symlink. `omarchy plugin validate` covers the schema;
// this covers what is specific to Cloud Mounts.

const fs = require("fs")
const os = require("os")
const path = require("path")
const assert = require("assert")

const pluginDir = path.resolve(path.join(__dirname, ".."))
const manifest = JSON.parse(fs.readFileSync(path.join(pluginDir, "manifest.json"), "utf8"))
const qmlFiles = fs.readdirSync(pluginDir).filter(f => f.endsWith(".qml"))
const isFile = p => { try { return fs.statSync(p).isFile() } catch (e) { return false } }

const SKIP = Symbol("skip")
const tests = []
const test = (name, fn) => tests.push([name, fn])

test("manifest identity", () => {
  assert.strictEqual(manifest.schemaVersion, 1)
  assert.strictEqual(manifest.id, "io.github.rsd.cloud-mounts")
  assert.strictEqual(manifest.name, "Cloud Mounts")
  assert.strictEqual(manifest.version, "0.3.3")
  assert.strictEqual(manifest.author, "Raul Dias")
  assert.strictEqual(manifest.license, "MIT")
  assert.ok(manifest.description)
  assert.ok(!manifest.id.startsWith("omarchy."), "omarchy.* is reserved")
  // The descriptions name what the panel shows, not one machine's instances.
  for (const d of [manifest.description, manifest.barWidget.description]) {
    assert.ok(/offline folders?/.test(d) && /backups?/.test(d), d)
    assert.ok(!/KeePass|vault-A/i.test(d), d)
  }
})

// The shell loads a plugin from whatever folder its manifest sits in, but
// `omarchy plugin remove/enable` find it as ~/.config/omarchy/plugins/<id>, so
// the installed folder (or symlink) must be named by the id. This checkout's
// own folder need not be: it is linked in under the id. So: a checkout named
// by the id passes; otherwise the install path is checked if it exists (it
// must lead to this checkout), and when it does not the check is skipped.
// Read-only: lstat and realpath, nothing is created.
test("the installed folder is named by the manifest id", () => {
  if (path.basename(pluginDir) === manifest.id) return
  const installed = path.join(os.homedir(), ".config", "omarchy", "plugins", manifest.id)
  let real
  try { real = fs.realpathSync(installed) } catch (e) {
    console.log("skip the installed folder is named by the manifest id: this checkout is '" + path.basename(pluginDir)
      + "', not the id, and " + installed + " does not exist; link it there under the id (README, Dev workflow)")
    return SKIP
  }
  if (real !== fs.realpathSync(pluginDir)) {
    console.log("skip the installed folder is named by the manifest id: " + installed + " is another copy (" + real + "), not this checkout")
    return SKIP
  }
})

// The release workflow refuses a tag whose version differs from either; the
// prebuilt binary is only installed when its BUILD-INFO version is Cargo's.
test("the manifest version is the app's (app/Cargo.toml)", () => {
  const toml = fs.readFileSync(path.join(pluginDir, "app", "Cargo.toml"), "utf8")
  const pkg = toml.split(/^\[/m).find(s => s.startsWith("package]"))
  const m = pkg && pkg.match(/^version\s*=\s*"([^"]+)"/m)
  assert.ok(m, "no [package] version in app/Cargo.toml")
  assert.strictEqual(m[1], manifest.version)
})

test("manifest declares a single bar widget on the right", () => {
  assert.deepStrictEqual(manifest.kinds, ["bar-widget"])
  assert.strictEqual(manifest.barWidget.defaultSection, "right")
  assert.strictEqual(manifest.barWidget.allowMultiple, false)
  assert.strictEqual(manifest.barWidget.displayName, "Cloud Mounts")
  assert.strictEqual(manifest.barWidget.category, "Files")
})

test("entry points are safe relative paths and exist", () => {
  assert.deepStrictEqual(Object.keys(manifest.entryPoints), ["barWidget"])
  for (const rel of Object.values(manifest.entryPoints)) {
    assert.ok(!rel.startsWith("/") && !rel.includes(".."), rel)
    assert.ok(isFile(path.join(pluginDir, rel)), rel)
  }
})

test("the repository root is the plugin: manifest, licence and qmldir sit there", () => {
  for (const f of ["manifest.json", "LICENSE", "README.md", "qmldir", "Model.js", "BarWidget.qml", "CloudState.qml"])
    assert.ok(isFile(path.join(pluginDir, f)), f)
})

test("relative QML imports resolve inside the plugin", () => {
  for (const file of qmlFiles) {
    const text = fs.readFileSync(path.join(pluginDir, file), "utf8")
    for (const m of text.matchAll(/^import\s+"([^"]+)"/gm)) {
      const target = path.resolve(pluginDir, m[1])
      assert.ok(target.startsWith(pluginDir + path.sep), file + " imports outside the plugin: " + m[1])
      assert.ok(isFile(target), file + " imports missing " + m[1])
    }
  }
})

test("no symlinks inside the plugin", () => {
  const found = []
  const walk = dir => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === ".git") continue
      const full = path.join(dir, entry.name)
      if (entry.isSymbolicLink()) found.push(full)
      else if (entry.isDirectory()) walk(full)
    }
  }
  walk(pluginDir)
  assert.deepStrictEqual(found, [])
})

let failed = 0
let skipped = 0
for (const [name, fn] of tests) {
  try {
    if (fn() === SKIP) { skipped++; continue }
    console.log("ok   " + name)
  } catch (e) {
    failed++
    console.log("FAIL " + name + "\n     " + String(e && e.message || e).split("\n").join("\n     "))
  }
}
const ran = tests.length - skipped
if (skipped) console.log(skipped + " skipped")
console.log((ran - failed) + "/" + ran + " passed")
process.exit(failed ? 1 : 0)
