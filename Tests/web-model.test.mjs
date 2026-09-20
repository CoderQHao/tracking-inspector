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

const { MultiDeviceStore, DevicePoller } = await import('../Sources/TrackingInspector/Web/model.js');
const a = { id: 'a', name: 'Device A', generation: 'a1', mode: 'usb' };
const b = { id: 'b', name: 'Device B', generation: 'b1', mode: 'wifi' };
const response = (source, ids, overrides = {}) => ({ ...batch(ids, overrides), sourceID: source.id, generation: source.generation });
const flush = () => new Promise(resolve => setImmediate(resolve));

test('device IDs and sessions isolate duplicate event IDs and a single app restart', () => {
  const store = new MultiDeviceStore();
  store.updateSources([a, b]);
  store.ingest(a, batch([1, 2]));
  store.ingest(b, batch([1, 2]));
  assert.equal(new Set(store.events.map(e => e.key)).size, 4);
  assert.equal(store.filter('device b', '', '', 'b').length, 2);
  store.ingest(a, batch([1], { session: 'restarted' }));
  assert.equal(store.events.filter(e => e.sourceID === 'a').length, 1);
  assert.equal(store.events.filter(e => e.sourceID === 'b').length, 2);
  const exported = exportEvent(store.events.at(-1));
  assert.equal(exported.sourceID, 'a');
  assert.equal(exported.session, 'restarted');
  assert.ok(!('search' in exported));
});

test('pause, clear and re-pair affect only the intended device', () => {
  const store = new MultiDeviceStore();
  store.updateSources([a, b]);
  store.ingest(a, batch([1])); store.ingest(b, batch([1]));
  store.togglePause();
  store.ingest(b, batch([2]));
  assert.equal(store.visible.length, 2);
  store.clear('a');
  assert.deepEqual(store.visible.map(e => e.sourceID), ['b']);
  store.ingest(a, batch([2], { latestID: 9 }));
  assert.equal(store.channels.get('a').store.cursor, 9);
  assert.equal(store.channels.get('b').store.cursor, 2);
  store.togglePause();
  assert.equal(store.events.length, 2);
  store.updateSources([{ ...a, generation: 'a2' }, b]);
  assert.equal(store.ingest(a, batch([3])), false);
  assert.equal(store.events.length, 2);
  store.updateSources([b]);
  assert.equal(store.channels.has('a'), false);
});

test('retention budget applies across devices, regardless of phone clock skew', () => {
  const store = new MultiDeviceStore({ limit: 3, byteLimit: 10000 });
  store.updateSources([a, b]);
  store.ingest(a, batch([1, 2]));
  store.ingest(b, batch([1, 2]));
  assert.deepEqual(store.events.map(e => [e.sourceID, e.id]), [['a', 2], ['b', 1], ['b', 2]]);
  assert.equal(store.trimmed, 1);
  const tiny = new MultiDeviceStore({ byteLimit: 1200 });
  tiny.updateSources([a, b]);
  tiny.ingest(a, batch([1, 2, 3])); tiny.ingest(b, batch([1, 2, 3]));
  assert.ok(tiny.events.reduce((n, e) => n + e.bytes, 0) <= 1200);
});

test('a slow device never blocks another, and a stale response cannot restore a removed channel', async () => {
  const store = new MultiDeviceStore();
  let sources = [a, b], now = 1000, resolveA;
  const calls = [];
  const poller = new DevicePoller(store, async request => {
    if (request.command === 'channels') return sources;
    calls.push(request);
    if (request.deviceID === 'a') return new Promise(resolve => { resolveA = resolve; });
    return response(b, [request.after + 1]);
  }, () => {}, () => {}, () => now);
  await poller.tick(); await flush();
  assert.equal(store.channels.get('b').store.cursor, 1);
  assert.equal(store.channels.get('a').inFlight, true);
  now += 1000; await poller.tick(); await flush();
  assert.equal(calls.filter(c => c.deviceID === 'a').length, 1);
  assert.equal(store.channels.get('b').store.cursor, 2);
  sources = [b]; await poller.tick();
  resolveA(response(a, [1])); await flush();
  assert.deepEqual(store.events.map(e => e.sourceID), ['b', 'b']);
});

test('one device error and a mismatched generation leave other streams intact', async () => {
  const store = new MultiDeviceStore();
  let now = 1000;
  const poller = new DevicePoller(store, async request => {
    if (request.command === 'channels') return [a, b];
    if (request.deviceID === 'a') return { ...response(a, []), error: 'offline' };
    return now === 1000 ? response(b, [1]) : response({ ...b, generation: 'old' }, [2]);
  }, () => {}, () => {}, () => now);
  await poller.tick(); await flush();
  assert.equal(store.channels.get('a').error, 'offline');
  assert.equal(store.channels.get('b').connected, true);
  now += 1000; await poller.tick(); await flush();
  assert.equal(store.channels.get('b').store.cursor, 1);
  assert.equal(store.events.length, 1);
});
