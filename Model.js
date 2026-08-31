function defaultStatus() {
  return {
    ok: false,
    configured: false,
    transportReady: false,
    repo: "",
    transport: "",
    secrets: "",
    lastStatus: "unknown",
    lastError: "",
    lastBackupUnix: 0,
    statusText: "Unconfigured",
    snapshotCount: -1,
    repoSizeBytes: 0,
    repoSizeText: "—",
    packedSizeText: "",
    retentionPreset: "standard",
    retentionLabel: "7 days / 4 weeks / 6 months / 2 years",
    setupComplete: false,
    severity: "ok",
    issueTitle: "",
    issueKind: "",
    issueAcked: false,
    connected: false,
    watchPath: "",
    watchPaths: [],
    locationId: "",
    locationLabel: "",
    locationSchedule: "on",
    locations: []
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    var base = defaultStatus()
    for (var key in parsed) {
      if (Object.prototype.hasOwnProperty.call(parsed, key))
        base[key] = parsed[key]
    }
    return base
  } catch (e) {
    var failed = defaultStatus()
    failed.lastError = "Failed to parse backup status"
    failed.severity = "error"
    failed.issueTitle = "Status unreadable"
    return failed
  }
}

function installedLocations(list) {
  var out = []
  if (!list) return out
  for (var i = 0; i < list.length; i++) {
    var loc = list[i]
    if (!loc || loc.source === "discovered") continue
    if (!loc.backend) continue
    out.push(loc)
  }
  return out
}

function paneLocations(list) {
  var out = []
  var seenId = {}
  var seenUuid = {}
  if (!list) return out
  for (var i = 0; i < list.length; i++) {
    var loc = list[i]
    if (!loc) continue
    if (!loc.backend) continue
    if (String(loc.backend) === "disk" && loc.connected !== true) continue
    var id = String(loc.id || "")
    var uuid = String(loc.uuid || "")
    if (id && seenId[id]) continue
    if (uuid && seenUuid[uuid]) continue
    if (id) seenId[id] = true
    if (uuid) seenUuid[uuid] = true
    out.push(loc)
  }
  return out
}

function locationById(list, id) {
  if (!list || id === undefined || id === null) return null
  var want = String(id)
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].id) === want) return list[i]
  }
  return null
}

function locationFingerprint(list) {
  var bits = []
  var rows = paneLocations(list)
  for (var i = 0; i < rows.length; i++) {
    var loc = rows[i]
    bits.push(String(loc.id) + ":" + (loc.connected ? "1" : "0") + ":" + (loc.active ? "1" : "0"))
  }
  return bits.join("|")
}

function activeLocation(status) {
  var list = paneLocations(status && status.locations)
  var id = status && status.locationId ? String(status.locationId) : ""
  var i
  if (id) {
    for (i = 0; i < list.length; i++) {
      if (String(list[i].id) === id) return list[i]
    }
  }
  for (i = 0; i < list.length; i++) {
    if (list[i].active) return list[i]
  }
  return list[0] || null
}

function storageKind(loc) {
  if (!loc) return ""
  var b = String(loc.backend || "")
  if (b === "nfs" || b === "cifs" || b === "sftp") return "NAS"
  if (b === "disk") {
    if (loc.mode === "cold" || /usb|stick/i.test(String(loc.label || ""))) return "USB"
    return "Extra disk"
  }
  if (b === "s3") return "Cloud"
  if (b === "local") return "Local"
  return loc.label || loc.id || ""
}

function storageDisplay(loc) {
  if (!loc) return "—"
  return loc.label || storageKind(loc) || loc.id || "—"
}

function storageHint(loc, status) {
  if (!loc) return "no location"
  var bits = []
  var kind = storageKind(loc)
  if (kind && kind !== loc.label) bits.push(kind)
  else if (loc.backend) bits.push(String(loc.backend))
  bits.push(loc.connected ? "connected" : "offline")
  if (status && status.repoSizeText && status.repoSizeText !== "—")
    bits.push(String(status.repoSizeText))
  return bits.join(" · ")
}

function connectedLabels(list) {
  var out = []
  var rows = paneLocations(list)
  for (var i = 0; i < rows.length; i++) {
    if (rows[i] && rows[i].connected) out.push(storageDisplay(rows[i]))
  }
  return out
}

function locationCloneText(loc) {
  if (!loc || loc.connected !== true) return ""
  if (loc.snapshotCount === undefined || loc.snapshotCount === null) return ""
  var n = parseInt(String(loc.snapshotCount), 10)
  if (!isFinite(n) || n < 0) return ""
  return n === 1 ? "1 clone" : n + " clones"
}

function retentionPresets() {
  return [
    { id: "last-5", label: "Last 5 clones" },
    { id: "week", label: "Last 7 days" },
    { id: "month", label: "Last 30 days" },
    { id: "quarter", label: "3 months" },
    { id: "year", label: "1 year" },
    { id: "standard", label: "7 days / 4 weeks / 6 months / 2 years" }
  ]
}

function retentionLabel(id) {
  var list = retentionPresets()
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === id) return list[i].label
  }
  return "7 days / 4 weeks / 6 months / 2 years"
}

function retentionRank(id) {
  switch (id) {
    case "last-5": return 1
    case "week": return 2
    case "month": return 3
    case "quarter": return 4
    case "year": return 5
    case "standard": return 6
    default: return 6
  }
}

function retentionTighter(next, current) {
  return retentionRank(next) < retentionRank(current)
}

function retentionShort(id) {
  switch (id) {
    case "last-5": return "5"
    case "week": return "7d"
    case "month": return "30d"
    case "quarter": return "3mo"
    case "year": return "1y"
    case "standard": return "1y+"
    default: return "1y+"
  }
}
