import QtQuick
import qs.Commons

// Glyph + uppercase, letter-spaced state word.
Row {
  id: root

  property string glyph: ""
  property string label: ""
  property color color: Color.accent
  property string fontFamily: Style.font.family

  spacing: Style.space(8)

  Text {
    textFormat: Text.PlainText
    anchors.verticalCenter: parent.verticalCenter
    text: root.glyph
    visible: text !== ""
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    color: root.color

    Behavior on color { ColorAnimation { duration: 160 } }
  }

  Text {
    textFormat: Text.PlainText
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 2
    font.capitalization: Font.AllUppercase
    color: root.color

    Behavior on color { ColorAnimation { duration: 160 } }
  }
}
