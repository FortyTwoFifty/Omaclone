const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8");
const ctx = { console };
vm.createContext(ctx);
vm.runInContext(src + "\nthis.Model = { defaultStatus, parseStatus, installedLocations, activeLocation, storageKind, storageDisplay, storageHint, paneLocations, locationById, locationFingerprint, connectedLabels, locationCloneText };", ctx);
const M = ctx.Model;

function fixture(overrides) {
  return Object.assign({
    configured: true,
    locationId: "nas",
    locationLabel: "NAS",
    repoSizeText: "12 GB",
    locations: [
      { id: "nas", label: "NAS", backend: "nfs", schedule: "on", connected: true, active: true, source: "config" },
      { id: "usb", label: "Discovered USB Drive", backend: "disk", schedule: "off", connected: false, active: false, source: "config" },
      { id: "stick", label: "Found stick", backend: "disk", connected: true, source: "discovered" }
    ]
  }, overrides || {});
}

const parsed = M.parseStatus(JSON.stringify(fixture()));
assert.strictEqual(parsed.locationId, "nas");
assert.ok(Array.isArray(parsed.locations));

const installed = M.installedLocations(parsed.locations);
assert.strictEqual(installed.length, 2, "discovered entries must be excluded");
assert.strictEqual(installed.map((l) => String(l.id)).join(","), "nas,usb");

const active = M.activeLocation(parsed);
assert.strictEqual(active.id, "nas");
assert.strictEqual(M.storageKind(active), "NAS");
assert.strictEqual(M.storageDisplay(active), "NAS");
assert.match(M.storageHint(active, parsed), /connected/i);

const usb = installed[1];
assert.strictEqual(M.storageKind(usb), "USB");
assert.strictEqual(M.storageDisplay(usb), "Discovered USB Drive");

const empty = M.parseStatus("");
assert.strictEqual(empty.locationId, "");
assert.ok(Array.isArray(empty.locations));
assert.strictEqual(empty.locations.length, 0);
assert.ok(Array.isArray(empty.watchPaths));
assert.strictEqual(M.storageDisplay(M.activeLocation(empty)), "—");

const stale = fixture();
stale.locationId = "usb";
stale.locations[0].active = true;
stale.locations[1].active = false;
assert.strictEqual(M.activeLocation(stale).id, "nas", "unplugged USB must not be the pane active location");

assert.strictEqual(typeof M.paneLocations, "function");
assert.strictEqual(typeof M.locationById, "function");
assert.strictEqual(typeof M.locationFingerprint, "function");

const pane = M.paneLocations(parsed.locations);
assert.strictEqual(pane.length, 2, "unplugged USB must not appear in the pane");
assert.strictEqual(pane.map((l) => String(l.id)).join(","), "nas,stick");

const byUsb = M.locationById(parsed.locations, "usb");
assert.strictEqual(byUsb.connected, false);

const flipped = fixture();
flipped.locations[1].connected = true;
assert.notStrictEqual(
  M.locationFingerprint(parsed.locations),
  M.locationFingerprint(flipped.locations)
);

const noBackend = [{ id: "ghost", label: "Ghost", source: "config" }];
assert.strictEqual(M.paneLocations(noBackend).length, 0);

const uuidDup = [
  { id: "usb", label: "USB", backend: "disk", uuid: "AAAA-1111", connected: true, source: "config" },
  { id: "discovered:/run/media/x/USB", label: "Backup at USB", backend: "disk", uuid: "AAAA-1111", connected: true, source: "discovered" }
];
const deduped = M.paneLocations(uuidDup);
assert.strictEqual(deduped.length, 1, "same UUID must not list twice");
assert.strictEqual(deduped[0].id, "usb");

const connected = M.connectedLabels(uuidDup);
assert.strictEqual(connected.join(","), "USB");

assert.strictEqual(M.locationCloneText({ snapshotCount: 3, connected: true }), "3 clones");
assert.strictEqual(M.locationCloneText({ snapshotCount: 1, connected: true }), "1 clone");
assert.strictEqual(M.locationCloneText({ snapshotCount: 3, connected: false }), "");
assert.strictEqual(M.locationCloneText({}), "");

console.log("OK");
