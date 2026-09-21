// Contextual filtering and rule editing. Telemetry stays in the existing in-memory store.
let filterUndo = null;
let filterUISignature = '';
let catalogSignature = '';
let catalogSamples = [];
let presetDraft = null;
let editor = null;

function actionButton(label, action, className = '') {
  const button = node('button', label, className);
  button.type = 'button'; button.onclick = action;
  return button;
}
function applyFilter(filter) {
  preferences.filter = normalizeFilter(filter);
  $('search').value = preferences.filter.query;
  for (const id of ['action', 'page']) {
    options(id, [preferences.filter[id]], id === 'action' ? '全部动作' : '全部页面');
    $(id).value = preferences.filter[id];
  }
  $('show-hidden').checked = preferences.filter.showHidden;
  $('issues-only').checked = preferences.filter.issuesOnly;
}
function persistPreferences() {
  if (!preferencesReady) return;
  preferences.filter = currentFilter();
  try {
    const text = JSON.stringify(normalizePreferences(preferences));
    native({ command: 'savePreferences', text }).catch(error => toast(`设置保存失败：${error.message}`));
  } catch (error) { toast(error.message); }
}
function changeFilter(change, { resetPreset = false, resetDevice = false } = {}) {
  const previous = { filter: normalizeFilter(currentFilter()), activePresetID: preferences.activePresetID, device: $('device').value };
  try {
    const next = normalizeFilter(change(previous.filter));
    filterUndo = previous;
    if (resetPreset) preferences.activePresetID = '';
    if (resetDevice) $('device').value = '';
    applyFilter(next); persistPreferences(); render(); renderDetail();
    if ($('filters-dialog').open) renderCatalog(true);
  } catch (error) { toast(error.message); }
}
function undoFilter() {
  if (!filterUndo) return;
  const previous = filterUndo; filterUndo = null;
  preferences.activePresetID = previous.activePresetID;
  $('device').value = previous.device;
  applyFilter(previous.filter); persistPreferences(); render(); renderDetail();
  if ($('filters-dialog').open) renderCatalog(true);
}
function focusEvent(name) {
  changeFilter(f => ({ ...f, eventName: name, hiddenNames: f.hiddenNames.filter(n => n !== name) }));
}
function excludeEvent(name) {
  changeFilter(f => ({ ...f, hiddenNames: f.hiddenNames.includes(name) ? f.hiddenNames.filter(n => n !== name) : [...f.hiddenNames, name], showHidden: false }));
}
function filterDidChange() { filterUndo = null; persistPreferences(); render(); }
function renderAnalysisControls() {
  const filter = currentFilter();
  const active = preferences.presets.find(p => p.id === preferences.activePresetID);
  const changed = !!active && !sameFilter(active.filter, filter);
  const signature = JSON.stringify([filter, preferences.presets, preferences.activePresetID, !!filterUndo, $('device').value]);
  if (signature !== filterUISignature) {
    filterUISignature = signature;
    const custom = !active && !sameFilter(filter, normalizeFilter());
    $('presets').replaceChildren(new Option(custom ? '当前：自定义筛选' : '全部事件', ''), ...preferences.presets.map(p => new Option(`${p.name}${p.id === active?.id && changed ? ' · 已修改' : ''}`, p.id)));
    $('presets').value = active?.id || '';
    $('update-preset').hidden = !changed;
    $('reset-filters').hidden = !custom && !active && !$('device').value;
    $('filters-button').textContent = filter.hiddenNames.length ? `事件筛选 · 排除 ${filter.hiddenNames.length} 种` : '事件筛选';
    const chips = [];
    const chip = (label, remove) => { const b = actionButton(`${label} ×`, remove, 'filter-chip'); b.title = `移除条件：${label}`; chips.push(b); };
    if (filter.eventName) chip(`只看 ${filter.eventName}`, () => changeFilter(f => ({ ...f, eventName: '' })));
    if (filter.query) chip(`搜索 ${filter.query}`, () => changeFilter(f => ({ ...f, query: '' })));
    if (filter.action) chip(`动作 ${filter.action}`, () => changeFilter(f => ({ ...f, action: '' })));
    if (filter.page) chip(`页面 ${filter.page}`, () => changeFilter(f => ({ ...f, page: '' })));
    for (const name of filter.hiddenNames.slice(0, 4)) chip(`${filter.showHidden ? '暂时显示' : '排除'} ${name}`, () => changeFilter(f => ({ ...f, hiddenNames: f.hiddenNames.filter(n => n !== name) })));
    if (filter.hiddenNames.length > 4) chips.push(actionButton(`另 ${filter.hiddenNames.length - 4} 种…`, openCatalog, 'text-button'));
    if (filter.issuesOnly) chip('只看异常', () => changeFilter(f => ({ ...f, issuesOnly: false })));
    if (filterUndo) chips.push(actionButton('↶ 撤销上一步', undoFilter, 'text-button undo-filter'));
    $('active-filters').hidden = !chips.length;
    $('active-filters').replaceChildren(...chips);
  }
  $('rules-count').textContent = preferences.rules.filter(r => r.enabled).length;
  if ($('filters-dialog').open) renderCatalog();
}
function openCatalog() {
  // Keep rows stable while the user chooses; incoming events must not move click targets.
  catalogSamples = store.visible.slice();
  $('event-name-search').value = ''; renderCatalog(true); $('filters-dialog').showModal(); $('event-name-search').focus();
}
function renderCatalog(force = false) {
  const filter = currentFilter(), query = $('event-name-search').value.trim().toLowerCase();
  const counts = new Map();
  for (const event of catalogSamples) if (!$('device').value || event.sourceID === $('device').value) counts.set(event.name, (counts.get(event.name) || 0) + 1);
  for (const name of [...filter.hiddenNames, filter.eventName].filter(Boolean)) if (!counts.has(name)) counts.set(name, 0);
  const names = [...counts.keys()].filter(name => name.toLowerCase().includes(query)).sort((a, b) => (counts.get(b) - counts.get(a)) || a.localeCompare(b));
  const signature = JSON.stringify([filter, query, [...counts]]);
  if (!force && signature === catalogSignature) return;
  catalogSignature = signature;
  $('catalog-count').textContent = `打开时 ${counts.size} 种事件 · 已排除 ${filter.hiddenNames.length} 种`;
  $('event-catalog').replaceChildren(...names.map(name => {
    const excluded = filter.hiddenNames.includes(name);
    const row = node('div', undefined, `catalog-row${excluded ? ' excluded' : ''}`);
    const title = node('div', undefined, 'catalog-name');
    title.append(node('strong', name), node('small', `${counts.get(name)} 条${excluded ? ' · 已排除' : filter.eventName === name ? ' · 正在只看' : ''}`));
    row.append(title, actionButton('只看', () => { focusEvent(name); $('filters-dialog').close(); }), actionButton(excluded ? '恢复' : '排除', () => excludeEvent(name), excluded ? 'restore' : 'text-button'));
    return row;
  }));
  if (!names.length) $('event-catalog').append(node('p', query ? '没有找到这个事件。' : '收到事件后会在这里列出；也可以先打开一份记录。', 'subtle'));
}
function openPresetDialog() {
  presetDraft = normalizeFilter(currentFilter());
  $('preset-summary').textContent = filterDescription(presetDraft);
  $('preset-name').value = ''; $('preset-error').textContent = '';
  renderPresetList(); $('preset-dialog').showModal(); $('preset-name').focus();
}
function usePreset(preset) {
  changeFilter(() => preset.filter);
  preferences.activePresetID = preset.id; persistPreferences(); render();
}
function renderPresetList() {
  $('preset-list').replaceChildren(...preferences.presets.map(p => {
    const row = node('div', undefined, 'managed-row');
    const label = node('div', undefined, 'managed-text'); label.append(node('strong', p.name), node('small', filterDescription(p.filter)));
    row.append(label, actionButton('应用', () => { usePreset(p); $('preset-dialog').close(); }), actionButton('删除', () => {
      preferences.presets = preferences.presets.filter(v => v.id !== p.id);
      if (preferences.activePresetID === p.id) preferences.activePresetID = '';
      persistPreferences(); renderPresetList(); render();
    }, 'text-button'));
    return row;
  }));
  if (!preferences.presets.length) $('preset-list').append(node('p', '还没有保存过筛选。', 'subtle'));
}
function ruleTargets(rule, events = store.visible) { return events.filter(e => ruleMatchesEvent(e, rule)); }
function renderRuleList() {
  $('rule-list').replaceChildren(...preferences.rules.map(rule => {
    const matching = ruleTargets(rule);
    const failed = matching.filter(e => issues.get(e.key)?.some(i => i.ruleID === rule.id));
    const card = node('section', undefined, `rule-card${rule.enabled ? '' : ' disabled'}`);
    const top = node('div', undefined, 'rule-card-top');
    const toggle = node('input'); toggle.type = 'checkbox'; toggle.checked = rule.enabled;
    toggle.setAttribute('aria-label', `启用 ${rule.name}`);
    toggle.onchange = () => { preferences.rules = preferences.rules.map(r => r.id === rule.id ? { ...r, enabled: toggle.checked } : r); persistPreferences(); render(); renderRuleList(); };
    top.append(toggle, node('strong', rule.name), node('span', rule.enabled ? `${failed.length} 条异常 / ${matching.length} 条匹配` : '已停用', failed.length ? 'issue-badge' : 'subtle'));
    const summary = node('p', `${rule.eventMatch === 'exact' ? '事件' : '匹配'} ${rule.event} · ${ruleDescription(rule)}`);
    const actions = node('div', undefined, 'rule-card-actions');
    actions.append(actionButton('编辑', () => openRuleEditor({ rule })), actionButton('定位首条异常', () => {
      $('rules-dialog').close();
      if (failed.length) { changeFilter(() => normalizeFilter({ eventName: failed[0].name, issuesOnly: true }), { resetPreset: true, resetDevice: true }); select(failed[0]); }
      else toast('当前记录没有命中这条规则的异常。');
    }), actionButton('删除', () => { preferences.rules = preferences.rules.filter(r => r.id !== rule.id); persistPreferences(); render(); renderRuleList(); }, 'text-button'));
    card.append(top, summary, actions); return card;
  }));
  if (!preferences.rules.length) {
    const empty = node('div', undefined, 'rules-empty');
    empty.append(node('strong', '先选一条事件，再点字段旁的「校验」'), node('p', '事件名、字段和样本值会自动带入。也可以点击「新建规则」从现有事件中选择。'));
    $('rule-list').append(empty);
  }
}
function openRuleEditor({ rule = null, event = selected, path = '' } = {}) {
  if ($('rules-dialog').open) $('rules-dialog').close();
  editor = { ruleID: rule?.id || null, enabled: rule?.enabled ?? true, values: [...(rule?.values || [])], keyPaths: [...(rule?.keyPaths || [])], samples: store.visible.slice(), event, fields: [] };
  $('rule-form').reset();
  $('rule-editor-title').textContent = rule ? '编辑检查规则' : path ? '检查这个字段' : '新建检查规则';
  $('rule-error').textContent = '';
  const names = [...new Set([...editor.samples.map(e => e.name), event?.name, rule?.eventMatch === 'exact' ? rule.event : null].filter(Boolean))].sort();
  $('rule-event').replaceChildren(new Option('所有事件', ''), ...names.map(name => new Option(name, name)));
  $('rule-event').value = rule ? (rule.eventMatch === 'exact' ? rule.event : '') : event?.name || names[0] || '';
  $('rule-pattern').value = rule?.eventMatch === 'pattern' && rule.event !== '*' ? rule.event : '';
  $('rule-kind').value = rule?.kind || 'nonempty';
  $('rule-name').value = rule?.name || '';
  $('rule-window').value = (rule?.windowMs || 500) / 1000;
  $('require-present').checked = rule ? rule.requirePresent : true;
  $('rule-editor').querySelector('.rule-advanced').open = !!$('rule-pattern').value;
  $('rule-keys-row').open = !!editor.keyPaths.length;
  rebuildFieldChoices(rule?.path || path);
  if (rule?.type) $('rule-type').value = rule.type;
  if (rule?.kind === 'enum') editor.values = [...rule.values];
  renderAllowedValues(); updateRuleEditor();
  $('rule-submit').textContent = rule ? '保存修改' : '保存并启用';
  $('rule-editor').showModal();
}
function editorMatcher() {
  const pattern = $('rule-pattern').value.trim();
  const name = $('rule-event').value;
  return { event: pattern || name || '*', eventMatch: pattern || !name ? 'pattern' : 'exact' };
}
function rebuildFieldChoices(preferred = '', preserveCondition = false) {
  const matching = ruleTargets(editorMatcher(), editor.samples);
  const ordered = editor.event && matching.includes(editor.event) ? [editor.event, ...matching.filter(e => e !== editor.event)] : matching;
  editor.fields = collectFields(ordered);
  $('rule-path').replaceChildren(...editor.fields.map(f => new Option(f.label, f.path)), new Option('手动指定尚未出现的字段…', ':custom'));
  if (preferred && !editor.fields.some(f => f.path === preferred)) {
    // Preserve old dotted paths exactly when editing older rules.
    $('rule-path').append(new Option(fieldLabel(preferred), preferred));
  }
  $('rule-path').value = preferred || editor.fields.find(f => f.path === '/content_info/id')?.path || editor.fields.find(f => kindOf(f.sample) !== 'object' && kindOf(f.sample) !== 'array')?.path || editor.fields[0]?.path || ':custom';
  if ($('rule-path').value !== ':custom') $('custom-path').value = '';
  if (!preserveCondition) fieldChoiceChanged(); else renderAllowedValues();
  const available = [...editor.fields.map(f => ({ path: f.path, label: f.label })), ...editor.keyPaths.filter(p => !editor.fields.some(f => f.path === p)).map(p => ({ path: p, label: fieldLabel(p) }))];
  $('duplicate-fields').replaceChildren(...available.map(field => {
    const label = node('label', undefined, 'check-label'), input = node('input'); input.type = 'checkbox'; input.value = field.path; input.checked = editor.keyPaths.includes(field.path);
    input.onchange = () => {
      if (input.checked && editor.keyPaths.length >= 10) { input.checked = false; $('rule-error').textContent = '最多选择 10 个判断字段。'; return; }
      editor.keyPaths = input.checked ? [...editor.keyPaths, field.path] : editor.keyPaths.filter(p => p !== field.path); updateRuleEditor();
    };
    label.append(input, node('span', field.label)); return label;
  }));
}
function editorPath() { return $('rule-path').value === ':custom' ? $('custom-path').value.trim() : $('rule-path').value; }
function currentSample() {
  const path = editorPath(), matching = ruleTargets(editorMatcher(), editor.samples);
  const first = editor.event && matching.includes(editor.event) ? editor.event : matching.at(-1);
  return { event: first, field: first ? fieldAt(first.payload, path) : { present: false } };
}
function fieldChoiceChanged() {
  const sample = currentSample().field;
  const type = sample.present ? kindOf(sample.value) : 'string';
  $('rule-type').value = typeLabels[type] ? type : 'string';
  $('allowed-type').value = ['number', 'boolean', 'null'].includes(type) ? type : 'string';
  updateAllowedInput();
  editor.values = sample.present && ['string', 'number', 'boolean', 'null'].includes(type) ? [sample.value] : [];
  renderAllowedValues();
}
function updateAllowedInput() {
  $('allowed-input').disabled = $('allowed-type').value === 'null';
  $('allowed-input').placeholder = $('allowed-type').value === 'boolean' ? 'true 或 false' : '输入一个值';
}
function renderAllowedValues() {
  $('allowed-values').replaceChildren(...editor.values.map((value, index) => actionButton(`${typeLabels[kindOf(value)]} ${JSON.stringify(value)} ×`, () => { editor.values.splice(index, 1); renderAllowedValues(); updateRuleEditor(); }, 'value-chip')));
  if (!editor.values.length) $('allowed-values').append(node('span', '还没有允许值；从下方样本点选，或手动添加。', 'subtle'));
  const observed = new Map();
  for (const event of ruleTargets(editorMatcher(), editor.samples)) {
    const field = fieldAt(event.payload, editorPath());
    if (field.present && ['string', 'number', 'boolean', 'null'].includes(kindOf(field.value))) observed.set(canonical(field.value), field.value);
    if (observed.size >= 12) break;
  }
  $('observed-values').replaceChildren();
  if (observed.size) {
    $('observed-values').append(node('small', '记录中出现过，点击添加：'));
    for (const value of observed.values()) {
      const b = actionButton(`${typeLabels[kindOf(value)]} ${JSON.stringify(value)}`, () => addAllowedValue(value), 'text-button');
      b.disabled = editor.values.some(v => v === value); $('observed-values').append(b);
    }
  }
}
function addAllowedValue(value) {
  if (editor.values.some(v => v === value)) return;
  if (editor.values.length >= 50) { $('rule-error').textContent = '最多允许 50 个值。'; return; }
  editor.values.push(value); $('allowed-input').value = ''; renderAllowedValues(); updateRuleEditor();
}
function editorRule() {
  const candidate = { id: editor.ruleID || 'preview', name: '预览', ...editorMatcher(), kind: $('rule-kind').value,
    path: editorPath(), type: $('rule-type').value, values: editor.values, windowMs: Math.round(Number($('rule-window').value) * 1000), keyPaths: editor.keyPaths,
    requirePresent: ['type', 'enum'].includes($('rule-kind').value) && $('require-present').checked, enabled: true };
  const rule = normalizeRule(candidate);
  rule.name = $('rule-name').value.trim() || ruleDescription(rule).slice(0, 100);
  return rule;
}
function updateRuleEditor() {
  if (!editor) return;
  const kind = $('rule-kind').value;
  $('rule-path-row').hidden = kind === 'duplicate';
  $('custom-path-row').hidden = kind === 'duplicate' || $('rule-path').value !== ':custom';
  $('field-sample').hidden = kind === 'duplicate';
  $('rule-type-row').hidden = kind !== 'type'; $('rule-values-row').hidden = kind !== 'enum';
  $('require-present-row').hidden = !['type', 'enum'].includes(kind);
  $('rule-window-row').hidden = $('rule-keys-row').hidden = kind !== 'duplicate';
  $('rule-window').disabled = kind !== 'duplicate';
  $('rule-explanation').textContent = ({ nonempty: '缺失、null、空文本、空数组和空对象都算空；0 和 false 是有效值。', required: '只检查字段是否存在，null 和空文本也算存在。', type: '选择你期望的类型；是否要求字段存在可单独勾选。', enum: '一个值一项，无需填写 JSON。文本 1 和数字 1 会分别判断。', duplicate: '只比较同设备、同会话、同名事件；标记后一次触发。' })[kind];
  const sample = currentSample();
  $('field-sample').textContent = sample.event ? `样本 #${sample.event.id}：${sample.field.present ? JSON.stringify(sample.field.value) : '此字段缺失'}` : '暂时没有样本，收到匹配事件后自动检查。';
  $('preview-events').replaceChildren(); $('rule-error').textContent = '';
  try {
    const rule = editorRule();
    $('preview-title').textContent = ruleDescription(rule);
    const matched = ruleTargets(rule, editor.samples), preview = validateEvents(matched, [rule]);
    const failed = matched.filter(e => preview.get(e.key)?.length);
    $('preview-counts').replaceChildren(...[[matched.length, '条匹配'], [matched.length - failed.length, '条通过'], [failed.length, '条异常']].map(([count, label]) => {
      const box = node('div'); box.append(node('strong', count), node('span', label)); return box;
    }));
    $('preview-scope').textContent = matched.length ? `基于打开面板时的记录，跨 ${new Set(matched.map(e => e.sourceID)).size} 台设备。保存后持续检查新事件。` : '当前没有匹配记录；保存后，收到这类事件时自动检查。';
    for (const event of failed.slice(0, 4)) {
      const row = node('div', undefined, 'preview-result');
      row.append(node('strong', `${event.deviceName} · #${event.id}`), node('p', preview.get(event.key)[0].message));
      $('preview-events').append(row);
    }
    if (failed.length > 4) $('preview-events').append(node('p', `另有 ${failed.length - 4} 条异常`, 'subtle'));
    if (matched.length && !failed.length) $('preview-events').append(node('p', '✓ 当前样本全部通过', 'preview-success'));
    $('rule-submit').disabled = false;
  } catch (error) {
    $('preview-title').textContent = '还差一步'; $('preview-counts').replaceChildren();
    $('preview-scope').textContent = error.message; $('rule-submit').disabled = true;
  }
}
function initAnalysisWorkspace() {
  $('filters-button').onclick = openCatalog;
  $('event-name-search').oninput = () => renderCatalog(true);
  $('show-hidden').onchange = filterDidChange;
  $('restore-events').onclick = () => changeFilter(f => ({ ...f, eventName: '', hiddenNames: [], showHidden: false }));
  $('focus-event').onclick = () => focusEvent(selected.name);
  $('hide-event').onclick = () => excludeEvent(selected.name);
  $('check-event').onclick = () => openRuleEditor({ event: selected });
  $('reset-filters').onclick = () => changeFilter(() => normalizeFilter(), { resetPreset: true, resetDevice: true });
  $('issues-only').onchange = filterDidChange;
  $('presets').onchange = () => {
    const preset = preferences.presets.find(p => p.id === $('presets').value);
    if (preset) usePreset(preset); else changeFilter(() => normalizeFilter(), { resetPreset: true });
  };
  $('save-preset').onclick = openPresetDialog;
  $('update-preset').onclick = () => {
    const active = preferences.presets.find(p => p.id === preferences.activePresetID);
    if (!active) return;
    try {
      preferences = normalizePreferences({ ...preferences, presets: preferences.presets.map(p => p.id === active.id ? { ...p, filter: currentFilter() } : p) });
      persistPreferences(); render(); toast(`已更新「${active.name}」`);
    } catch (error) { toast(error.message); }
  };
  $('preset-form').onsubmit = event => {
    event.preventDefault();
    try {
      if (preferences.presets.length >= AnalysisLimits.presets) throw new Error('最多保存 20 个筛选，请先在下方管理列表中删除不再使用的筛选。');
      const name = $('preset-name').value.trim(); if (!name) throw new Error('请给筛选起个名字。');
      const id = crypto.randomUUID();
      preferences = normalizePreferences({ ...preferences, activePresetID: id, presets: [...preferences.presets, { id, name, filter: presetDraft }] });
      persistPreferences(); render(); $('preset-dialog').close(); toast(`已保存「${name}」`);
    } catch (error) { $('preset-error').textContent = error.message; }
  };
  $('rules-button').onclick = () => { renderRuleList(); $('rules-dialog').showModal(); };
  $('new-rule').onclick = () => openRuleEditor();
  for (const button of document.querySelectorAll('[data-close]')) button.onclick = () => button.closest('dialog').close();
  $('rule-editor').addEventListener('close', () => { editor = null; });
  $('rule-event').onchange = () => { $('rule-pattern').value = ''; rebuildFieldChoices(editorPath(), true); updateRuleEditor(); };
  $('rule-path').onchange = () => { fieldChoiceChanged(); updateRuleEditor(); };
  $('custom-path').oninput = updateRuleEditor;
  $('rule-pattern').oninput = () => { rebuildFieldChoices(editorPath(), true); updateRuleEditor(); };
  for (const id of ['rule-kind', 'rule-type', 'require-present']) $(id).onchange = updateRuleEditor;
  for (const id of ['rule-name', 'rule-window']) $(id).oninput = updateRuleEditor;
  $('allowed-type').onchange = updateAllowedInput;
  $('add-value').onclick = () => { try { addAllowedValue(parseAllowedValue($('allowed-input').value, $('allowed-type').value)); } catch (error) { $('rule-error').textContent = error.message; } };
  $('allowed-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); $('add-value').click(); } };
  $('rule-form').onsubmit = event => {
    event.preventDefault();
    try {
      if (!editor.ruleID && preferences.rules.length >= AnalysisLimits.rules) throw new Error('最多保存 50 条规则。');
      const rule = { ...editorRule(), id: editor.ruleID || crypto.randomUUID(), enabled: editor.enabled };
      const rules = editor.ruleID ? preferences.rules.map(r => r.id === editor.ruleID ? rule : r) : [...preferences.rules, rule];
      preferences = normalizePreferences({ ...preferences, rules }); persistPreferences(); render(); renderDetail();
      $('rule-editor').close(); toast('规则已保存，异常会显示在事件行与详情中');
    } catch (error) { $('rule-error').textContent = error.message; }
  };
  renderAnalysisControls();
}
