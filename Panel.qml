import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omaclone.plugin"
  ipcTarget: "omaclone.plugin"
  manageIpc: false

  property string focusSection: "actions"
  property int actionIndex: 0
  property int retentionIndex: 0
  property int locationIndex: 0
  property string pendingPreset: ""
  property bool cursorActive: false

  onOpenedChanged: {
    backup.paneOpen = opened
    if (opened) {
      backup.requestDiscover()
      cursorActive = false
      focusSection = "actions"
      actionIndex = 0
    }
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color popupBg: Color.popups.background
  readonly property color barBg: bar && bar.background ? bar.background : Color.background
  readonly property color warning: Color.accent
  readonly property color barIconColor: {
    var base = bar ? bar.barForeground : Color.foreground
    if (backup.switching) return base
    if (backup.severity === "error") return root.urgent
    if (backup.issueKind === "password_locked") return root.warning
    if (backup.severity === "warning") return Qt.darker(base, 1.55)
    return base
  }
  readonly property bool hasIssue: !backup.switching && (backup.severity === "error" || backup.severity === "warning" || backup.switchError !== "")

  readonly property var keepPresets: Model.retentionPresets()

  readonly property var actions: [
    { id: "setup", title: "Set up Omaclone", subtitle: "Create a clone or restore from NAS, disk, or cloud", command: ["setup"] },
    { id: "clone", title: "Clone now", subtitle: "Save an identity clone", command: ["clone"] },
    { id: "keep", title: "Change keep plan…", subtitle: "How long clones are retained", command: [] },
    { id: "snapshots", title: "Clones", subtitle: "List restic snapshots of this identity", command: ["snapshots"] },
    { id: "forget", title: "Remove clones…", subtitle: "Delete clones from this location", command: ["forget"] },
    { id: "forget-location", title: "Forget location…", subtitle: "Drop a saved location; does not erase the drive", command: ["location", "remove"] },
    { id: "restore", title: "Restore…", subtitle: "Clone this identity onto this machine", command: ["restore"] }
  ]

  readonly property string heroMeta: {
    if (backup.switching) return "Switching location…"
    if (backup.issueTitle) return backup.issueTitle
    if (backup.statusText) return backup.statusText
    return "Ready"
  }

  readonly property string clonesText: {
    if (!backup.configured) return "—"
    if (!backup.connected) return "—"
    if (backup.snapshotCount < 0) return "—"
    return String(backup.snapshotCount)
  }
  readonly property var installedLocations: Model.installedLocations(backup.locations)
  readonly property var paneLocations: Model.paneLocations(backup.locations)
  readonly property var activeLoc: Model.activeLocation({
    locationId: backup.locationId,
    locations: backup.locations
  })
  readonly property string storageText: backup.configured ? Model.storageDisplay(root.activeLoc) : "—"
  readonly property string storageHintText: {
    if (!backup.configured) return "not set"
    var labels = Model.connectedLabels(backup.locations)
    if (!labels.length) return "none connected"
    if (labels.length === 1) return labels[0] + " connected"
    return labels.join(" · ") + " connected"
  }
  readonly property string keepText: backup.retentionLabel || Model.retentionLabel(backup.retentionPreset)
  readonly property string keepShort: Model.retentionShort(backup.retentionPreset)
  readonly property int installedCount: installedLocations.length
  readonly property int paneCount: paneLocations.length
  readonly property string locationEpoch: backup.locationEpoch

  Service {
    id: backup
    settings: root.settings
  }

  function launchAction(index) {
    var action = root.actions[Math.max(0, Math.min(index, root.actions.length - 1))]
    if (!action) return
    if (action.id === "keep") {
      root.openRetention()
      return
    }

    backup.launchTui(action.command)
    root.closeForPopoutSwitch()
  }

  function locationDescription(loc) {
    if (!loc) return ""
    var bits = []
    var kind = Model.storageKind(loc)
    if (kind) bits.push(kind)
    else if (loc.backend) bits.push(String(loc.backend))
    var clones = Model.locationCloneText(loc)
    if (clones) bits.push(clones)
    bits.push(loc.schedule === "on" ? "daily" : "manual")
    bits.push(loc.connected ? "connected" : "offline")
    return bits.join(" · ")
  }

  function openLocations() {
    if (root.paneCount < 1) return
    cursorActive = true
    focusSection = "locations"
    var list = root.paneLocations
    locationIndex = 0
    for (var i = 0; i < list.length; i++) {
      if (list[i] && String(list[i].id) === String(backup.locationId)) locationIndex = i
    }
  }

  function selectLocation(index) {
    if (backup.switching) return
    var list = root.paneLocations
    var loc = list[Math.max(0, Math.min(index, list.length - 1))]
    if (!loc) return
    locationIndex = index
    if (String(loc.id) === String(backup.locationId) || loc.active) return
    backup.switchLocation(loc.id)
  }

  function openRetention() {
    cursorActive = true
    focusSection = "retention"
    var list = root.keepPresets
    retentionIndex = 0
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === backup.retentionPreset) retentionIndex = i
    }
    pendingPreset = ""
  }

  function selectRetention(index) {
    var list = root.keepPresets
    var preset = list[Math.max(0, Math.min(index, list.length - 1))]
    if (!preset) return
    retentionIndex = index
    if (preset.id === backup.retentionPreset) {
      pendingPreset = ""
      focusSection = "actions"
      return
    }
    pendingPreset = preset.id
    focusSection = "confirm"
  }

  function confirmRetention() {
    if (pendingPreset === "") return
    var preset = pendingPreset
    pendingPreset = ""
    focusSection = "actions"
    backup.launchTui(["retention", "set", preset, "--yes"])
    root.closeForPopoutSwitch()
  }

  function cancelRetention() {
    pendingPreset = ""
    focusSection = "actions"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0) return
    if (focusSection === "retention") {
      retentionIndex = Math.max(0, Math.min(keepPresets.length - 1, retentionIndex + dy))
      return
    }
    if (focusSection === "locations") {
      var n = root.paneCount
      if (n > 0) locationIndex = Math.max(0, Math.min(n - 1, locationIndex + dy))
      return
    }
    if (focusSection === "confirm") return
    actionIndex = Math.max(0, Math.min(actions.length - 1, actionIndex + dy))
  }

  function activateCursor() {
    if (focusSection === "retention") selectRetention(retentionIndex)
    else if (focusSection === "locations") selectLocation(locationIndex)
    else if (focusSection === "confirm") confirmRetention()
    else if (focusSection === "actions") launchAction(actionIndex)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { backup.refresh(); return "ok" }
    function backupNow(): string { backup.launchTui(["clone"]); return "ok" }
    function cloneNow(): string { backup.launchTui(["clone"]); return "ok" }
  }

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  Row {
    id: chip
    spacing: Style.space(6)
    height: button.implicitHeight

    BarIconButton {
      id: button
      bar: root.bar
    iconComponent: Component {
      Item {
        OmacloneIcon {
          anchors.centerIn: parent
          iconSize: Math.round(Style.bar.iconCanvas * 0.75)
          color: root.barIconColor
          cutoutColor: root.barBg
        }
      }
    }
    foreground: root.barIconColor
    tooltipText: {
      if (backup.severity === "error" || backup.severity === "warning")
        return "Omaclone · " + (backup.issueTitle || root.heroMeta) + (backup.lastError ? " — " + backup.lastError : "")
      if (!backup.configured) return "Omaclone"
      var locInfo = backup.locationLabel || ""
      var connState = backup.connected ? "connected" : "offline"
      return "Omaclone · " + root.clonesText + " clones · " + root.storageText + " · " + root.keepText + (locInfo ? " · " + locInfo + " (" + connState + ")" : "")
    }
    active: backup.severity === "error"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) backup.refresh()
      else root.toggle()
    }
  }

    Text {
      visible: backup.configured && root.clonesText !== "—" && !(root.bar && root.bar.vertical)
      anchors.verticalCenter: parent.verticalCenter
      text: root.clonesText
      color: root.barIconColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.focusSection === "confirm" || root.focusSection === "retention") root.cancelRetention()
        else if (root.focusSection === "locations") root.focusSection = "actions"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") backup.refresh()
        else if (t === "b" || t === "B") root.launchAction(1)
        else if (t === "k" || t === "K") root.openRetention()
        else if (t === "l" || t === "L") root.openLocations()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(14)

          Item {
            id: header
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, cloneMark.implicitHeight)

            Column {
              id: headerText
              anchors.left: parent.left
              anchors.right: cloneMark.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "Omaclone"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.heroMeta.toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
              }
            }

            OmacloneIcon {
              id: cloneMark
              anchors.right: parent.right
              anchors.top: parent.top
              iconSize: Math.round(Style.font.display * 1.2)
              color: root.barIconColor
              cutoutColor: root.popupBg
            }
          }

          IssueBanner {
            visible: root.hasIssue
            width: parent.width
          }

          Column {
            visible: backup.configured && root.paneCount >= 1
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: backup.switching ? "SWITCHING…" : "LOCATION"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            Repeater {
              model: root.paneLocations
              LocationRadio {
                required property var modelData
                required property int index
                width: parent.width
                rowIndex: index
                loc: modelData
                hasCursor: root.cursorActive && root.focusSection === "locations" && root.locationIndex === index
              }
            }

            Text {
              visible: backup.switching
              width: parent.width
              text: "Switching to " + (backup.locationLabel || backup.locationId || "location") + "…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

          }

          Row {
            id: statsRow
            width: parent.width
            spacing: Style.space(8)

            StatTile {
              label: "CLONES"
              value: root.clonesText
              hint: backup.configured
                ? (root.storageText !== "—" ? "on " + root.storageText : "snapshots")
                : "none yet"
            }

            StatTile {
              label: "STORAGE"
              value: root.storageText
              hint: root.storageHintText
              clickable: root.installedCount >= 1
              onClicked: root.openLocations()
            }

            StatTile {
              label: "KEEP"
              value: root.keepShort
              hint: root.keepText
              clickable: true
              onClicked: root.openRetention()
            }
          }

          Column {
            visible: root.focusSection === "retention" || root.focusSection === "confirm"
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "KEEP PLAN"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            Repeater {
              model: root.keepPresets
              RetentionRow {
                required property var modelData
                required property int index
                width: parent.width
                preset: modelData
                rowIndex: index
              }
            }
          }

          Column {
            visible: root.focusSection === "confirm" && root.pendingPreset !== ""
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "Switch to " + Model.retentionLabel(root.pendingPreset) + "? Clones outside this plan will be pruned."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)
              ConfirmButton {
                width: (column.width - Style.space(8)) / 2
                label: "Cancel"
                destructive: false
                onClicked: root.cancelRetention()
              }
              ConfirmButton {
                width: (column.width - Style.space(8)) / 2
                label: "Confirm prune"
                destructive: true
                onClicked: root.confirmRetention()
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: root.dim
            opacity: 0.25
          }

          Text {
            text: "ACTIONS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Column {
            id: actionColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.actions
              ActionRow {
                required property var modelData
                required property int index
                width: actionColumn.width
                action: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  component IssueBanner: Item {
    id: banner
    readonly property bool isError: backup.severity === "error" || backup.switchError !== ""
    readonly property color tone: banner.isError ? root.urgent : root.warning
    implicitHeight: bannerCol.implicitHeight + Style.space(20)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(banner.tone.r, banner.tone.g, banner.tone.b, 0.14)
      border.width: 1
      border.color: Qt.rgba(banner.tone.r, banner.tone.g, banner.tone.b, 0.45)
    }

    Column {
      id: bannerCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Text {
        width: parent.width
        text: backup.switchError !== "" ? "SWITCH FAILED" : (banner.isError ? "ERROR" : "WARNING")
        color: banner.tone
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }

      Text {
        width: parent.width
        text: backup.switchError !== "" ? backup.switchError : (backup.lastError || backup.issueTitle || root.heroMeta)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Row {
        visible: banner.isError || backup.issueKind === "password_locked"
        spacing: Style.space(8)
        width: parent.width

        ConfirmButton {
          width: banner.isError ? (bannerCol.width - Style.space(8)) / 2 : bannerCol.width
          label: backup.issueKind === "password_locked" ? "Clone now" : "Retry clone"
          destructive: false
          onClicked: {
            backup.launchTui(["clone"])
            root.closeForPopoutSwitch()
          }
        }
        ConfirmButton {
          visible: banner.isError
          width: (bannerCol.width - Style.space(8)) / 2
          label: "Dismiss"
          destructive: false
          onClicked: backup.dismissIssue()
        }
      }
    }
  }

  component StatTile: Item {
    id: tile
    property string label: ""
    property string value: ""
    property string hint: ""
    property bool clickable: false
    signal clicked

    width: (statsRow.width - Style.space(8) * 2) / 3
    implicitHeight: Style.space(78)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
    }

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(4)

      Text {
        width: parent.width
        text: tile.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.1
      }

      Text {
        width: parent.width
        text: tile.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: tile.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: tile.clickable
      hoverEnabled: true
      cursorShape: tile.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: tile.clicked()
    }
  }

  component RetentionRow: CursorSurface {
    id: keepRow
    property var preset: null
    property int rowIndex: 0
    hasCursor: root.cursorActive && root.focusSection === "retention" && root.retentionIndex === rowIndex
    foreground: root.foreground
    implicitHeight: Style.space(36)

    readonly property bool isCurrent: preset && preset.id === backup.retentionPreset

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: keepRow.hasCursor || keepRow.isCurrent ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.focusSection = "retention"
        root.retentionIndex = keepRow.rowIndex
      }
      onClicked: root.selectRetention(keepRow.rowIndex)
    }

    Text {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      text: (keepRow.preset ? keepRow.preset.label : "") + (keepRow.isCurrent ? "  · current" : "")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  component ConfirmButton: Item {
    id: confirmBtn
    property string label: ""
    property bool destructive: false
    signal clicked
    implicitHeight: Style.space(36)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: confirmBtn.destructive ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      border.width: 1
      border.color: confirmBtn.destructive ? root.urgent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
    }

    Text {
      anchors.centerIn: parent
      text: confirmBtn.label
      color: confirmBtn.destructive ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: confirmBtn.destructive
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: confirmBtn.clicked()
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    property int rowIndex: 0
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === rowIndex
    foreground: root.foreground
    implicitHeight: actionInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.focusSection = "actions"
        root.actionIndex = actionRow.rowIndex
      }
      onClicked: root.launchAction(actionRow.rowIndex)
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
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: action ? action.subtitle : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰁔"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.launchAction(actionRow.rowIndex)
      }
    }
  }

  component LocationRadio: CursorSurface {
    id: locRow
    property int rowIndex: 0
    property var loc: null
    readonly property string locId: loc && loc.id ? String(loc.id) : ""
    readonly property string _epoch: root.locationEpoch
    readonly property bool isActive: !!(locId && locId === String(backup.locationId))
    readonly property bool rounded: Style.cornerRadius > 0
    hasCursor: root.cursorActive && root.focusSection === "locations" && root.locationIndex === locRow.rowIndex
    foreground: root.foreground
    implicitHeight: Math.max(Style.space(54), radioContent.implicitHeight + Style.spacing.rowPaddingX)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: locRow.hasCursor || locRow.isActive ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.focusSection = "locations"
        root.locationIndex = locRow.rowIndex
      }
      onClicked: root.selectLocation(locRow.rowIndex)
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
          width: parent.width
          text: locRow.loc ? (locRow.loc.label || locRow.loc.id) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: locRow.loc ? root.locationDescription(locRow.loc) : ""
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
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
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : Style.normalFillFor(root.foreground, Color.accent)
        border.width: 1
        border.color: locRow.isActive
          ? Style.selectedStateColor(root.foreground, Color.accent)
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)

        Rectangle {
          visible: locRow.isActive
          anchors.centerIn: parent
          width: Style.space(10)
          height: width
          radius: locRow.rounded ? width / 2 : 0
          color: Style.selectedStateColor(root.foreground, Color.accent)
        }
      }
    }
  }
}
