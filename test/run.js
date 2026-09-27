// node test/run.js <scan.json>  — loads Keybinds.js outside QML and checks the
// round-trip: every editable binding re-renders to the text it was read from
// or to an equivalent call.
const fs = require("fs"), path = require("path"), vm = require("vm")
const src = fs.readFileSync(path.join(__dirname, "..", "Keybinds.js"), "utf8").replace(/^\.pragma library\s*/, "")
const K = {}; vm.createContext(K); vm.runInContext(src, K)
const rawScan = fs.readFileSync(process.argv[2], "utf8")
const scan = JSON.parse(rawScan.slice(rawScan.lastIndexOf("@@KEYSMITH-SCAN@@\n") + "@@KEYSMITH-SCAN@@\n".length))
const m = K.buildModel(scan, "/usr/share/omarchy", process.env.HOME)
let fail = 0
const ok = (c, msg) => { if (!c) { fail++; console.log("FAIL", msg) } }
console.log("mine:", m.mine.length, "defaults:", m.defaults.length, "all:", m.all.length)
for (const r of m.mine) {
  console.log((r.editable ? "E" : r.removable ? "R" : "-"), r.kind.padEnd(7), r.keys.padEnd(28), "|", r.desc, "|", r.summary,
    r.replaces.length ? "| replaces " + r.replaces.join(", ") : "", r.owner ? "| owner " + r.owner : "", r.lockedReason ? "| " + r.lockedReason : "")
  if (r.editable) {
    const lua = K.renderBind(r.binding)
    console.log("    ", lua)
    ok(K.validate(r.binding) === "", "validate " + r.keys + ": " + K.validate(r.binding))
  }
}
// combos
ok(K.comboId("SUPER + code:10") === K.comboId("super + 1"), "code alias")
ok(K.formatCombo(["ALT", "SUPER"], "x") === "SUPER + ALT + x", "format order")
ok(JSON.stringify(K.parseCombo("SUPER SHIFT + RETURN")) === JSON.stringify({ mods: ["SUPER", "SHIFT"], key: "RETURN" }), "space mods")
ok(K.shellUnquote(K.shellQuote("it's \"x\"")) === "it's \"x\"", "shell quote")
// every type renders something valid and parses back to itself
const cases = [
  { type: "app", appId: "firefox" }, { type: "app", appId: "org.gnome.Nautilus", focus: true },
  { type: "webapp", url: "https://x.y/z" }, { type: "webapp", url: "https://x.y", focus: true },
  { type: "open", target: "/home/me/My Docs" }, { type: "command", cmd: "notify-send hi" },
  { type: "command", cmd: "btop", mode: "terminal" }, { type: "command", cmd: "code", mode: "launch" },
  { type: "type", text: "it's me@x.com", delay: 300 }, { type: "window", preset: "move", param: "4" },
  { type: "window", preset: "close" }, { type: "media", preset: "vol-up" }, { type: "capture", preset: "screenshot" },
  { type: "system", preset: "lock" }, { type: "plugin", pluginId: "zzwong.stage" }, { type: "plugin", pluginId: "mirador", payload: "{}" },
  { type: "menu", menu: "" }, { type: "menu", menu: "theme" }, { type: "toggle", toggle: "idle" }, { type: "nothing" },
  { type: "lua", expr: 'hl.dsp.window.pin()' }
]
for (const c of cases) {
  const spec = Object.assign(K.emptySpec(c.type), c)
  const d = K.renderDispatcher(spec)
  // evaluate the rendered dispatcher the way scan.lua would see it
  let back
  if (d.startsWith('"')) back = K.specFromDispatcher(JSON.parse(d))
  else if (d.startsWith("{")) back = K.specFromDispatcher(Function("return " + d.replace(/(\w+) = /g, '"$1": '))())
  else back = K.specFromDispatcher({ __dsp: true, kind: "lua", expr: d })
  const keys = Object.keys(c).filter(k => k !== "type")
  const same = back.type === c.type && keys.every(k => String(back[k]) === String(c[k]))
  ok(same, "round trip " + JSON.stringify(c) + " -> " + d + " -> " + JSON.stringify(back))
}
// deletion keeps shared comments
const lines = ["-- A", "o.bind(1)", "", "-- shared", "o.bind(2)", "o.bind(3)", "", "-- M", "o.bind(4)", "-- M"]
ok(JSON.stringify(K.applyOps(lines, K.deletionOps(lines, [{ start: 2, stop: 2 }]))) === JSON.stringify(["-- shared", "o.bind(2)", "o.bind(3)", "", "-- M", "o.bind(4)", "-- M"]), "delete with own comment")
ok(JSON.stringify(K.applyOps(lines, K.deletionOps(lines, [{ start: 5, stop: 5 }]))) === JSON.stringify(["-- A", "o.bind(1)", "", "-- shared", "o.bind(3)", "", "-- M", "o.bind(4)", "-- M"]), "delete keeps shared comment")
ok(JSON.stringify(K.applyOps(lines, K.deletionOps(lines, [{ start: 9, stop: 9 }]))) === JSON.stringify(["-- A", "o.bind(1)", "", "-- shared", "o.bind(2)", "o.bind(3)"]), "delete bracketed comment")
ok(K.keyLabel("code:191") === "F13" && K.keyLabel("code:202") === "F24", "F13-F24 labels")
console.log(fail ? fail + " failures" : "all passed")
process.exit(fail ? 1 : 0)
