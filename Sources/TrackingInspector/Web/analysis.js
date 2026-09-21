// Pure analysis shared by the live workspace, imported recordings and tests.
const AnalysisLimits = Object.freeze({ events: 2000, bytes: 16 * 1024 * 1024, fileBytes: 40 * 1024 * 1024, rules: 50, presets: 20, hidden: 100 });
const own = (value, key) => value !== null && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, key);
const kindOf = value => value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
const pointerPart = key => String(key).replace(/~/g, '~0').replace(/\//g, '~1');
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  return JSON.stringify(value);
}
function diffValues(before, after) {
  const changes = [];
  function walk(a, b, path, hasA = true, hasB = true) {
    if (!hasA || !hasB) { changes.push({ path: path || '/', kind: hasA ? 'removed' : 'added', before: a, after: b }); return; }
    if (kindOf(a) !== kindOf(b)) { changes.push({ path: path || '/', kind: 'changed', before: a, after: b }); return; }
    if (a !== null && typeof a === 'object') {
      for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) walk(a[key], b[key], `${path}/${pointerPart(key)}`, own(a, key), own(b, key));
    } else if (a !== b) changes.push({ path: path || '/', kind: 'changed', before: a, after: b });
  }
  walk(before, after, '');
  return changes;
}
function fieldAt(payload, path) {
  const parts = path.startsWith('/') ? path.slice(1).split('/').map(v => v.replace(/~1/g, '/').replace(/~0/g, '~')) : path.split('.');
  let value = payload;
  for (const part of parts) { if (!own(value, part)) return { present: false }; value = value[part]; }
  return { present: true, value };
}
function matchesName(name, pattern) {
  if (!pattern || pattern === '*') return true;
  if (!pattern.includes('*')) return name === pattern;
  const parts = pattern.split('*');
  if (!name.startsWith(parts[0]) || !name.endsWith(parts.at(-1))) return false;
  let offset = parts[0].length;
  const end = name.length - parts.at(-1).length;
  for (const part of parts.slice(1, -1)) {
    const at = name.indexOf(part, offset);
    if (at < 0) return false;
    offset = at + part.length;
  }
  return offset <= end;
}

function textValue(value, limit, label, allowEmpty = true) {
  if (typeof value !== 'string' || value.length > limit || (!allowEmpty && !value.trim())) throw new Error(`${label}无效或超出长度限制。`);
  return value;
}
function normalizeRule(value) {
  if (!value || typeof value !== 'object') throw new Error('校验规则无效。');
  const rule = { id: textValue(value.id, 100, '规则 ID', false), name: textValue(value.name, 100, '规则名称', false),
    event: textValue(value.event || '*', value.eventMatch === 'exact' ? 1024 : 128, '事件名称'), kind: value.kind, enabled: value.enabled !== false, eventMatch: value.eventMatch === "exact" ? "exact" : "pattern", requirePresent: value.requirePresent === true };
  if (!['required', 'nonempty', 'type', 'enum', 'duplicate'].includes(rule.kind)) throw new Error('不支持的规则类型。');
  if (rule.kind === 'duplicate') {
    if (!Number.isInteger(value.windowMs) || value.windowMs < 1 || value.windowMs > 60000) throw new Error('重复窗口需要为 1–60000 毫秒。');
    rule.windowMs = value.windowMs;
    if (!Array.isArray(value.keyPaths) || value.keyPaths.length > 10) throw new Error('重复判断最多指定 10 个字段。');
    rule.keyPaths = value.keyPaths.map(v => textValue(v, 256, '重复判断字段', false));
  } else {
    rule.path = textValue(value.path, 256, '参数路径', false);
    if (rule.kind === 'type') {
      if (!['string', 'number', 'integer', 'boolean', 'object', 'array', 'null'].includes(value.type)) throw new Error('字段类型无效。');
      rule.type = value.type;
    }
    if (rule.kind === 'enum') {
      if (!Array.isArray(value.values) || !value.values.length || value.values.length > 50 || value.values.some(v => !['string', 'number', 'boolean', 'null'].includes(kindOf(v)) || (typeof v === 'string' && v.length > 1000) || (typeof v === 'number' && !Number.isFinite(v)))) throw new Error('请添加 1–50 个允许值，支持文本、数字、布尔值和 null；每段文本最多 1,000 字。');
      rule.values = value.values;
    }
  }
  return rule;
}
function normalizeFilter(value = {}) {
  const hiddenNames = value.hiddenNames || [];
  if (!Array.isArray(hiddenNames) || hiddenNames.length > AnalysisLimits.hidden) throw new Error('最多隐藏 100 种事件。');
  return { eventName: textValue(value.eventName || "", 1024, "事件名"), query: textValue(value.query || '', 1000, '搜索内容'), action: textValue(value.action || '', 256, '动作'), page: textValue(value.page || '', 256, '页面'),
    hiddenNames: [...new Set(hiddenNames.map(v => textValue(v, 1024, '隐藏事件', false)))], issuesOnly: value.issuesOnly === true, showHidden: value.showHidden === true };
}
function normalizePreferences(value = {}) {
  if (value.version !== undefined && value.version !== 1) throw new Error('不支持的设置版本。');
  const rules = value.rules || [], presets = value.presets || [];
  if (!Array.isArray(rules) || rules.length > AnalysisLimits.rules || !Array.isArray(presets) || presets.length > AnalysisLimits.presets) throw new Error('最多保存 50 条规则、20 个筛选预设。');
  const result = { version: 1, activePresetID: textValue(value.activePresetID || "", 100, "当前筛选"), filter: normalizeFilter(value.filter), rules: rules.map(normalizeRule), presets: presets.map(p => ({ id: textValue(p.id, 100, '预设 ID', false), name: textValue(p.name, 100, '预设名称', false), filter: normalizeFilter(p.filter) })) };
  if (new Set(result.rules.map(r => r.id)).size !== result.rules.length || new Set(result.presets.map(p => p.id)).size !== result.presets.length) throw new Error('设置包含重复 ID。');
  if (!result.presets.some(p => p.id === result.activePresetID)) result.activePresetID = "";
  if (new TextEncoder().encode(JSON.stringify(result)).length > 256 * 1024) throw new Error('设置总大小不能超过 256 KB。');
  return result;
}
function validateEvents(events, rules) {
  const issues = new Map(events.map(e => [e.key, []]));
  for (const rule of rules.filter(r => r.enabled)) {
    const previous = new Map();
    const matching = events.filter(e => ruleMatchesEvent(e, rule));
    if (rule.kind === 'duplicate') matching.sort((a, b) => a.timestamp - b.timestamp || a.id - b.id);
    for (const event of matching) {
      let message = '';
      if (rule.kind === 'duplicate') {
        const values = rule.keyPaths.map(path => fieldAt(event.payload, path));
        if (values.some(v => !v.present)) continue;
        const key = canonical([event.sourceID, event.session, event.name, values.length ? values.map(v => v.value) : event.payload]);
        const last = previous.get(key);
        if (last && (event.timestamp - last.timestamp) * 1000 <= rule.windowMs) message = `与 #${last.id} 在 ${rule.windowMs} ms 内重复`;
        previous.set(key, event);
      } else {
        const field = fieldAt(event.payload, rule.path);
        if ((rule.kind === 'required' || rule.requirePresent) && !field.present) message = `缺少字段 ${fieldLabel(rule.path)}`;
        if (rule.kind === 'nonempty' && (!field.present || isEmptyValue(field.value))) message = `${fieldLabel(rule.path)} 不能为空`;
        if (rule.kind === 'type' && field.present && !(rule.type === 'integer' ? Number.isInteger(field.value) : kindOf(field.value) === rule.type)) message = `${fieldLabel(rule.path)} 应为${typeLabels[rule.type]}，实际为${typeLabels[kindOf(field.value)]}`;
        if (rule.kind === 'enum' && field.present && !rule.values.some(v => v === field.value)) message = `${fieldLabel(rule.path)} 不在允许值中`;
      }
      if (message) issues.get(event.key).push({ ruleID: rule.id, name: rule.name, message });
    }
  }
  return issues;
}
function filterEvents(events, filter, sourceID = '', issues = new Map()) {
  const terms = filter.query.toLowerCase().trim().split(/\s+/).filter(Boolean);
  const hidden = new Set(filter.hiddenNames);
  return events.filter(e => (!filter.eventName || e.name === filter.eventName) && (!sourceID || e.sourceID === sourceID) && terms.every(t => e.search.includes(t))
    && (!filter.action || e.payload.event_info?.action === filter.action) && (!filter.page || e.payload.event_info?.current_page_name === filter.page)
    && (filter.showHidden || !hidden.has(e.name)) && (!filter.issuesOnly || issues.get(e.key)?.length));
}
function assertJSONTree(value) {
  const pending = [[value, 0]];
  let count = 0;
  while (pending.length) {
    const [next, depth] = pending.pop();
    if (++count > 1000000 || depth > 32) throw new Error('记录中的参数层级或字段数量过多。');
    if (typeof next === 'number' && !Number.isFinite(next)) throw new Error('记录含无效数值。');
    if (next !== null && typeof next === 'object') for (const child of Object.values(next)) pending.push([child, depth + 1]);
  }
}
function parseRecording(text) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > AnalysisLimits.fileBytes) throw new Error('记录不能超过 40 MB。');
  let value;
  try { value = JSON.parse(text); } catch { throw new Error('无法读取 JSON 记录。'); }
  if (!value || ![2, 3].includes(value.formatVersion) || !Array.isArray(value.events) || value.events.length > AnalysisLimits.events) throw new Error('不支持的记录格式，或事件超过 2,000 条。');
  assertJSONTree(value);
  const keys = new Set();
  let bytes = 0;
  const events = value.events.map((raw, index) => {
    if (!raw || !Number.isSafeInteger(raw.id) || raw.id < 1 || !Number.isFinite(raw.timestamp) || !Number.isFinite(new Date(raw.timestamp * 1000).getTime()) || kindOf(raw.payload) !== 'object') throw new Error(`第 ${index + 1} 条事件格式无效。`);
    const row = { id: raw.id, timestamp: raw.timestamp, name: textValue(raw.name, 1024, '事件名称', false), payload: raw.payload,
      sourceID: textValue(raw.sourceID || 'recording', 512, '来源'), deviceName: textValue(raw.deviceName || '导入设备', 512, '设备名称'),
      mode: ['usb', 'lan', 'wifi'].includes(raw.mode) ? raw.mode : 'recording', session: textValue(raw.session || 'recording', 128, '会话'), app: {} };
    for (const key of ['bundleID', 'version', 'build']) row.app[key] = textValue(raw.app?.[key] || '', 512, 'App 信息');
    row.key = JSON.stringify([row.sourceID, row.session, row.id]);
    if (keys.has(row.key)) throw new Error('记录含重复事件标识。');
    keys.add(row.key);
    row.search = JSON.stringify(row).toLowerCase(); row.bytes = row.search.length * 2; row.arrival = index;
    bytes += row.bytes;
    return row;
  });
  if (bytes > AnalysisLimits.bytes) throw new Error('记录展开后超过 16 MB，无法完整导入。');
  return new RecordingStore(events);
}
class RecordingStore {
  constructor(events) { this.events = events; this.paused = true; this.trimmed = 0; this.missed = 0; }
  get visible() { return this.events; }
  metadata(sourceID = '') {
    const devices = new Map();
    for (const e of this.events) if (!sourceID || sourceID === e.sourceID) devices.set(e.sourceID, { id: e.sourceID, name: e.deviceName, mode: e.mode, app: e.app, session: e.session, connected: false, error: '', dropped: 0 });
    return [...devices.values()];
  }
}
function ruleMatchesEvent(event, rule) {
  return rule.eventMatch === 'exact' ? event.name === rule.event : matchesName(event.name, rule.event);
}
function isEmptyValue(value) {
  return value === null || (typeof value === 'string' && !value.trim())
    || (typeof value === 'object' && !Object.keys(value).length);
}
function fieldLabel(path) {
  if (!path.startsWith('/')) return path;
  return path.slice(1).split('/').map(v => v.replace(/~1/g, '/').replace(/~0/g, '~')).map((v, i) => /^[a-zA-Z_][a-zA-Z_0-9]*$/.test(v) ? `${i ? '.' : ''}${v}` : `[${JSON.stringify(v)}]`).join('');
}
function collectFields(events) {
  const fields = new Map();
  for (const event of events) {
    const pending = [[event.payload, '', 0]];
    while (pending.length) {
      const [object, prefix, depth] = pending.pop();
      if (depth > 24 || object === null || typeof object !== 'object') continue;
      for (const [key, value] of Object.entries(object)) {
        const path = `${prefix}/${pointerPart(key)}`;
        if (!fields.has(path) && fields.size < 1000) fields.set(path, { path, label: fieldLabel(path), sample: value });
        if (value !== null && typeof value === 'object') pending.push([value, path, depth + 1]);
      }
    }
  }
  return [...fields.values()].sort((a, b) => a.label.localeCompare(b.label));
}
const typeLabels = Object.freeze({ string: '文本', number: '数字', integer: '整数', boolean: '布尔值', object: '对象', array: '数组', null: '空值 null' });
function ruleDescription(rule) {
  const path = fieldLabel(rule.path || '');
  const suffix = rule.requirePresent && ['type', 'enum'].includes(rule.kind) ? '，且必须存在' : '';
  if (rule.kind === 'required') return `${path} 必须存在`;
  if (rule.kind === 'nonempty') return `${path} 不能为空`;
  if (rule.kind === 'type') return `${path} 应为${typeLabels[rule.type]}${suffix}`;
  if (rule.kind === 'enum') return `${path} 的允许值：${rule.values.slice(0, 3).map(v => (JSON.stringify(v).length > 60 ? `${JSON.stringify(v).slice(0, 60)}…` : JSON.stringify(v))).join('、') + (rule.values.length > 3 ? ` 等 ${rule.values.length} 项` : '')}${suffix}`;
  return `${rule.windowMs / 1000} 秒内不可重复 · ${rule.keyPaths.length ? rule.keyPaths.map(fieldLabel).join('、') : '全部参数一致'}`;
}
function filterDescription(filter) {
  const parts = [];
  if (filter.eventName) parts.push(`只看 ${filter.eventName}`);
  if (filter.query) parts.push(`搜索「${filter.query}」`);
  if (filter.action) parts.push(`动作 ${filter.action}`);
  if (filter.page) parts.push(`页面 ${filter.page}`);
  if (filter.hiddenNames.length) parts.push(`${filter.showHidden ? '临时显示已排除' : '排除'} ${filter.hiddenNames.join('、')}`);
  if (filter.issuesOnly) parts.push('只看异常');
  return parts.length ? parts.join(' · ') : '全部事件';
}
function sameFilter(a, b) {
  const normalize = f => { const value = normalizeFilter(f); return { ...value, hiddenNames: value.hiddenNames.sort() }; };
  return canonical(normalize(a)) === canonical(normalize(b));
}
function parseAllowedValue(text, type) {
  if (type === 'string') return text;
  if (type === 'null') return null;
  if (type === 'boolean' && ['true', 'false'].includes(text.trim())) return text.trim() === 'true';
  if (type === 'number' && text.trim() && Number.isFinite(Number(text))) return Number(text);
  throw new Error(type === 'boolean' ? '布尔值请填写 true 或 false。' : '请输入有效数字。');
}
if (typeof module !== 'undefined') module.exports = { ruleMatchesEvent, isEmptyValue, fieldLabel, collectFields, typeLabels, ruleDescription, filterDescription, sameFilter, parseAllowedValue, AnalysisLimits, canonical, diffValues, fieldAt, matchesName, normalizeRule, normalizeFilter, normalizePreferences, validateEvents, filterEvents, parseRecording, RecordingStore };
