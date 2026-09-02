import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool configured: false
  property bool setupComplete: false
  property bool transportReady: false
  property bool ok: false
  property string repo: ""
  property string transport: ""
  property string secrets: ""
  property string lastStatus: "unknown"
  property string lastError: ""
  property string statusText: "Checking…"
  property int snapshotCount: -1
  property int repoSizeBytes: 0
  property string repoSizeText: "—"
  property string packedSizeText: ""
  property string retentionPreset: "standard"
  property string retentionLabel: "7 days / 4 weeks / 6 months / 2 years"
  property string locationId: ""
  property string locationLabel: ""
  property string locationSchedule: "on"
  property var locations: []
  property bool refreshing: false
  property bool switching: false
  property string switchError: ""
  property string severity: "ok"
  property string issueTitle: ""
  property string issueKind: ""
  property bool issueAcked: false
  property bool connected: false
  property string watchPath: ""
  property var watchPaths: []
  property string locationEpoch: ""
  property bool paneOpen: false
  property bool _wantDiscover: false
  property int _statusGen: 0
  property int _statusRunGen: 0
  property bool _pendingRefresh: false
  property bool _statusBusy: false
  readonly property bool hasOfflineRemovable: {
    var src = locations || []
    for (var i = 0; i < src.length; i++) {
      var loc = src[i]
      if (!loc || loc.source === "discovered") continue
      var b = String(loc.backend || "")
      if ((b === "disk" || b === "nfs" || b === "cifs" || b === "sftp") && loc.connected !== true) return true
    }
    return false
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property string pluginDir: {
    try {
      var u = String(Qt.resolvedUrl("./"))
      if (u.indexOf("file://") === 0) {
        u = u.substring(7)
        if (u.length && u.charAt(0) !== "/") {
          var slash = u.indexOf("/")
          if (slash >= 0) u = u.substring(slash)
        }
        try { u = decodeURIComponent(u) } catch (e) {}
        if (u.length > 1 && u.charAt(u.length - 1) === "/")
          u = u.substring(0, u.length - 1)
        if (u) return u
      }
    } catch (e) {}
    var home = Quickshell.env("HOME") + "/.config/omarchy/plugins/"
    return home + "omaclone.plugin"
  }
  readonly property string helperPath: pluginDir + "/scripts/status.sh"
  readonly property string discoverPath: pluginDir + "/scripts/discover-status.sh"
  readonly property string cliPath: pluginDir + "/scripts/omaclone"
  readonly property string mediaWatchPath: {
    var user = Quickshell.env("USER")
    return user ? "/run/media/" + user : ""
  }
  readonly property string mediaWatchPathAlt: {
    var user = Quickshell.env("USER")
    return user ? "/media/" + user : ""
  }

  property string _output: ""
  property string _error: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function requestDiscover() {
    _wantDiscover = true
    refresh()
  }

  function refresh() {
    if (switching) {
      _pendingRefresh = true
      return
    }
    if (statusProc.running || _statusBusy) {
      _pendingRefresh = true
      return
    }
    _startStatus()
  }

  function _startStatus() {
    _pendingRefresh = false
    _statusBusy = true
    _statusGen += 1
    _statusRunGen = _statusGen
    _output = ""
    _error = ""
    refreshing = true
    watchdogTimer.restart()
    statusProc.command = [helperPath]
    statusProc.running = true
  }

  function _statusFinished() {
    if (_pendingRefresh && !switching && !_statusBusy && !statusProc.running)
      _startStatus()
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (parsed && parsed.lastError === "Failed to parse backup status") {
      root._pendingRefresh = true
      return
    }
    if (!Model.shouldApplyStatus(switching, locationId, parsed)) return
    configured = parsed.configured === true
    setupComplete = parsed.setupComplete === true
    transportReady = parsed.transportReady === true
    ok = parsed.ok === true
    repo = String(parsed.repo || "")
    transport = String(parsed.transport || "")
    secrets = String(parsed.secrets || "")
    lastStatus = String(parsed.lastStatus || "unknown")
    lastError = String(parsed.lastError || "")
    statusText = String(parsed.statusText || lastStatus)
    var sc = parseInt(String(parsed.snapshotCount), 10)
    snapshotCount = isFinite(sc) ? sc : -1
    repoSizeBytes = parseInt(String(parsed.repoSizeBytes || 0), 10) || 0
    repoSizeText = String(parsed.repoSizeText || "—")
    packedSizeText = String(parsed.packedSizeText || "")
    retentionPreset = String(parsed.retentionPreset || "standard")
    retentionLabel = String(parsed.retentionLabel || Model.retentionLabel(retentionPreset))
    locationId = String(parsed.locationId || "")
    locationLabel = String(parsed.locationLabel || locationId)
    locationSchedule = String(parsed.locationSchedule || "on")
    severity = String(parsed.severity || "ok")
    issueTitle = String(parsed.issueTitle || "")
    issueKind = String(parsed.issueKind || "")
    issueAcked = parsed.issueAcked === true
    connected = parsed.connected === true
    var nextWatch = String(parsed.watchPath || "")
    if (nextWatch !== watchPath) watchPath = nextWatch
    var locs = parsed.locations
    if (locs && (Array.isArray(locs) || typeof locs.length === "number")) {
      var copy = []
      for (var i = 0; i < locs.length; i++) copy.push(locs[i])
      locations = copy
    } else {
      locations = []
    }
    if (!locationId) {
      for (var j = 0; j < locations.length; j++) {
        if (locations[j] && locations[j].active) {
          locationId = String(locations[j].id || "")
          locationLabel = String(locations[j].label || locationId)
          break
        }
      }
    }
    if (!locations.length) {
      locationId = ""
      locationLabel = ""
    }
    var paths = parsed.watchPaths
    if (paths && typeof paths.length === "number") {
      var pc = []
      for (var p = 0; p < paths.length; p++) {
        if (paths[p]) pc.push(String(paths[p]))
      }
      watchPaths = pc
    } else {
      watchPaths = []
    }
    locationEpoch = Model.locationFingerprint(locations)
    if (_wantDiscover) {
      _wantDiscover = false
      discover()
    }
  }

  function applyDiscover(raw) {
    if (switching) {
      _wantDiscover = true
      return
    }
    var text = String(raw || "").trim()
    if (text === "") return
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!parsed || typeof parsed.length !== "number") return
    var copy = []
    var src = locations || []
    var i
    for (i = 0; i < src.length; i++) {
      if (src[i] && src[i].source !== "discovered") copy.push(src[i])
    }
    for (i = 0; i < parsed.length; i++) {
      var row = parsed[i]
      if (!row || row.source !== "discovered") continue
      if (!row.backend) continue
      copy.push(row)
    }
    locations = copy
    locationEpoch = Model.locationFingerprint(copy)
  }

  function discover() {
    if (discoverProc.running) discoverProc.running = false
    discoverProc.command = [discoverPath]
    discoverProc.running = true
  }

  function launchTui(args) {

    var quoted = Util.shellQuote(pluginDir + "/scripts/launch-tui.sh") + " " + Util.shellQuote(cliPath)
    for (var i = 0; i < args.length; i++) quoted += " " + Util.shellQuote(args[i])
    Util.execDetached(quoted)
  }

  function switchLocation(id) {
    if (!id || switchProc.running) return
    lastStatus = "unknown"
    lastError = ""
    ok = false
    severity = "ok"
    issueTitle = ""
    switchError = ""
    switching = true
    _pendingRefresh = false
    _statusGen += 1
    snapshotCount = -1
    repoSizeText = "—"
    repoSizeBytes = 0
    packedSizeText = ""
    locationId = String(id)
    if (statusProc.running) statusProc.running = false
    watchdogTimer.restart()
    var src = locations || []
    var copy = []
    for (var i = 0; i < src.length; i++) {
      var item = src[i] || {}
      var next = {}
      for (var key in item) {
        if (Object.prototype.hasOwnProperty.call(item, key)) next[key] = item[key]
      }
      next.active = String(item.id) === String(id)
      if (next.active) {
        locationLabel = String(item.label || item.id || "")
        locationSchedule = String(item.schedule || "on")
      }
      copy.push(next)
    }
    locations = copy
    locationEpoch = Model.locationFingerprint(copy)
    switchProc.command = [cliPath, "location", "switch", id, "--yes"]
    switchProc.running = true
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var runGen = root._statusRunGen
      root._statusBusy = false
      root.refreshing = false
      if (!root.switching) watchdogTimer.stop()
      if (runGen !== root._statusGen) {
        root._statusFinished()
        return
      }
      var stdout = String(statusStdout.text || "")
      var stderr = String(statusStderr.text || "")
      if (stdout.trim() !== "") { root.applyStatus(stdout); root._fsWatchArmed = true; }
      else {
        root._pendingRefresh = true
      }
      root._statusFinished()
    }
  }

  Process {
    id: switchProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: switchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.switching = false
      if (exitCode !== 0) {
        var err = String(switchStderr.text || "").trim()
        root.switchError = err !== "" ? err : "Failed to switch location"
      }
      root.refresh()
    }
  }

  Process {
    id: discoverProc
    running: false
    command: []
    stdout: StdioCollector { id: discoverStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(discoverStdout.text || "")
      if (stdout.trim() !== "") root.applyDiscover(stdout)
    }
  }

  function dismissIssue() {
    switchError = ""
    if (ackProc.running) ackProc.running = false
    ackProc.command = [cliPath, "status", "--ack"]
    ackProc.running = true
  }

  Process {
    id: ackProc
    running: false
    command: []
    onExited: function(exitCode) {
      root.refresh()
    }
  }

  Timer {
    id: _debounceTimer
    interval: 400
    running: false
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: _discoverDebounce
    interval: 400
    running: false
    repeat: false
    onTriggered: root.requestDiscover()
  }

  property bool _fsWatchArmed: false

  Timer {
    id: refreshTimer
    property int _interval: {
      if (!root.configured) return root.refreshIntervalSec
      if (!root.connected || root.hasOfflineRemovable || root.paneOpen)
        return Math.min(root.refreshIntervalSec, 10)
      return root.refreshIntervalSec
    }
    interval: _interval * 1000
    running: true
    repeat: true
    onTriggered: {
      if (root.paneOpen) root.requestDiscover()
      else root.refresh()
    }
    onIntervalChanged: { restart(); }
  }

  FileView {
    id: watchFileView
    path: watchPath
    watchChanges: true
    printErrors: false
    onLoaded: if (root._fsWatchArmed && root.watchPath !== "") _debounceTimer.restart()
    onLoadFailed: if (root._fsWatchArmed && root.watchPath !== "") _debounceTimer.restart()
    onFileChanged: if (root._fsWatchArmed && root.watchPath !== "") _debounceTimer.restart()
  }

  FileView {
    id: lastResultFileView
    path: {
      var data = Quickshell.env("XDG_DATA_HOME")
      if (data && data.length) return data + "/omaclone/last-result.json"
      return Quickshell.env("HOME") + "/.local/share/omaclone/last-result.json"
    }
    watchChanges: true
    printErrors: false
    onFileChanged: if (root._fsWatchArmed) _debounceTimer.restart()
  }

  Instantiator {
    model: root.watchPaths
    delegate: FileView {
      required property string modelData
      path: modelData
      watchChanges: true
      printErrors: false
      onLoaded: if (root._fsWatchArmed && path !== "") _debounceTimer.restart()
      onLoadFailed: if (root._fsWatchArmed && path !== "") _debounceTimer.restart()
      onFileChanged: if (root._fsWatchArmed && path !== "") _debounceTimer.restart()
    }
  }

  FileView {
    id: mediaWatchView
    path: root.mediaWatchPath
    watchChanges: true
    printErrors: false
    onLoaded: if (root._fsWatchArmed && root.mediaWatchPath !== "") _discoverDebounce.restart()
    onLoadFailed: if (root._fsWatchArmed && root.mediaWatchPath !== "") _discoverDebounce.restart()
    onFileChanged: if (root._fsWatchArmed && root.mediaWatchPath !== "") _discoverDebounce.restart()
  }

  FileView {
    id: mediaWatchViewAlt
    path: root.mediaWatchPathAlt
    watchChanges: true
    printErrors: false
    onLoaded: if (root._fsWatchArmed && root.mediaWatchPathAlt !== "") _discoverDebounce.restart()
    onLoadFailed: if (root._fsWatchArmed && root.mediaWatchPathAlt !== "") _discoverDebounce.restart()
    onFileChanged: if (root._fsWatchArmed && root.mediaWatchPathAlt !== "") _discoverDebounce.restart()
  }

  Timer {
    id: watchdogTimer
    interval: 12000
    running: false
    repeat: false
    onTriggered: {
      root._statusGen += 1
      if (statusProc.running) statusProc.running = false
      root.refreshing = false
      if (root.switching) {
        if (switchProc.running) switchProc.running = false
        root.switching = false
        root.switchError = "Location switch timed out"
        root.refresh()
      } else if (root._statusBusy) {
        root.lastError = "Status helper failed"
        root.severity = "error"
        root.issueTitle = "Status unreadable"
      }
    }
  }

  Component.onCompleted: root.refresh()
}
