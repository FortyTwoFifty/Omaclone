import QtQuick
import qs.Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color cutoutColor: Color.popups.background

  readonly property int markSize: Math.max(8, Math.round(iconSize))
  readonly property int offset: Math.max(2, Math.round(markSize * 0.24))
  readonly property int gap: Math.max(1, Math.round(markSize * 0.07))

  implicitWidth: markSize + offset
  implicitHeight: markSize + offset
  width: implicitWidth
  height: implicitHeight

  component LogoMark: Item {
    width: root.markSize
    height: root.markSize
    clip: true

    Text {
      anchors.fill: parent
      text: "\ue900"
      color: root.color
      font.family: "omarchy"
      font.pixelSize: root.markSize
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      renderType: Text.NativeRendering
    }
  }

  LogoMark {
    x: root.offset
    y: root.offset
  }

  Rectangle {
    width: root.markSize + root.gap
    height: root.markSize + root.gap
    color: root.cutoutColor
    antialiasing: false
  }

  LogoMark {
    x: 0
    y: 0
  }
}
