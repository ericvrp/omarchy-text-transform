import QtQuick
import Quickshell
import Quickshell.Hyprland

Item {
  id: root

  readonly property string panelKeys: "SUPER + SHIFT + T"
  readonly property string panelDescription: "Text Transform panel"
  readonly property string panelCommand:
    "omarchy-shell shell toggle jankeesvw.text-transform"
  readonly property string clipboardKeys: "SUPER + SHIFT + V"
  readonly property string clipboardDescription: "Transform clipboard"
  readonly property string clipboardCommand:
    "omarchy-shell jankeesvw.text-transform transformClipboard"
  readonly property string legacySelectionKeys: "SUPER + ALT + V"

  function luaString(value) {
    return '"' + String(value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"') + '"'
  }

  function bindCode(keys, description, command) {
    return "hl.unbind(" + root.luaString(keys) + "); o.bind("
      + root.luaString(keys) + ", "
      + root.luaString(description) + ", "
      + root.luaString(command) + ")"
  }

  function registerBindings(clearLegacy) {
    // This service is loaded once even when the bar is shown on multiple monitors.
    var code = (clearLegacy
      ? "hl.unbind(" + root.luaString(root.legacySelectionKeys) + "); "
      : "")
      + root.bindCode(root.panelKeys, root.panelDescription, root.panelCommand) + "; "
      + root.bindCode(root.clipboardKeys, root.clipboardDescription, root.clipboardCommand)
    Quickshell.execDetached(["hyprctl", "repl", code])
  }

  function unregisterBindings() {
    Quickshell.execDetached(["hyprctl", "repl",
      "hl.unbind(" + root.luaString(root.panelKeys) + "); hl.unbind("
        + root.luaString(root.clipboardKeys) + ")"])
  }

  Component.onCompleted: Qt.callLater(function() { root.registerBindings(true) })
  Component.onDestruction: root.unregisterBindings()

  // Dynamic bindings disappear when Hyprland reloads its Lua config.
  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!event || String(event.name || "") !== "configreloaded") return
      Qt.callLater(function() { root.registerBindings(false) })
    }
  }
}
