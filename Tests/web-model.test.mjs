import test from "node:test";
import assert from "node:assert/strict";
import { EventStore, exportEvent } from "../Sources/TrackingInspector/Web/model.js";

const event = id => ({ id, timestamp: id, name: "button_click", payload: { event_info: { action: "CLICK", current_page_name: "DEMO" }, content_info: { id: "模拟项目" } } });
const batch = (ids, overrides = {}) => ({ session: "app-1", events: ids.map(event), oldestID: 1, latestID: ids.at(-1) || 0, nextCursor: ids.at(-1) || 0, ...overrides });

test("reconnect deduplicates, restart resets identity and cursor", () => {
  const store = new EventStore();
  store.ingest(batch([1, 2]));
  store.ingest(batch([1, 2, 3]));
  assert.deepEqual(store.events.map(e => e.id), [1, 2, 3]);
  assert.equal(store.ingest(batch([1], { session: "app-2" })).changed, true);
  assert.deepEqual(store.events.map(e => e.id), [1]);
  assert.equal(store.cursor, 1);
});
test("clear rejects in-flight history and backlog through a snapshot boundary", () => {
  const store = new EventStore();
  store.ingest(batch([1]));
  store.clear();
  store.ingest(batch([2, 3], { latestID: 8 }));
  assert.equal(store.events.length, 0);
  assert.equal(store.cursor, 8);
  store.ingest(batch([9], { oldestID: 1 }));
  assert.deepEqual(store.events.map(e => e.id), [9]);
});
test("pause freezes display while receiving, retaining, and filtering new events", () => {
  const store = new EventStore({ limit: 2 });
  store.ingest(batch([1, 2]));
  store.togglePause();
  store.ingest(batch([3, 4]));
  assert.deepEqual(store.visible.map(e => e.id), [1, 2]);
  store.togglePause();
  assert.deepEqual(store.visible.map(e => e.id), [3, 4]);
  assert.equal(store.filter("button 模拟项目", "CLICK", "DEMO").length, 2);
  assert.equal(store.filter("missing", "", "").length, 0);
});
test("byte cap, lost history and exports are explicit", () => {
  const store = new EventStore({ byteLimit: 1000 });
  store.ingest(batch([4, 5, 6, 7], { oldestID: 4 }));
  assert.equal(store.missed, 3);
  assert.ok(store.bytes <= 1000);
  assert.ok(store.trimmed > 0);
  assert.deepEqual(exportEvent(store.events.at(-1)), event(7));
});
