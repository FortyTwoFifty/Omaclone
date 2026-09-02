var MAX_STATUS_BYTES = 65536
var MAX_STRING = 512
var MAX_LOCATIONS = 32
var MAX_WATCH_PATHS = 8

function clampString(value, max) {
  var text = String(value == null ? "" : value)
  if (max === undefined) max = MAX_STRING
  if (text.length > max) return text.substring(0, max)
  return text
}

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

function parseLocationRow(row) {
  if (!row || typeof row !== "object") return null
  var backend = clampString(row.backend, 32)
  if (!backend) return null
  return {
    id: clampString(row.id, 128),
    label: clampString(row.label, MAX_STRING),
    backend: backend,
    uuid: clampString(row.uuid, 64),
    source: clampString(row.source, 32),
    mode: clampString(row.mode, 16),
    schedule: clampString(row.schedule, 16),
    connected: row.connected === true,
    active: row.active === true,
    snapshotCount: row.snapshotCount,
    preset: clampString(row.preset, 32),
    config: clampString(row.config, 512)
  }
}

function parseStatus(raw) {
  var text = String(raw || "")
  if (text.length > MAX_STATUS_BYTES) {
    var oversized = defaultStatus()
    oversized.lastError = "Failed to parse backup status"
    oversized.severity = "error"
    oversized.issueTitle = "Status unreadable"
    return oversized
  }
  text = text.trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    var base = defaultStatus()
    var key
    for (key in base) {
      if (!Object.prototype.hasOwnProperty.call(parsed, key)) continue
      if (key === "locations" || key === "watchPaths") continue
      if (typeof base[key] === "string") base[key] = clampString(parsed[key])
      else if (typeof base[key] === "boolean") base[key] = parsed[key] === true
      else if (typeof base[key] === "number") {
        var n = parseInt(String(parsed[key]), 10)
        base[key] = isFinite(n) ? n : base[key]
      } else base[key] = parsed[key]
    }
    var locs = parsed.locations
    var copy = []
    if (locs && typeof locs.length === "number") {
      for (var i = 0; i < locs.length && copy.length < MAX_LOCATIONS; i++) {
        var loc = parseLocationRow(locs[i])
        if (loc) copy.push(loc)
      }
    }
    base.locations = copy
    var paths = parsed.watchPaths
    var pc = []
    if (paths && typeof paths.length === "number") {
      for (var p = 0; p < paths.length && pc.length < MAX_WATCH_PATHS; p++) {
        var wp = clampString(paths[p], 128)
        if (watchPathAllowed(wp)) pc.push(wp)
      }
    }
    base.watchPaths = pc
    if (!watchPathAllowed(base.watchPath)) base.watchPath = ""
    return base
  } catch (e) {
    var failed = defaultStatus()
    failed.lastError = "Failed to parse backup status"
    failed.severity = "error"
    failed.issueTitle = "Status unreadable"
    return failed
  }
}

function parseDiscover(raw) {
  var text = String(raw || "")
  if (text.length > MAX_STATUS_BYTES) return []
  text = text.trim()
  if (text === "") return []
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return []
  }
  if (!parsed || typeof parsed.length !== "number") return []
  var copy = []
  for (var i = 0; i < parsed.length && copy.length < MAX_LOCATIONS; i++) {
    var row = parseLocationRow(parsed[i])
    if (row && row.source === "discovered") copy.push(row)
  }
  return copy
}

function shouldApplyStatus(switching, targetId, parsed) {
  if (!switching) return true
  if (!parsed || typeof parsed !== "object") return false
  var got = String(parsed.locationId || "")
  var want = String(targetId || "")
  return want !== "" && got !== "" && got === want
}

function watchPathAllowed(p) {
  var s = String(p || "")
  if (s.length > 128) return false
  return /^\/dev\/disk\/by-uuid\/[0-9A-Fa-f-]+$/.test(s)
}

function watchPathsEqual(a, b) {
  function fingerprint(list) {
    var out = []
    if (list && typeof list.length === "number") {
      for (var i = 0; i < list.length; i++) out.push(String(list[i] || ""))
    }
    out.sort()
    return out.join("\0")
  }
  return fingerprint(a) === fingerprint(b)
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
  if (b === "s3") {
    var preset = String(loc.preset || "")
    if (preset === "aws") return "AWS S3"
    if (preset === "r2") return "Cloudflare R2"
    if (preset === "wasabi") return "Wasabi"
    if (preset === "b2") return "Backblaze B2"
    if (preset === "minio") return "MinIO"
    return "Cloud"
  }
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

function connectionLabel(loc, transportReady) {
  if (!loc || loc.connected !== true) return "offline"
  var backend = String(loc.backend || "")
  if ((backend === "s3" || backend === "sftp") && loc.active && transportReady === false)
    return "keys missing"
  return "connected"
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
