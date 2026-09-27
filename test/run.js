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
// macros: recorded events -> steps keep total timing; render -> parse round trip
{
  const ev = [{ kind: "down", key: "ctrl", t: 0 }, { kind: "down", key: "s", t: 120 }, { kind: "up", key: "s", t: 190 },
              { kind: "up", key: "ctrl", t: 250 }, { kind: "down", key: "a", t: 600 }, { kind: "up", key: "a", t: 680 },
              { kind: "down", key: "shift", t: 700 }]
  const steps = K.stepsFromEvents(ev)
  ok(steps.map(s => s.kind + ":" + s.key + ":" + s.delay).join(" ") === "down:ctrl:0 tap:s:120 up:ctrl:130 tap:a:350 down:shift:100 up:shift:0", "macro steps " + JSON.stringify(steps))
  const spec = Object.assign(K.emptySpec("macro"), { steps, start: 300, repeat: 3 })
  const back = K.specFromCommand(K.renderMacroCommand(spec))
  ok(back.type === "macro" && back.start === 300 && back.repeat === 3 && JSON.stringify(back.steps) === JSON.stringify(steps), "macro round trip")
  const text = Object.assign(K.emptySpec("macro"), { steps: [{ kind: "text", key: "", text: "it's -- ok", delay: 0 }, { kind: "tap", key: "Return", text: "", delay: 40 }] })
  const tb = K.specFromCommand(K.renderMacroCommand(text))
  ok(tb.type === "macro" && tb.steps[0].text === "it's -- ok" && tb.steps[1].key === "Return", "macro text round trip")
  ok(K.specFromCommand("wtype -s 300 -- 'hi'").type === "type", "type text still type")
  ok(K.specFromCommand("wtype x; rm -rf ~").type === "command", "shell metachar not a macro")
  ok(K.validate({ keys: "SUPER + F9", spec: Object.assign(K.emptySpec("macro"), { steps: [] }) }) !== "", "empty macro invalid")
  ok(K.validate({ keys: "SUPER + F9", spec: spec }) === "", "macro valid")
}
ok(K.keyLabel("code:191") === "F13" && K.keyLabel("code:202") === "F24", "F13-F24 labels")
console.log(fail ? fail + " failures" : "all passed")
process.exit(fail ? 1 : 0)
