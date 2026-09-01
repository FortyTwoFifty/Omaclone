import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

CursorSurface {
  id: actionRow
  property var panel
  property var action: null
  property int rowIndex: 0
  hasCursor: panel && panel.cursorActive && panel.focusSection === "actions" && panel.actionIndex === rowIndex
  foreground: panel ? panel.foreground : Color.foreground
  implicitHeight: actionInner.implicitHeight + Style.spacing.rowPaddingX

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      if (!panel) return
      panel.cursorActive = true
      panel.focusSection = "actions"
      panel.actionIndex = actionRow.rowIndex
    }
    onClicked: if (panel) panel.launchAction(actionRow.rowIndex)
  }

  RowLayout {
    id: actionInner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(8)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)
      Text {
        Layout.fillWidth: true
        text: action ? action.title : ""
        color: panel ? panel.foreground : Color.foreground
        font.family: panel ? panel.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        text: action ? action.subtitle : ""
        color: panel ? panel.dim : Color.foreground
        font.family: panel ? panel.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      iconText: "󰁔"
      foreground: panel ? panel.foreground : Color.foreground
      fontFamily: panel ? panel.fontFamily : Style.font.family
      onClicked: if (panel) panel.launchAction(actionRow.rowIndex)
    }
  }
}
