class EventStore {
  constructor({ limit = 2000, byteLimit = 16 * 1024 * 1024, namespace = "" } = {}) {
    this.namespace = namespace;
    this.limit = limit;
    this.byteLimit = byteLimit;
    this.events = [];
    this.bytes = 0;
    this.session = "";
    this.cursor = 0;
    this.latestID = 0;
    this.missed = 0;
    this.trimmed = 0;
    this.paused = false;
    this.frozen = [];
    this.clearRequested = false;
  }

  ingest(batch) {
    const changed = !!this.session && this.session !== batch.session;
    if (this.session !== batch.session) {
      this.events = [];
      this.frozen = [];
      this.bytes = this.cursor = this.missed = this.trimmed = 0;
      this.session = batch.session;
    }
    this.latestID = batch.latestID;
    if (this.clearRequested) {
      this.cursor = batch.latestID;
      this.clearRequested = false;
      return { changed, cleared: true };
    }
    this.missed += Math.max(0, batch.oldestID - this.cursor - 1);
    for (const event of batch.events) {
      if (event.id <= this.cursor) continue;
      const encoded = JSON.stringify(event);
      const row = { ...event, key: JSON.stringify([this.namespace, batch.session, event.id]), search: encoded.toLowerCase(), bytes: encoded.length * 2 };
      this.events.push(row);
      this.bytes += row.bytes;
    }
    this.cursor = batch.nextCursor;
    while (this.events.length > this.limit || this.bytes > this.byteLimit) {
      this.bytes -= this.events.shift().bytes;
      this.trimmed++;
    }
    return { changed, cleared: false };
  }

  clear() {
    this.events = [];
    this.frozen = [];
    this.bytes = this.missed = this.trimmed = 0;
    // Complete at the next snapshot boundary, so an in-flight response cannot restore old rows.
    this.clearRequested = true;
  }

  togglePause() {
    this.paused = !this.paused;
    this.frozen = this.paused ? this.events.slice() : [];
  }

  get visible() { return this.paused ? this.frozen : this.events; }

  filter(query, action, page) {
    const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
    return this.visible.filter(e => terms.every(term => e.search.includes(term))
      && (!action || e.payload.event_info?.action === action)
      && (!page || e.payload.event_info?.current_page_name === page));
  }
}

// Independent device sessions with one shared retention budget. Arrival order is local;
// phone clocks are not assumed to be synchronized.
class MultiDeviceStore {
  constructor({ limit = 2000, byteLimit = 16 * 1024 * 1024 } = {}) {
    this.limit = limit;
    this.byteLimit = byteLimit;
    this.channels = new Map();
    this.paused = false;
    this.frozen = [];
    this.sequence = 0;
  }

  updateSources(sources) {
    // Transfer recordings before removing transport aliases. Old in-flight responses remain
    // fenced by channel object identity; a handover keeps the canonical cursor and generation.
    for (const source of sources) {
      const aliases = (source.aliases || []).filter(id => id !== source.id && this.channels.has(id));
      if (!aliases.length) continue;
      const existing = this.channels.get(source.id);
      const donors = aliases.map(id => this.channels.get(id));
      const preferred = existing || donors[0];
      const session = preferred.store.session;
      const matching = [existing, ...donors].filter(c => c && c.store.session === session);
      const target = existing || { ...preferred, source, inFlight: false, nextDue: 0,
        store: new EventStore({ limit: this.limit, byteLimit: this.byteLimit, namespace: source.id }) };
      const normalize = e => {
        const row = { ...e, sourceID: source.id, deviceName: source.name,
          key: JSON.stringify([source.id, e.session, e.id]) };
        row.search = JSON.stringify(exportEvent(row)).toLowerCase();
        row.bytes = row.search.length * 2;
        return row;
      };
      const unique = events => {
        const values = new Map();
        for (const event of events) {
          const row = normalize(event), previous = values.get(row.key);
          if (!previous || row.arrival < previous.arrival) values.set(row.key, row);
        }
        return [...values.values()];
      };
      Object.assign(target.store, { session, namespace: source.id,
        cursor: Math.max(...matching.map(c => c.store.cursor)),
        latestID: Math.max(...matching.map(c => c.store.latestID)),
        clearRequested: matching.some(c => c.store.clearRequested),
        events: unique(matching.flatMap(c => c.store.events)).sort((a, b) => a.id - b.id) });
      if (target.store.clearRequested) target.store.events = [];
      target.store.bytes = target.store.events.reduce((n, e) => n + e.bytes, 0);
      const related = new Set([source.id, ...aliases]);
      this.frozen = this.frozen.filter(e => !related.has(e.sourceID)).concat(
        target.store.clearRequested ? [] : unique(this.frozen.filter(e => related.has(e.sourceID) && e.session === session))).sort((a, b) => a.arrival - b.arrival);
      this.channels.set(source.id, target);
    }
    const allowed = new Set(sources.map(s => s.id));
    for (const id of this.channels.keys()) {
      if (!allowed.has(id)) this.remove(id);
    }
    for (const source of sources) {
      const previous = this.channels.get(source.id);
      if (previous?.source.generation === source.generation) {
        previous.source = source;
      } else {
        this.remove(source.id);
        this.channels.set(source.id, {
          source, store: new EventStore({ limit: this.limit, byteLimit: this.byteLimit, namespace: source.id }),
          connected: false, error: "正在连接…", app: {}, dropped: 0, inFlight: false, nextDue: 0,
        });
      }
    }
  }

  remove(id) {
    this.channels.delete(id);
    this.frozen = this.frozen.filter(e => e.sourceID !== id);
  }

  ingest(source, batch) {
    const channel = this.channels.get(source.id);
    if (channel?.source.generation !== source.generation) return false;
    const result = channel.store.ingest({ ...batch, events: batch.events.map(event => ({
      ...event, sourceID: source.id, deviceName: source.name, mode: batch.connection?.mode || source.mode,
      session: batch.session, app: batch.app || {},
    })) });
    if (result.changed) this.frozen = this.frozen.filter(e => e.sourceID !== source.id);
    for (const event of channel.store.events) {
      if (event.arrival === undefined) event.arrival = ++this.sequence;
    }
    channel.connected = true;
    channel.error = "";
    channel.app = batch.app || {};
    channel.dropped = batch.dropped || 0;
    const events = this.events;
    let bytes = events.reduce((total, event) => total + event.bytes, 0);
    let count = events.length;
    for (const event of events) {
      if (count <= this.limit && bytes <= this.byteLimit) break;
      const store = this.channels.get(event.sourceID).store;
      store.events.shift();
      store.bytes -= event.bytes;
      store.trimmed++;
      bytes -= event.bytes;
      count--;
    }
    return result;
  }

  get events() { return [...this.channels.values()].flatMap(c => c.store.events).sort((a, b) => a.arrival - b.arrival); }
  get visible() { return this.paused ? this.frozen : this.events; }
  get trimmed() { return [...this.channels.values()].reduce((n, c) => n + c.store.trimmed, 0); }
  get missed() { return [...this.channels.values()].reduce((n, c) => n + c.store.missed, 0); }

  togglePause() {
    this.paused = !this.paused;
    this.frozen = this.paused ? this.events.slice() : [];
  }

  clear(sourceID = "") {
    for (const [id, channel] of this.channels) {
      if (!sourceID || id === sourceID) channel.store.clear();
    }
    this.frozen = this.frozen.filter(e => sourceID && e.sourceID !== sourceID);
  }

  filter(query, action, page, sourceID = "") {
    const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
    return this.visible.filter(e => (!sourceID || e.sourceID === sourceID)
      && terms.every(term => e.search.includes(term))
      && (!action || e.payload.event_info?.action === action)
      && (!page || e.payload.event_info?.current_page_name === page));
  }

  metadata(sourceID = "") {
    return [...this.channels.values()].filter(c => !sourceID || c.source.id === sourceID).map(c => ({
      id: c.source.id, name: c.source.name, mode: c.source.mode, session: c.store.session,
      app: c.app, connected: c.connected, error: c.error, dropped: c.dropped,
    }));
  }
}

class DevicePoller {
  constructor(store, request, onChange = () => {}, onError = () => {}, now = () => Date.now()) {
    Object.assign(this, { store, request, onChange, onError, now });
    this.discovering = false;
  }

  async tick() {
    if (this.discovering) return;
    this.discovering = true;
    try {
      const sources = await this.request({ command: "channels" });
      this.store.updateSources(sources);
      this.onError("");
      for (const channel of this.store.channels.values()) {
        if (!channel.inFlight && this.now() >= channel.nextDue) this.read(channel);
      }
      this.onChange();
    } catch (error) { this.onError(error.message); }
    finally { this.discovering = false; }
  }

  read(channel) {
    channel.inFlight = true;
    const source = channel.source;
    Promise.resolve().then(() => this.request({ command: "fetch", deviceID: source.id, generation: source.generation,
      after: channel.store.cursor, session: channel.store.session })).then(batch => {
      if (this.store.channels.get(source.id) !== channel) return;
      if (batch.sourceID !== source.id || batch.generation !== source.generation) throw new Error("连接已更新，正在重试。");
      if (batch.superseded) return;
      if (batch.error) throw new Error(batch.error);
      this.store.ingest(source, batch);
    }).catch(error => {
      if (this.store.channels.get(source.id) !== channel) return;
      channel.connected = false;
      channel.error = error.message;
    }).finally(() => {
      channel.inFlight = false;
      channel.nextDue = this.now() + (channel.connected && channel.store.cursor < channel.store.latestID ? 50 : 600);
      if (this.store.channels.get(source.id) === channel) this.onChange();
    });
  }
}

function exportEvent(event) {
  const { id, timestamp, name, payload, sourceID, deviceName, mode, session, app } = event;
  return sourceID ? { sourceID, deviceName, mode, session, app, id, timestamp, name, payload } : { id, timestamp, name, payload };
}

if (typeof module !== "undefined") module.exports = { EventStore, MultiDeviceStore, DevicePoller, exportEvent };
