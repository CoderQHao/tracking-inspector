class EventStore {
  constructor({ limit = 2000, byteLimit = 16 * 1024 * 1024 } = {}) {
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
      const row = { ...event, key: `${batch.session}:${event.id}`, search: encoded.toLowerCase(), bytes: encoded.length * 2 };
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

function exportEvent(event) {
  const { id, timestamp, name, payload } = event;
  return { id, timestamp, name, payload };
}

if (typeof module !== "undefined") module.exports = { EventStore, exportEvent };
