import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../VoxhudModel.js" as M

// Popup body: state + actions, recent takes, and the dictionary — everything
// Voxtype does to your words, read live from its config so what you see is
// what is there. Reads through the voxhud CLI (which parses voxtype's TOML)
// and writes through `voxtype config set/unset`, so the file keeps its
// comments.
Column {
  id: body

  property var svc: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool editing: fromField.activeFocus || toField.activeFocus || promptField.activeFocus
  // The CLI beside this file. A marketplace install has no `voxhud` on PATH
  // until setup has run — a bare name fails exactly when the setup banner is
  // needed — and the service only knows its own dir if the shell stamped the
  // manifest it was given. Resolve from here; the service's answer is the
  // fallback.
  readonly property string localCli: {
    var url = String(Qt.resolvedUrl("../bin/voxhud"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : ""
  }
  readonly property string cli: localCli !== "" ? localCli : (svc ? svc.cliPath : "voxhud")
  readonly property string phase: svc ? svc.phase : "idle"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/voxtype/config.toml"
  readonly property var builtinFillers: ["uh", "um", "er", "ah", "eh", "hmm", "hm", "mm", "mhm"]

  property var replacements: []
  property string initialPrompt: ""
  property bool filterFillers: true
  property var fillerWords: null
  property bool spokenPunctuation: false
  property bool loaded: false
  property bool busy: false
  property bool needsRestart: false
  property string error: ""

  // `omarchy plugin add` never runs plugin code, so a marketplace install lands
  // with Voxtype's own overlay still on: two overlays while you talk. The rest
  // of the setup is install.sh, and the banner below runs it on a click so the
  // config change is the user's decision, not the installer's. Keyed on the
  // symptom they can see; nothing shows until the list has loaded, and an
  // older CLI without the `setup` block simply never shows it.
  property bool voxtypeInstalled: true
  property bool osdEnabled: false
  property bool settingUp: false
  property bool setupFailed: false
  property bool setupDone: false
  readonly property bool setupPending: loaded && voxtypeInstalled && osdEnabled
  readonly property string setupLog: Quickshell.env("HOME") + "/.local/state/voxhud/setup.log"

  // For the "2 min ago" labels; ticks only while the popup is open.
  property double nowMs: Date.now()
  property int copiedIndex: -1
  readonly property var recent: svc && svc.recent ? svc.recent : []

  spacing: Style.space(12)

  Timer {
    interval: 10000
    repeat: true
    running: body.visible
    onTriggered: body.nowMs = Date.now()
  }

  Timer {
    id: copiedReset
    interval: 1400
    repeat: false
    onTriggered: body.copiedIndex = -1
  }

  // Watches the config until install.sh has turned the overlay off. ~30 s is
  // generous: the script restarts Voxtype and waits on the shell in between.
  Timer {
    id: setupPoll
    property int attempts: 0
    interval: 1500
    repeat: true
    onTriggered: {
      attempts += 1
      if (attempts > 20) {
        stop()
        body.settingUp = false
        body.setupFailed = true
        return
      }
      body.reload()
    }
  }

  Timer {
    id: setupDoneReset
    interval: 8000
    repeat: false
    onTriggered: body.setupDone = false
  }

  function copyRecent(index) {
    if (!svc || typeof svc.copyRecent !== "function") return
    if (svc.copyRecent(index)) {
      copiedIndex = index
      copiedReset.restart()
    }
  }

  function reload() {
    nowMs = Date.now()
    if (listProc.running) return
    listProc.running = true
  }

  function applyList(text) {
    var data
    try { data = JSON.parse(String(text || "{}")) } catch (e) { data = {} }
    replacements = M.sortedReplacements(data.replacements)
    initialPrompt = String(data.initial_prompt || "")
    filterFillers = data.filter_filler_words !== false
    fillerWords = Array.isArray(data.filler_words) ? data.filler_words : null
    spokenPunctuation = data.spoken_punctuation === true
    if (!promptField.activeFocus) promptField.text = initialPrompt
    var setup = data.setup && typeof data.setup === "object" ? data.setup : {}
    voxtypeInstalled = setup.voxtype_installed !== false
    osdEnabled = setup.osd_enabled === true
    loaded = true
    if (settingUp && !osdEnabled) {
      settingUp = false
      setupPoll.stop()
      setupDone = true
      setupDoneReset.restart()
    }
  }

  function finishSetup() {
    if (settingUp) return
    error = ""
    setupFailed = false
    setupDone = false
    settingUp = true
    // Detached on purpose: hiding Omarchy's indicator edits shell.json, which
    // reloads the bar and can take this popup down mid-run. The script has to
    // outlive us, and its output goes to a log the failure text points at.
    Quickshell.execDetached(["bash", "-c",
      'mkdir -p "$(dirname "$1")" && exec "$0" setup > "$1" 2>&1', cli, setupLog])
    setupPoll.attempts = 0
    setupPoll.start()
  }

  function run(argv, onDone) {
    if (mutateProc.running) return
    error = ""
    busy = true
    mutateProc.pendingDone = onDone
    mutateProc.command = argv
    mutateProc.running = true
  }

  // Not `add()`: Column already has an `add` transition property.
  function addReplacement() {
    var from = fromField.text.trim().toLowerCase()
    var to = toField.text.trim()
    var problem = M.validateFrom(from)
    if (problem === "") {
      if (to === "") problem = "Say what it should type instead."
    }
    if (problem !== "") { error = problem; return }
    run(["voxtype", "config", "set", "text.replacements." + from, to], function() {
      fromField.text = ""
      toField.text = ""
      body.needsRestart = true
      fromField.forceActiveFocus()
    })
  }

  function remove(from) {
    run(["voxtype", "config", "unset", "text.replacements." + from], function() {
      body.needsRestart = true
    })
  }

  function setFlag(key, value) {
    run(["voxtype", "config", "set", key, value ? "true" : "false"], function() {
      body.needsRestart = true
    })
  }

  function savePrompt() {
    var text = promptField.text.trim()
    var argv = text === ""
      ? ["voxtype", "config", "unset", "whisper.initial_prompt"]
      : ["voxtype", "config", "set", "whisper.initial_prompt", text]
    run(argv, function() { body.needsRestart = true })
  }

  function restart() {
    run(["systemctl", "--user", "restart", "voxtype.service"], function() {
      body.needsRestart = false
      if (body.svc && typeof body.svc.refreshBinds === "function") body.svc.refreshBinds()
    })
  }

  function openConfig() {
    Quickshell.execDetached(["omarchy-launch-config-editor", body.configPath])
  }

  function setSetting(key, value) {
    var registry = svc && svc.shell ? svc.shell.pluginRegistry : null
    if (registry && typeof registry.setBarWidget === "function")
      registry.setBarWidget("io.github.aashbury.voxhud", key, value)
  }

  Process {
    id: listProc
    command: [body.cli, "dictionary", "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: body.applyList(text)
    }
  }

  Process {
    id: mutateProc
    property var pendingDone: null
    stderr: StdioCollector { id: mutateErr }
    onExited: function(code) {
      body.busy = false
      var done = pendingDone
      pendingDone = null
      if (code === 0) {
        if (typeof done === "function") done()
      } else {
        var msg = String(mutateErr.text || "").trim().split("\n")[0]
        body.error = msg !== "" ? msg : "Command failed (" + code + ")"
      }
      body.reload()
    }
  }

  // ---------------------------------------------------------------- hero
  PanelHero {
    width: parent.width
    title: "Voxhud"
    meta: body.svc
      ? (body.phase === "idle" ? "dictation ready" : body.svc.label)
        + (body.svc.model ? " · " + body.svc.model : "")
      : "service not loaded"
    foreground: body.foreground
    fontFamily: body.fontFamily

    iconComponent: Component {
      Text {
        textFormat: Text.PlainText
        text: body.svc ? body.svc.glyph : "󰍬"
        color: body.phase === "listening" ? Color.bar.active : body.foreground
        font.family: body.fontFamily
        font.pixelSize: Style.font.display
      }
    }

    trailingControl: Component {
      ToggleSwitch {
        checked: body.svc ? body.svc.hudEnabled : false
        foreground: body.foreground
        onToggled: body.setSetting("hudEnabled", !checked)
      }
    }
  }

  // ---------------------------------------------------------------- setup
  BorderSurface {
    id: setupCard
    visible: body.setupPending || body.settingUp || body.setupFailed
    width: parent.width
    implicitHeight: setupContent.implicitHeight + Style.spacing.huge
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, body.foreground, Color.accent)
    borderSpec: Border.controlSpec("selected", body.foreground, Color.accent)

    Column {
      id: setupContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: setupCard.borderLeft + Style.spacing.rowPaddingX
      anchors.rightMargin: setupCard.borderRight + Style.spacing.rowPaddingX
      spacing: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "One more step"
        color: Color.accent
        font.family: body.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Voxtype's own overlay is still on, so you see two while you talk. "
          + "This turns it off, hides Omarchy's stock dictation icon (it disappears "
          + "mid-transcription) and puts the voxhud command on your PATH. "
          + "uninstall.sh puts all three back."
        color: body.dim
        font.family: body.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Button {
        text: body.settingUp ? "Setting up…" : "Finish setup"
        bordered: true
        foreground: Color.accent
        fontFamily: body.fontFamily
        fontSize: Style.font.bodySmall
        enabled: !body.settingUp
        onClicked: body.finishSetup()
      }

      Text {
        textFormat: Text.PlainText
        visible: body.setupFailed
        width: parent.width
        text: "Setup didn't finish. Details are in ~/.local/state/voxhud/setup.log, "
          + "or run install.sh from the plugin folder in a terminal."
        color: Color.urgent
        font.family: body.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // Actions live up here so they never scroll out of reach.
  Row {
    width: parent.width
    spacing: Style.space(6)

    Button {
      text: "Preview HUD"
      bordered: true
      foreground: body.foreground
      fontFamily: body.fontFamily
      fontSize: Style.font.bodySmall
      enabled: !!body.svc
      onClicked: if (body.svc) body.svc.demo("tour")
    }

    Button {
      text: "Restart Voxtype"
      visible: body.needsRestart
      bordered: true
      foreground: Color.accent
      fontFamily: body.fontFamily
      fontSize: Style.font.bodySmall
      enabled: !body.busy
      onClicked: body.restart()
    }

    Button {
      text: "Cancel take"
      visible: body.phase === "listening" || body.phase === "processing"
      bordered: true
      foreground: Color.urgent
      fontFamily: body.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: if (body.svc) body.svc.cancel()
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: body.setupDone
      ? "Setup finished — Voxtype's overlay is off and it has been restarted."
      : body.needsRestart
        ? "Voxtype reads its dictionary at start — restart it to use the changes."
        : "HUD " + (body.svc && body.svc.hudEnabled ? "on" : "off") + " · ✕ on the HUD or middle-click the icon cancels a take"
    color: body.setupDone || body.needsRestart ? Color.accent : body.dim
    font.family: body.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // ---------------------------------------------------------------- recent
  PanelSeparator { foreground: body.foreground }

  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      width: parent.width
      text: "RECENT"
      foreground: body.foreground
      fontFamily: body.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      visible: body.recent.length === 0
      width: parent.width
      text: "Your last three takes will show up here."
      color: body.dim
      font.family: body.fontFamily
      font.pixelSize: Style.font.body
    }

    Repeater {
      model: body.recent

      RecentRow {
        required property var modelData
        required property int index
        width: parent.width
        text: modelData.text
        when: M.relativeTime(modelData.at, body.nowMs)
        copied: body.copiedIndex === index
        foreground: body.foreground
        fontFamily: body.fontFamily
        onCopyRequested: body.copyRecent(index)
      }
    }
  }

  // ---------------------------------------------------------------- dictionary
  PanelSeparator { foreground: body.foreground }

  Column {
    width: parent.width
    spacing: Style.space(8)

    Item {
      width: parent.width
      implicitHeight: Math.max(dictHeader.implicitHeight, openButton.implicitHeight)

      PanelSectionHeader {
        id: dictHeader
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "DICTIONARY"
        foreground: body.foreground
        fontFamily: body.fontFamily
      }

      PanelActionButton {
        id: openButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰏫"
        tooltipText: "Open " + body.configPath + " in your editor"
        foreground: body.foreground
        fontFamily: body.fontFamily
        onClicked: body.openConfig()
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Everything Voxtype does to your words, live from its config. The pencil opens the file."
      color: body.dim
      font.family: body.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // -- replacements
    Text {
      textFormat: Text.PlainText
      width: parent.width
      topPadding: Style.space(4)
      text: "Replacements · " + body.replacements.length
      color: body.foreground
      font.family: body.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: (body.loaded && body.replacements.length === 0 ? "None yet. " : "") + "Hears the left side, types the right."
      color: body.dim
      font.family: body.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: body.replacements

      ReplacementRow {
        required property var modelData
        width: parent.width
        from: modelData.from
        to: modelData.to
        foreground: body.foreground
        fontFamily: body.fontFamily
        enabled: !body.busy
        onRemoveRequested: body.remove(modelData.from)
      }
    }

    Row {
      id: addRow
      width: parent.width
      spacing: Style.space(6)

      readonly property real fieldWidth: (width - spacing * 2 - addButton.implicitWidth) / 2

      TextField {
        id: fromField
        width: addRow.fieldWidth
        placeholderText: "heard as"
        foreground: body.foreground
        enabled: !body.busy
        onAccepted: toField.forceActiveFocus()
      }

      TextField {
        id: toField
        width: addRow.fieldWidth
        placeholderText: "typed as"
        foreground: body.foreground
        enabled: !body.busy
        onAccepted: body.addReplacement()
      }

      Button {
        id: addButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Add"
        bordered: true
        foreground: body.foreground
        fontFamily: body.fontFamily
        enabled: !body.busy
        onClicked: body.addReplacement()
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: body.error !== ""
      width: parent.width
      text: body.error
      color: Color.urgent
      font.family: body.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // -- built-in processing
    Toggle {
      width: parent.width
      label: "Drop filler words"
      description: (body.fillerWords ? body.fillerWords : body.builtinFillers).join(", ")
        + (body.fillerWords ? "" : "  (built-in list)")
      checked: body.filterFillers
      foreground: body.foreground
      fontFamily: body.fontFamily
      titleSize: Style.font.body
      enabled: !body.busy
      onClicked: body.setFlag("text.filter_filler_words", !body.filterFillers)
    }

    Toggle {
      width: parent.width
      label: "Spoken punctuation"
      description: "Say \"period\", \"comma\", \"new line\" and get the character."
      checked: body.spokenPunctuation
      foreground: body.foreground
      fontFamily: body.fontFamily
      titleSize: Style.font.body
      enabled: !body.busy
      onClicked: body.setFlag("text.spoken_punctuation", !body.spokenPunctuation)
    }

    // -- vocabulary hints
    Text {
      textFormat: Text.PlainText
      width: parent.width
      topPadding: Style.space(4)
      text: "Vocabulary hints"
      color: body.foreground
      font.family: body.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Names and jargon Whisper should expect, comma separated. A nudge, not a rule."
      color: body.dim
      font.family: body.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: promptField
        width: parent.width - parent.spacing - saveButton.implicitWidth
        placeholderText: "Omarchy, Hyprland, Voxtype…"
        foreground: body.foreground
        enabled: !body.busy
        onAccepted: body.savePrompt()
      }

      Button {
        id: saveButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Save"
        bordered: true
        foreground: body.foreground
        fontFamily: body.fontFamily
        enabled: !body.busy && promptField.text.trim() !== body.initialPrompt
        onClicked: body.savePrompt()
      }
    }
  }
}
