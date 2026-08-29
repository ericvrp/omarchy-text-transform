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
  readonly property string clipboardPasteKeys: "SUPER + ALT + V"
  readonly property string clipboardPasteDescription: "Transform clipboard and paste"
  readonly property string clipboardPasteCommand:
    "omarchy-shell jankeesvw.text-transform transformClipboardAndPaste"

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

  function registerBindings() {
    // This service is loaded once even when the bar is shown on multiple monitors.
    var code = root.bindCode(root.panelKeys, root.panelDescription, root.panelCommand) + "; "
      + root.bindCode(root.clipboardKeys, root.clipboardDescription, root.clipboardCommand) + "; "
      + root.bindCode(root.clipboardPasteKeys, root.clipboardPasteDescription,
                      root.clipboardPasteCommand)
    Quickshell.execDetached(["hyprctl", "repl", code])
  }

  function unregisterBindings() {
    Quickshell.execDetached(["hyprctl", "repl",
      "hl.unbind(" + root.luaString(root.panelKeys) + "); hl.unbind("
        + root.luaString(root.clipboardKeys) + "); hl.unbind("
        + root.luaString(root.clipboardPasteKeys) + ")"])
  }

  Component.onCompleted: Qt.callLater(root.registerBindings)
  Component.onDestruction: root.unregisterBindings()

  // Dynamic bindings disappear when Hyprland reloads its Lua config.
  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!event || String(event.name || "") !== "configreloaded") return
      Qt.callLater(root.registerBindings)
    }
  }
}
