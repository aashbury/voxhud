import QtQuick
import qs.Commons
import qs.Ui

// "heard as  →  typed as" with a remove action at the right edge.
Item {
  id: row

  property string from: ""
  property string to: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal removeRequested()

  implicitHeight: Math.max(fromText.implicitHeight, removeButton.implicitHeight) + Style.space(4)

  Text {
    id: fromText
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, (parent.width - removeButton.width - Style.space(40)) / 2)
    text: row.from
    color: row.foreground
    font.family: row.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  Text {
    id: arrow
    textFormat: Text.PlainText
    anchors.left: fromText.right
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: "→"
    color: Qt.darker(row.foreground, 1.4)
    font.family: row.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    id: toText
    textFormat: Text.PlainText
    anchors.left: arrow.right
    anchors.leftMargin: Style.space(8)
    anchors.right: removeButton.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: row.to
    color: row.foreground
    font.family: row.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
    elide: Text.ElideRight
  }

  PanelActionButton {
    id: removeButton
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    iconText: "󰅖"
    tooltipText: "Remove"
    foreground: row.foreground
    hoverColor: Color.urgent
    fontFamily: row.fontFamily
    enabled: row.enabled
    onClicked: row.removeRequested()
  }
}
