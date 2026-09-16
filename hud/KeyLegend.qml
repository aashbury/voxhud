import QtQuick
import qs.Commons

// One muted line: the keys that stop and insert, or where the text is going.
Text {
  id: root

  property string fontFamily: Style.font.family

  textFormat: Text.PlainText
  font.family: fontFamily
  font.pixelSize: Style.font.caption
  color: Color.muted
  elide: Text.ElideRight
  maximumLineCount: 1
  // Keep the line's height when there is nothing to say.
  height: Math.ceil(Style.font.caption * 1.3)
  verticalAlignment: Text.AlignVCenter

  Behavior on color { ColorAnimation { duration: 160 } }
}
