import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeRule, normalizeFilter, normalizePreferences, ruleMatchesEvent, validateEvents, filterEvents, fieldAt, fieldLabel, collectFields, sameFilter, parseAllowedValue } from '../Sources/TrackingInspector/Web/analysis.js';

const event = (id, payload = {}, name = 'play_click') => ({ id, key: `a:${id}`, payload, name, sourceID: 'a', session: 's', timestamp: id, search: JSON.stringify(payload).toLowerCase() });
const rule = (kind, extra = {}) => normalizeRule({ id: 'r', name: '检查', event: 'play_click', kind, path: '/value', ...extra });
const failures = (events, r) => [...validateEvents(events, [r]).values()].map(v => v.length);

test('v0.3.0 preferences retain wildcard matching, optional type checks and saved exclusions', () => {
  const old = { version: 1, filter: { hiddenNames: ['noise'], query: 'player' }, presets: [{ id: 'p', name: '旧筛选', filter: { page: 'player', hiddenNames: ['noise'] } }], rules: [
    { id: 'r', name: '旧类型', kind: 'type', event: 'play_*', path: 'content.id', type: 'string', enabled: false },
    { id: 'required', name: '旧必填', kind: 'required', event: '*', path: 'content.id' }
  ] };
  const prefs = normalizePreferences(old);
  assert.deepEqual(prefs.filter.hiddenNames, ['noise']);
  assert.equal(prefs.filter.eventName, '');
  assert.equal(prefs.rules[0].eventMatch, 'pattern');
  assert.equal(prefs.rules[0].requirePresent, false);
  assert.equal(prefs.rules[0].enabled, false);
  assert.equal(ruleMatchesEvent(event(1), prefs.rules[0]), true);
  assert.deepEqual(failures([event(1), event(2, { content: { id: null } })], prefs.rules[1]), [1, 0]);
  assert.deepEqual(normalizePreferences(JSON.parse(JSON.stringify(prefs))), prefs);
  assert.equal(normalizePreferences({ ...old, activePresetID: 'p' }).activePresetID, 'p');
  assert.equal(normalizePreferences({ ...old, activePresetID: 'deleted' }).activePresetID, '');
});

test('nonempty rejects missing/null/empty containers and whitespace but accepts zero and false', () => {
  const events = [event(1), ...[null, '', ' \n\t', [], {}, 0, false, [null], { a: '' }, '0'].map((value, i) => event(i + 2, { value }))];
  assert.deepEqual(failures(events, rule('nonempty')), [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]);
  assert.deepEqual(failures(events, rule('required')), [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
});

test('type and allowed-value rules can require presence in the same rule', () => {
  const events = [event(1), event(2, { value: '1' }), event(3, { value: 1 }), event(4, { value: null })];
  for (const r of [rule('type', { type: 'string' }), rule('enum', { values: ['1'] })]) {
    assert.deepEqual(failures(events, r), [0, 0, 1, 1]);
    assert.deepEqual(failures(events, { ...r, requirePresent: true }), [1, 0, 1, 1]);
  }
});

test('direct event selection treats wildcard characters literally, while older patterns still work', () => {
  const events = [event(1, {}, 'play_*'), event(2), event(3, {}, 'view')];
  const exact = rule('nonempty', { event: 'play_*', eventMatch: 'exact' });
  assert.deepEqual(failures(events, exact), [1, 0, 0]);
  assert.deepEqual(failures(events, { ...exact, eventMatch: 'pattern' }), [1, 1, 0]);
  assert.deepEqual(filterEvents(events, normalizeFilter({ eventName: 'play_*' })).map(e => e.id), [1]);
});

test('field discovery preserves escaped keys, arrays and fields missing from the selected event', () => {
  const events = [event(1, { 'a/b': { '~key': 0 }, 'dot.key': false, items: [{ id: 'a' }], value: null }), event(2, { value: 2, later: { id: 3 } })];
  const fields = collectFields(events);
  const slash = fields.find(f => f.path === '/a~1b/~0key');
  assert.equal(slash.label, '["a/b"]["~key"]');
  assert.equal(fieldLabel('/items/0/id'), 'items["0"].id');
  assert.equal(fieldAt(events[0].payload, '/dot.key').value, false);
  assert.equal(fields.find(f => f.path === '/value').sample, null);
  assert.equal(fields.find(f => f.path === '/later/id').sample, 3);
  for (const field of fields) assert.ok(events.some(e => fieldAt(e.payload, field.path).present));
});

test('preset modification detection ignores exclusion order and detects every effective condition', () => {
  const original = normalizeFilter({ eventName: 'play_click', hiddenNames: ['noise', 'view'] });
  assert.ok(sameFilter(original, { ...original, hiddenNames: ['view', 'noise', 'noise'] }));
  for (const change of [{ eventName: '' }, { query: 'foo' }, { action: 'CLICK' }, { page: 'player' }, { showHidden: true }, { issuesOnly: true }, { hiddenNames: [] }]) assert.equal(sameFilter(original, { ...original, ...change }), false);
  assert.deepEqual(original.hiddenNames, ['noise', 'view']);
});

test('plain allowed-value entry preserves types, whitespace and false/null', () => {
  assert.equal(parseAllowedValue(' 1 ', 'string'), ' 1 ');
  assert.equal(parseAllowedValue('1', 'number'), 1);
  assert.equal(parseAllowedValue('false', 'boolean'), false);
  assert.equal(parseAllowedValue('', 'null'), null);
  for (const value of ['', ' ', 'Infinity', 'NaN']) assert.throws(() => parseAllowedValue(value, 'number'));
  assert.throws(() => parseAllowedValue('yes', 'boolean'));
  const values = [parseAllowedValue('1', 'string'), parseAllowedValue('false', 'boolean'), parseAllowedValue('', 'null')];
  assert.deepEqual(failures([event(1, { value: '1' }), event(2, { value: 1 }), event(3, { value: false }), event(4, { value: null })], rule('enum', { values })), [0, 1, 0, 0]);
});
