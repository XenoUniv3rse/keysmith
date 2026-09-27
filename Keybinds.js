.pragma library

// Pure model for the Keysmith panel: key combos, action types, reading a
// scanned binding back into an editable spec, and rendering a spec as the Lua
// that goes into ~/.config/hypr/bindings.lua. No QML in here, so it can be
// exercised from node (see test/run.js).

// ------------------------------------------------------------------ keys

var MODIFIERS = ["SUPER", "SHIFT", "CTRL", "ALT"]

var MOD_ALIASES = {
  SUPER: "SUPER", WIN: "SUPER", LOGO: "SUPER", META: "SUPER", MOD4: "SUPER", MOD: "SUPER",
  SHIFT: "SHIFT",
  CTRL: "CTRL", CONTROL: "CTRL",
  ALT: "ALT", MOD1: "ALT"
}

// xkb keycodes Omarchy binds with "code:N" so they survive layout changes.
var CODE_NAMES = {
  "10": "1", "11": "2", "12": "3", "13": "4", "14": "5", "15": "6", "16": "7", "17": "8", "18": "9", "19": "0",
  "20": "minus", "21": "equal", "34": "bracketleft", "35": "bracketright", "47": "semicolon",
  "48": "apostrophe", "49": "grave", "51": "backslash", "59": "comma", "60": "period", "61": "slash",
  "201": "Copilot"
}

function keyOption(value, label, group) { return { value: value, label: label, description: group } }

var KEY_OPTIONS = (function() {
  var out = []
  var i
  for (i = 0; i < 26; i++) {
    var c = String.fromCharCode(65 + i)
    out.push(keyOption(c, c, "Letter"))
  }
  for (i = 1; i <= 10; i++) {
    var d = String(i % 10)
    out.push(keyOption(d, d, "Number"))
  }
  for (i = 1; i <= 24; i++) out.push(keyOption("F" + i, "F" + i, "Function key"))
  var named = [
    ["RETURN", "Enter"], ["SPACE", "Space"], ["TAB", "Tab"], ["ESCAPE", "Escape"],
    ["BACKSPACE", "Backspace"], ["Delete", "Delete"], ["Insert", "Insert"],
    ["Home", "Home"], ["End", "End"], ["Prior", "Page Up"], ["Next", "Page Down"],
    ["LEFT", "← Left"], ["RIGHT", "→ Right"], ["UP", "↑ Up"], ["DOWN", "↓ Down"],
    ["PRINT", "Print Screen"], ["Pause", "Pause"], ["Scroll_Lock", "Scroll Lock"], ["Menu", "Menu"]
  ]
  for (i = 0; i < named.length; i++) out.push(keyOption(named[i][0], named[i][1], "Navigation & editing"))
  var punct = [
    ["comma", ", comma"], ["period", ". period"], ["slash", "/ slash"], ["backslash", "\\ backslash"],
    ["semicolon", "; semicolon"], ["apostrophe", "' apostrophe"], ["grave", "` grave"],
    ["minus", "- minus"], ["equal", "= equal"], ["bracketleft", "[ left bracket"], ["bracketright", "] right bracket"]
  ]
  for (i = 0; i < punct.length; i++) out.push(keyOption(punct[i][0], punct[i][1], "Punctuation"))
  var media = [
    ["XF86AudioRaiseVolume", "Volume up"], ["XF86AudioLowerVolume", "Volume down"], ["XF86AudioMute", "Mute"],
    ["XF86AudioMicMute", "Mic mute"], ["XF86AudioPlay", "Play"], ["XF86AudioPause", "Pause"],
    ["XF86AudioNext", "Next track"], ["XF86AudioPrev", "Previous track"], ["XF86AudioStop", "Stop"],
    ["XF86MonBrightnessUp", "Brightness up"], ["XF86MonBrightnessDown", "Brightness down"],
    ["XF86Calculator", "Calculator"], ["XF86Mail", "Mail"], ["XF86HomePage", "Home page"],
    ["XF86Search", "Search"], ["XF86Explorer", "Explorer"], ["XF86Tools", "Tools"],
    ["XF86Launch1", "Launch 1"], ["XF86Launch2", "Launch 2"], ["XF86PowerOff", "Power"]
  ]
  for (i = 0; i < media.length; i++) out.push(keyOption(media[i][0], media[i][1], "Media & special"))
  var pad = ["KP_0", "KP_1", "KP_2", "KP_3", "KP_4", "KP_5", "KP_6", "KP_7", "KP_8", "KP_9",
             "KP_Add", "KP_Subtract", "KP_Multiply", "KP_Divide", "KP_Enter", "KP_Decimal"]
  for (i = 0; i < pad.length; i++) out.push(keyOption(pad[i], "Keypad " + pad[i].slice(3), "Keypad"))
  return out
})()

var KEY_LABELS = (function() {
  var m = {}
  for (var i = 0; i < KEY_OPTIONS.length; i++) m[KEY_OPTIONS[i].value.toLowerCase()] = KEY_OPTIONS[i]
  return m
})()

function trim(s) { return String(s === undefined || s === null ? "" : s).replace(/^\s+|\s+$/g, "") }

// "SUPER + SHIFT + x" -> { mods: ["SUPER","SHIFT"], key: "X" }
function parseCombo(text) {
  var parts = String(text || "").split("+")
  var mods = []
  var key = ""
  for (var i = 0; i < parts.length; i++) {
    var p = trim(parts[i])
    if (p === "") {
      // "SUPER + +" style: a literal plus
      if (i === parts.length - 1 && parts.length > 1 && key === "") key = "plus"
      continue
    }
    // Hyprland also accepts space separated modifiers ("SUPER SHIFT")
    var words = p.split(/\s+/)
    for (var w = 0; w < words.length; w++) {
      var alias = MOD_ALIASES[words[w].toUpperCase()]
      if (alias && (w < words.length - 1 || i < parts.length - 1)) {
        if (mods.indexOf(alias) === -1) mods.push(alias)
      } else if (alias && key === "" && i === parts.length - 1 && words.length === 1 && parts.length === 1) {
        key = words[w]  // a bare modifier as the key itself ("SUPER_L")
      } else {
        key = words.slice(w).join(" ")
        break
      }
    }
  }
  var ordered = []
  for (var m = 0; m < MODIFIERS.length; m++) if (mods.indexOf(MODIFIERS[m]) !== -1) ordered.push(MODIFIERS[m])
  if (/^[a-z]$/.test(key)) key = key.toUpperCase()
  return { mods: ordered, key: key }
}

function formatCombo(mods, key) {
  var parts = []
  for (var m = 0; m < MODIFIERS.length; m++) if ((mods || []).indexOf(MODIFIERS[m]) !== -1) parts.push(MODIFIERS[m])
  if (key) parts.push(key)
  return parts.join(" + ")
}

function canonicalKey(key) {
  var k = String(key || "")
  var code = k.match(/^code:(\d+)$/)
  if (code && CODE_NAMES[code[1]]) k = CODE_NAMES[code[1]]
  return k.toLowerCase()
}

// Identity used to decide whether two binds share a key. Case-insensitive on
// purpose: flagging a near-miss as a conflict beats missing a real one.
function comboId(text) {
  var c = parseCombo(text)
  return c.mods.join("+") + "|" + canonicalKey(c.key)
}

function keyLabel(key) {
  var k = String(key || "")
  var code = k.match(/^code:(\d+)$/)
  if (code) return CODE_NAMES[code[1]] ? keyLabel(CODE_NAMES[code[1]]) : k
  var known = KEY_LABELS[k.toLowerCase()]
  if (known) {
    var sym = { comma: ",", period: ".", slash: "/", backslash: "\\", semicolon: ";", apostrophe: "'",
                grave: "`", minus: "-", equal: "=", bracketleft: "[", bracketright: "]" }[k.toLowerCase()]
    if (sym) return sym
    var arrow = { left: "←", right: "→", up: "↑", down: "↓" }[k.toLowerCase()]
    return arrow || known.label
  }
  if (k.indexOf("XF86") === 0) return k.slice(4)
  if (k.indexOf("mouse:") === 0) return { "272": "Left click", "273": "Right click", "274": "Middle click" }[k.slice(6)] || k
  return k
}

// Pieces to draw as keycaps.
function comboCaps(text) {
  var c = parseCombo(text)
  var caps = []
  for (var i = 0; i < c.mods.length; i++) caps.push(c.mods[i] === "SUPER" ? "Super" : c.mods[i].charAt(0) + c.mods[i].slice(1).toLowerCase())
  if (c.key) caps.push(keyLabel(c.key))
  return caps
}

// Qt key event -> xkb key name for a recorded shortcut. `scanCode` is the
// native scan code, which on Wayland is the xkb keycode.
function keyFromEvent(qtKey, text, scanCode) {
  var byCode = { 10: "1", 11: "2", 12: "3", 13: "4", 14: "5", 15: "6", 16: "7", 17: "8", 18: "9", 19: "0",
                 20: "minus", 21: "equal", 34: "bracketleft", 35: "bracketright", 47: "semicolon",
                 48: "apostrophe", 49: "grave", 51: "backslash", 59: "comma", 60: "period", 61: "slash" }
  if (byCode[scanCode]) return byCode[scanCode]
  if (qtKey >= 0x41 && qtKey <= 0x5a) return String.fromCharCode(qtKey)
  if (qtKey >= 0x01000030 && qtKey <= 0x01000047) return "F" + (qtKey - 0x01000030 + 1)
  var named = {
    0x01000004: "RETURN", 0x01000005: "KP_Enter", 0x20: "SPACE", 0x01000001: "TAB", 0x01000002: "TAB",
    0x01000000: "ESCAPE", 0x01000003: "BACKSPACE", 0x01000007: "Delete", 0x01000006: "Insert",
    0x01000010: "Home", 0x01000011: "End", 0x01000016: "Prior", 0x01000017: "Next",
    0x01000012: "LEFT", 0x01000014: "RIGHT", 0x01000013: "UP", 0x01000015: "DOWN",
    0x01000009: "PRINT", 0x01000008: "Pause", 0x01000026: "Scroll_Lock", 0x01000055: "Menu",
    0x01000070: "XF86AudioRaiseVolume", 0x01000072: "XF86AudioLowerVolume", 0x01000071: "XF86AudioMute",
    0x01000080: "XF86AudioPlay", 0x01000085: "XF86AudioPause", 0x01000083: "XF86AudioNext",
    0x01000082: "XF86AudioPrev", 0x01000081: "XF86AudioStop", 0x010000b2: "XF86MonBrightnessUp",
    0x010000b3: "XF86MonBrightnessDown", 0x010000cb: "XF86Calculator", 0x010000a0: "XF86Mail",
    0x01000090: "XF86HomePage", 0x01000092: "XF86Search", 0x010000a2: "XF86Launch1", 0x010000a3: "XF86Launch2",
    0x0100010c: "XF86AudioMicMute"
  }
  if (named[qtKey]) return named[qtKey]
  if (scanCode > 8) return "code:" + scanCode
  return ""
}

function isModifierKey(qtKey) {
  // Shift, Control, Meta, Alt, AltGr, Super_L/R, Hyper
  return [0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01001103, 0x01000053, 0x01000054, 0x01000056, 0x01000057].indexOf(qtKey) !== -1
}

// ---------------------------------------------------------------- quoting

function luaString(s) {
  return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t") + '"'
}

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

// Undo shellQuote for a string made only of '...' runs and \' escapes.
// Returns null when the text is anything else.
function shellUnquote(s) {
  var t = String(s)
  var out = ""
  var i = 0
  if (t === "") return null
  while (i < t.length) {
    if (t.charAt(i) === "'") {
      var end = t.indexOf("'", i + 1)
      if (end === -1) return null
      out += t.slice(i + 1, end)
      i = end + 1
    } else if (t.slice(i, i + 2) === "\\'") {
      out += "'"
      i += 2
    } else return null
  }
  return out
}

// A shell word: quoted, or bare with no spaces or metacharacters.
function shellWord(s) {
  var t = String(s)
  var q = shellUnquote(t)
  if (q !== null) return q
  if (/^[A-Za-z0-9_@%+=:,.\/-]+$/.test(t)) return t
  return null
}

function luaLiteral(v) {
  if (v === null || v === undefined) return "nil"
  if (typeof v === "string") return luaString(v)
  if (typeof v === "number" || typeof v === "boolean") return String(v)
  if (Array.isArray(v)) return "{ " + v.map(luaLiteral).join(", ") + " }"
  if (typeof v === "object") {
    var keys = Object.keys(v)
    if (keys.length === 0) return "{}"
    return "{ " + keys.map(function(k) {
      return (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "[" + luaString(k) + "]") + " = " + luaLiteral(v[k])
    }).join(", ") + " }"
  }
  return "nil"
}

// --------------------------------------------------------------- presets

var WINDOW_ACTIONS = [
  { value: "close", label: "Close window", expr: "hl.dsp.window.close()" },
  { value: "fullscreen", label: "Full screen", expr: 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' },
  { value: "maximize", label: "Full width (maximize)", expr: 'hl.dsp.window.fullscreen({ mode = "maximized" })' },
  { value: "float", label: "Toggle floating / tiling", expr: 'hl.dsp.window.float({ action = "toggle" })' },
  { value: "pseudo", label: "Pseudo-tile window", expr: "hl.dsp.window.pseudo()" },
  { value: "split", label: "Toggle split direction", expr: 'hl.dsp.layout("togglesplit")' },
  { value: "focus-l", label: "Focus window to the left", expr: 'hl.dsp.focus({ direction = "l" })' },
  { value: "focus-r", label: "Focus window to the right", expr: 'hl.dsp.focus({ direction = "r" })' },
  { value: "focus-u", label: "Focus window above", expr: 'hl.dsp.focus({ direction = "u" })' },
  { value: "focus-d", label: "Focus window below", expr: 'hl.dsp.focus({ direction = "d" })' },
  { value: "swap-l", label: "Swap window left", expr: 'hl.dsp.window.swap({ direction = "l" })' },
  { value: "swap-r", label: "Swap window right", expr: 'hl.dsp.window.swap({ direction = "r" })' },
  { value: "swap-u", label: "Swap window up", expr: 'hl.dsp.window.swap({ direction = "u" })' },
  { value: "swap-d", label: "Swap window down", expr: 'hl.dsp.window.swap({ direction = "d" })' },
  { value: "cycle", label: "Focus next window", expr: "hl.dsp.window.cycle_next()" },
  { value: "cycle-prev", label: "Focus previous window", expr: "hl.dsp.window.cycle_next({ next = false })" },
  { value: "workspace", label: "Switch to workspace…", expr: 'hl.dsp.focus({ workspace = "%s" })', param: "Workspace" },
  { value: "move", label: "Move window to workspace…", expr: 'hl.dsp.window.move({ workspace = "%s" })', param: "Workspace" },
  { value: "move-silent", label: "Move window silently to workspace…", expr: 'hl.dsp.window.move({ follow = false, workspace = "%s" })', param: "Workspace" },
  { value: "ws-next", label: "Next workspace", expr: 'hl.dsp.focus({ workspace = "e+1" })' },
  { value: "ws-prev", label: "Previous workspace", expr: 'hl.dsp.focus({ workspace = "e-1" })' },
  { value: "ws-last", label: "Last used workspace", expr: 'hl.dsp.focus({ workspace = "previous" })' },
  { value: "scratchpad", label: "Toggle scratchpad", expr: 'hl.dsp.workspace.toggle_special("scratchpad")' },
  { value: "to-scratchpad", label: "Move window to scratchpad", expr: 'hl.dsp.window.move({ follow = false, workspace = "special:scratchpad" })' },
  { value: "monitor-next", label: "Focus next monitor", expr: 'hl.dsp.focus({ monitor = "+1" })' },
  { value: "monitor-prev", label: "Focus previous monitor", expr: 'hl.dsp.focus({ monitor = "-1" })' },
  { value: "pop", label: "Pop window out (float & pin)", cmd: "omarchy-hyprland-window-pop" },
  { value: "close-all", label: "Close all windows", cmd: "omarchy-hyprland-window-close-all" },
  { value: "transparency", label: "Toggle window transparency", cmd: "omarchy-hyprland-window-transparency-toggle" }
]

var MEDIA_ACTIONS = [
  { value: "vol-up", label: "Volume up", cmd: "omarchy-audio-output-volume raise", repeating: true },
  { value: "vol-down", label: "Volume down", cmd: "omarchy-audio-output-volume lower", repeating: true },
  { value: "mute", label: "Mute / unmute", cmd: "omarchy-audio-output-volume mute-toggle" },
  { value: "mic", label: "Mute microphone", cmd: "omarchy-audio-input-mute" },
  { value: "output", label: "Switch audio output", cmd: "omarchy-audio-output-switch" },
  { value: "play", label: "Play / pause", cmd: "omarchy-shell media playPause" },
  { value: "next", label: "Next track", cmd: "omarchy-shell media next" },
  { value: "prev", label: "Previous track", cmd: "omarchy-shell media previous" },
  { value: "bright-up", label: "Brightness up", cmd: "omarchy-brightness-display +5%", repeating: true },
  { value: "bright-down", label: "Brightness down", cmd: "omarchy-brightness-display 5%-", repeating: true }
]

var CAPTURE_ACTIONS = [
  { value: "screenshot", label: "Screenshot", cmd: "omarchy-capture-screenshot" },
  { value: "record", label: "Start / stop screen recording", cmd: "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord" },
  { value: "color", label: "Color picker", cmd: "pkill hyprpicker || hyprpicker -a" },
  { value: "ocr", label: "Extract text (OCR)", cmd: "omarchy-capture-text" },
  { value: "qr", label: "Scan QR code", cmd: "omarchy-capture-qr" }
]

var SYSTEM_ACTIONS = [
  { value: "lock", label: "Lock screen", cmd: "omarchy-system-lock" },
  { value: "screensaver", label: "Start screensaver", cmd: "omarchy-launch-screensaver force" },
  { value: "suspend", label: "Suspend", cmd: "systemctl suspend" },
  { value: "logout", label: "Log out", cmd: "omarchy-system-logout" },
  { value: "reboot", label: "Reboot", cmd: "omarchy-system-reboot" },
  { value: "shutdown", label: "Shut down", cmd: "omarchy-system-shutdown" },
  { value: "dismiss", label: "Dismiss last notification", cmd: "omarchy-shell notifications dismissOne" },
  { value: "dismiss-all", label: "Dismiss all notifications", cmd: "omarchy-shell notifications dismissAll" },
  { value: "history", label: "Notification history", cmd: "omarchy-shell notifications showHistory" }
]

var MENUS = [
  { value: "", label: "Omarchy menu" }, { value: "apps", label: "Apps" }, { value: "system", label: "System (power)" },
  { value: "capture", label: "Capture" }, { value: "toggle", label: "Toggles" }, { value: "hardware", label: "Hardware" },
  { value: "theme", label: "Themes" }, { value: "background", label: "Backgrounds" }, { value: "style", label: "Style" },
  { value: "setup", label: "Setup" }, { value: "install", label: "Install" }, { value: "remove", label: "Remove" },
  { value: "update", label: "Update" }, { value: "learn", label: "Learn" }, { value: "trigger", label: "Trigger" }
]

var TOGGLES = [
  { value: "nightlight", label: "Night light" }, { value: "idle", label: "Lock on idle" },
  { value: "bar", label: "Top bar" }, { value: "notification-silencing", label: "Silence notifications" },
  { value: "screensaver", label: "Screensaver" }, { value: "suspend", label: "Suspend" },
  { value: "touchpad", label: "Touchpad" }, { value: "touchscreen", label: "Touchscreen" }
]

var ACTION_TYPES = [
  { value: "app", label: "Open an app", icon: "󰀻" },
  { value: "webapp", label: "Open a web app", icon: "󰖟" },
  { value: "open", label: "Open a link, file or folder", icon: "󰏌" },
  { value: "command", label: "Run a command", icon: "" },
  { value: "type", label: "Type text", icon: "󰌌" },
  { value: "window", label: "Window & workspace", icon: "" },
  { value: "media", label: "Media, volume & brightness", icon: "󰝚" },
  { value: "capture", label: "Screenshot & capture", icon: "󰄀" },
  { value: "system", label: "System & notifications", icon: "" },
  { value: "plugin", label: "Toggle a shell plugin / panel", icon: "󰏗" },
  { value: "menu", label: "Open an Omarchy menu", icon: "󰍜" },
  { value: "toggle", label: "Omarchy toggle", icon: "󰔡" },
  { value: "nothing", label: "Do nothing (block the key)", icon: "󰜺" },
  { value: "lua", label: "Custom Lua dispatcher", icon: "" },
  { value: "function", label: "Lua function", icon: "", hidden: true }
]

function actionType(value) {
  for (var i = 0; i < ACTION_TYPES.length; i++) if (ACTION_TYPES[i].value === value) return ACTION_TYPES[i]
  return ACTION_TYPES[3]
}

function presetsFor(type) {
  return { window: WINDOW_ACTIONS, media: MEDIA_ACTIONS, capture: CAPTURE_ACTIONS, system: SYSTEM_ACTIONS }[type] || []
}

function findPreset(list, value) {
  for (var i = 0; i < list.length; i++) if (list[i].value === value) return list[i]
  return null
}

function labelIn(list, value) {
  var p = findPreset(list, value)
  return p ? p.label : value
}

var TYPE_DELAY_DEFAULT = 300

function emptySpec(type) {
  return {
    type: type || "app",
    appId: "", focus: false,
    url: "", target: "",
    cmd: "", mode: "plain",
    text: "", delay: TYPE_DELAY_DEFAULT,
    preset: (presetsFor(type)[0] || {}).value || "", param: "1",
    pluginId: "", payload: "",
    menu: "", toggle: "nightlight",
    expr: ""
  }
}

// ----------------------------------------------------- reading a binding

function isNil(v) { return v === null || v === undefined || (typeof v === "object" && v.__nil === true) }

function templateMatch(template, expr) {
  var parts = template.split("%s")
  if (parts.length === 1) return template === expr ? "" : null
  var re = new RegExp("^" + parts.map(function(p) { return p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") }).join('([^"]*)') + "$")
  var m = String(expr).match(re)
  return m ? m[1] : null
}

// A shell command string -> spec. Unknown commands stay "command".
function specFromCommand(cmd) {
  var s = emptySpec("command")
  var c = trim(cmd)
  var m, q

  var presetTypes = ["window", "media", "capture", "system"]
  for (var t = 0; t < presetTypes.length; t++) {
    var list = presetsFor(presetTypes[t])
    for (var i = 0; i < list.length; i++) {
      if (list[i].cmd && list[i].cmd === c) {
        s = emptySpec(presetTypes[t]); s.preset = list[i].value; return s
      }
    }
  }
  if (c === "true" || c === ":") return emptySpec("nothing")
  if ((m = c.match(/^uwsm-app -- (\S+)\.desktop$/))) { s = emptySpec("app"); s.appId = m[1]; return s }
  if ((m = c.match(/^omarchy-launch-or-focus (\S+|'[^']*') 'uwsm-app -- (\S+)\.desktop'$/))) {
    s = emptySpec("app"); s.appId = m[2]; s.focus = true; return s
  }
  if ((m = c.match(/^omarchy-launch-webapp (.+)$/)) && (q = shellWord(m[1])) !== null) {
    s = emptySpec("webapp"); s.url = q; return s
  }
  if ((m = c.match(/^omarchy-launch-or-focus-webapp ('(?:[^']|'\\'')*'|\S+) (.+)$/)) && (q = shellWord(m[2])) !== null) {
    s = emptySpec("webapp"); s.url = q; s.focus = true; return s
  }
  if ((m = c.match(/^xdg-open (.+)$/)) && (q = shellWord(m[1])) !== null) {
    s = emptySpec("open"); s.target = q; return s
  }
  if ((m = c.match(/^omarchy-shell shell toggle (\S+)(?: (.+))?$/))) {
    var payload = m[2] === undefined ? "" : shellWord(m[2])
    if (payload !== null) { s = emptySpec("plugin"); s.pluginId = m[1]; s.payload = payload; return s }
  }
  if ((m = c.match(/^omarchy-menu toggle(?: (\S+))?$/))) {
    var name = m[1] || ""
    if (name === "root") name = ""
    s = emptySpec("menu"); s.menu = name; return s
  }
  if ((m = c.match(/^omarchy-toggle-([a-z-]+)$/))) { s = emptySpec("toggle"); s.toggle = m[1]; return s }
  if ((m = c.match(/^wtype(?: -s (\d+))? -- (.+)$/)) && (q = shellWord(m[2])) !== null) {
    s = emptySpec("type"); s.text = q; s.delay = m[1] ? Number(m[1]) : 0; return s
  }
  s.cmd = c
  return s
}

function specFromDispatcher(d) {
  var s
  if (typeof d === "string") return specFromCommand(d)
  if (!d || typeof d !== "object") return emptySpec("lua")
  if (d.__fn) return emptySpec("function")
  if (d.__dsp) {
    if (d.kind === "exec") return specFromCommand(d.arg)
    for (var i = 0; i < WINDOW_ACTIONS.length; i++) {
      var w = WINDOW_ACTIONS[i]
      if (!w.expr) continue
      var p = templateMatch(w.expr, d.expr)
      if (p !== null) { s = emptySpec("window"); s.preset = w.value; if (w.param) s.param = p; return s }
    }
    s = emptySpec("lua"); s.expr = d.expr; return s
  }
  // o.bind's table forms
  if (typeof d.webapp === "string") { s = emptySpec("webapp"); s.url = d.webapp; s.focus = !!d.focus; return s }
  if (typeof d.launch === "string") {
    var app = d.launch.match(/^(\S+)\.desktop$/)
    if (app && (d.focus === undefined || typeof d.focus === "string")) {
      s = emptySpec("app"); s.appId = app[1]; s.focus = d.focus !== undefined; s.focusClass = d.focus || ""; return s
    }
    if (d.focus === undefined) { s = emptySpec("command"); s.cmd = d.launch; s.mode = "launch"; return s }
  }
  if (typeof d.tui === "string" && d.focus === undefined) { s = emptySpec("command"); s.cmd = d.tui; s.mode = "terminal"; return s }
  if (typeof d.omarchy === "string") { s = emptySpec("command"); s.cmd = "omarchy-launch-" + d.omarchy; return s }
  s = emptySpec("lua"); s.expr = luaLiteral(d); return s
}

var KNOWN_OPTS = ["locked", "repeating", "release", "description"]

// A scanned raw call ({ fn, args }) -> { keys, desc, spec, locked, repeating, release, extraOpts }
function bindingFromRaw(raw) {
  var a = (raw && raw.args) || []
  var keys = "", desc = "", disp = null, opts = {}
  if (raw.fn === "o.bind") { keys = a[0]; desc = isNil(a[1]) ? "" : a[1]; disp = a[2]; opts = isNil(a[3]) ? {} : a[3] }
  else if (raw.fn === "o.bind_toggle") { keys = a[0]; desc = isNil(a[1]) ? "" : a[1]; disp = "omarchy-toggle-" + a[2]; opts = isNil(a[3]) ? {} : a[3] }
  else if (raw.fn === "hl.bind") { keys = a[0]; disp = a[1]; opts = isNil(a[2]) ? {} : a[2]; desc = opts.description || "" }
  if (typeof opts !== "object" || opts.__opaque) opts = {}
  var extra = {}
  for (var k in opts) if (KNOWN_OPTS.indexOf(k) === -1) extra[k] = opts[k]
  return {
    keys: String(keys || ""),
    desc: String(desc || ""),
    spec: specFromDispatcher(disp),
    locked: opts.locked === true,
    repeating: opts.repeating === true,
    release: opts.release === true,
    extraOpts: extra
  }
}

function hasOpaque(v) {
  if (!v || typeof v !== "object") return false
  if (v.__fn || v.__opaque) return true
  for (var k in v) if (hasOpaque(v[k])) return true
  return false
}

// ---------------------------------------------------------------- render

function renderDispatcher(spec, desc) {
  var p
  switch (spec.type) {
  case "app":
    if (spec.focus) return luaLiteral({ focus: spec.focusClass || spec.appId, launch: spec.appId + ".desktop" })
    return luaLiteral({ launch: spec.appId + ".desktop" })
  case "webapp":
    return spec.focus ? luaLiteral({ webapp: spec.url, focus: true }) : luaLiteral({ webapp: spec.url })
  case "open":
    return luaString("xdg-open " + shellQuote(spec.target))
  case "command":
    if (spec.mode === "launch") return luaLiteral({ launch: spec.cmd })
    if (spec.mode === "terminal") return luaLiteral({ tui: spec.cmd })
    return luaString(spec.cmd)
  case "type":
    var delay = Math.max(0, Math.round(Number(spec.delay) || 0))
    return luaString("wtype" + (delay > 0 ? " -s " + delay : "") + " -- " + shellQuote(spec.text))
  case "window": case "media": case "capture": case "system":
    p = findPreset(presetsFor(spec.type), spec.preset)
    if (!p) return "nil"
    if (p.cmd) return luaString(p.cmd)
    return p.param ? p.expr.replace("%s", String(spec.param).replace(/["\\]/g, "")) : p.expr
  case "plugin":
    return luaString("omarchy-shell shell toggle " + spec.pluginId + (spec.payload ? " " + shellQuote(spec.payload) : ""))
  case "menu":
    return luaString("omarchy-menu toggle" + (spec.menu ? " " + spec.menu : ""))
  case "toggle":
    return luaString("omarchy-toggle-" + spec.toggle)
  case "nothing":
    return luaString("true")
  case "lua":
    return trim(spec.expr)
  }
  return "nil"
}

function renderOpts(b) {
  var o = {}
  if (b.locked) o.locked = true
  if (b.repeating) o.repeating = true
  if (b.release) o.release = true
  for (var k in (b.extraOpts || {})) o[k] = b.extraOpts[k]
  return Object.keys(o).length ? luaLiteral(o) : ""
}

// b: { keys, desc, spec, locked, repeating, release, extraOpts }
function renderBind(b) {
  var args = [luaString(b.keys), b.desc ? luaString(b.desc) : "nil", renderDispatcher(b.spec, b.desc)]
  var opts = renderOpts(b)
  if (opts) args.push(opts)
  return "o.bind(" + args.join(", ") + ")"
}

function renderUnbind(keys) { return "hl.unbind(" + luaString(keys) + ")" }

// Empty string when the binding can be written; otherwise what's missing.
function validate(b) {
  var c = parseCombo(b.keys)
  if (!c.key) return "Pick a key"
  if (/["\\\n]/.test(b.keys)) return "Key names can't contain quotes"
  var s = b.spec
  switch (s.type) {
  case "app": if (!s.appId) return "Pick an app"; break
  case "webapp": if (!trim(s.url)) return "Enter a URL"; break
  case "open": if (!trim(s.target)) return "Enter a link or path"; break
  case "command": if (!trim(s.cmd)) return "Enter a command"; break
  case "type": if (s.text === "") return "Enter the text to type"; break
  case "window": case "media": case "capture": case "system":
    var p = findPreset(presetsFor(s.type), s.preset)
    if (!p) return "Pick an action"
    if (p.param && !trim(s.param)) return "Enter a " + p.param.toLowerCase()
    break
  case "plugin": if (!/^[A-Za-z0-9_.-]+$/.test(s.pluginId)) return "Pick a plugin"; break
  case "lua": if (!/^hl\.|^\{|^function/.test(trim(s.expr))) return "Enter an hl.dsp.… expression"; break
  case "function": return "Lua functions can only be edited by hand"
  }
  return ""
}

// One-line, human description of what a spec does.
function summarize(spec, names) {
  names = names || {}
  var p
  switch (spec.type) {
  case "app": return "Open " + ((names.apps && names.apps[spec.appId]) || spec.appId) + (spec.focus ? " (or focus it)" : "")
  case "webapp": return "Web app " + spec.url.replace(/^https?:\/\//, "") + (spec.focus ? " (or focus it)" : "")
  case "open": return "Open " + spec.target
  case "command": return (spec.mode === "terminal" ? "In terminal: " : spec.mode === "launch" ? "Launch: " : "Run: ") + spec.cmd
  case "type": return "Type “" + (spec.text.length > 40 ? spec.text.slice(0, 40) + "…" : spec.text) + "”"
  case "window": case "media": case "capture": case "system":
    p = findPreset(presetsFor(spec.type), spec.preset)
    if (!p) return spec.preset
    return p.param ? p.label.replace("…", " " + spec.param) : p.label
  case "plugin": return "Toggle " + ((names.plugins && names.plugins[spec.pluginId]) || spec.pluginId)
  case "menu": return "Menu: " + labelIn(MENUS, spec.menu)
  case "toggle": return "Toggle " + labelIn(TOGGLES, spec.toggle).toLowerCase()
  case "nothing": return "Does nothing (key blocked)"
  case "lua": return spec.expr
  case "function": return "Lua function"
  }
  return ""
}

function dspSummary(dsp) {
  if (!dsp) return ""
  if (dsp.kind === "exec") return summarize(specFromCommand(dsp.arg))
  if (dsp.kind === "function") return "Lua function"
  return summarize(specFromDispatcher(dsp))
}

// ----------------------------------------------------------------- model

function isDefaultFile(file, omarchyPath) {
  return (omarchyPath && file.indexOf(omarchyPath + "/") === 0) || file.indexOf("/default/hypr/") !== -1
}

function shortPath(file, home) {
  return home && file.indexOf(home + "/") === 0 ? "~" + file.slice(home.length) : file
}

function descOf(ev) { return (ev.opts && ev.opts.description) || "" }

function blockOwner(blocks, line) {
  for (var i = 0; i < (blocks || []).length; i++)
    if (line > blocks[i].start && line < blocks[i].stop) return blocks[i].owner
  return ""
}

// Replays scanned events the way Hyprland applies them and returns the rows
// the panel shows.
function buildModel(scan, omarchyPath, home) {
  var events = scan.events || []
  var userFile = scan.userFile
  var active = []
  var i, j, ev

  for (i = 0; i < events.length; i++) {
    ev = events[i]
    ev.index = i
    ev.id = comboId(ev.keys)
    ev.source = ev.origin.file === userFile ? "mine" : (isDefaultFile(ev.origin.file, omarchyPath) ? "default" : "other")
    if (ev.t === "bind") {
      ev.active = true
      active.push(ev)
    } else {
      var kept = [], removed = []
      for (j = 0; j < active.length; j++) (active[j].id === ev.id ? removed : kept).push(active[j])
      for (j = 0; j < removed.length; j++) { removed[j].active = false; removed[j].removedBy = ev }
      ev.removed = removed
      active = kept
    }
  }

  var mine = [], defaults = [], all = []
  var claimed = {}

  for (i = 0; i < events.length; i++) {
    ev = events[i]
    if (ev.t !== "bind") continue

    var row = {
      key: "b" + i,
      kind: "bind",
      keys: ev.keys,
      id: ev.id,
      event: ev,
      source: ev.source,
      active: ev.active,
      file: shortPath(ev.origin.file, home),
      line: ev.origin.line,
      desc: descOf(ev),
      summary: dspSummary(ev.dsp),
      binding: null,
      unbind: null,
      replaces: [],
      owner: "",
      editable: false,
      removable: false,
      lockedReason: ""
    }
    all.push(row)

    if (ev.source === "default") {
      row.removedBy = ev.removedBy ? ev.removedBy.source : ""
      defaults.push(row)
      continue
    }

    if (ev.source === "mine") {
      // Pair with the nearest unclaimed hl.unbind of the same key above it.
      for (j = i - 1; j >= 0; j--) {
        var u = events[j]
        if (u.t === "unbind" && u.source === "mine" && u.id === ev.id && !claimed[j]) {
          claimed[j] = true
          row.unbind = u
          for (var r = 0; r < u.removed.length; r++)
            if (u.removed[r].source !== "mine") row.replaces.push(descOf(u.removed[r]) || dspSummary(u.removed[r].dsp))
          break
        }
      }
      row.owner = blockOwner(scan.blocks, ev.origin.line)
      if (ev.raw) {
        row.binding = bindingFromRaw(ev.raw)
        if (!row.desc) row.desc = row.binding.desc
        if (row.binding.spec.type !== "lua" || !row.summary) row.summary = summarize(row.binding.spec)
      }
      row.removable = !!ev.span && (!row.unbind || !!row.unbind.span)
      row.editable = row.removable && !!row.binding && !hasOpaque(ev.raw.args)
        && row.binding.spec.type !== "function"
      if (!ev.span) row.lockedReason = ev.hits > 1 ? "Created in a loop — edit by hand" : "Not a plain call — edit by hand"
      else if (!row.editable) row.lockedReason = "Lua function — edit by hand"
    } else {
      row.lockedReason = "Defined in " + row.file
    }
    mine.push(row)
  }

  // hl.unbind with no replacement: a default the user switched off.
  for (i = 0; i < events.length; i++) {
    ev = events[i]
    if (ev.t !== "unbind" || ev.source !== "mine" || claimed[i]) continue
    var names = []
    for (j = 0; j < ev.removed.length; j++) names.push(descOf(ev.removed[j]) || dspSummary(ev.removed[j].dsp))
    mine.push({
      key: "u" + i,
      kind: "disable",
      keys: ev.keys,
      id: ev.id,
      event: ev,
      unbind: ev,
      source: "mine",
      active: true,
      file: shortPath(ev.origin.file, home),
      line: ev.origin.line,
      desc: names.length ? names.join(", ") : "Nothing was bound here",
      summary: "Disabled",
      binding: null,
      replaces: names,
      owner: blockOwner(scan.blocks, ev.origin.line),
      editable: false,
      removable: !!ev.span,
      lockedReason: ev.span ? "" : (ev.hits > 1 ? "Created in a loop — edit by hand" : "Not a plain call — edit by hand")
    })
  }

  mine.sort(function(a, b) { return a.event.index - b.event.index })
  return { mine: mine, defaults: defaults, all: all, events: events }
}

// Binds that would still fire on `keys` if `row` were rewritten, i.e. what a
// new binding there has to unbind first.
function conflictsFor(model, keys, row) {
  var id = comboId(keys)
  var out = []
  var events = model.events || []
  for (var i = 0; i < events.length; i++) {
    var ev = events[i]
    if (ev.t !== "bind" || ev.id !== id) continue
    if (row && ev === row.event) continue
    var revived = row && row.unbind && row.unbind.id === id && (row.unbind.removed || []).indexOf(ev) !== -1
    if (ev.active || revived) out.push(ev)
  }
  return out
}

// ------------------------------------------------------------------ edits

// Each op replaces lines [start, stop] (1-based, inclusive) with `lines`. An
// insert before line n is { start: n, stop: n - 1 }. Ops must not overlap.
function applyOps(lines, ops) {
  var out = lines.slice()
  var sorted = ops.slice().sort(function(a, b) { return b.start - a.start })
  for (var i = 0; i < sorted.length; i++) {
    var op = sorted[i]
    var at = op.start - 1
    var add = op.lines || []
    Array.prototype.splice.apply(out, [at, op.stop - op.start + 1].concat(add))
    // Only the seam an edit made gets its blank lines collapsed; the rest of
    // the file keeps whatever spacing its author chose.
    var seam = at + add.length
    while (seam > 0 && seam < out.length && trim(out[seam]) === "" && trim(out[seam - 1]) === "") out.splice(seam, 1)
  }
  while (out.length && trim(out[out.length - 1]) === "") out.pop()
  while (out.length && trim(out[0]) === "") out.shift()
  return out
}

// A new binding goes at the end of the file, set off by a blank line and a
// comment naming it.
function appendOps(lines, newLines) {
  var block = []
  if (lines.length && trim(lines[lines.length - 1]) !== "") block.push("")
  return [{ start: lines.length + 1, stop: lines.length, lines: block.concat(newLines) }]
}

function isFence(line) {
  return /^\s*--\s*(BEGIN|END)\s+\S/.test(line) || /^\s*--\s*\S+:(start|end)\s*$/.test(line) || /^\s*--\s*(>>>|<<<)/.test(line)
}

function isComment(line) { return /^\s*--/.test(line) && !isFence(line) }

// Deleting spans [first..last]: also take the comment block glued above them,
// but only if nothing else follows it (a blank line, a fence or EOF below), so
// a comment shared with the next binding survives. A matching closing comment
// right below ("-- Mirador" … "-- Mirador") goes too.
function deletionOps(lines, spans) {
  var ops = []
  var first = Infinity, last = 0
  for (var i = 0; i < spans.length; i++) {
    ops.push({ start: spans[i].start, stop: spans[i].stop, lines: [] })
    first = Math.min(first, spans[i].start)
    last = Math.max(last, spans[i].stop)
  }
  var below = lines[last]   // line last+1 (0-based index `last`)
  var alone = below === undefined || trim(below) === "" || isFence(below)
  var top = first
  while (top > 1 && isComment(lines[top - 2])) top--
  if (top < first && alone) {
    ops.push({ start: top, stop: first - 1, lines: [] })
  } else if (top < first && !alone && below !== undefined && isComment(below)
             && trim(below) === trim(lines[first - 2])) {
    // "-- Mirador" above and below: both belong to this binding
    ops.push({ start: top, stop: first - 1, lines: [] })
    ops.push({ start: last + 1, stop: last + 1, lines: [] })
  }
  return ops
}
