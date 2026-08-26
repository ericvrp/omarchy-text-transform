import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell.Io
import qs.Commons
import qs.Ui

// Text Transform: paste text, pick a transformation, get the result back.
//
// The transforming is done by whichever coding agent Omarchy is already set up
// with, through `bin/text-transform`. That is the whole design: someone who
// installs this has already picked an agent and is already paying for its
// tokens, so there is no API key to enter and no model to choose.
//
// Structured after the stock Basecamp plugin: a Panel root owning the
// open/close lifecycle, a BarIconButton for the bar, and a KeyboardPanel for
// the popup. KeyboardPanel matters specifically because PopupCard is a
// PopupWindow, which never receives keyboard focus on Wayland, so a text field
// inside one can be clicked but not typed into — and this panel is two text
// fields and little else.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.text-transform"
  ipcTarget: "jankeesvw.text-transform"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/text-transform").toString().replace(/^file:\/\//, "")

  readonly property string iconWand: "\uF0EC"
  readonly property string iconRun: "\uF063"
  readonly property string iconCopy: "\uF0C5"
  readonly property string iconSettings: "\uF013"
  readonly property string iconAdd: "\uF067"
  readonly property string iconRemove: "\uF1F8"
  readonly property string iconDone: "\uF00C"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // [{ name, prompt }], as the script hands them over.
  property var transformations: []
  property int selectedIndex: 0
  property string inputText: ""
  property string outputText: ""
  property string errorText: ""
  property bool busy: false
  property bool copied: false
  // A result that landed while the panel was closed, so the bar can say so.
  property bool resultWaiting: false

  // Which agent is going to do the work, so the panel can name it and say so
  // when there is nothing to do the work with.
  property string agentLabel: ""
  property bool agentReady: false
  property string agentProblem: ""

  // The settings view replaces the main view in the same card rather than
  // opening a second one: it edits the list the main view selects from, and
  // two surfaces for one thing is one too many.
  property bool settingsOpen: false

  readonly property var currentTransformation:
    selectedIndex >= 0 && selectedIndex < transformations.length
      ? transformations[selectedIndex]
      : null

  readonly property bool canRun:
    agentReady && !busy && currentTransformation !== null
    && inputText.trim().length > 0

  // Options in the shape Dropdown wants: the index is the value, so two
  // transformations that happen to share a name still select apart.
  readonly property var dropdownOptions: {
    var out = []
    for (var i = 0; i < transformations.length; i++) {
      out.push({ value: String(i), label: String(transformations[i].name) })
    }
    return out
  }

  // Panel is a bare Item, so it has no size of its own and the bar would give
  // the widget zero width. Set it here, never from a child that fills this
  // item: that is a loop where nothing decides the size and everything
  // collapses to zero.
  readonly property int barSlot: Style.bar.iconFont + Style.space(14)
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // Strip the markup characters out of anything the agent produced before it
  // reaches a Text element the shell owns. Ours are all PlainText, but the
  // shared bar tooltip is the shell's component and its textFormat is not
  // ours to set.
  function plain(value) {
    return String(value || "").replace(/[<>]/g, "")
  }

  function refreshAgent() {
    if (!agentProc.running) agentProc.running = true
  }

  function loadTransformations() {
    if (!listProc.running) listProc.running = true
  }

  function applyTransformations(list) {
    var wanted = currentTransformation ? currentTransformation.name : ""
    transformations = list

    // Keep the selection on the same transformation across a reload, since
    // editing the list in settings rebuilds it wholesale.
    selectedIndex = 0
    if (wanted !== "") {
      for (var i = 0; i < list.length; i++) {
        if (String(list[i].name) === wanted) {
          selectedIndex = i
          break
        }
      }
    }
  }

  function runTransform() {
    if (!canRun) return
    errorText = ""
    outputText = ""
    copied = false
    busy = true
    runProc.request = JSON.stringify({
      text: inputText,
      prompt: String(currentTransformation.prompt)
    })
    runProc.running = true
  }

  function copyOutput() {
    if (outputText === "") return
    copyProc.payload = outputText
    copyProc.running = true
    copied = true
    copiedTimer.restart()
  }

  // Settings edit a copy, so abandoning them by closing the panel leaves the
  // saved list alone.
  //
  // A ListModel rather than a JavaScript array, because the rows write back
  // into it on every keystroke: replacing an array reassigns the Repeater's
  // model, which rebuilds every delegate mid-word and is a binding loop
  // besides. setProperty touches one field and leaves the rows standing.
  function openSettings() {
    draft.clear()
    for (var i = 0; i < transformations.length; i++) {
      draft.append({ name: String(transformations[i].name),
                     prompt: String(transformations[i].prompt) })
    }
    settingsOpen = true
  }

  function updateDraft(index, field, value) {
    if (index < 0 || index >= draft.count) return
    if (String(draft.get(index)[field]) === String(value)) return
    draft.setProperty(index, field, String(value))
  }

  function addDraft() {
    draft.append({ name: "New transformation", prompt: "" })
  }

  function removeDraft(index) {
    if (index < 0 || index >= draft.count) return
    draft.remove(index)
  }

  function saveSettings() {
    settingsOpen = false
    var list = []
    for (var i = 0; i < draft.count; i++) {
      var item = draft.get(i)
      list.push({ name: String(item.name), prompt: String(item.prompt) })
    }
    saveProc.request = JSON.stringify({ transformations: list })
    saveProc.running = true
  }

  // Panel's own close() is what actually hides the card, so this override has
  // to end by calling it: replacing it outright leaves Escape, the bar button
  // and `omarchy-shell shell hide` all doing nothing but tidying up.
  //
  // Whatever is running keeps running. A transform takes seconds and there is
  // no reason to sit and watch it — the bar shows it is working and says so
  // again when the answer lands.
  function close() {
    // Leaving settings half-edited would lose the edits silently, so closing
    // the panel commits them the same way the done button does.
    if (settingsOpen) saveSettings()
    dropdown.close()
    errorText = ""
    controller.hide()
  }

  Process {
    id: agentProc
    command: [root.script, "agent"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload
        try { payload = JSON.parse(text) } catch (e) { return }
        if (!payload || payload.ok !== true) return

        root.agentReady = payload.ready === true
        root.agentLabel = String(payload.label || "")

        if (root.agentReady) {
          root.agentProblem = ""
        } else if (payload.reason === "unset") {
          root.agentProblem = "No default agent yet. Pick one with: omarchy default agent"
        } else if (payload.reason === "missing") {
          root.agentProblem = root.agentLabel + " is not installed"
        } else if (payload.reason === "unsupported") {
          root.agentProblem = "This plugin cannot drive " + root.agentLabel + " without a terminal"
        } else {
          root.agentProblem = String(payload.reason || "The default agent is not ready")
        }
      }
    }
  }

  Process {
    id: listProc
    command: [root.script, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload
        try { payload = JSON.parse(text) } catch (e) { return }
        if (!payload || payload.ok !== true) return
        root.applyTransformations(payload.transformations || [])
      }
    }
  }

  // The text being transformed goes in over stdin, never argv, so it stays out
  // of /proc/PID/cmdline where any account on the machine could read it.
  Process {
    id: runProc
    property string request: ""
    command: [root.script, "run"]
    stdinEnabled: true
    onStarted: {
      write(request)
      request = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.errorText = "Could not read the answer"
          return
        }
        if (payload && payload.ok === true) {
          root.outputText = String(payload.output || "")
          root.errorText = ""
        } else {
          root.errorText = String((payload && payload.error) || "Something went wrong")
        }

        // The run outlives the panel on purpose, so a result can arrive with
        // nobody looking. Say so, without putting the text in a notification
        // that lands on a lock screen.
        if (!root.opened) {
          root.resultWaiting = true
          notifyProc.command = ["notify-send", "--app-name=Text Transform",
                                "--icon=accessories-text-editor", "--",
                                payload && payload.ok === true
                                  ? "Text Transform" : "Text Transform failed",
                                payload && payload.ok === true
                                  ? "Your text is ready in the panel."
                                  : "Open the panel to see what went wrong."]
          notifyProc.running = true
        }
      }
    }
    onExited: root.busy = false
  }

  Process {
    id: saveProc
    property string request: ""
    command: [root.script, "save"]
    stdinEnabled: true
    onStarted: {
      write(request)
      request = ""
      stdinEnabled = false
    }
    onExited: root.loadTransformations()
  }

  // wl-copy takes the text on stdin for the same reason the script does.
  Process {
    id: copyProc
    property string payload: ""
    command: ["wl-copy"]
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
  }

  Process { id: notifyProc }

  ListModel { id: draft }

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copied = false
  }

  Component.onCompleted: {
    refreshAgent()
    loadTransformations()
  }

  // The default agent can change while the shell runs, and a panel that still
  // names the old one is worse than one that says nothing.
  onOpenedChanged: {
    if (opened) {
      refreshAgent()
      resultWaiting = false
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    tooltipText: {
      if (root.busy) return "Text Transform · working"
      if (root.resultWaiting) return "Text Transform · result ready"
      if (root.agentReady && root.agentLabel !== "")
        return "Text Transform · " + root.plain(root.agentLabel)
      return "Text Transform"
    }
    onPressed: function(b) { root.toggle() }

    // A transform runs for seconds and keeps running with the panel shut, so
    // the bar has to carry that state: there is nowhere else to see it.
    iconComponent: Component {
      Item {
        Text {
          id: barGlyph
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.iconWand
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          color: root.busy || root.resultWaiting || root.opened
            ? root.accent
            : root.foreground

          SequentialAnimation on opacity {
            running: root.busy
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Focus lands in the input box, so the panel opens ready to paste.
    focusTarget: inputField

    // Plain property reads rather than fittedContentWidth, which is evaluated
    // once on open and would not follow a panel that resizes while it is up.
    readonly property int desiredWidth: Style.space(420)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a field or the dropdown owns the keys, the panel's own shortcuts
      // stay out of the way, or typing would drive them.
      blocked: inputField.activeFocus || outputField.activeFocus
               || dropdown.popupOpen || root.settingsOpen
      onCloseRequested: root.close()

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // --- header ---------------------------------------------------------

        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, settingsButton.height)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.settingsOpen ? "Transformations" : "Text Transform"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.settingsOpen && root.agentLabel !== ""
            textFormat: Text.PlainText
            text: root.agentLabel
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            id: settingsButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: true
            iconText: root.settingsOpen ? root.iconDone : root.iconSettings
            tooltipText: root.settingsOpen ? "Done" : "Edit transformations"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.settingsOpen ? root.saveSettings() : root.openSettings()
          }
        }

        // --- main view ------------------------------------------------------

        // Input. One box you can paste a paragraph into; Ctrl+Enter runs it,
        // because plain Enter has to stay a line break in text this long.
        Rectangle {
          visible: !root.settingsOpen
          width: parent.width
          height: Style.space(120)
          radius: Style.cornerRadius
          color: Style.controlFill(inputField.activeFocus, false, root.foreground, root.accent)
          border.width: 1
          border.color: inputField.activeFocus
            ? root.accent
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

          ScrollView {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            clip: true

            TextArea {
              id: inputField
              text: root.inputText
              onTextChanged: root.inputText = text
              wrapMode: TextArea.Wrap
              textFormat: TextEdit.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, root.accent)
              selectedTextColor: root.foreground
              placeholderText: "Paste or type the text here"
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              background: null

              Keys.onPressed: function(event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    && (event.modifiers & Qt.ControlModifier)) {
                  root.runTransform()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  // A TextArea would otherwise insert a literal tab, and this
                  // is a form: Tab has to walk to the next control.
                  inputField.nextItemInFocusChain(event.key === Qt.Key_Tab).forceActiveFocus()
                  event.accepted = true
                }
              }
            }
          }
        }

        // Transformation and the button that fires it. The arrow points down
        // because that is where the answer lands.
        Item {
          visible: !root.settingsOpen
          width: parent.width
          height: Math.max(dropdown.height, runButton.height)

          Dropdown {
            id: dropdown
            anchors.left: parent.left
            anchors.right: runButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            showLabel: false
            options: root.dropdownOptions
            value: String(root.selectedIndex)
            fontFamily: root.fontFamily
            onChanged: function(value) { root.selectedIndex = parseInt(value) }
          }

          PanelActionButton {
            id: runButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: true
            enabled: root.canRun
            size: Style.spacing.controlHeight
            iconText: root.iconRun
            tooltipText: root.busy ? "Working" : "Transform (Ctrl+Enter)"
            foreground: root.busy ? root.accent : root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.runTransform()
          }
        }

        // Output. Selectable and read-only: it is an answer, not a draft, and
        // editing it here would be lost the moment the next run lands.
        Rectangle {
          visible: !root.settingsOpen
          width: parent.width
          height: Style.space(140)
          radius: Style.cornerRadius
          color: Style.controlFill(outputField.activeFocus, false, root.foreground, root.accent)
          border.width: 1
          border.color: outputField.activeFocus
            ? root.accent
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

          ScrollView {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            anchors.bottomMargin: Style.space(30)
            clip: true

            TextArea {
              id: outputField
              text: root.outputText
              readOnly: true
              wrapMode: TextArea.Wrap
              // The agent wrote this, so it is displayed as plain text and
              // never as markup: rich text would fetch <img src="http://..">
              // from whatever host it named.
              textFormat: TextEdit.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, root.accent)
              selectedTextColor: root.foreground
              placeholderText: root.busy ? "" : "The result appears here"
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              background: null

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.close()
                  event.accepted = true
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            visible: root.busy
            spacing: Style.space(10)

            Item {
              id: spinner
              width: Style.space(26)
              height: width
              anchors.horizontalCenter: parent.horizontalCenter

              Shape {
                anchors.fill: parent
                antialiasing: true
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                  strokeColor: root.accent
                  strokeWidth: 2
                  fillColor: "transparent"
                  capStyle: ShapePath.RoundCap

                  PathAngleArc {
                    centerX: spinner.width / 2
                    centerY: spinner.height / 2
                    radiusX: spinner.width / 2 - 2
                    radiusY: spinner.height / 2 - 2
                    startAngle: 0
                    sweepAngle: 280
                  }
                }
              }

              RotationAnimator on rotation {
                running: root.busy && root.opened
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.agentLabel !== "" ? root.plain(root.agentLabel) + " is working" : "Working"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "You can close this and carry on"
              color: Qt.darker(root.foreground, 1.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(7)
            visible: root.copied
            textFormat: Text.PlainText
            text: "Copied"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            focusable: true
            enabled: root.outputText !== ""
            iconText: root.iconCopy
            tooltipText: "Copy"
            foreground: root.copied ? root.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.copyOutput()
          }
        }

        // One strip for whatever went wrong, which is nearly always the agent
        // saying it is not logged in or out of quota. Worth passing on
        // verbatim: it is the only thing that tells someone what to fix.
        Text {
          visible: !root.settingsOpen && (root.errorText !== "" || root.agentProblem !== "")
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorText !== "" ? root.errorText : root.agentProblem
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // --- settings view ---------------------------------------------------

        Text {
          visible: root.settingsOpen
          width: parent.width
          textFormat: Text.PlainText
          text: "The name is what the dropdown shows. The prompt is what the agent is told to do with your text."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        ScrollView {
          visible: root.settingsOpen
          width: parent.width
          height: Style.space(360)
          clip: true

          Column {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: draft

              delegate: Rectangle {
                id: draftRow
                required property int index
                required property string name
                required property string prompt

                width: parent.width
                height: rowContent.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: Style.normalFill
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Column {
                  id: rowContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(6)
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    height: Style.spacing.controlHeight

                    TextField {
                      id: nameField
                      anchors.left: parent.left
                      anchors.right: removeButton.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: draftRow.name
                      placeholderText: "Name"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      onTextChanged: root.updateDraft(draftRow.index, "name", text)
                    }

                    PanelActionButton {
                      id: removeButton
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      focusable: true
                      iconText: root.iconRemove
                      tooltipText: "Remove"
                      foreground: root.foreground
                      hoverColor: Color.urgent
                      fontFamily: root.fontFamily
                      onClicked: root.removeDraft(draftRow.index)
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(64)
                    radius: Style.cornerRadius
                    color: Style.controlFill(promptField.activeFocus, false, root.foreground, root.accent)
                    border.width: 1
                    border.color: promptField.activeFocus
                      ? root.accent
                      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

                    ScrollView {
                      anchors.fill: parent
                      anchors.margins: Style.space(5)
                      clip: true

                      TextArea {
                        id: promptField
                        text: draftRow.prompt
                        onTextChanged: root.updateDraft(draftRow.index, "prompt", text)
                        wrapMode: TextArea.Wrap
                        textFormat: TextEdit.PlainText
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        color: root.foreground
                        selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                        selectedTextColor: root.foreground
                        placeholderText: "What should the agent do with the text?"
                        placeholderTextColor: Qt.darker(root.foreground, 1.6)
                        background: null

                        Keys.onPressed: function(event) {
                          if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            promptField.nextItemInFocusChain(event.key === Qt.Key_Tab).forceActiveFocus()
                            event.accepted = true
                          } else if (event.key === Qt.Key_Escape) {
                            root.close()
                            event.accepted = true
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Item {
          visible: root.settingsOpen
          width: parent.width
          height: addButton.height

          PanelActionButton {
            id: addButton
            anchors.left: parent.left
            focusable: true
            iconText: root.iconAdd
            tooltipText: "Add a transformation"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.addDraft()
          }

          Text {
            anchors.left: addButton.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: addButton.verticalCenter
            textFormat: Text.PlainText
            text: "Add"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
