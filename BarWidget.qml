import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "popup"

// The bar icon that never disappears, plus the popup that holds the dictionary.
Panel {
  id: root
  moduleName: "voxhud"
  manageIpc: false

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("voxhud") : null
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string phase: svc ? svc.phase : "idle"
  readonly property string glyph: svc ? svc.glyph : "󰍬"

  // The glyph breathes while Voxtype is transcribing: dim ↔ full through the
  // button's own 140 ms fade.
  property bool pulse: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    body.reload()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: 520
    repeat: true
    running: root.phase === "processing"
    onTriggered: root.pulse = !root.pulse
    onRunningChanged: if (!running) root.pulse = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.phase === "listening"
    dimmed: root.phase === "idle" || (root.phase === "processing" && root.pulse)
    tooltipText: root.svc ? root.svc.tooltip : "Voxhud"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) { if (root.svc) root.svc.cancel() }
      else if (buttonCode === Qt.RightButton) { if (root.svc) root.svc.demo("tour") }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Taller than the control panels: it's a reference sheet, and the point
    // is seeing the whole dictionary without scrolling.
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: body.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        DictionaryPanel {
          id: body
          width: flick.width
          svc: root.svc
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
      }
    }
  }
}
