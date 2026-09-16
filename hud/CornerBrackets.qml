import QtQuick
import qs.Commons

// Four L-shaped corner marks, drawn just outside whatever this is anchored to.
Item {
  id: root

  property color color: Color.accent
  property int length: Style.space(10)
  property int thickness: Math.max(1, Style.space(2))

  Behavior on color { ColorAnimation { duration: 160 } }

  // top-left
  Rectangle { x: 0; y: 0; width: root.length; height: root.thickness; color: root.color }
  Rectangle { x: 0; y: 0; width: root.thickness; height: root.length; color: root.color }
  // top-right
  Rectangle { x: root.width - root.length; y: 0; width: root.length; height: root.thickness; color: root.color }
  Rectangle { x: root.width - root.thickness; y: 0; width: root.thickness; height: root.length; color: root.color }
  // bottom-left
  Rectangle { x: 0; y: root.height - root.thickness; width: root.length; height: root.thickness; color: root.color }
  Rectangle { x: 0; y: root.height - root.length; width: root.thickness; height: root.length; color: root.color }
  // bottom-right
  Rectangle { x: root.width - root.length; y: root.height - root.thickness; width: root.length; height: root.thickness; color: root.color }
  Rectangle { x: root.width - root.thickness; y: root.height - root.length; width: root.thickness; height: root.length; color: root.color }
}
