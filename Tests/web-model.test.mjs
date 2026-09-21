import test from 'node:test';
import assert from 'node:assert/strict';
import { NativeRecordingStore, RecordingPoller, exportEvent } from '../Sources/TrackingInspector/Web/model.js';

const source = (id = 'a', epoch = 'e') => ({ id, name: `Device ${id}`, session: 's', mode: 'usb', epoch, acceptedEpochs: [epoch], aliases: [], connected: true });
const event = (id, sourceID = 'a', extra = {}) => ({ id, timestamp: id, name: 'play_click', payload: { value: '中文' },
  sourceID, deviceName: `Device ${sourceID}`, session: 's', mode: 'usb', app: {}, arrival: id, epoch: 'e', ...extra });
const snapshot = (events, extra = {}) => ({ reset: true, version: 1, sequence: events.at(-1)?.arrival || 0,
  oldestArrival: events[0]?.arrival || 1, channels: [source()], trimmed: 0, missed: 0, events, ...extra });

test('incremental snapshots and a recreated view show the same retained recording', () => {
  const view = new NativeRecordingStore();
  view.applySnapshot(snapshot([event(1), event(2)]));
  view.applySnapshot(snapshot([event(3)], { reset: false, oldestArrival: 2, trimmed: 1 }));
  assert.deepEqual(view.events.map(e => e.id), [2, 3]);
  const reopened = new NativeRecordingStore();
  reopened.applySnapshot(snapshot([event(2), event(3)], { trimmed: 1 }));
  assert.deepEqual(view.events, reopened.events);
  assert.equal(view.applySnapshot(snapshot([], { reset: false, sequence: 3, oldestArrival: 2, trimmed: 1 })), false);
  assert.ok(view.visible[0].search.includes('中文'));
  assert.ok(!('epoch' in exportEvent(view.visible[0])));
  assert.ok(!('arrival' in exportEvent(view.visible[0])));
});

test('pause freezes display across retention while new native data continues arriving', () => {
  const view = new NativeRecordingStore();
  view.applySnapshot(snapshot([event(1), event(2)]));
  view.togglePause();
  view.applySnapshot(snapshot([event(3), event(4)], { reset: false, oldestArrival: 3, trimmed: 2 }));
  assert.deepEqual(view.visible.map(e => e.id), [1, 2]);
  assert.deepEqual(view.events.map(e => e.id), [3, 4]);
  view.togglePause();
  assert.deepEqual(view.visible.map(e => e.id), [3, 4]);
});

test('clear, restart and deselection invalidate only the affected frozen rows', () => {
  const view = new NativeRecordingStore();
  view.applySnapshot(snapshot([event(1), event(1, 'b', { arrival: 2 })], { channels: [source(), source('b')] }));
  view.togglePause();
  view.applySnapshot(snapshot([event(1, 'b', { arrival: 2 })], { version: 2, channels: [source('a', 'cleared'), source('b')] }));
  assert.deepEqual(view.visible.map(e => e.sourceID), ['b']);
  view.applySnapshot(snapshot([event(1, 'b', { epoch: 'new', session: 'restarted', arrival: 3 })], {
    version: 3, channels: [{ ...source('b', 'new'), session: 'restarted' }]
  }));
  assert.equal(view.visible.length, 0);
  view.togglePause();
  assert.equal(view.visible[0].session, 'restarted');
  view.applySnapshot(snapshot([], { version: 4, channels: [] }));
  assert.equal(view.events.length, 0);
});

test('authenticated alias merges rekey frozen rows and deduplicate without unpausing', () => {
  const view = new NativeRecordingStore();
  view.applySnapshot(snapshot([event(1), event(1, 'b', { arrival: 2, epoch: 'b' }), event(2, 'b', { arrival: 3, epoch: 'b' })],
    { channels: [source(), source('b', 'b')] }));
  view.togglePause();
  const merged = { ...source('device'), aliases: ['a', 'b'], acceptedEpochs: ['e', 'b'] };
  view.applySnapshot(snapshot([event(1, 'device'), event(2, 'device', { arrival: 3 })], { version: 2, channels: [merged] }));
  assert.equal(view.paused, true);
  assert.deepEqual(view.visible.map(e => [e.sourceID, e.id]), [['device', 1], ['device', 2]]);
});

test('clear waits for the previous snapshot, then replaces it with the authoritative result', async () => {
  const view = new NativeRecordingStore();
  let resolveOld;
  const calls = [];
  const poller = new RecordingPoller(view, async request => {
    calls.push(request.command);
    if (calls.length === 1) return new Promise(resolve => { resolveOld = resolve; });
    if (request.command === 'clearRecording') return true;
    return snapshot([], { version: 2, sequence: 10, channels: [source('a', 'clear')] });
  });
  const first = poller.tick();
  assert.equal(poller.tick(), first);
  const clear = poller.clear('a');
  await Promise.resolve();
  resolveOld(snapshot([event(1)]));
  await clear;
  assert.deepEqual(calls, ['recording', 'clearRecording', 'recording']);
  assert.equal(view.events.length, 0);
  assert.equal(view.sequence, 10);
});

test('bridge failures recover and refresh their notice even when the recording is unchanged', async () => {
  const view = new NativeRecordingStore();
  let fail = false, error = '', renders = 0;
  const poller = new RecordingPoller(view, async () => {
    if (fail) throw new Error('bridge unavailable');
    return snapshot([], { reset: view.version < 0 });
  }, () => { renders++; }, message => { error = message; });
  await poller.tick(); fail = true;
  await poller.tick();
  assert.equal(error, 'bridge unavailable');
  fail = false;
  await poller.tick();
  assert.equal(error, '');
  assert.equal(renders, 3);
});
