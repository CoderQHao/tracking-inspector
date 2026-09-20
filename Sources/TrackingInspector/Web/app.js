
const $ = id => document.getElementById(id);
const store = new MultiDeviceStore();
const native = value => window.webkit.messageHandlers.inspector.postMessage(value);
let selected = null;
let bridgeError = "";
let jsonMode = false;
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
function filtered() { return store.filter($("search").value, $("action").value, $("page").value, $("device").value); }
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
  $("status").textContent = `${connected} / ${channels.length} 台已连接`;
  $("status").className = connected ? "status connected" : "status";
  $("mode").textContent = channels.length > 1 ? "MULTI DEVICE" : (channels[0]?.mode.toUpperCase() || "DEBUG");
  const scoped = store.metadata(deviceSelect.value);
  $("app-info").textContent = scoped.length === 1 ? (scoped[0].app.bundleID || scoped[0].name) : `同时查看 ${channels.length} 台设备`;
  $("device-info").textContent = "每条事件标记来源设备 · 按接收顺序排列";
  const warnings = channels.filter(c => c.error).map(c => `${c.name}：${c.error}`);
  for (const c of channels) if (c.dropped) warnings.push(`${c.name}：累计丢弃 ${c.dropped} 条调试副本。`);
  notice = bridgeError || (channels.length ? warnings.join("  ") : "在左侧勾选 USB 或无线设备，可同时选择多台。");
  if (selected && (!store.visible.some(e => e.key === selected.key) || (deviceSelect.value && selected.sourceID !== deviceSelect.value))) { selected = null; renderDetail(); }
  options("action", store.visible.map(e => e.payload.event_info?.action), "全部动作");
  options("page", store.visible.map(e => e.payload.event_info?.current_page_name), "全部页面");
  const rows = filtered();
  $("count").textContent = rows.length;
  $("summary").textContent = `${rows.length} 条匹配 / ${store.visible.length} 条记录`;
  $("live-label").textContent = store.paused ? "Ⅱ 已暂停" : "● LIVE";
  $("live-label").classList.toggle("paused", store.paused);
  $("pause").textContent = store.paused ? "继续实时更新" : "暂停滚动更新";
  $("clear").textContent = $("device").value ? "清空此设备" : "清空全部";
  $("notice").textContent = notice;
  $("notice").hidden = !notice;
  $("retention").textContent = `最多保留 2,000 条 / 16 MB${store.trimmed ? ` · 已淘汰 ${store.trimmed} 条` : ""}${store.missed ? ` · App 缓存已错过 ${store.missed} 条` : ""}`;
  $("empty").hidden = rows.length > 0;
  $("empty").querySelector("strong").textContent = store.visible.length ? "没有符合筛选条件的事件" : "你的操作，会在这里出现";
  const signature = `${rows.map(e => e.key).join(",")}|${selected?.key}`;
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
    button.append(node("div", event.deviceName, `device-label ${event.mode}`), top, middle, node("div", info.current_page_name || "未设置当前页", "event-page mono"));
    button.addEventListener("click", () => select(event));
    fragment.append(button);
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

function renderValue(value, depth = 0) {
  if (value !== null && typeof value === "object") {
    const container = node("div", undefined, "value-tree");
    for (const [key, child] of Object.entries(value)) {
      if (child !== null && typeof child === "object") {
        const details = node("details");
        details.open = depth < 2;
        details.append(node("summary", `${key}  ·  ${Object.keys(child).length} 项`, "mono"), renderValue(child, depth + 1));
        container.append(details);
      } else {
        const row = node("div", undefined, "field-row");
        row.append(node("span", key, "field-key mono"), node("span", child === "" ? '""' : String(child), `field-value mono ${typeof child}`));
        container.append(row);
      }
    }
    if (!Object.keys(value).length) container.append(node("span", Array.isArray(value) ? "[]" : "{}", "subtle mono"));
    return container;
  }
  return node("span", String(value), "mono");
}

function renderDetail() {
  $("detail").hidden = !selected;
  $("detail-empty").hidden = !!selected;
  if (!selected) return;
  const info = selected.payload.event_info || {};
  $("event-meta").textContent = `${selected.deviceName}  /  EVENT #${selected.id}  /  ${time(selected.timestamp)}`;
  $("event-name").textContent = selected.name;
  $("context").replaceChildren(...[
    ["当前页面", info.current_page_name], ["来源页面", info.source_page_name],
    ["归因页面", info.trace_page_name], ["上一页面", info.previous_page_name],
  ].map(([label, value]) => { const item = node("div"); item.append(node("span", label), node("strong", value || "未设置", "mono")); return item; }));
  const fragment = document.createDocumentFragment();
  for (const [key, value] of Object.entries(selected.payload)) {
    const group = node("section", undefined, "field-group");
    group.append(node("h4", key, "mono"), renderValue(value));
    fragment.append(group);
  }
  $("fields").replaceChildren(fragment);
  $("json").textContent = JSON.stringify(selected.payload, null, 2);
  $("fields").hidden = jsonMode;
  $("json").hidden = !jsonMode;
  $("fields-tab").setAttribute("aria-selected", String(!jsonMode));
  $("json-tab").setAttribute("aria-selected", String(jsonMode));
}

function refresh() {
  render();
  if (!selected && filtered().length) select(filtered().at(-1));
}
const poller = new DevicePoller(store, native, refresh, message => { bridgeError = message; });

for (const id of ["search", "action", "page", "device"]) $(id).addEventListener(id === "search" ? "input" : "change", render);
$("pause").onclick = () => { store.togglePause(); render(); };
$("clear").onclick = () => { store.clear($("device").value); refresh(); };
$("latest").onclick = () => { const latest = filtered().at(-1); if (latest) select(latest); $("events").scrollTop = $("events").scrollHeight; };
$("fields-tab").onclick = () => { jsonMode = false; renderDetail(); };
$("json-tab").onclick = () => { jsonMode = true; renderDetail(); };
$("copy").onclick = async () => {
  try { await native({ command: "copy", text: JSON.stringify(selected.payload, null, 2) }); toast("已复制事件参数"); }
  catch { toast("复制失败，可在原始 JSON 中选中并复制。"); }
};
$("export").onclick = async () => {
  const rows = filtered();
  const payload = { formatVersion: 2, devices: store.metadata($("device").value),
    exportedAt: new Date().toISOString(), events: rows.map(exportEvent) };
  try {
    const saved = await native({ command: "export", text: JSON.stringify(payload, null, 2) });
    if (saved) toast(`已保存 ${rows.length} 条事件`);
  } catch (error) { toast(error.message); }
};
document.addEventListener("keydown", event => { if ((event.metaKey || event.ctrlKey) && event.key === "k") { event.preventDefault(); $("search").focus(); } });
render();
poller.tick();
setInterval(() => poller.tick(), 250);
