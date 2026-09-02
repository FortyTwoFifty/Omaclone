import QtQuick
import qs.Commons
import qs.Ui

CursorSurface {
  id: locRow
  property var panel
  property var backup
  property int rowIndex: 0
  property var loc: null
  readonly property string _epoch: panel ? panel.locationEpoch : ""
  readonly property string locId: {
    var epoch = _epoch
    return loc ? String(loc["id"] || "") : ""
  }
  readonly property bool isActive: {
    var epoch = _epoch
    if (loc && loc.active) return true
    var want = backup ? String(backup.locationId || "") : ""
    if (!want && panel && panel.activeLoc)
      want = String(panel.activeLoc["id"] || "")
    return locId !== "" && want !== "" && locId === want
  }
  readonly property bool rounded: Style.cornerRadius > 0
  hasCursor: panel && panel.cursorActive && panel.focusSection === "locations" && panel.locationIndex === locRow.rowIndex
  current: isActive
  foreground: panel ? panel.foreground : Color.foreground
  implicitHeight: Math.max(Style.space(54), radioContent.implicitHeight + Style.spacing.rowPaddingX)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: locRow.hasCursor || locRow.isActive ? Qt.rgba(locRow.foreground.r, locRow.foreground.g, locRow.foreground.b, 0.10) : "transparent"
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      if (!panel) return
      panel.cursorActive = true
      panel.focusSection = "locations"
      panel.locationIndex = locRow.rowIndex
    }
    onClicked: if (panel) panel.selectLocation(locRow.rowIndex)
  }

  Row {
    id: radioContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(10)

    Column {
      width: parent.width - mark.width - parent.spacing
      spacing: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: locRow.loc ? (locRow.loc.label || locRow.locId) : ""
        color: locRow.foreground
        font.family: panel ? panel.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: locRow.loc && panel ? panel.locationDescription(locRow.loc) : ""
        color: Qt.darker(locRow.foreground, 1.5)
        font.family: panel ? panel.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Rectangle {
      id: mark
      width: Style.space(22)
      height: Style.space(22)
      radius: locRow.rounded ? width / 2 : 0
      anchors.verticalCenter: parent.verticalCenter
      color: locRow.isActive
        ? Style.selectedFillFor(locRow.foreground, Color.accent)
        : Style.normalFillFor(locRow.foreground, Color.accent)
      border.width: 1
      border.color: locRow.isActive
        ? Style.selectedStateColor(locRow.foreground, Color.accent)
        : Qt.rgba(locRow.foreground.r, locRow.foreground.g, locRow.foreground.b, 0.35)

      Rectangle {
        visible: locRow.isActive
        anchors.centerIn: parent
        width: Style.space(10)
        height: width
        radius: locRow.rounded ? width / 2 : 0
        color: Style.selectedStateColor(locRow.foreground, Color.accent)
      }
    }
  }
}
