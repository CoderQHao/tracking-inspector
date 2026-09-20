import test from 'node:test';
import assert from 'node:assert/strict';
import { diffValues, fieldAt, matchesName, normalizeRule, normalizePreferences, validateEvents, filterEvents, parseRecording, AnalysisLimits } from '../Sources/TrackingInspector/Web/analysis.js';
import { MultiDeviceStore, exportEvent } from '../Sources/TrackingInspector/Web/model.js';
const source = { id: 'a', name: 'Phone A', mode: 'usb', generation: 'g1' };
const event = (id, payload = {}, extra = {}) => ({ id, name: 'play_click', timestamp: id / 10, payload, sourceID: 'a', deviceName: 'Phone A', mode: 'usb', session: 's', app: {}, key: `a:${id}`, search: JSON.stringify(payload).toLowerCase(), ...extra });
const rule = (kind, extra = {}) => normalizeRule({ id: kind, name: kind, event: '*', kind, path: 'content.id', ...extra });
const snapshot = (events, extra = {}) => ({ session: 's', oldestID: 1, latestID: events.at(-1)?.id || 0, nextCursor: events.at(-1)?.id || 0, events, ...extra });

test('diff distinguishes missing/null/types, arrays and escaped object keys', () => {
  const result = diffValues({ x: null, a: [1, 2], 'a/b': { '~': true }, type: 1 }, { y: null, a: [1, 3, 4], 'a/b': { '~': false }, type: '1' });
  assert.deepEqual(result.map(r => [r.path, r.kind]), [['/x', 'removed'], ['/a/1', 'changed'], ['/a/2', 'added'], ['/a~1b/~0', 'changed'], ['/type', 'changed'], ['/y', 'added']]);
  assert.deepEqual(diffValues({ z: 1, a: 2 }, { a: 2, z: 1 }), []);
  assert.equal(fieldAt({ content: { id: null } }, 'content.id').present, true);
  assert.equal(fieldAt({}, 'constructor').present, false);
  assert.equal(fieldAt({ 'a/b': { '~': 2 } }, '/a~1b/~0').value, 2);
});
test('rule matching and field validation remain type-sensitive', () => {
  for (const [pattern, name, expected] of [['play_*', 'play_click', true], ['play_*', 'xplay_click', false], ['*click', 'play_click', true], ['*click', 'click_x', false], ['a*b*c', 'aXXbYYc', true], ['*a', 'aba', true], ['a*a', 'a', false]]) assert.equal(matchesName(name, pattern), expected);
  const events = [event(1), event(2, { content: { id: null } }), event(3, { content: { id: 2 } }), event(4, { content: { id: '2' } })];
  const issues = validateEvents(events, [rule('required'), rule('type', { type: 'string' }), rule('enum', { values: ['2'] })]);
  assert.deepEqual([...issues.values()].map(v => v.length), [1, 2, 2, 0]);
  assert.equal(validateEvents(events, [rule('required', { enabled: false })]).get('a:1').length, 0);
});
test('duplicate rules isolate device/session/name, key fields and time window', () => {
  const events = [event(1, { content: { id: 1 }, nonce: 1 }), event(2, { content: { id: 1 }, nonce: 2 }),
    event(3, { content: { id: 1 } }, { sourceID: 'b' }), event(4, { content: { id: 1 } }, { session: 'new' }),
    event(5, { content: { id: 1 } }, { name: 'view' }), event(10, { content: { id: 1 } }), event(11, {})];
  const rules = [rule('duplicate', { windowMs: 150, keyPaths: ['content.id'] })];
  assert.deepEqual([...validateEvents(events, rules).values()].map(v => v.length), [0, 1, 0, 0, 0, 0, 0]);
  const same = [event(1, { a: 1, b: 2 }), event(2, { b: 2, a: 1 })];
  assert.equal(validateEvents(same, [rule('duplicate', { windowMs: 200, keyPaths: [] })]).get('a:2').length, 1);
});
test('preferences roundtrip and hiding do not mutate recording or presets', () => {
  const prefs = normalizePreferences({ filter: { hiddenNames: ['play_click'] }, rules: [rule('required')], presets: [{ id: 'p', name: 'Playback', filter: { query: 'abc', hiddenNames: ['noise'] } }] });
  assert.deepEqual(normalizePreferences(JSON.parse(JSON.stringify(prefs))), prefs);
  const events = [event(1, { text: 'abc' }), event(2, { text: 'abc' }, { name: 'noise' })];
  assert.equal(filterEvents(events, prefs.filter).length, 1);
  assert.equal(filterEvents(events, { ...prefs.filter, showHidden: true }).length, 2);
  assert.equal(events.length, 2);
  assert.equal(filterEvents(events, { ...prefs.presets[0].filter, issuesOnly: true }, '', validateEvents(events, prefs.rules)).length, 1);
  assert.throws(() => normalizeRule({ ...rule('required'), kind: 'script' }));
  assert.throws(() => normalizeRule({ ...rule('required'), kind: 'duplicate', windowMs: 0, keyPaths: [] }));
  assert.throws(() => normalizePreferences({ presets: Array(21).fill({}) }));
});
test('recordings roundtrip exported fields, isolate live buffers and reject malformed files atomically', () => {
  const live = new MultiDeviceStore(); live.updateSources([source]); live.ingest(source, snapshot([event(1), event(2)]));
  const text = JSON.stringify({ formatVersion: 3, events: live.events.map(exportEvent) });
  const imported = parseRecording(text);
  assert.deepEqual(imported.events.map(exportEvent), live.events.map(e => ({ ...exportEvent(e), app: { bundleID: '', version: '', build: '' } })));
  live.clear(); assert.equal(imported.visible.length, 2);
  assert.equal(imported.metadata()[0].connected, false);
  assert.equal(parseRecording(text.replace('"formatVersion":3', '"formatVersion":2')).events.length, 2);
  for (const value of [{ formatVersion: 4, events: [] }, { formatVersion: 3, events: [event(1), event(1)] }, { formatVersion: 3, events: [event(-1)] }, { formatVersion: 3, events: [event(1, [])] }, { formatVersion: 3, events: Array(AnalysisLimits.events + 1).fill(event(1)) }]) assert.throws(() => parseRecording(JSON.stringify(value)));
  assert.throws(() => parseRecording('{bad'));
  let nested = {}; for (let i = 0; i < 35; i++) nested = { child: nested };
  assert.throws(() => parseRecording(JSON.stringify({ formatVersion: 3, events: [event(1, nested)] })));
});
test('merging authenticated aliases retains cursor, deduplicates rows and freezes correctly', () => {
  const store = new MultiDeviceStore(); const b = { ...source, id: 'b', generation: 'g2' };
  store.updateSources([source, b]); store.ingest(source, snapshot([event(1), event(2)])); store.ingest(b, snapshot([event(1), event(2), event(3)]));
  store.togglePause();
  const merged = { ...source, id: 'device:stable', generation: 'g3', aliases: ['a', 'b'] };
  store.updateSources([merged]);
  assert.equal(store.channels.size, 1); assert.equal(store.channels.get(merged.id).store.cursor, 3);
  assert.deepEqual(store.events.map(e => e.id), [1, 2, 3]); assert.equal(store.visible.length, 3);
  assert.ok(store.events.every(e => e.sourceID === merged.id));
  assert.equal(store.ingest(source, snapshot([event(4)])), false);
  store.togglePause(); store.ingest(merged, snapshot([event(3), event(4)], { connection: { mode: 'lan' } }));
  assert.deepEqual(store.events.map(e => e.id), [1, 2, 3, 4]); assert.equal(store.events.at(-1).mode, 'lan');
});
test('merging with an established stream preserves clear boundary and independent devices', () => {
  const store = new MultiDeviceStore(); const b = { ...source, id: 'b', generation: 'g2' }; const c = { ...source, id: 'c', generation: 'g3' };
  store.updateSources([source, b, c]); store.ingest(source, snapshot([event(1)])); store.ingest(b, snapshot([event(1), event(2)])); store.ingest(c, snapshot([event(1)]));
  store.clear('a'); store.updateSources([{ ...source, aliases: ['b'] }, c]);
  store.ingest(source, snapshot([event(2), event(3)], { latestID: 10 }));
  assert.equal(store.channels.get('a').store.cursor, 10);
  assert.equal(store.events.filter(e => e.sourceID === 'a').length, 0);
  assert.equal(store.events.filter(e => e.sourceID === 'c').length, 1);
});
