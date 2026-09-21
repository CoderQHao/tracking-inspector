
const $ = id => document.getElementById(id);
const liveStore = new MultiDeviceStore();
let store = liveStore;
let recordingName = "";
let preferences = normalizePreferences();
let baseline = null;
let issues = new Map();
let analysisSignature = "";
let preferencesReady = false;
const native = value => window.webkit.messageHandlers.inspector.postMessage(value);
let selected = null;
let bridgeError = "";
let detailMode = "fields";
let lastListSignature = "";
let notice = "";
let toastTimer;

function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = String(text);
  if (className) element.className = className;
  return element;
}
function time(value) {
  return new Date(value * 1000).toLocaleTimeString("zh-CN", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit", fractionalSecondDigits: 3 });
}
function currentFilter() {
  return { eventName: preferences.filter.eventName, query: $("search").value, action: $("action").value, page: $("page").value,
    hiddenNames: preferences.filter.hiddenNames, showHidden: $("show-hidden").checked, issuesOnly: $("issues-only").checked };
}
function filtered() { return filterEvents(store.visible, currentFilter(), $("device").value, issues); }
function analyze() {
  const signature = JSON.stringify([store === liveStore, store.visible.map(e => e.key), preferences.rules]);
  if (signature === analysisSignature) return;
  analysisSignature = signature;
  const previous = JSON.stringify(issues.get(selected?.key) || []);
  issues = validateEvents(store.visible, preferences.rules);
  if (previous !== JSON.stringify(issues.get(selected?.key) || [])) renderDetail();
}
function toast(text) {
  $("toast").textContent = text;
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { $("toast").hidden = true; }, 2500);
}
function options(id, values, label) {
  const element = $(id);
  const current = element.value;
  const sorted = [...new Set(values.filter(Boolean).concat(current || []))].sort();
  if (element.dataset.values === JSON.stringify(sorted)) return;
  element.dataset.values = JSON.stringify(sorted);
  element.replaceChildren(new Option(label, ""), ...sorted.map(value => new Option(value, value)));
  element.value = current;
}

function render() {
  analyze();
  const offline = store !== liveStore;
  const channels = store.metadata();
  const deviceSelect = $("device");
  const deviceSignature = JSON.stringify(channels.map(c => [c.id, c.name]));
  if (deviceSelect.dataset.values !== deviceSignature) {
    const current = deviceSelect.value;
    deviceSelect.replaceChildren(new Option("全部设备", ""), ...channels.map(c => new Option(c.name, c.id)));
    deviceSelect.value = channels.some(c => c.id === current) ? current : "";
    deviceSelect.dataset.values = deviceSignature;
  }
  const connected = channels.filter(c => c.connected).length;
  $("status").textContent = offline ? "离线记录" : `${connected} / ${channels.length} 台已连接`;
  $("status").className = connected ? "status connected" : "status";
  $("mode").textContent = offline ? "RECORDING" : channels.length > 1 ? "MULTI DEVICE" : (channels[0]?.mode.toUpperCase() || "DEBUG");
  const scoped = store.metadata(deviceSelect.value);
  $("app-info").textContent = scoped.length === 1 ? (scoped[0].app.bundleID || scoped[0].name) : `同时查看 ${channels.length} 台设备`;
  $("device-info").textContent = "每条事件标记来源设备 · 按接收顺序排列";
  const warnings = channels.filter(c => c.error).map(c => `${c.name}：${c.error}`);
  for (const c of channels) if (c.dropped) warnings.push(`${c.name}：累计丢弃 ${c.dropped} 条调试副本。`);
  notice = offline ? "" : bridgeError || (channels.length ? warnings.join("  ") : "在左侧勾选 USB 或无线设备，可同时选择多台。");
  if (selected && (!store.visible.some(e => e.key === selected.key) || (deviceSelect.value && selected.sourceID !== deviceSelect.value))) { selected = null; renderDetail(); }
  options("action", store.visible.map(e => e.payload.event_info?.action), "全部动作");
  options("page", store.visible.map(e => e.payload.event_info?.current_page_name), "全部页面");
  const rows = filtered();
  if (selected && !rows.some(e => e.key === selected.key)) { selected = null; renderDetail(); }
  $("count").textContent = rows.length;
  $("summary").textContent = `${rows.length} 条匹配 / ${store.visible.length} 条 · ${[...issues.values()].filter(v => v.length).length} 条异常`;
  $("live-label").textContent = offline ? "◇ RECORDING" : store.paused ? "Ⅱ 已暂停" : "● LIVE";
  $("live-label").classList.toggle("paused", store.paused);
  $("pause").textContent = store.paused ? "继续实时更新" : "暂停滚动更新";
  $("pause").disabled = offline;
  $("clear").disabled = offline;
  $("workspace-title").textContent = offline ? "记录回看" : "实时事件";
  $("recording-banner").hidden = !offline;
  $("recording-name").textContent = `${recordingName} · 实时采集仍在后台继续`;
  renderAnalysisControls();
  $("clear").textContent = $("device").value ? "清空此设备" : "清空全部";
  $("notice").textContent = notice;
  $("notice").hidden = !notice;
  $("retention").textContent = `最多保留 2,000 条 / 16 MB${store.trimmed ? ` · 已淘汰 ${store.trimmed} 条` : ""}${store.missed ? ` · App 缓存已错过 ${store.missed} 条` : ""}`;
  $("empty").hidden = rows.length > 0;
  $("empty").querySelector("strong").textContent = store.visible.length ? "没有符合筛选条件的事件" : "你的操作，会在这里出现";
  const signature = `${rows.map(e => `${e.key}:${issues.get(e.key)?.length}`).join(",")}|${selected?.key}|${JSON.stringify(preferences.filter.hiddenNames)}`;
  if (signature === lastListSignature) return;
  lastListSignature = signature;
  const list = $("events");
  const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 60;
  const oldScroll = list.scrollTop;
  const fragment = document.createDocumentFragment();
  for (const event of rows) {
    const info = event.payload.event_info || {};
    const button = node("button", undefined, `event-row${selected?.key === event.key ? " selected" : ""}`);
    button.setAttribute("aria-pressed", String(selected?.key === event.key));
    const top = node("div", undefined, "event-top");
    top.append(node("span", `#${String(event.id).padStart(3, "0")}`, "event-id mono"), node("span", time(event.timestamp), "event-time mono"));
    const middle = node("div", undefined, "event-middle");
    middle.append(node("strong", event.name), node("span", info.action || "EVENT", `badge ${String(info.action).toLowerCase().includes("view") ? "view" : ""}`));
    if (issues.get(event.key)?.length) middle.append(node("span", `${issues.get(event.key).length} 异常`, "issue-badge"));
    button.append(node("div", event.deviceName, `device-label ${event.mode}`), top, middle, node("div", info.current_page_name || "未设置当前页", "event-page mono"));
    button.addEventListener("click", () => select(event));
    const entry = node("div", undefined, "event-entry");
    const quick = node("div", undefined, "event-quick");
    const focus = actionButton("只看", () => focusEvent(event.name)); focus.setAttribute("aria-label", `只看 ${event.name}`);
    const excluded = preferences.filter.hiddenNames.includes(event.name);
    const exclude = actionButton(excluded ? "恢复" : "排除", () => excludeEvent(event.name)); exclude.setAttribute("aria-label", `${excluded ? "恢复" : "排除"} ${event.name}`);
    quick.append(focus, exclude); entry.append(button, quick); fragment.append(entry);
  }
  list.replaceChildren(fragment);
  list.scrollTop = atBottom && !store.paused ? list.scrollHeight : oldScroll;
}

function select(event) {
  selected = event;
  renderDetail();
  $("detail").scrollTop = 0;
  render();
}

function renderValue(value, depth = 0, path = "") {
  if (value !== null && typeof value === "object") {
    const container = node("div", undefined, "value-tree");
    for (const [key, child] of Object.entries(value)) {
      const childPath = `${path}/${pointerPart(key)}`;
      if (child !== null && typeof child === "object") {
        const details = node("details");
        details.open = depth < 2;
        details.append(node("summary", `${key}  ·  ${Object.keys(child).length} 项`, "mono"), renderValue(child, depth + 1, childPath));
        details.append(fieldCheckButton(childPath));
        container.append(details);
      } else {
        const row = node("div", undefined, "field-row");
        row.append(node("span", key, "field-key mono"), node("span", child === "" ? '""' : String(child), `field-value mono ${typeof child}`));
        row.append(fieldCheckButton(childPath));
        container.append(row);
      }
    }
    if (!Object.keys(value).length) container.append(node("span", Array.isArray(value) ? "[]" : "{}", "subtle mono"));
    return container;
  }
  return node("span", String(value), "mono");
}

function fieldCheckButton(path) {
  const event = selected;
  const button = actionButton("校验", () => openRuleEditor({ event, path }), "field-check");
  button.setAttribute("aria-label", `校验 ${fieldLabel(path)}`);
  return button;
}
function renderDetail() {
  $("detail").hidden = !selected;
  $("detail-empty").hidden = !!selected;
  if (!selected) return;
  const info = selected.payload.event_info || {};
  $("event-meta").textContent = `${selected.deviceName}  /  EVENT #${selected.id}  /  ${time(selected.timestamp)}`;
  $("event-name").textContent = selected.name;
  $("context").hidden = detailMode === "diff";
  $("context").replaceChildren(...[
    ["当前页面", info.current_page_name], ["来源页面", info.source_page_name],
    ["归因页面", info.trace_page_name], ["上一页面", info.previous_page_name],
  ].map(([label, value]) => { const item = node("div"); item.append(node("span", label), node("strong", value || "未设置", "mono")); return item; }));
  const fragment = document.createDocumentFragment();
  for (const [key, value] of Object.entries(selected.payload)) {
    const group = node("section", undefined, "field-group");
    const heading = node("div", undefined, "field-group-heading");
    heading.append(node("h4", key, "mono"), fieldCheckButton(`/${pointerPart(key)}`));
    group.append(heading, renderValue(value, 0, `/${pointerPart(key)}`));
    fragment.append(group);
  }
  $("fields").replaceChildren(fragment);
  $("json").textContent = JSON.stringify(selected.payload, null, 2);
  const messages = issues.get(selected.key) || [];
  $("event-issues").hidden = !messages.length;
  $("event-issues").replaceChildren(...messages.map(issue => node("div", `${issue.name}：${issue.message}`)));
  $("hide-event").textContent = preferences.filter.hiddenNames.includes(selected.name) ? "恢复此事件" : "排除此事件";
  $("baseline-label").textContent = baseline ? `基准：${baseline.deviceName} #${baseline.id}` : "先设置基准，再选择另一条事件";
  $("clear-baseline").hidden = !baseline;
  renderDiff();
  $("fields").hidden = detailMode !== "fields";
  $("json").hidden = detailMode !== "json";
  $("diff").hidden = detailMode !== "diff";
  $("fields-tab").setAttribute("aria-selected", String(detailMode === "fields"));
  $("json-tab").setAttribute("aria-selected", String(detailMode === "json"));
  $("diff-tab").setAttribute("aria-selected", String(detailMode === "diff"));
}

function refresh() {
  render();
  if (!selected && filtered().length) select(filtered().at(-1));
}
const poller = new DevicePoller(liveStore, native, refresh, message => { bridgeError = message; });

for (const id of ["search", "action", "page", "device"]) $(id).addEventListener(id === "search" ? "input" : "change", filterDidChange);
$("pause").onclick = () => { store.togglePause(); render(); };
$("clear").onclick = () => { store.clear($("device").value); refresh(); };
$("latest").onclick = () => { const latest = filtered().at(-1); if (latest) select(latest); $("events").scrollTop = $("events").scrollHeight; };
for (const tab of ["fields", "json", "diff"]) $(`${tab}-tab`).onclick = () => { detailMode = tab; renderDetail(); };
$("copy").onclick = async () => {
  try { await native({ command: "copy", text: JSON.stringify(selected.payload, null, 2) }); toast("已复制事件参数"); }
  catch { toast("复制失败，可在原始 JSON 中选中并复制。"); }
};
async function saveRecording(filteredOnly) {
  const rows = filteredOnly ? filtered() : store.visible;
  const payload = { formatVersion: 3, devices: store.metadata(filteredOnly ? $("device").value : ""),
    exportedAt: new Date().toISOString(), scope: filteredOnly ? "filtered" : "retained", events: rows.map(exportEvent) };
  try {
    const saved = await native({ command: "export", text: JSON.stringify(payload, null, 2) });
    if (saved) toast(`已保存 ${rows.length} 条${filteredOnly ? "筛选" : "当前保留的"}事件`);
  } catch (error) { toast(error.message); }
}
$("export").onclick = () => saveRecording(false);
$("export-filtered").onclick = () => saveRecording(true);
$("import").onclick = async () => {
  try {
    const file = await native({ command: "import" });
    if (!file) return;
    const imported = parseRecording(file.text);
    store = imported;
    recordingName = `${file.name} · ${store.events.length} 条事件`;
    resetWorkspace();
    toast("记录已打开，可继续筛选、对比和校验");
  } catch (error) { toast(error.message); }
};
$("return-live").onclick = () => { store = liveStore; resetWorkspace(); };
function resetWorkspace() {
  selected = baseline = null;
  analysisSignature = lastListSignature = "";
  $("device").value = "";
  renderDetail(); refresh();
}
function renderDiff() {
  const container = $("diff");
  container.replaceChildren();
  if (!baseline) { container.append(node("p", "点击「设为对比基准」，再选择另一条事件。", "subtle")); return; }
  const changes = diffValues({ name: baseline.name, payload: baseline.payload }, { name: selected.name, payload: selected.payload });
  container.append(node("p", `基准 ${baseline.deviceName} #${baseline.id} → 当前 ${selected.deviceName} #${selected.id} · ${changes.length} 处差异（事件名及参数）`, "diff-summary"));
  if (!changes.length) container.append(node("p", "事件名和全部参数一致。", "subtle"));
  for (const change of changes) {
    const row = node("section", undefined, `diff-row ${change.kind}`);
    row.append(node("div", `${({ added: "新增", removed: "缺失", changed: "变化" })[change.kind]}  ${change.path}`, "diff-path"));
    const values = node("div", undefined, "diff-values");
    values.append(node("pre", change.kind === "added" ? "基准：不存在" : `基准：${JSON.stringify(change.before, null, 2)}`), node("pre", change.kind === "removed" ? "当前：不存在" : `当前：${JSON.stringify(change.after, null, 2)}`));
    row.append(values); container.append(row);
  }
}
$("set-baseline").onclick = () => { baseline = selected; detailMode = "diff"; renderDetail(); toast("基准已固定，请选择另一条事件"); };
$("clear-baseline").onclick = () => { baseline = null; renderDetail(); };
document.addEventListener("keydown", event => { if ((event.metaKey || event.ctrlKey) && event.key === "k") { event.preventDefault(); $("search").focus(); } });
async function start() {
  try { preferences = normalizePreferences(JSON.parse(await native({ command: "loadPreferences" }))); applyFilter(preferences.filter); }
  catch { toast("已保存的设置无法读取，当前使用默认设置。"); }
  preferencesReady = true;
  initAnalysisWorkspace(); render(); poller.tick();
  setInterval(() => poller.tick(), 250);
}
start();
