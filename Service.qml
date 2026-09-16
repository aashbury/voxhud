import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "VoxhudModel.js" as M

// The one long-lived piece of voxhud. Follows the Voxtype daemon, keeps the
// phase machine, reads mic levels while listening, discovers the live key
// bindings for the legend, and owns the "voxhud" IPC target. The HUD panel
// and the bar widget only read from here.
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string cliPath: pluginDir !== "" ? pluginDir + "/bin/voxhud" : "voxhud"
  readonly property string runtimeDir: {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    return dir && dir !== "" ? dir : "/tmp"
  }

  // ---------------------------------------------------------------- settings
  // Settings live on the widget's inline shell.json entry; the shell only hands
  // them to bar widgets, so the service reads the config directly. Re-evaluates
  // whenever shell.json changes.
  readonly property var cfg: M.mergeSettings(M.findEntry(shell ? shell.shellConfig : null, "io.github.aashbury.voxhud"))
  readonly property bool hudEnabled: cfg.hudEnabled === true
  readonly property string position: String(cfg.position)
  readonly property string meter: String(cfg.meter)
  readonly property bool brackets: cfg.brackets === true
  readonly property bool showLegend: cfg.showLegend === true
  readonly property bool showTarget: cfg.showTarget === true
  readonly property int barCount: cfg.barCount
  readonly property int doneHoldMs: cfg.doneHoldMs

  // ---------------------------------------------------------------- state
  property string daemonState: "idle"
  property bool daemonAvailable: true
  property bool streamSeen: false
  property string model: ""
  property string backend: ""

  property string phase: "idle"
  property string reason: ""
  property bool hudVisible: false
  property bool cancelRequested: false
  property bool demoActive: false
  property int demoStep: 0
  property double startedAt: 0
  property int elapsedMs: 0
  property int maxDurationSecs: 60
  property string target: ""

  property var binds: M.emptyBinds()
  property var levels: M.emptyLevels(24)
  property real peakHold: 0
  property real rms: 0
  property real peak: 0
  property bool vad: false
  property bool bridgeConnected: false
  // Input saturated recently. Held ~350 ms so a single hot frame reads.
  property bool clipping: false
  property double clipUntil: 0
  // Running noise floor (rms) for the current take.
  property real floorRms: 0
  // voxhud's own 16 ms meter (bin/voxhud-levels). Preferred over the daemon's
  // socket, whose rms is windowed and lags the start of a take.
  property real meterRms: 0
  property real meterPeak: 0
  property double meterSeenAt: 0

  readonly property string label: M.labelFor(phase, reason)
  readonly property string glyph: M.glyphFor(phase)
  readonly property string barsMode: M.barsMode(phase)
  readonly property int remainingSecs: Math.max(0, maxDurationSecs - Math.floor(elapsedMs / 1000))
  readonly property string legend: M.legendFor(binds, phase, target, { showLegend: showLegend, showTarget: showTarget })
  readonly property string tooltip: M.tooltipFor(phase, reason, elapsedMs, model, backend, daemonAvailable)
  readonly property bool wantBridge: hudEnabled && daemonAvailable

  // ---------------------------------------------------------------- daemon
  function applyStatusJson(line) {
    var parsed = M.parseStatusLine(line)
    if (!parsed) return
    daemonAvailable = parsed.available
    if (parsed.model !== "") model = parsed.model
    if (parsed.backend !== "") backend = parsed.backend
    applyDaemonState(parsed.state)
  }

  function applyDaemonState(raw) {
    var next = M.normalizeDaemonState(raw)
    if (next === daemonState) return
    var prev = daemonState
    daemonState = next
    if (demoActive) {
      demoActive = false
      demoTimer.stop()
    }
    var t = M.transition(prev, next, {
      cancelRequested: cancelRequested,
      elapsedMs: elapsedMs,
      tooShortMs: cfg.tooShortMs
    })
    if (t) enterPhase(t.phase, t.reason)
  }

  function enterPhase(nextPhase, nextReason) {
    holdTimer.stop()
    phaseResetTimer.stop()
    phase = nextPhase
    reason = nextReason || ""
    if (nextPhase === "listening") {
      startedAt = Date.now()
      elapsedMs = 0
      cancelRequested = false
      target = ""
      levels = M.emptyLevels(barCount)
      peakHold = 0
      clipping = false
      clipUntil = 0
      floorRms = 0
      meterSeenAt = 0
      hudVisible = true
      refreshBinds()
    } else if (nextPhase === "processing") {
      target = M.targetLabel(ToplevelManager.activeToplevel)
      hudVisible = true
    } else if (nextPhase === "done" || nextPhase === "cancelled") {
      if (nextPhase === "done") lastDoneAt = Date.now()
      hudVisible = true
      holdTimer.interval = doneHoldMs
      holdTimer.restart()
    } else {
      hudVisible = false
    }
  }

  function cancel() {
    if (phase !== "listening" && phase !== "processing") return
    cancelRequested = true
    if (demoActive) {
      demoTimer.stop()
      enterPhase("cancelled", "cancel")
      return
    }
    Quickshell.execDetached(["voxtype", "record", "cancel"])
  }

  function refreshBinds() {
    if (!bindsProc.running) bindsProc.running = true
  }

  // ---------------------------------------------------------------- demo
  readonly property var tourSteps: [["listening", 3500], ["processing", 2200], ["done", 0]]

  function demo(state) {
    var want = String(state || "").trim().toLowerCase()
    demoTimer.stop()
    if (want === "off" || want === "") {
      demoActive = false
      enterPhase("idle", "")
      return
    }
    demoActive = true
    if (want === "tour") {
      demoStep = 0
      runDemoStep()
      return
    }
    var map = {
      recording: "listening", listening: "listening",
      processing: "processing", transcribing: "processing",
      done: "done", inserted: "done",
      cancelled: "cancelled", canceled: "cancelled"
    }
    var p = map[want]
    if (!p) {
      demoActive = false
      return
    }
    enterPhase(p, p === "cancelled" ? "cancel" : "")
  }

  function runDemoStep() {
    if (!demoActive || demoStep >= tourSteps.length) return
    var step = tourSteps[demoStep]
    enterPhase(step[0], "")
    if (step[1] > 0) {
      demoTimer.interval = step[1]
      demoTimer.restart()
    }
  }

  Timer {
    id: demoTimer
    repeat: false
    onTriggered: {
      service.demoStep += 1
      service.runDemoStep()
    }
  }

  // ---------------------------------------------------------------- timers
  Timer {
    id: holdTimer
    repeat: false
    onTriggered: {
      service.hudVisible = false
      phaseResetTimer.restart()
    }
  }

  // Lets the 140 ms fade finish before the label changes underneath it.
  Timer {
    id: phaseResetTimer
    interval: 220
    repeat: false
    onTriggered: {
      if (service.hudVisible) return
      if (service.phase === "done" || service.phase === "cancelled") {
        service.phase = "idle"
        service.reason = ""
        service.cancelRequested = false
      }
      if (service.demoActive && service.demoStep >= service.tourSteps.length - 1) service.demoActive = false
    }
  }

  Timer {
    interval: 100
    repeat: true
    running: service.phase === "listening"
    onTriggered: service.elapsedMs = Date.now() - service.startedAt
  }

  // 60 fps sampling of the 100 Hz frame stream; the bars tween between
  // samples, so motion is continuous rather than stepped.
  property int levelTick: 0

  Timer {
    interval: 16
    repeat: true
    running: service.phase === "listening"
    onTriggered: {
      var now = Date.now()
      var target
      if (service.demoActive) {
        target = M.syntheticLevel(now)
      } else {
        // Our meter needs ~0.3 s to open the mic. Until then show quiet
        // rather than the daemon's socket, whose start-of-take rms is
        // inflated by the input's DC settling; fall back to the socket only
        // if the meter never turns up.
        var fresh = now - service.meterSeenAt < 250
        var useSocket = !fresh && now - service.startedAt > 1500
        var r = fresh ? service.meterRms : (useSocket ? service.rms : 0)
        var p = fresh ? service.meterPeak : (useSocket ? service.peak : 0)
        if (fresh || useSocket) service.floorRms = M.trackFloor(service.floorRms, r)
        target = (fresh || useSocket) ? M.levelTarget(r, p, service.floorRms) : 0.04
        if ((fresh || useSocket) && M.isClipping(p)) service.clipUntil = now + 350
      }
      service.levelTick += 1
      service.levels = M.pushLevel(service.levels, target, service.barCount, service.levelTick % 2 === 0)
      service.peakHold = M.decayPeak(service.peakHold, target, 0.016)
      service.clipping = now < service.clipUntil
    }
  }

  // ---------------------------------------------------------------- status stream
  // Same follower the bar's dictation indicator uses. The shim execs
  // `setpriv --pdeathsig TERM voxtype status --follow`, so it dies with the
  // shell. It prints nothing until the first state change, hence the seed.
  Process {
    id: statusProc
    command: ["bash", "-c", "omarchy-voxtype-status"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        service.streamSeen = true
        service.applyStatusJson(line)
      }
    }
    onRunningChanged: if (!running) statusRestart.restart()
  }

  Timer {
    id: statusRestart
    interval: service.daemonAvailable ? 3000 : 30000
    repeat: false
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  Process {
    id: seedProc
    command: ["voxtype", "status", "--extended", "--format", "json"]
    stdout: StdioCollector {
      onStreamFinished: if (!service.streamSeen) service.applyStatusJson(text)
    }
  }

  // The first seed can race the plugin reload that created this service; a
  // second one a moment later fills in model/backend for the tooltip.
  Timer {
    id: seedAgain
    interval: 2500
    repeat: false
    onTriggered: if (!service.streamSeen && !seedProc.running) seedProc.running = true
  }

  // Belt and braces: the daemon rewrites this file on every transition, and a
  // watcher on it catches anything the stream misses (a cancel, a restart).
  FileView {
    id: stateFile
    path: service.runtimeDir + "/voxtype/state"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: service.applyDaemonState(text().trim())
  }

  Process {
    id: maxDurationProc
    command: ["voxtype", "config", "get", "audio.max_duration_secs"]
    stdout: StdioCollector {
      onStreamFinished: {
        var m = String(text || "").match(/(\d+)/)
        var n = m ? parseInt(m[1], 10) : 0
        if (n > 0) service.maxDurationSecs = n
      }
    }
  }

  // ---------------------------------------------------------------- audio bridge
  // Reads the daemon's audio socket and prints one NDJSON frame per line.
  // Frames only flow while the daemon records, so it can stay attached.
  Process {
    id: bridge
    command: ["voxtype-audio-bridge"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { service.onBridgeLine(line) }
    }
    onRunningChanged: if (!running) bridgeRestart.restart()
  }

  Timer {
    id: bridgeRestart
    interval: 1000
    repeat: false
    onTriggered: service.syncBridge()
  }

  function syncBridge() {
    if (wantBridge && !bridge.running) bridge.running = true
    else if (!wantBridge && bridge.running) bridge.running = false
  }

  onWantBridgeChanged: syncBridge()

  function onBridgeLine(line) {
    var trimmed = String(line || "").trim()
    if (trimmed === "") return
    var obj
    try { obj = JSON.parse(trimmed) } catch (e) { return }
    if (obj.status === "connected") { bridgeConnected = true; return }
    if (obj.status === "disconnected") { bridgeConnected = false; return }
    if (typeof obj.rms === "number") {
      rms = obj.rms
      peak = typeof obj.peak === "number" ? obj.peak : obj.rms
      vad = !!obj.vad
    }
  }

  // ---------------------------------------------------------------- recent takes
  // Voxtype logs each final transcript; following its journal gives the
  // popup a three-deep clipboard without touching Voxtype's config or the
  // text path. In memory only. `-n 40` seeds the list from the last few
  // takes at startup; those show as "earlier".
  property var recent: []
  property bool journalSeeded: false
  property double lastDoneAt: 0

  Process {
    id: journalProc
    command: ["setpriv", "--pdeathsig", "TERM", "journalctl", "--user", "-u", "voxtype.service", "-f", "-n", "40", "-o", "cat"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { service.onJournalLine(line) }
    }
    onRunningChanged: if (!running) journalRestart.restart()
  }

  Timer {
    id: journalRestart
    interval: 5000
    repeat: false
    onTriggered: if (!journalProc.running) journalProc.running = true
  }

  // Lines that arrive within a second of the follower starting are history.
  Timer {
    id: journalSeedTimer
    interval: 1000
    repeat: false
    running: true
    onTriggered: service.journalSeeded = true
  }

  function onJournalLine(line) {
    var parsed = M.parseTranscriptLog(line)
    if (!parsed) return
    var live = journalSeeded
    if (parsed.kind === "final") {
      recent = M.pushRecent(recent, parsed.text, live ? Date.now() : 0, 3)
      return
    }
    // An empty take: the daemon still reports transcribing → idle, which
    // reads as DONE. Correct it while that DONE is still on screen.
    if (live && (phase === "processing" || (phase === "done" && Date.now() - lastDoneAt < 1500)))
      enterPhase("cancelled", "rejected")
  }

  function copyText(text) {
    var t = String(text || "")
    if (t === "") return false
    // The text rides as $0, never through the shell's parser.
    Quickshell.execDetached(["sh", "-c", "printf %s \"$0\" | wl-copy", t])
    return true
  }

  function copyRecent(index) {
    var i = Number(index || 0)
    if (!(i >= 0 && i < recent.length)) return false
    return copyText(recent[i].text)
  }

  // ---------------------------------------------------------------- level meter
  // Runs only while listening; Quickshell stops it when `running` goes false
  // and the script takes pw-record down with it.
  Process {
    id: meter
    command: [service.pluginDir + "/bin/voxhud-levels"]
    running: service.phase === "listening" && !service.demoActive && service.pluginDir !== ""
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { service.onMeterLine(line) }
    }
  }

  function onMeterLine(line) {
    var obj
    try { obj = JSON.parse(String(line || "").trim()) } catch (e) { return }
    if (typeof obj.rms !== "number") return
    meterRms = obj.rms
    meterPeak = typeof obj.peak === "number" ? obj.peak : obj.rms
    meterSeenAt = Date.now()
  }

  // ---------------------------------------------------------------- key legend
  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: service.binds = M.parseBinds(text)
    }
  }

  // ---------------------------------------------------------------- ipc
  IpcHandler {
    target: "voxhud"
    function state(): string {
      return JSON.stringify({
        phase: service.phase,
        reason: service.reason,
        daemonState: service.daemonState,
        daemonAvailable: service.daemonAvailable,
        hudVisible: service.hudVisible,
        demoActive: service.demoActive,
        elapsedMs: service.elapsedMs,
        maxDurationSecs: service.maxDurationSecs,
        model: service.model,
        backend: service.backend,
        bridgeConnected: service.bridgeConnected,
        clipping: service.clipping,
        rms: service.rms,
        peak: service.peak,
        meterRms: service.meterRms,
        meterPeak: service.meterPeak,
        meterFresh: Date.now() - service.meterSeenAt < 250,
        target: service.target,
        legend: service.legend,
        binds: service.binds,
        settings: service.cfg
      })
    }
    function demo(state: string): string { service.demo(state); return "ok" }
    function cancel(): string { service.cancel(); return "ok" }
    function popup(): string {
      var bar = service.shell ? service.shell.bar : null
      if (!bar || typeof bar.summonBarWidget !== "function") return "no-bar"
      return bar.summonBarWidget("io.github.aashbury.voxhud") ? "ok" : "no-widget"
    }
    function recent(): string { return JSON.stringify(service.recent) }
    function copy(index: string): string {
      return service.copyRecent(parseInt(index || "0", 10)) ? "ok" : "none"
    }
    function refresh(): string {
      service.refreshBinds()
      if (!seedProc.running) seedProc.running = true
      return "ok"
    }
    function ping(): string { return "ok" }
  }

  Component.onCompleted: {
    seedProc.running = true
    seedAgain.restart()
    maxDurationProc.running = true
    refreshBinds()
    syncBridge()
  }
}
