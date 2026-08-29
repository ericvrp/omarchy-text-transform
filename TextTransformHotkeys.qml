import QtQuick
import Quickshell
import Quickshell.Hyprland

Item {
  id: root

  readonly property string bindingKeys: "SUPER + ALT + V"
  readonly property string bindingDescription: "Transform selection"
  readonly property string bindingCommand:
    "omarchy-shell jankeesvw.text-transform transformSelection"

  function luaString(value) {
    return '"' + String(value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"') + '"'
  }

  function registerBinding() {
    // This service is loaded once even when the bar is shown on multiple monitors.
    var code = "hl.unbind(" + root.luaString(root.bindingKeys) + "); o.bind("
      + root.luaString(root.bindingKeys) + ", "
      + root.luaString(root.bindingDescription) + ", "
      + root.luaString(root.bindingCommand) + ")"
    Quickshell.execDetached(["hyprctl", "repl", code])
  }

  function unregisterBinding() {
    Quickshell.execDetached(["hyprctl", "repl",
      "hl.unbind(" + root.luaString(root.bindingKeys) + ")"])
  }

  Component.onCompleted: Qt.callLater(root.registerBinding)
  Component.onDestruction: root.unregisterBinding()

  // Dynamic bindings disappear when Hyprland reloads its Lua config.
  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!event || String(event.name || "") !== "configreloaded") return
      Qt.callLater(root.registerBinding)
    }
  }
}
