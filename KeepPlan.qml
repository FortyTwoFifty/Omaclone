import QtQuick
import qs.Commons
import qs.Ui

CursorSurface {
  id: keepRow
  property var panel
  property var backup
  property var preset: null
  property int rowIndex: 0
  hasCursor: panel && panel.cursorActive && panel.focusSection === "retention" && panel.retentionIndex === rowIndex
  foreground: panel ? panel.foreground : Color.foreground
  implicitHeight: Style.space(36)

  readonly property bool isCurrent: !!(preset && backup && preset.id === backup.retentionPreset)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: keepRow.hasCursor || keepRow.isCurrent ? Qt.rgba(keepRow.foreground.r, keepRow.foreground.g, keepRow.foreground.b, 0.10) : "transparent"
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      if (!panel) return
      panel.cursorActive = true
      panel.focusSection = "retention"
      panel.retentionIndex = keepRow.rowIndex
    }
    onClicked: if (panel) panel.selectRetention(keepRow.rowIndex)
  }

  Text {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    text: (keepRow.preset ? keepRow.preset.label : "") + (keepRow.isCurrent ? "  · current" : "")
    color: keepRow.foreground
    font.family: panel ? panel.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }
}
