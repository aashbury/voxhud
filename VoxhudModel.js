.pragma library

// Pure logic for voxhud: phase transitions, key-legend parsing, level
// smoothing and label formatting. No QML types in here, so every function can
// be exercised from node (see tests/model.test.js).

// ---------------------------------------------------------------- settings

function defaults() {
  return {
    hudEnabled: true,
    position: "bottom",
    meter: "line",
    brackets: false,
    showLegend: true,
    showTarget: true,
    barCount: 24,
    doneHoldMs: 1200,
    tooShortMs: 500
  }
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

// The widget's inline entry in shell.json: `bar.layout.<section>[i]` with
// `id === "voxhud"`. Entries can also be bare id strings, which carry no
// settings.
function findEntry(config, id) {
  if (!isPlainObject(config) || !isPlainObject(config.bar) || !isPlainObject(config.bar.layout)) return null
  var layout = config.bar.layout
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var list = layout[sections[s]]
    if (!Array.isArray(list)) continue
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (isPlainObject(entry) && String(entry.id) === id) return entry
      if (typeof entry === "string" && entry === id) return { id: id }
    }
  }
  return null
}

// `omarchy bar set` without --json writes strings, so booleans and numbers
// are coerced against the default's type.
function coerce(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (typeof fallback === "boolean") {
    if (typeof value === "boolean") return value
    var s = String(value).trim().toLowerCase()
    return s === "true" || s === "1" || s === "yes" || s === "on"
  }
  if (typeof fallback === "number") {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }
  return String(value)
}

function mergeSettings(entry) {
  var out = defaults()
  if (!isPlainObject(entry)) return out
  for (var key in out) {
    if (key in entry) out[key] = coerce(entry[key], out[key])
  }
  if (out.position !== "top") out.position = "bottom"
  if (out.meter !== "bars") out.meter = "line"
  out.barCount = Math.max(8, Math.min(64, Math.round(out.barCount)))
  out.doneHoldMs = Math.max(300, Math.min(5000, Math.round(out.doneHoldMs)))
  return out
}

// ---------------------------------------------------------------- daemon

var DAEMON_STATES = ["idle", "recording", "streaming", "transcribing"]

function normalizeDaemonState(raw) {
  var s = String(raw || "").trim().toLowerCase()
  return DAEMON_STATES.indexOf(s) === -1 ? "idle" : s
}

// One line of `voxtype status --follow --extended --format json`, or of the
// `omarchy-voxtype-status` shim. Returns null for anything unparsable.
function parseStatusLine(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  if (!isPlainObject(data)) return null
  var alt = data.alt !== undefined && data.alt !== null ? String(data.alt) : ""
  var cls = data["class"] !== undefined && data["class"] !== null ? String(data["class"]) : ""
  // The shim prints {"alt": "", "class": "idle", "tooltip": ""} when voxtype
  // is not installed at all.
  var available = !(alt === "" && String(data.tooltip || "") === "")
  return {
    state: normalizeDaemonState(alt !== "" ? alt : cls),
    model: String(data.model || ""),
    backend: String(data.backend || ""),
    device: String(data.device || ""),
    tooltip: String(data.tooltip || ""),
    available: available
  }
}

// ---------------------------------------------------------------- phases

// phase: idle | listening | processing | done | cancelled
// reason (for cancelled): cancel | short | rejected
function transition(prevDaemon, nextDaemon, ctx) {
  var prev = normalizeDaemonState(prevDaemon)
  var next = normalizeDaemonState(nextDaemon)
  if (prev === next) return null
  ctx = ctx || {}
  if (next === "recording" || next === "streaming") return { phase: "listening", reason: "" }
  if (next === "transcribing") return { phase: "processing", reason: "" }
  // next === idle
  if (prev === "transcribing") {
    return ctx.cancelRequested ? { phase: "cancelled", reason: "cancel" } : { phase: "done", reason: "" }
  }
  if (prev === "recording" || prev === "streaming") {
    if (ctx.cancelRequested) return { phase: "cancelled", reason: "cancel" }
    var tooShort = Number(ctx.tooShortMs || 500)
    if (Number(ctx.elapsedMs || 0) < tooShort) return { phase: "cancelled", reason: "short" }
    return { phase: "cancelled", reason: "rejected" }
  }
  return { phase: "idle", reason: "" }
}

function labelFor(phase, reason) {
  switch (phase) {
  case "listening": return "LISTENING"
  case "processing": return "PROCESSING"
  case "done": return "DONE"
  case "cancelled": return reason === "short" ? "TOO SHORT" : (reason === "rejected" ? "NOTHING HEARD" : "CANCELLED")
  default: return ""
  }
}

function glyphFor(phase) {
  switch (phase) {
  case "listening": return "󰍬"
  case "processing": return "󰔟"
  case "done": return "󰄬"
  case "cancelled": return "󰅖"
  default: return "󰍬"
  }
}

function barsMode(phase) {
  switch (phase) {
  case "listening": return "live"
  case "processing": return "sweep"
  case "done": return "flash"
  case "cancelled": return "drop"
  default: return "idle"
  }
}

function formatClock(elapsedMs) {
  var total = Math.max(0, Math.floor(Number(elapsedMs || 0) / 1000))
  var m = Math.floor(total / 60)
  var s = total % 60
  return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
}

function tooltipFor(phase, reason, elapsedMs, model, backend, available) {
  if (available === false) return "Voxtype is not installed"
  var parts = []
  if (phase === "listening") parts.push("LISTENING " + formatClock(elapsedMs))
  else if (phase === "idle") parts.push("Dictation ready")
  else parts.push(labelFor(phase, reason))
  if (model) parts.push(model)
  if (backend) parts.push(backend)
  return parts.join(" · ")
}

// ---------------------------------------------------------------- key legend

var MOD_BITS = [
  [64, "SUPER"],
  [4, "CTRL"],
  [8, "ALT"],
  [1, "SHIFT"]
]

function modLabel(modmask) {
  var mask = Number(modmask || 0)
  var out = []
  for (var i = 0; i < MOD_BITS.length; i++) {
    if (mask & MOD_BITS[i][0]) out.push(MOD_BITS[i][1])
  }
  return out.join("+")
}

function keyLabel(key) {
  var k = String(key || "")
  if (k === "") return ""
  if (k.indexOf("code:") === 0) return "KEY " + k.slice(5)
  return k.length === 1 ? k.toUpperCase() : k.charAt(0).toUpperCase() + k.slice(1)
}

function bindLabel(b) {
  if (!b) return ""
  var mods = modLabel(b.modmask)
  var key = keyLabel(b.key)
  return mods === "" ? key : mods + "+" + key
}

function emptyBinds() {
  return { start: null, stop: null, toggle: null, cancel: null, ptt: false, found: false }
}

// `hyprctl binds -j`. Omarchy binds through Lua, so `arg` is a callback index
// and the only thing that names the action is the description. The stock
// ones read "Start dictation (push-to-talk)", "Stop dictation (push-to-talk)"
// and "Toggle dictation"; anything a user adds with "dictation" in it is
// picked up the same way.
function parseBinds(json) {
  var out = emptyBinds()
  var list
  try { list = JSON.parse(String(json || "[]")) } catch (e) { return out }
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var b = list[i] || {}
    var desc = String(b.description || "")
    var arg = String(b.arg || "")
    if (!/dictat/i.test(desc) && !/voxtype record/i.test(arg)) continue
    var entry = {
      key: String(b.key || ""),
      modmask: Number(b.modmask || 0),
      release: b.release === true,
      description: desc
    }
    entry.label = bindLabel(entry)
    var probe = desc + " " + arg
    var kind
    if (/cancel/i.test(probe)) kind = "cancel"
    else if (/toggle/i.test(probe)) kind = "toggle"
    else if (entry.release || /\bstop\b/i.test(probe)) kind = "stop"
    else kind = "start"
    if (!out[kind]) out[kind] = entry
    out.found = true
  }
  out.ptt = !!(out.start && out.stop && out.start.key === out.stop.key
    && out.start.modmask === out.stop.modmask && out.stop.release)
  return out
}

function legendFor(binds, phase, target, settings) {
  binds = binds || emptyBinds()
  settings = settings || {}
  var showLegend = settings.showLegend !== false
  var showTarget = settings.showTarget !== false
  if (phase === "listening") {
    if (!showLegend) return ""
    var parts = []
    if (binds.ptt) parts.push("release " + binds.stop.label + " to insert")
    else if (binds.stop) parts.push(binds.stop.label + " to insert")
    if (binds.toggle) parts.push(binds.toggle.label + " to insert")
    if (parts.length === 0) parts.push("release the key to insert")
    parts.push("✕ cancel")
    if (binds.cancel) parts.push(binds.cancel.label + " cancel")
    return parts.join("  ·  ")
  }
  if (phase === "processing") {
    if (showTarget && target) return "→ " + target
    return showLegend ? "hands off · inserting when ready" : ""
  }
  if (phase === "done") return showTarget && target ? "→ " + target : ""
  if (phase === "cancelled") return showLegend ? "nothing inserted" : ""
  return ""
}

function prettyAppId(appId) {
  var id = String(appId || "")
  if (id === "") return ""
  var last = id.split(".").pop()
  last = last.replace(/[-_]+/g, " ")
  return last.charAt(0).toUpperCase() + last.slice(1)
}

function elide(text, max) {
  var t = String(text || "")
  return t.length > max ? t.slice(0, Math.max(0, max - 1)) + "…" : t
}

function targetLabel(toplevel) {
  if (!toplevel) return ""
  var app = prettyAppId(toplevel.appId)
  var title = String(toplevel.title || "").trim()
  if (app === "" && title === "") return ""
  if (app === "") return elide(title, 44)
  if (title === "" || title.toLowerCase() === app.toLowerCase()) return app
  return app + " — " + elide(title, 40)
}

// ---------------------------------------------------------------- levels

function emptyLevels(count) {
  var out = []
  for (var i = 0; i < count; i++) out.push(0)
  return out
}

// rms/peak arrive as 0..1 amplitudes. The bars show how far above the room's
// noise floor you are, in dB: silence hugs the bottom whatever the mic gain,
// speech climbs, and a saturated input pins them at the top. The floor is a
// running minimum of rms that follows quieter frames at once and creeps back
// up slowly, so a pause mid-sentence doesn't re-zero it.
// (The daemon's VAD flag is always set on this build, so it isn't used.)
// Normal speech on a laptop mic lands 10-15 dB over the room; 18 dB is full.
var LEVEL_RANGE_DB = 18
var FLOOR_OFFSET_DB = 2

function toDb(amplitude) {
  return 20 * Math.log10(Math.max(0.00001, Number(amplitude || 0)))
}

function trackFloor(prevFloorRms, rms) {
  var r = Math.max(0.0005, Number(rms || 0))
  var prev = Number(prevFloorRms || 0)
  if (prev <= 0 || r < prev) return r
  return Math.min(r, prev * 1.01)
}

function levelTarget(rms, peak, floorRms) {
  var floorDb = toDb(floorRms) + FLOOR_OFFSET_DB
  var v = (toDb(rms) - floorDb) / LEVEL_RANGE_DB
  var p = (toDb(peak) - floorDb) / LEVEL_RANGE_DB * 0.8
  v = Math.max(v, p)
  return Math.max(0.04, Math.min(1, v))
}

// The daemon reports peaks of exactly 1.0 when its input saturates.
function isClipping(peak) {
  return Number(peak || 0) >= 0.985
}

function syntheticLevel(tMs) {
  var t = Number(tMs || 0)
  var wave = Math.abs(Math.sin(t / 230)) * 0.55 + Math.abs(Math.sin(t / 97)) * 0.2
  return Math.max(0.04, Math.min(1, 0.08 + wave * (0.55 + 0.45 * Math.random())))
}

// New sample enters at the centre and the history spreads outward, mirrored,
// so the row reads like an EQ. Old bars decay rather than drop. The sampler
// runs at 60 fps but only advances the history every other tick (`advance`),
// so the outward flow keeps a readable pace while the centre stays live.
function pushLevel(levels, target, count, advance) {
  var half = Math.ceil(count / 2)
  var centre = Math.floor((count - 1) / 2)
  var prev = Array.isArray(levels) && levels.length === count ? levels : emptyLevels(count)
  var history = []
  for (var h = 0; h < half; h++) history.push(Number(prev[centre - h] || 0))
  var next
  if (advance === false) {
    next = history.slice()
    next[0] = Math.max(target, history[0] * 0.9)
  } else {
    next = [Math.max(target, history[0] * 0.9)]
    for (var j = 0; j < half - 1; j++) next.push(history[j] * 0.94)
  }
  var out = []
  for (var i = 0; i < count; i++) {
    var d = Math.abs(i - (count - 1) / 2)
    var idx = Math.min(half - 1, Math.floor(d))
    out.push(next[idx])
  }
  return out
}

function decayPeak(peakHold, target, dtSeconds) {
  var decayed = Number(peakHold || 0) - 1.2 * Number(dtSeconds || 0)
  return Math.max(Number(target || 0), Math.max(0, decayed))
}

// ---------------------------------------------------------------- transcripts

// Voxtype logs every take to the journal:
//   INFO Transcribed: "the final text, after replacements"
//   INFO Transcription completed in 3.47s: "the first fifty chars..."   (or "")
// The first carries the full text; the second, when its string is empty, is
// the only sign that a take produced nothing. Strings are Rust debug-escaped.
var RE_TRANSCRIBED = /Transcribed:\s*"(.*)"\s*$/
var RE_COMPLETED = /Transcription completed in [\d.]+s:\s*"(.*)"\s*$/

function unescapeRust(s) {
  return String(s || "").replace(/\\u\{([0-9a-fA-F]+)\}/g, function(_, hex) {
    return String.fromCodePoint(parseInt(hex, 16))
  }).replace(/\\n/g, "\n").replace(/\\t/g, "\t").replace(/\\r/g, "")
    .replace(/\\"/g, "\"").replace(/\\'/g, "'").replace(/\\\\/g, "\\")
}

function parseTranscriptLog(line) {
  var text = String(line || "").replace(/\x1b\[[0-9;]*m/g, "")
  var m = text.match(RE_TRANSCRIBED)
  if (m) {
    var final = unescapeRust(m[1]).trim()
    return final === "" ? { kind: "empty" } : { kind: "final", text: final }
  }
  m = text.match(RE_COMPLETED)
  if (m && unescapeRust(m[1]).trim() === "") return { kind: "empty" }
  return null
}

function pushRecent(list, text, at, max) {
  var out = [{ text: String(text), at: Number(at || 0) }]
  var prev = Array.isArray(list) ? list : []
  for (var i = 0; i < prev.length && out.length < (max || 3); i++) {
    if (prev[i] && prev[i].text === out[0].text) continue
    out.push(prev[i])
  }
  return out
}

function relativeTime(at, now) {
  var t = Number(at || 0)
  if (t <= 0) return "earlier"
  var s = Math.max(0, Math.round((Number(now) - t) / 1000))
  if (s < 5) return "just now"
  if (s < 60) return s + "s ago"
  var m = Math.round(s / 60)
  if (m < 60) return m + " min ago"
  var h = Math.round(m / 60)
  return h + " h ago"
}

// ---------------------------------------------------------------- dictionary

// `voxtype config set text.replacements.<from>` addresses entries by dotted
// key, so the spoken form cannot carry the characters TOML keys are built
// from.
function validateFrom(from) {
  var f = String(from || "").trim()
  if (f === "") return "Say what it should hear first."
  if (/[.=\"'\[\]]/.test(f)) return "Spoken form can't contain . = quotes or brackets."
  if (f.length > 64) return "Keep the spoken form under 64 characters."
  return ""
}

function sortedReplacements(map) {
  var out = []
  if (!isPlainObject(map)) return out
  for (var from in map) out.push({ from: from, to: String(map[from]) })
  out.sort(function(a, b) { return a.from.localeCompare(b.from) })
  return out
}
