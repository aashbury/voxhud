import QtQuick
import qs.Commons

// A row of thin vertical bars. Four looks, one component:
//   live   - mirrored EQ driven by `levels`, with a faint held-peak line
//   sweep  - bars rest low, a highlight scans back and forth (processing)
//   flash  - every bar full (done; the caller fades the row)
//   drop   - bars collapse (cancelled)
//   idle   - bars at the floor, dim
Item {
  id: root

  property int count: 24
  property string mode: "idle"
  property var levels: []
  property color color: Color.accent
  property color dimColor: Util.alpha(Color.foreground, 0.18)
  property int barWidth: Math.max(2, Style.space(3))
  property int floor: 2
  property real sweepPos: 0

  readonly property real gap: count > 1 ? (width - count * barWidth) / (count - 1) : 0

  SequentialAnimation on sweepPos {
    running: root.mode === "sweep" && root.visible
    loops: Animation.Infinite
    NumberAnimation { from: 0; to: root.count - 1; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { from: root.count - 1; to: 0; duration: 900; easing.type: Easing.InOutSine }
  }

  Repeater {
    model: root.count

    Rectangle {
      id: bar
      required property int index

      readonly property real level: root.mode === "live" && root.levels && index < root.levels.length
        ? Math.max(0, Math.min(1, Number(root.levels[index]))) : 0
      readonly property real hl: root.mode === "sweep"
        ? Math.max(0, 1 - Math.abs(index - root.sweepPos) / 2.5) : 0

      x: Math.round(index * (root.barWidth + root.gap))
      width: root.barWidth
      anchors.bottom: parent.bottom
      radius: 0
      height: root.mode === "live" ? root.floor + (root.height - root.floor) * level
        : root.mode === "sweep" ? 3 + (root.height - 3) * 0.6 * hl
        : root.mode === "flash" ? root.height
        : root.floor
      color: root.mode === "live" || root.mode === "flash" || root.mode === "drop" ? root.color
        : root.mode === "sweep" ? (hl > 0.05 ? Util.alpha(root.color, 0.35 + 0.65 * hl) : root.dimColor)
        : root.dimColor

      // Live samples land every 16 ms; a short ease between them is what
      // makes the motion read as continuous. The sweep animates itself.
      Behavior on height {
        enabled: root.mode !== "sweep"
        NumberAnimation { duration: root.mode === "live" ? 90 : 200; easing.type: Easing.OutCubic }
      }
      Behavior on color { ColorAnimation { duration: 160 } }
    }
  }
}
