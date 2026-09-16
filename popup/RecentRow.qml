import QtQuick
import qs.Commons
import qs.Ui

// One recent take: the text (two lines, then elided), when it happened, and
// a copy button that briefly confirms.
Item {
  id: row

  property string text: ""
  property string when: ""
  property bool copied: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal copyRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)

  implicitHeight: Math.max(textColumn.implicitHeight, copyButton.implicitHeight) + Style.space(4)

  Column {
    id: textColumn
    anchors.left: parent.left
    anchors.right: copyButton.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: row.text
      color: row.foreground
      font.family: row.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: row.copied ? "copied" : row.when
      color: row.copied ? Color.accent : row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption

      Behavior on color { ColorAnimation { duration: 120 } }
    }
  }

  PanelActionButton {
    id: copyButton
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    iconText: row.copied ? "󰄬" : "󰆏"
    tooltipText: "Copy"
    foreground: row.foreground
    hoverColor: Color.accent
    fontFamily: row.fontFamily
    onClicked: row.copyRequested()
  }
}
