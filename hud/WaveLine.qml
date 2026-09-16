import QtQuick
import qs.Commons

// A single oscilloscope line. Same inputs as LevelBars, four looks:
//   live   - the line deforms with your voice; the level history (centre
//            out, mirrored) is the envelope on a slowly flowing wave
//   sweep  - a calm wave packet travels along a flat line (processing)
//   flash  - one bright pulse rolls through, then the line lies flat (done)
//   drop   - the wave collapses to a flatline (cancelled)
//   idle   - flat, dim
// Drawn on a Canvas at 60 fps with the envelope eased toward the newest
// samples, so it breathes rather than jitters.
Item {
  id: root

  property string mode: "idle"
  property var levels: []
  property color color: Color.accent
  property color dimColor: Util.alpha(Color.foreground, 0.18)
  property real strokeWidth: Math.max(1.25, Style.spaceReal(1.5))
  property real cycles: 6          // wave periods across the width when live
  property real flowSpeed: 0.55    // phase advance per second, in periods

  // Animation state.
  property var drawn: []           // eased envelope, 0..1 per sample
  property real phase: 0           // wave phase, in periods
  property real sweepPos: 0        // 0..1 position of the processing packet
  property real pulsePos: -1       // 0..1 position of the done pulse, -1 = none
  property real collapse: 1        // 1 = full envelope, 0 = flat (drop)
  property double lastTick: 0

  readonly property bool animating: visible && (mode === "live" || mode === "sweep" || pulseAnim.running || collapseAnim.running)

  onModeChanged: {
    if (mode === "flash") { pulsePos = 0; pulseAnim.restart() }
    else pulseAnim.stop()
    if (mode === "drop") { collapse = 1; collapseAnim.restart() }
    else { collapseAnim.stop(); collapse = 1 }
    if (mode === "live") drawn = []
    canvas.requestPaint()
  }
  onLevelsChanged: if (mode === "live" && !animating) canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onDimColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  NumberAnimation on pulsePos {
    id: pulseAnim
    from: 0; to: 1.15
    duration: 650
    easing.type: Easing.OutQuad
    running: false
    onFinished: { root.pulsePos = -1; canvas.requestPaint() }
  }

  NumberAnimation on collapse {
    id: collapseAnim
    from: 1; to: 0
    duration: 220
    easing.type: Easing.InQuad
    running: false
  }

  Timer {
    interval: 16
    repeat: true
    running: root.animating
    onTriggered: {
      var now = Date.now()
      var dt = root.lastTick > 0 ? Math.min(0.05, (now - root.lastTick) / 1000) : 0.016
      root.lastTick = now
      root.phase += root.flowSpeed * dt
      if (root.mode === "sweep") root.sweepPos = (root.sweepPos + dt / 1.7) % 1
      if (root.mode === "live") root.easeEnvelope()
      canvas.requestPaint()
    }
    onRunningChanged: if (!running) root.lastTick = 0
  }

  // Ease the drawn envelope toward the newest samples; rises are quicker
  // than falls so a syllable lands, then settles.
  function easeEnvelope() {
    var src = Array.isArray(root.levels) ? root.levels : []
    var n = src.length
    if (n === 0) return
    var cur = Array.isArray(root.drawn) && root.drawn.length === n ? root.drawn : new Array(n).fill(0)
    var next = new Array(n)
    for (var i = 0; i < n; i++) {
      var target = Math.max(0, Math.min(1, Number(src[i]) || 0))
      var v = cur[i]
      next[i] = v + (target - v) * (target > v ? 0.45 : 0.22)
    }
    root.drawn = next
  }

  // Linear interpolation into the envelope at a 0..1 position.
  function envelopeAt(u) {
    var e = root.drawn
    var n = e ? e.length : 0
    if (n === 0) return 0
    if (n === 1) return e[0]
    var f = u * (n - 1)
    var i = Math.floor(f)
    if (i >= n - 1) return e[n - 1]
    var t = f - i
    return e[i] * (1 - t) + e[i + 1] * t
  }

  function gauss(x, sigma) {
    return Math.exp(-(x * x) / (2 * sigma * sigma))
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderTarget: Canvas.Image

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.clearRect(0, 0, w, h)
      if (w < 4 || h < 4) return
      var mid = h / 2
      var amp = h / 2 - 1
      var mode = root.mode
      var step = 2
      var pts = []
      var flat = mode === "idle" || (mode === "flash" && root.pulsePos < 0)

      for (var x = 0; x <= w; x += step) {
        var u = x / w
        var y = mid
        if (!flat) {
          var theta = 2 * Math.PI * (u * root.cycles - root.phase)
          var wave = Math.sin(theta) * 0.78 + Math.sin(2 * theta + root.phase * 1.7) * 0.22
          var env = 0
          if (mode === "live") env = root.envelopeAt(u)
          else if (mode === "drop") env = root.envelopeAt(u) * root.collapse
          else if (mode === "sweep") {
            var d = u - root.sweepPos
            // wrap so the packet re-enters from the left seamlessly
            if (d > 0.5) d -= 1; else if (d < -0.5) d += 1
            env = 0.7 * root.gauss(d, 0.07)
            wave = Math.sin(2 * Math.PI * (u * 9 - root.phase * 2.2))
          } else if (mode === "flash") {
            env = 0.95 * root.gauss(u - root.pulsePos, 0.09)
            wave = Math.sin(2 * Math.PI * (u * 8))
          }
          y = mid - env * amp * wave
        }
        pts.push([x, y])
      }

      var c = mode === "idle" ? root.dimColor : root.color
      // Soft glow under the stroke.
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, mode === "idle" ? 0 : 0.22)
      ctx.lineWidth = root.strokeWidth * 3.2
      ctx.beginPath()
      ctx.moveTo(pts[0][0], pts[0][1])
      for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1])
      ctx.stroke()
      // The line itself.
      ctx.strokeStyle = c
      ctx.lineWidth = root.strokeWidth
      ctx.beginPath()
      ctx.moveTo(pts[0][0], pts[0][1])
      for (var j = 1; j < pts.length; j++) ctx.lineTo(pts[j][0], pts[j][1])
      ctx.stroke()
    }
  }

  Component.onCompleted: canvas.requestPaint()
}
