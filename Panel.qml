import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Keybinds.js" as K

// Keysmith — view, add, edit and remove the shortcuts in
// ~/.config/hypr/bindings.lua.
//
// Reading goes through scan.lua, which runs the real Hyprland config against
// recording stubs, so what the list shows is what Hyprland registers —
// Omarchy's defaults included. Writing edits only the exact source lines a
// binding came from; anything built in a loop, a function, or another file is
// shown but left for hand-editing.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  // Omarchy 4.0.3+ strips __sourceDir from third-party manifests.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string hyprDir: home + "/.config/hypr"
  readonly property string bindingsPath: hyprDir + "/bindings.lua"
  readonly property string configPath: hyprDir + "/hyprland.lua"

  property bool opened: false

  property var model: ({ mine: [], defaults: [], all: [], events: [] })
  property var lines: []
  property bool scanned: false
  property string loadError: ""

  property string tab: "mine"
  property string query: ""
  property int cursorIndex: -1

  property var undoStack: []
  property bool backedUp: false
  property string baselineErrors: ""
  property bool errorsBaselined: false
  property bool selfWrite: false
  property string pendingText: ""
  property string revertText: ""
  property bool reverting: false
  property string pendingStatus: ""

  property string errorText: ""
  property string statusText: ""

  // editor
  property bool editorOpen: false
  property var editRow: null
  property var draft: null
  property bool recording: false
  property var recordMods: []

  // confirm
  property var confirmRow: null
  property string confirmMessage: ""

  property var appOptions: []
  property var appNames: ({})
  property var appClasses: ({})
  property var pluginOptions: []
  property var pluginNames: ({})

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color scrim: Color.menu.scrim
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  property string fontFamily: Style.font.menuFamily

  readonly property var names: ({ apps: appNames, plugins: pluginNames })

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    root.errorText = ""
    root.statusText = ""
    root.query = ""
    root.cursorIndex = -1
    root.errorsBaselined = false
    rescan()
    baselineProc.running = true
    pluginsProc.running = true
    refreshApps()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (payload.tab === "defaults") root.tab = "defaults"
    if (payload.new === true) Qt.callLater(function() { root.startNew("") })
  }

  function close() {
    root.editorOpen = false
    root.recording = false
    root.confirmRow = null
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ebirkhoff.keysmith")
    else close()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --------------------------------------------------------------- reading

  function rescan() {
    if (scanProc.running) { scanAgain.restart(); return }
    scanProc.command = ["lua", root.pluginDir + "/scan.lua", root.configPath, root.bindingsPath]
    scanProc.running = true
  }

  function applyScan(text) {
    var scan
    try { scan = JSON.parse(text) } catch (e) {
      root.errorText = "Could not read bindings: " + String(text || e).slice(0, 200)
      return
    }
    root.loadError = scan.loadError || ""
    root.lines = scan.lines || []
    root.model = K.buildModel(scan, root.omarchyPath, root.home)
    root.scanned = true
    if (root.loadError !== "") root.errorText = "Config stopped loading early: " + root.loadError.split("\n")[0]
  }

  function refreshApps() {
    var values = DesktopEntries.applications.values || []
    var opts = [], names = {}, classes = {}
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (!e || e.noDisplay || !e.id) continue
      names[e.id] = e.name
      classes[e.id] = e.startupClass || ""
      opts.push({ value: e.id, label: e.name, description: e.genericName || e.id })
    }
    opts.sort(function(a, b) { return a.label.toLowerCase() < b.label.toLowerCase() ? -1 : 1 })
    root.appOptions = opts
    root.appNames = names
    root.appClasses = classes
  }

  function applyPlugins(text) {
    var list = []
    try { list = JSON.parse(text) } catch (e) { return }
    var opts = [], names = {}
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      var kinds = p.kinds || []
      names[p.id] = p.name
      if (!p.enabled) continue
      if (kinds.indexOf("panel") === -1 && kinds.indexOf("overlay") === -1 && kinds.indexOf("menu") === -1) continue
      opts.push({ value: p.id, label: p.name, description: p.id })
    }
    opts.sort(function(a, b) { return a.label.toLowerCase() < b.label.toLowerCase() ? -1 : 1 })
    root.pluginOptions = opts
    root.pluginNames = names
  }

  // Rows for the current tab and search, with a header wherever the source
  // changes.
  readonly property var visibleRows: {
    var src = root.tab === "mine" ? root.model.mine : root.model.defaults
    var q = root.query.toLowerCase().trim()
    var out = []
    var lastGroup = null
    for (var i = 0; i < src.length; i++) {
      var r = src[i]
      if (q !== "") {
        var hay = (r.keys + " " + K.comboCaps(r.keys).join(" ") + " " + r.desc + " " + summaryOf(r)).toLowerCase()
        if (hay.indexOf(q) === -1) continue
      }
      var group = groupOf(r)
      if (group !== lastGroup) {
        out.push({ header: true, title: group, key: "h" + i })
        lastGroup = group
      }
      out.push(r)
    }
    return out
  }

  function groupOf(r) {
    if (root.tab === "defaults") {
      var base = r.file.replace(/^.*\//, "").replace(/\.lua$/, "")
      var dir = r.file.indexOf("/apps/") !== -1 ? "Apps · " : ""
      return dir + base.charAt(0).toUpperCase() + base.slice(1).replace(/-/g, " ")
    }
    if (r.owner) return "Managed by " + r.owner
    if (r.source === "other") return r.file
    return "bindings.lua"
  }

  function summaryOf(r) {
    if (r.binding && r.editable) return K.summarize(r.binding.spec, root.names)
    return r.summary
  }

  readonly property int mineCount: root.model.mine.length
  readonly property int defaultsCount: root.model.defaults.length

  // --------------------------------------------------------------- editing

  function blankDraft(keys) {
    return { keys: keys || "", desc: "", spec: K.emptySpec("app"), locked: false, repeating: false, release: false, extraOpts: {} }
  }

  function startNew(keys) {
    root.editRow = null
    root.draft = blankDraft(keys)
    root.editorOpen = true
    // With no key yet, the fastest path is to just press it.
    root.recording = !keys
    root.recordMods = []
    Qt.callLater(function() { if (root.recording) recorder.forceActiveFocus(); else editorScope.forceActiveFocus() })
  }

  function startEdit(row) {
    if (!row || !row.editable) return
    root.editRow = row
    var b = row.binding
    root.draft = {
      keys: b.keys, desc: b.desc, spec: JSON.parse(JSON.stringify(b.spec)),
      locked: b.locked, repeating: b.repeating, release: b.release, extraOpts: b.extraOpts || {}
    }
    root.editorOpen = true
    root.recording = false
    Qt.callLater(function() { editorScope.forceActiveFocus() })
  }

  function closeEditor() {
    root.editorOpen = false
    root.recording = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function setDraft(patch) {
    var next = {}
    for (var k in root.draft) next[k] = root.draft[k]
    for (var p in patch) next[p] = patch[p]
    root.draft = next
  }

  function setSpec(patch) {
    var spec = {}
    for (var k in root.draft.spec) spec[k] = root.draft.spec[k]
    for (var p in patch) spec[p] = patch[p]
    setDraft({ spec: spec })
  }

  function setType(type) {
    if (type === root.draft.spec.type) return
    setDraft({ spec: K.emptySpec(type) })
  }

  function setPreset(value) {
    setSpec({ preset: value })
    var p = K.findPreset(K.presetsFor(root.draft.spec.type), value)
    if (p && p.repeating) setDraft({ repeating: true })
  }

  function draftCombo() { return K.parseCombo(root.draft ? root.draft.keys : "") }

  function toggleMod(mod) {
    var c = draftCombo()
    var mods = c.mods.slice()
    var at = mods.indexOf(mod)
    if (at === -1) mods.push(mod); else mods.splice(at, 1)
    setDraft({ keys: K.formatCombo(mods, c.key) })
  }

  function setKey(key) {
    setDraft({ keys: K.formatCombo(draftCombo().mods, key) })
  }

  // The finished binding as it will be written, description filled in.
  function finalDraft() {
    var d = root.draft
    if (!d) return null
    var out = {}
    for (var k in d) out[k] = d[k]
    out.keys = K.formatCombo(K.parseCombo(d.keys).mods, K.parseCombo(d.keys).key)
    if (out.spec.type === "app" && out.spec.focus && !out.spec.focusClass)
      out.spec = Object.assign({}, out.spec, { focusClass: root.appClasses[out.spec.appId] || out.spec.appId })
    if (K.trim(out.desc) === "") out.desc = K.summarize(out.spec, root.names).slice(0, 60)
    return out
  }

  readonly property var draftConflicts: {
    if (!root.draft || !root.editorOpen) return []
    var c = K.parseCombo(root.draft.keys)
    if (!c.key) return []
    return K.conflictsFor(root.model, K.formatCombo(c.mods, c.key), root.editRow)
  }

  readonly property string draftError: root.draft ? K.validate(root.draft) : ""

  readonly property string draftLua: {
    var d = finalDraft()
    if (!d || root.draftError !== "") return ""
    var out = []
    if (root.draftConflicts.length > 0) out.push(K.renderUnbind(d.keys))
    out.push(K.renderBind(d))
    return out.join("\n")
  }

  function conflictText(evs) {
    var parts = []
    for (var i = 0; i < evs.length; i++) {
      var ev = evs[i]
      var who = ev.source === "default" ? "Omarchy" : ev.source === "mine" ? "you" : K.shortPath(ev.origin.file, root.home)
      parts.push("“" + ((ev.opts && ev.opts.description) || K.dspSummary(ev.dsp)) + "” (" + who + ")")
    }
    return parts.join(", ")
  }

  function saveDraft() {
    if (root.draftError !== "") return
    var d = finalDraft()
    var newLines = []
    if (root.draftConflicts.length > 0) newLines.push(K.renderUnbind(d.keys))
    newLines.push(K.renderBind(d))

    var ops
    var row = root.editRow
    if (row) {
      ops = [{ start: row.event.span.start, stop: row.event.span.stop, lines: newLines }]
      if (row.unbind && row.unbind.span)
        ops.push({ start: row.unbind.span.start, stop: row.unbind.span.stop, lines: [] })
    } else {
      ops = K.appendOps(root.lines, ["-- " + d.desc].concat(newLines))
    }
    if (commit(ops, (row ? "Updated " : "Added ") + d.keys)) closeEditor()
  }

  function askRemove(row) {
    if (!row || !row.removable) return
    var msg
    if (row.kind === "disable") {
      msg = "Turn " + row.keys + " back on?"
      if (row.replaces.length) msg += "\nOmarchy's “" + row.replaces.join("”, “") + "” comes back."
    } else {
      msg = "Remove " + row.keys + (row.desc ? " (" + row.desc + ")" : "") + "?"
      if (row.replaces.length) msg += "\nOmarchy's “" + row.replaces.join("”, “") + "” comes back on this key."
      if (row.owner) msg += "\nNote: " + row.owner + " manages this block and may add it again."
    }
    root.confirmRow = row
    root.confirmMessage = msg
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function removeRow(row) {
    var spans = []
    if (row.kind === "disable") spans.push(row.unbind.span)
    else {
      spans.push(row.event.span)
      if (row.unbind && row.unbind.span) spans.push(row.unbind.span)
    }
    commit(K.deletionOps(root.lines, spans), (row.kind === "disable" ? "Re-enabled " : "Removed ") + row.keys)
  }

  function disableDefault(row) {
    commit(K.appendOps(root.lines, ["-- Disable Omarchy default: " + (row.desc || row.summary), K.renderUnbind(row.keys)]),
           "Disabled " + row.keys)
  }

  // The user row that switched a default off, if it is a plain hl.unbind.
  function disablerOf(row) {
    var by = row.event.removedBy
    if (!by || by.source !== "mine") return null
    for (var i = 0; i < root.model.mine.length; i++) {
      var r = root.model.mine[i]
      if (r.unbind === by) return r
    }
    return null
  }

  // --------------------------------------------------------------- writing

  function currentFileText() {
    bindingsFile.reload()
    return bindingsFile.text()
  }

  function commit(ops, status) {
    if (root.selfWrite) return false
    var current = currentFileText()
    var scannedText = root.lines.join("\n")
    if (String(current).replace(/\s+$/, "") !== scannedText.replace(/\s+$/, "")) {
      root.errorText = "bindings.lua changed on disk — reloaded it, try again"
      rescan()
      return false
    }
    var next = K.applyOps(root.lines, ops).join("\n") + "\n"
    var stack = root.undoStack.slice()
    stack.push(current)
    root.undoStack = stack
    write(next, status)
    return true
  }

  function undo() {
    if (root.undoStack.length === 0 || root.selfWrite) return
    var stack = root.undoStack.slice()
    var prev = stack.pop()
    root.undoStack = stack
    write(prev, "Undone")
  }

  function write(text, status) {
    root.errorText = ""
    root.statusText = "Saving…"
    root.pendingStatus = status
    root.pendingText = text
    root.selfWrite = true
    if (!root.backedUp) {
      // One backup per session, taken before the first write lands.
      var stamp = Qt.formatDateTime(new Date(), "yyyyMMddhhmmss")
      backupProc.command = ["cp", "-p", root.bindingsPath, root.bindingsPath + ".bak.keysmith." + stamp]
      backupProc.running = true
      return
    }
    bindingsFile.setText(text)
  }

  function afterReload(errors) {
    var out = String(errors || "").trim()
    if (out === "no errors") out = ""
    if (out !== "" && out !== root.baselineErrors && !root.reverting && root.undoStack.length > 0) {
      // Hyprland rejected it: put the old file back rather than leave a
      // broken config behind.
      var stack = root.undoStack.slice()
      var prev = stack.pop()
      root.undoStack = stack
      root.reverting = true
      root.revertText = out
      write(prev, "")
      return
    }
    if (root.reverting) {
      root.reverting = false
      root.errorText = "Hyprland rejected the change, so it was reverted: " + root.revertText.split("\n")[0]
      root.statusText = ""
    } else {
      root.statusText = root.pendingStatus
    }
    rescan()
  }

  // ------------------------------------------------------------- processes

  Process {
    id: scanProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyScan(text) }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.errorText = "scan.lua: " + String(text).trim().split("\n")[0]
    }
  }

  Timer { id: scanAgain; interval: 150; onTriggered: root.rescan() }

  Process {
    id: pluginsProc
    command: ["omarchy-shell", "shell", "listPlugins"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyPlugins(text) }
  }

  // Errors already present before this panel touched anything, so a
  // pre-existing problem elsewhere doesn't make every save look rejected.
  Process {
    id: baselineProc
    command: ["hyprctl", "configerrors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        root.baselineErrors = out === "no errors" ? "" : out
        root.errorsBaselined = true
      }
    }
  }

  Process {
    id: backupProc
    onExited: function(code) {
      root.backedUp = true
      bindingsFile.setText(root.pendingText)
    }
  }

  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
    onExited: errorsProc.running = true
  }

  Process {
    id: errorsProc
    command: ["hyprctl", "configerrors"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.afterReload(text) }
  }

  Timer {
    id: statusClear
    interval: 2600
    running: root.statusText !== "" && root.statusText !== "Saving…"
    onTriggered: root.statusText = ""
  }

  FileView {
    id: bindingsFile
    path: root.bindingsPath
    blockLoading: true
    atomicWrites: true
    printErrors: false
    watchChanges: true
    onSaved: {
      root.selfWrite = false
      reloadProc.running = true
    }
    onSaveFailed: {
      root.selfWrite = false
      root.statusText = ""
      root.errorText = "Could not write ~/.config/hypr/bindings.lua"
    }
    onFileChanged: {
      if (root.selfWrite || !root.opened) return
      root.rescan()
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (root.opened) root.refreshApps() }
  }

  // -------------------------------------------------------------- pieces

  component KeyCaps: Row {
    id: caps
    property string keys: ""
    property color fg: root.foreground
    property real size: Style.font.bodySmall
    property bool struck: false
    spacing: Style.spacing.xs

    Repeater {
      model: K.comboCaps(caps.keys)
      Rectangle {
        required property string modelData
        height: capText.implicitHeight + Style.spacing.sm * 2
        width: Math.max(height, capText.implicitWidth + Style.spacing.lg * 2)
        radius: Math.max(2, Style.cornerRadius / 2)
        color: Qt.rgba(caps.fg.r, caps.fg.g, caps.fg.b, 0.07)
        border.width: 1
        border.color: Qt.rgba(caps.fg.r, caps.fg.g, caps.fg.b, 0.28)

        Text {
          id: capText
          anchors.centerIn: parent
          text: parent.modelData
          color: caps.fg
          font.family: root.fontFamily
          font.pixelSize: caps.size
          font.bold: true
          font.strikeout: caps.struck
        }
      }
    }
  }

  component Label: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.6
  }

  component Badge: Rectangle {
    id: badge
    property string text: ""
    property color tint: root.dim
    visible: text !== ""
    height: badgeText.implicitHeight + Style.spacing.xxs * 2
    width: badgeText.implicitWidth + Style.spacing.md * 2
    radius: height / 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)
    Text {
      id: badgeText
      anchors.centerIn: parent
      text: badge.text
      color: badge.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ------------------------------------------------------------------- UI

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "keysmith"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(1000), window.width - Style.gapsOut * 4)
      height: Math.min(Style.space(720), window.height - Style.gapsOut * 4)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          if (root.confirmRow) {
            if (confirm.handleKey(event)) event.accepted = true
            return
          }
          var plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
          if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
          else if (event.key === Qt.Key_Down || (plain && event.key === Qt.Key_J)) { moveCursor(1); event.accepted = true }
          else if (event.key === Qt.Key_Up || (plain && event.key === Qt.Key_K)) { moveCursor(-1); event.accepted = true }
          else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.tab = root.tab === "mine" ? "defaults" : "mine"; root.cursorIndex = -1; event.accepted = true
          }
          else if (plain && (event.key === Qt.Key_Slash)) { search.forceActiveFocus(); event.accepted = true }
          else if (plain && event.key === Qt.Key_N) { root.startNew(""); event.accepted = true }
          else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Z) { root.undo(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || (plain && event.key === Qt.Key_E)) {
            var r = cursorRow()
            if (r && root.tab === "mine") root.startEdit(r)
            else if (r) root.startNew(r.keys)
            event.accepted = true
          }
          else if (event.key === Qt.Key_Delete || (plain && event.key === Qt.Key_D)) {
            var d = cursorRow()
            if (d && root.tab === "mine") root.askRemove(d)
            event.accepted = true
          }
        }

        function moveCursor(delta) {
          var rows = root.visibleRows
          if (rows.length === 0) return
          var i = root.cursorIndex
          for (var n = 0; n < rows.length; n++) {
            i = (i + delta + rows.length) % rows.length
            if (!rows[i].header) break
          }
          root.cursorIndex = i
          list.positionViewAtIndex(i, ListView.Contain)
        }

        function cursorRow() {
          var r = root.visibleRows[root.cursorIndex]
          return r && !r.header ? r : null
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.panelGap

        // header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.lg

          Column {
            Layout.fillWidth: true
            spacing: Style.spacing.xxs
            Text {
              text: "Keysmith"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              text: "~/.config/hypr/bindings.lua"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            text: "Undo"
            iconText: "󰕌"
            enabled: root.undoStack.length > 0 && !root.selfWrite
            opacity: enabled ? 1 : 0.4
            bordered: true
            tooltipText: "Undo the last change  ·  Ctrl+Z"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.undo()
          }

          Button {
            text: "Edit file"
            iconText: "󰈔"
            bordered: true
            tooltipText: "Open bindings.lua in your editor"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: { Quickshell.execDetached(["omarchy-launch-editor", root.bindingsPath]); root.dismiss() }
          }

          Button {
            text: "New shortcut"
            iconText: "󰐕"
            bordered: true
            selected: true
            tooltipText: "Add a shortcut  ·  N"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.startNew("")
          }

          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Close  ·  Esc"
            foreground: root.foreground
            onClicked: root.dismiss()
          }
        }

        // tabs + search
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.lg

          ButtonGroup {
            options: [
              { value: "mine", label: "My shortcuts  " + root.mineCount },
              { value: "defaults", label: "Omarchy defaults  " + root.defaultsCount }
            ]
            value: root.tab
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { root.tab = v; root.cursorIndex = -1 }
          }

          Item { Layout.fillWidth: true }

          TextField {
            id: search
            Layout.preferredWidth: Style.space(280)
            placeholderText: "Search keys, names, commands…  ( / )"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            text: root.query
            onTextEdited: { root.query = text; root.cursorIndex = -1 }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape || event.key === Qt.Key_Down || event.key === Qt.Key_Return) {
                keyCatcher.forceActiveFocus()
                if (event.key === Qt.Key_Escape && root.query !== "") root.query = ""
                if (event.key !== Qt.Key_Escape) keyCatcher.moveCursor(1)
                event.accepted = true
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: root.visibleRows
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.spacing.xxs

          delegate: Item {
            id: rowItem
            required property var modelData
            required property int index
            readonly property var row: modelData
            readonly property bool isHeader: row.header === true
            readonly property bool isDefault: root.tab === "defaults"
            readonly property bool off: isDefault && !row.active
            readonly property var disabler: isDefault && off ? root.disablerOf(row) : null
            readonly property bool hot: hover.hovered || root.cursorIndex === index

            width: list.width - Style.spacing.xxl
            height: isHeader ? headerText.implicitHeight + Style.spacing.xl + (index === 0 ? 0 : Style.spacing.lg)
                             : Math.max(Style.space(50), body.implicitHeight + Style.spacing.lg * 2)

            Text {
              id: headerText
              visible: rowItem.isHeader
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.spacing.sm
              text: rowItem.isHeader ? rowItem.row.title : ""
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.capitalization: Font.AllUppercase
              font.letterSpacing: 0.6
            }

            Rectangle {
              visible: !rowItem.isHeader
              anchors.fill: parent
              radius: Style.cornerRadius
              color: rowItem.hot ? Color.menu.selectedBackground : "transparent"
            }

            HoverHandler { id: hover; enabled: !rowItem.isHeader }
            TapHandler {
              enabled: !rowItem.isHeader
              onTapped: { root.cursorIndex = rowItem.index; keyCatcher.forceActiveFocus() }
              onDoubleTapped: {
                if (rowItem.isDefault) root.startNew(rowItem.row.keys)
                else root.startEdit(rowItem.row)
              }
            }

            RowLayout {
              id: body
              visible: !rowItem.isHeader
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.lg
              anchors.rightMargin: Style.spacing.md
              spacing: Style.spacing.xxl

              Item {
                Layout.preferredWidth: Style.space(250)
                Layout.preferredHeight: capsRow.implicitHeight
                KeyCaps {
                  id: capsRow
                  keys: rowItem.isHeader ? "" : rowItem.row.keys
                  fg: rowItem.off ? root.dim : root.foreground
                  struck: rowItem.off || (!rowItem.isDefault && rowItem.row.kind === "disable")
                }
              }

              Column {
                Layout.fillWidth: true
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  text: rowItem.isHeader ? "" : (rowItem.row.kind === "disable"
                        ? "Disabled: " + rowItem.row.desc
                        : (rowItem.row.desc || rowItem.row.summary || "(no description)"))
                  color: rowItem.off ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: rowItem.isHeader || rowItem.row.kind === "disable" ? "" : root.summaryOf(rowItem.row)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.sm
                  visible: children.length > 0
                  Badge {
                    text: !rowItem.isHeader && !rowItem.isDefault && rowItem.row.replaces.length && rowItem.row.kind === "bind"
                          ? "replaces " + rowItem.row.replaces.join(", ") : ""
                    tint: root.accent
                  }
                  Badge {
                    text: rowItem.off ? (rowItem.row.removedBy === "mine" ? (rowItem.disabler ? "disabled by you" : "replaced by you") : "disabled elsewhere") : ""
                    tint: root.accent
                  }
                  Badge { text: !rowItem.isHeader && !rowItem.isDefault ? rowItem.row.lockedReason : "" }
                  Badge {
                    text: !rowItem.isHeader && (rowItem.row.event && rowItem.row.event.opts && rowItem.row.event.opts.locked) ? "󰌾 lock screen" : ""
                  }
                  Badge {
                    text: !rowItem.isHeader && (rowItem.row.event && rowItem.row.event.opts && rowItem.row.event.opts.repeating) ? "repeats" : ""
                  }
                }
              }

              // actions: mine
              Row {
                visible: !rowItem.isHeader && !rowItem.isDefault
                spacing: Style.spacing.xs
                opacity: rowItem.hot ? 1 : 0.55
                PanelActionButton {
                  visible: !rowItem.isHeader && rowItem.row.kind === "bind"
                  enabled: !rowItem.isHeader && rowItem.row.editable
                  opacity: enabled ? 1 : 0.3
                  iconText: "󰏫"
                  tooltipText: enabled ? "Edit  ·  Enter" : (rowItem.isHeader ? "" : rowItem.row.lockedReason)
                  foreground: root.foreground
                  onClicked: root.startEdit(rowItem.row)
                }
                PanelActionButton {
                  enabled: !rowItem.isHeader && rowItem.row.removable
                  opacity: enabled ? 1 : 0.3
                  iconText: !rowItem.isHeader && rowItem.row.kind === "disable" ? "󰑓" : "󰆴"
                  tooltipText: !enabled ? (rowItem.isHeader ? "" : rowItem.row.lockedReason)
                               : (rowItem.row.kind === "disable" ? "Re-enable the default" : "Remove  ·  Del")
                  foreground: root.foreground
                  onClicked: root.askRemove(rowItem.row)
                }
              }

              // actions: defaults
              Row {
                visible: !rowItem.isHeader && rowItem.isDefault
                spacing: Style.spacing.sm
                opacity: rowItem.hot ? 1 : 0.55
                Button {
                  text: "Override"
                  visible: !rowItem.isHeader && rowItem.row.active
                  bordered: true
                  tooltipText: "Bind something else to this key"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.startNew(rowItem.row.keys)
                }
                Button {
                  text: "Disable"
                  visible: !rowItem.isHeader && rowItem.row.active
                  bordered: true
                  tooltipText: "Turn this default off"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.disableDefault(rowItem.row)
                }
                Button {
                  text: "Re-enable"
                  visible: rowItem.disabler !== null && rowItem.disabler.removable
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.askRemove(rowItem.disabler)
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.scanned && root.visibleRows.length === 0
            text: root.query !== "" ? "No shortcuts match “" + root.query + "”" : "No shortcuts yet — press N to add one"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        Text {
          Layout.fillWidth: true
          text: {
            if (root.errorText !== "") return root.errorText
            if (root.statusText !== "") return root.statusText
            return "↑↓ select · Enter edit · Del remove · N new · Tab switch list · / search · Ctrl+Z undo · Esc close"
          }
          color: root.errorText !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          wrapMode: Text.WordWrap
          maximumLineCount: 2
        }
      }

      // ------------------------------------------------------------ editor

      Rectangle {
        id: editorLayer
        anchors.fill: parent
        visible: root.editorOpen && root.draft !== null
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.75)
        radius: Style.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: root.closeEditor() }

        BorderSurface {
          id: editorCard
          anchors.centerIn: parent
          width: Math.min(Style.space(660), parent.width - Style.space(40))
          height: Math.min(parent.height - Style.space(30), form.implicitHeight + editorCard.contentTopInset + editorCard.contentBottomInset + Style.space(8))
          radius: Style.cornerRadius
          color: root.background
          borderSpec: Border.surfaceSpec("menu", "border", root.accent, Math.max(1, Style.space(2)))
          padding: Style.spacing.panelPadding

          MouseArea { anchors.fill: parent; onClicked: editorScope.forceActiveFocus() }

          FocusScope {
            id: editorScope
            anchors.fill: parent
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.closeEditor(); event.accepted = true }
              else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_S)) {
                root.saveDraft(); event.accepted = true
              }
            }

            Flickable {
              anchors.fill: parent
              anchors.topMargin: editorCard.contentTopInset
              anchors.rightMargin: editorCard.contentRightInset
              anchors.bottomMargin: editorCard.contentBottomInset
              anchors.leftMargin: editorCard.contentLeftInset
              contentHeight: form.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ColumnLayout {
                id: form
                width: parent.width
                spacing: Style.spacing.xl

                readonly property var spec: root.draft ? root.draft.spec : K.emptySpec("app")
                readonly property var combo: root.draft ? K.parseCombo(root.draft.keys) : { mods: [], key: "" }

                Text {
                  text: root.editRow ? "Edit shortcut" : "New shortcut"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                // ---- key
                Label { text: "Shortcut" }

                Rectangle {
                  id: recorder
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(58)
                  radius: Style.cornerRadius
                  color: root.recording ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : root.faint
                  border.width: root.recording || recorder.activeFocus ? 2 : 1
                  border.color: root.recording ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                  activeFocusOnTab: true

                  KeyCaps {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.xl
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !root.recording && form.combo.key !== ""
                    keys: root.draft ? root.draft.keys : ""
                    size: Style.font.title
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.xl
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.md
                    visible: root.recording || form.combo.key === ""
                    KeyCaps {
                      visible: root.recording && root.recordMods.length > 0
                      keys: K.formatCombo(root.recordMods, "")
                      size: Style.font.title
                      fg: root.accent
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.recording ? "Press the shortcut…  (Esc to cancel)" : "No key yet — record one, or pick below"
                      color: root.recording ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }

                  Button {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.recording ? "Cancel" : "Record"
                    iconText: root.recording ? "󰜺" : "󰑊"
                    bordered: true
                    selected: root.recording
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: {
                      root.recording = !root.recording
                      root.recordMods = []
                      if (root.recording) recorder.forceActiveFocus()
                      else editorScope.forceActiveFocus()
                    }
                  }

                  function modsOf(event) {
                    var m = []
                    if (event.modifiers & Qt.MetaModifier) m.push("SUPER")
                    if (event.modifiers & Qt.ShiftModifier) m.push("SHIFT")
                    if (event.modifiers & Qt.ControlModifier) m.push("CTRL")
                    if (event.modifiers & Qt.AltModifier) m.push("ALT")
                    return m
                  }

                  Keys.onPressed: function(event) {
                    if (!root.recording) {
                      if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                        root.recording = true; root.recordMods = []; event.accepted = true
                      }
                      return
                    }
                    event.accepted = true
                    if (K.isModifierKey(event.key)) { root.recordMods = modsOf(event); return }
                    if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
                      root.recording = false
                      editorScope.forceActiveFocus()
                      return
                    }
                    var key = K.keyFromEvent(event.key, event.text, event.nativeScanCode)
                    if (!key) return
                    root.setDraft({ keys: K.formatCombo(modsOf(event), key) })
                    root.recording = false
                    editorScope.forceActiveFocus()
                  }
                  Keys.onReleased: function(event) {
                    if (root.recording) { root.recordMods = modsOf(event); event.accepted = true }
                  }
                }

                Text {
                  Layout.fillWidth: true
                  visible: root.recording
                  wrapMode: Text.WordWrap
                  text: "Shortcuts Hyprland already uses (like Super + F) are caught by Hyprland before they reach this window. For those, pick the key below instead."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.sm

                  Repeater {
                    model: K.MODIFIERS
                    Button {
                      required property string modelData
                      text: modelData === "SUPER" ? "Super" : modelData.charAt(0) + modelData.slice(1).toLowerCase()
                      bordered: true
                      selected: form.combo.mods.indexOf(modelData) !== -1
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.toggleMod(modelData)
                    }
                  }

                  Text {
                    text: "+"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                  }

                  SearchableDropdown {
                    Layout.fillWidth: true
                    showLabel: false
                    value: form.combo.key
                    triggerLabel: form.combo.key === "" ? "Choose a key…" : ""
                    placeholderText: "Search keys…"
                    options: {
                      var o = K.KEY_OPTIONS.slice()
                      var k = form.combo.key
                      var known = false
                      for (var i = 0; i < o.length; i++) if (o[i].value.toLowerCase() === k.toLowerCase()) known = true
                      if (k && !known) o.unshift({ value: k, label: K.keyLabel(k), description: k })
                      return o
                    }
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onChanged: function(v) { root.setKey(v) }
                  }
                }

                TextField {
                  id: comboField
                  Layout.fillWidth: true
                  placeholderText: "…or type it, e.g. SUPER + SHIFT + E"
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: root.draft ? root.draft.keys : ""
                  onTextEdited: root.setDraft({ keys: text })
                }

                Text {
                  Layout.fillWidth: true
                  visible: root.draftConflicts.length > 0
                  wrapMode: Text.WordWrap
                  text: "󰀦  Already bound to " + root.conflictText(root.draftConflicts) + ". Saving replaces it (adds hl.unbind first)."
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // ---- description
                Label { text: "Name" }
                TextField {
                  Layout.fillWidth: true
                  placeholderText: root.draft && root.draftError === ""
                    ? K.summarize(form.spec, root.names).slice(0, 60)
                    : "Shown in the Super + K keybindings list"
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: root.draft ? root.draft.desc : ""
                  onTextEdited: root.setDraft({ desc: text })
                }

                // ---- action
                Label { text: "What it does" }
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  value: form.spec.type
                  options: {
                    var out = []
                    for (var i = 0; i < K.ACTION_TYPES.length; i++) {
                      var t = K.ACTION_TYPES[i]
                      if (!t.hidden) out.push({ value: t.value, label: t.icon + "   " + t.label })
                    }
                    return out
                  }
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setType(v) }
                }

                // app
                SearchableDropdown {
                  Layout.fillWidth: true
                  visible: form.spec.type === "app"
                  showLabel: false
                  value: form.spec.appId
                  triggerLabel: form.spec.appId === "" ? "Choose an app…" : ""
                  placeholderText: "Search apps…"
                  options: {
                    var o = root.appOptions.slice()
                    if (form.spec.appId && !root.appNames[form.spec.appId])
                      o.unshift({ value: form.spec.appId, label: form.spec.appId, description: "not installed?" })
                    return o
                  }
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setSpec({ appId: v, focusClass: "" }) }
                }

                // web app
                TextField {
                  Layout.fillWidth: true
                  visible: form.spec.type === "webapp"
                  placeholderText: "https://…"
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: form.spec.url || ""
                  onTextEdited: root.setSpec({ url: text })
                }

                Toggle {
                  Layout.fillWidth: true
                  visible: form.spec.type === "app" || form.spec.type === "webapp"
                  label: "Focus it if it's already open"
                  description: "Instead of opening another window"
                  checked: !!form.spec.focus
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.setSpec({ focus: !form.spec.focus })
                }

                // open
                TextField {
                  Layout.fillWidth: true
                  visible: form.spec.type === "open"
                  placeholderText: "https://… or ~/Documents or /path/to/file.pdf"
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: form.spec.target || ""
                  onTextEdited: root.setSpec({ target: text.replace(/^~(?=\/|$)/, root.home) })
                }

                // command
                TextField {
                  Layout.fillWidth: true
                  visible: form.spec.type === "command"
                  placeholderText: "notify-send \"Hello\""
                  foreground: root.foreground
                  accent: root.accent
                  font.family: "monospace"
                  text: form.spec.cmd || ""
                  onTextEdited: root.setSpec({ cmd: text })
                }
                ButtonGroup {
                  visible: form.spec.type === "command"
                  options: [
                    { value: "plain", label: "Run in background" },
                    { value: "terminal", label: "Run in a terminal" },
                    { value: "launch", label: "Launch as an app" }
                  ]
                  value: form.spec.mode || "plain"
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setSpec({ mode: v }) }
                }

                // type text
                TextField {
                  Layout.fillWidth: true
                  visible: form.spec.type === "type"
                  placeholderText: "Text to type into the focused window"
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: form.spec.text || ""
                  onTextEdited: root.setSpec({ text: text })
                }
                RowLayout {
                  visible: form.spec.type === "type"
                  Layout.fillWidth: true
                  spacing: Style.spacing.lg
                  Text {
                    text: "Wait before typing"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  ButtonGroup {
                    options: [
                      { value: "0", label: "none" }, { value: "150", label: "0.15 s" },
                      { value: "300", label: "0.3 s" }, { value: "600", label: "0.6 s" }
                    ]
                    value: String(form.spec.delay)
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onChanged: function(v) { root.setSpec({ delay: Number(v) }) }
                  }
                }
                Text {
                  Layout.fillWidth: true
                  visible: form.spec.type === "type"
                  wrapMode: Text.WordWrap
                  text: "Keys you're still holding (like Super) mix into typed text, so typing waits a moment for you to let go. Uses wtype."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // presets
                SearchableDropdown {
                  Layout.fillWidth: true
                  visible: ["window", "media", "capture", "system"].indexOf(form.spec.type) !== -1
                  showLabel: false
                  value: form.spec.preset || ""
                  placeholderText: "Search actions…"
                  options: {
                    var list = K.presetsFor(form.spec.type)
                    var out = []
                    for (var i = 0; i < list.length; i++) out.push({ value: list[i].value, label: list[i].label, description: list[i].cmd || list[i].expr.replace("%s", "N") })
                    return out
                  }
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setPreset(v) }
                }
                RowLayout {
                  readonly property var preset: K.findPreset(K.presetsFor(form.spec.type), form.spec.preset)
                  visible: form.spec.type === "window" && preset !== null && !!preset.param
                  Layout.fillWidth: true
                  spacing: Style.spacing.lg
                  Text {
                    text: "Workspace"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  TextField {
                    Layout.preferredWidth: Style.space(120)
                    placeholderText: "1–10 or name"
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    text: form.spec.param || ""
                    onTextEdited: root.setSpec({ param: text })
                  }
                }

                // plugin
                SearchableDropdown {
                  Layout.fillWidth: true
                  visible: form.spec.type === "plugin"
                  showLabel: false
                  value: form.spec.pluginId || ""
                  triggerLabel: form.spec.pluginId ? "" : "Choose a plugin…"
                  placeholderText: "Search plugins…"
                  options: {
                    var o = root.pluginOptions.slice()
                    var have = false
                    for (var i = 0; i < o.length; i++) if (o[i].value === form.spec.pluginId) have = true
                    if (form.spec.pluginId && !have) o.unshift({ value: form.spec.pluginId, label: form.spec.pluginId, description: "not installed or not enabled" })
                    return o
                  }
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setSpec({ pluginId: v }) }
                }

                // menu
                Dropdown {
                  Layout.fillWidth: true
                  visible: form.spec.type === "menu"
                  showLabel: false
                  value: form.spec.menu || ""
                  options: K.MENUS
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setSpec({ menu: v }) }
                }

                // toggle
                Dropdown {
                  Layout.fillWidth: true
                  visible: form.spec.type === "toggle"
                  showLabel: false
                  value: form.spec.toggle || ""
                  options: K.TOGGLES
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setSpec({ toggle: v }) }
                }

                // lua
                TextField {
                  Layout.fillWidth: true
                  visible: form.spec.type === "lua"
                  placeholderText: "hl.dsp.window.pin()"
                  foreground: root.foreground
                  accent: root.accent
                  font.family: "monospace"
                  text: form.spec.expr || ""
                  onTextEdited: root.setSpec({ expr: text })
                }

                Text {
                  Layout.fillWidth: true
                  visible: form.spec.type === "nothing"
                  wrapMode: Text.WordWrap
                  text: "The key is swallowed: neither Omarchy nor the focused app sees it."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // ---- options
                Label { text: "Options" }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.lg
                  Toggle {
                    Layout.fillWidth: true
                    label: "On lock screen"
                    description: "Works while locked"
                    checked: !!(root.draft && root.draft.locked)
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.setDraft({ locked: !root.draft.locked })
                  }
                  Toggle {
                    Layout.fillWidth: true
                    label: "Repeat"
                    description: "Fires again while held"
                    checked: !!(root.draft && root.draft.repeating)
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.setDraft({ repeating: !root.draft.repeating })
                  }
                  Toggle {
                    Layout.fillWidth: true
                    label: "On release"
                    description: "Fires when you let go"
                    checked: !!(root.draft && root.draft.release)
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.setDraft({ release: !root.draft.release })
                  }
                }

                // ---- preview
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: preview.implicitHeight + Style.spacing.lg * 2
                  radius: Style.cornerRadius
                  color: root.faint
                  Text {
                    id: preview
                    anchors.fill: parent
                    anchors.margins: Style.spacing.lg
                    text: root.draftError !== "" ? root.draftError : root.draftLua
                    color: root.draftError !== "" ? root.dim : root.foreground
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WrapAnywhere
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.lg
                  Item { Layout.fillWidth: true }
                  Button {
                    text: "Cancel"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.closeEditor()
                  }
                  Button {
                    text: root.editRow ? "Save" : "Add shortcut"
                    iconText: "󰄬"
                    bordered: true
                    selected: enabled
                    enabled: root.draftError === "" && !root.selfWrite
                    opacity: enabled ? 1 : 0.4
                    tooltipText: "Ctrl+Enter"
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.saveDraft()
                  }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        opened: root.confirmRow !== null
        message: root.confirmMessage
        confirmText: root.confirmRow && root.confirmRow.kind === "disable" ? "Re-enable" : "Remove"
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.confirmRow = null
        onConfirmed: {
          var r = root.confirmRow
          root.confirmRow = null
          if (r) root.removeRow(r)
        }
      }
    }
  }
}
