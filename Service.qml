import QtQuick
import Quickshell

// Keeps keysmith.desktop in ~/.local/share/applications while the plugin is
// enabled, so Keysmith shows up in the SUPER+SPACE search. Omarchy has no
// enable/disable hook, but it runs a plugin's service only while the plugin
// is enabled, so this service does the job.
//
// Only a file carrying the X-Keysmith-Managed marker is ever overwritten or
// deleted; a hand-made keysmith.desktop without it is left alone.
QtObject {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  // Omarchy 4.0.3+ strips __sourceDir from third-party manifests.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string source: pluginDir + "/keysmith.desktop"
  readonly property string dest: Quickshell.env("HOME") + "/.local/share/applications/keysmith.desktop"
  readonly property string marker: "^X-Keysmith-Managed=true$"

  // The temp file is created by mktemp (O_EXCL, random name) in the
  // destination directory, so no pre-existing file or symlink is ever written
  // through, and mv replaces the entry atomically without following a link.
  readonly property string installScript:
      '[ -f "$1" ] || exit 0\n'
    + 'if [ -e "$2" ] && ! grep -q "$3" "$2"; then exit 0; fi\n'
    + 'mkdir -p "${2%/*}" || exit 0\n'
    + 'if cmp -s "$1" "$2"; then exit 0; fi\n'
    + 'tmp=$(mktemp "${2%/*}/.keysmith.desktop.XXXXXXXX") || exit 0\n'
    + 'if cat "$1" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$2"; then exit 0; fi\n'
    + 'rm -f "$tmp"\n'

  readonly property string removeScript:
    'grep -q "$2" "$1" 2>/dev/null && rm -f "$1"\n'

  Component.onCompleted: {
    Quickshell.execDetached(["sh", "-c", installScript, "sh", source, dest, marker])
  }

  // The shell destroys services on disable and remove, but also when it
  // reloads plugins or exits. The registry's enabled flag is updated before a
  // disable tears us down, so only remove the entry when it says we are off.
  Component.onDestruction: {
    if (root.pluginRegistry && root.pluginRegistry.enabled) return
    Quickshell.execDetached(["sh", "-c", removeScript, "sh", dest, marker])
  }
}
