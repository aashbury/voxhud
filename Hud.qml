import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "VoxhudModel.js" as M
import "hud"

// The HUD. Purely presentational: every value comes from the voxhud service.
// One click-through layer-shell surface per screen, shown on the focused one.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property var svc: service ? service
    : (shell && typeof shell.serviceFor === "function" ? shell.serviceFor("io.github.aashbury.voxhud") : null)

  // Host contract. `omarchy-shell shell summon voxhud '{"demo":"tour"}'`
  // previews the HUD; a bare summon runs the tour.
  property bool opened: root.svc ? root.svc.hudVisible === true : false

  function open(payloadJson) {
    var want = "tour"
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p && p.demo) want = String(p.demo)
    } catch (e) {}
    if (root.svc) root.svc.demo(want)
  }

  function close() {
    if (root.svc) root.svc.demo("off")
  }

  readonly property string phase: svc ? svc.phase : "idle"
  readonly property bool cancelable: phase === "listening" || phase === "processing"
  readonly property color stateColor: phase === "listening" ? Color.bar.active
    : (phase === "cancelled" ? Color.urgent : Color.accent)
  readonly property bool atTop: svc && svc.position === "top"

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData

      readonly property bool onFocusedScreen: {
        var m = Hyprland.focusedMonitor
        if (!m) return true
        return String(m.name || "") === String(modelData.name || "")
      }
      readonly property bool shouldShow: root.opened && win.onFocusedScreen
        && (root.svc ? root.svc.hudEnabled : true)

      // Stays mapped through the fade-out.
      visible: shouldShow || card.opacity > 0
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "voxhud"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Click-through everywhere except the cancel target, and only while
      // there is something to cancel.
      mask: Region { item: root.cancelable ? cancelHit : null }

      BorderSurface {
        id: card
        readonly property int padX: Style.space(14)
        readonly property int padY: Style.space(7)

        width: Style.space(420)
        height: card.borderTop + card.padY + column.implicitHeight + card.padY + card.borderBottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: root.atTop ? undefined : parent.bottom
        anchors.top: root.atTop ? parent.top : undefined
        anchors.bottomMargin: Style.space(67)
        anchors.topMargin: Style.space(67)
        color: Util.alpha(Color.background, 0.94)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
        opacity: win.shouldShow ? 1 : 0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        // Targeting-reticle corners, off by default: the waveform carries the
        // mood on its own. Only ever drawn on sharp themes, where they don't
        // fight a rounded border.
        CornerBrackets {
          anchors.fill: parent
          anchors.margins: -Style.space(5)
          visible: root.svc && root.svc.brackets && Style.cornerRadius <= Style.space(2)
          color: Util.alpha(root.stateColor, 0.7)
        }

        Column {
          id: column
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: card.borderLeft + card.padX
          anchors.rightMargin: card.borderRight + card.padX
          spacing: Style.space(4)

          // Row 1: glyph + label  ·  clock  ·  ✕
          Item {
            width: parent.width
            height: Math.max(stateLabel.implicitHeight, cancelHit.height)

            StateLabel {
              id: stateLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              glyph: root.svc ? root.svc.glyph : ""
              label: root.svc ? root.svc.label : ""
              color: root.stateColor
            }

            // Input saturating: the mic is too hot, and the text will suffer.
            Text {
              id: clipTag
              textFormat: Text.PlainText
              anchors.right: clock.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.phase === "listening" && root.svc && root.svc.clipping
              text: "CLIP"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 2
              color: Color.urgent
            }

            Text {
              id: clock
              textFormat: Text.PlainText
              anchors.right: cancelHit.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.phase === "listening" || root.phase === "processing"
              text: root.svc ? M.formatClock(root.svc.elapsedMs) : "00:00"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              color: root.phase === "listening" && root.svc && root.svc.remainingSecs < 10
                ? Color.urgent : Color.popups.text

              Behavior on color { ColorAnimation { duration: 160 } }
            }

            Item {
              id: cancelHit
              width: Style.space(20)
              height: Style.space(18)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.cancelable

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "󰅖"
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: cancelMouse.containsMouse ? Color.urgent : Color.muted

                Behavior on color { ColorAnimation { duration: 120 } }
              }

              MouseArea {
                id: cancelMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.svc) root.svc.cancel()
              }
            }
          }

          // Row 2: the meter — a waveform line by default, bars by setting.
          Loader {
            id: meter
            width: parent.width
            height: Style.space(20)
            readonly property string meterMode: root.svc ? root.svc.barsMode : "idle"
            sourceComponent: root.svc && root.svc.meter === "bars" ? barsMeter : waveMeter
            opacity: meterMode === "flash" ? 0.35 : 1

            Behavior on opacity {
              NumberAnimation { duration: root.svc ? root.svc.doneHoldMs : 1200; easing.type: Easing.InQuad }
            }

            Component {
              id: waveMeter
              WaveLine {
                mode: meter.meterMode
                levels: root.svc ? root.svc.levels : []
                color: root.stateColor
                dimColor: Util.alpha(Color.foreground, 0.18)
              }
            }

            Component {
              id: barsMeter
              LevelBars {
                count: root.svc ? root.svc.barCount : 24
                mode: meter.meterMode
                levels: root.svc ? root.svc.levels : []
                color: root.stateColor
                dimColor: Util.alpha(Color.foreground, 0.18)
              }
            }
          }

          // Row 3: the legend. Always laid out, so the card is the same
          // height in every state.
          KeyLegend {
            width: parent.width
            text: root.svc ? root.svc.legend : ""
            color: Color.muted
          }
        }
      }
    }
  }
}
