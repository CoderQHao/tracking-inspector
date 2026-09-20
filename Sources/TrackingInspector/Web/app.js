
const $ = id => document.getElementById(id);
let store = new EventStore();
let sourceID = "";
const native = value => window.webkit.messageHandlers.inspector.postMessage(value);
let selected = null;
let connection = {};
let app = {};
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
function filtered() { return store.filter($("search").value, $("action").value, $("page").value); }
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
  options("action", store.visible.map(e => e.payload.event_info?.action), "全部动作");
  options("page", store.visible.map(e => e.payload.event_info?.current_page_name), "全部页面");
  const rows = filtered();
  $("count").textContent = rows.length;
  $("summary").textContent = `${rows.length} 条匹配 / ${store.visible.length} 条记录`;
  $("live-label").textContent = store.paused ? `Ⅱ 已暂停 · 缓存至 #${store.cursor}` : "● LIVE";
  $("live-label").classList.toggle("paused", store.paused);
  $("pause").textContent = store.paused ? "继续实时更新" : "暂停滚动更新";
  $("clear").textContent = store.clearRequested ? "清空中…" : "清空";
  $("clear").disabled = store.clearRequested;
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
    button.append(top, middle, node("div", info.current_page_name || "未设置当前页", "event-page mono"));
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
  $("event-meta").textContent = `EVENT #${selected.id}  /  ${time(selected.timestamp)}`;
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

async function poll() {
  let connected = false;
  try {
    const batch = await native({ command: "fetch", after: store.cursor, session: store.session });
    if (sourceID !== batch.selectionID) {
      sourceID = batch.selectionID;
      store = new EventStore();
      selected = null;
      renderDetail();
      connection = {}; app = {};
      $("app-info").textContent = "等待 Debug App";
      $("device-info").textContent = "正在连接所选设备";
      $("mode").textContent = "DEBUG";
      $("action").value = ""; $("page").value = "";
    }
    if (batch.error) throw new Error(batch.error);
    connected = true;
    const result = store.ingest(batch);
    connection = batch.connection;
    app = batch.app || {};
    if (result.changed) { selected = null; renderDetail(); toast("App 会话已更新，已切换到本次启动的事件。"); }
    if (!selected && store.visible.length) select(store.visible.at(-1));
    $("status").textContent = connection.mode === "demo" ? "示例运行中" : "已连接";
    $("status").className = "status connected";
    $("mode").textContent = connection.mode === "demo" ? "DEMO · 示例数据" : connection.mode === "usb" ? "USB DEBUG" : "WI-FI · TLS";
    $("app-info").textContent = `${app.bundleID || "Debug App"} · ${app.version || ""} (${app.build || ""})`;
    $("device-info").textContent = connection.device;
    notice = connection.mode === "demo" ? "这是界面演示，事件均为模拟数据。在窗口顶部选择设备以读取真实事件。" : "";
    if (batch.dropped) notice += ` 采集端累计丢弃 ${batch.dropped} 条调试副本（积压、超限或编码失败）；业务上报不受影响。`;
  } catch (error) {
    $("status").textContent = "等待连接";
    $("status").className = "status";
    notice = error.name === "AbortError" ? "读取超时，正在重连。若 App 停在断点，请继续执行。" : error.message;
  }
  render();
  setTimeout(poll, connected && store.cursor < store.latestID && !store.clearRequested ? 50 : 600);
}

for (const id of ["search", "action", "page"]) $(id).addEventListener(id === "search" ? "input" : "change", render);
$("pause").onclick = () => { store.togglePause(); render(); };
$("clear").onclick = () => { store.clear(); selected = null; renderDetail(); render(); };
$("latest").onclick = () => { const latest = filtered().at(-1); if (latest) select(latest); $("events").scrollTop = $("events").scrollHeight; };
$("fields-tab").onclick = () => { jsonMode = false; renderDetail(); };
$("json-tab").onclick = () => { jsonMode = true; renderDetail(); };
$("copy").onclick = async () => {
  try { await native({ command: "copy", text: JSON.stringify(selected.payload, null, 2) }); toast("已复制事件参数"); }
  catch { toast("复制失败，可在原始 JSON 中选中并复制。"); }
};
$("export").onclick = async () => {
  const rows = filtered();
  const payload = { session: store.session, connection, app,
    exportedAt: new Date().toISOString(), events: rows.map(exportEvent) };
  try {
    const saved = await native({ command: "export", text: JSON.stringify(payload, null, 2) });
    if (saved) toast(`已保存 ${rows.length} 条事件`);
  } catch (error) { toast(error.message); }
};
document.addEventListener("keydown", event => { if ((event.metaKey || event.ctrlKey) && event.key === "k") { event.preventDefault(); $("search").focus(); } });
render();
poll();
