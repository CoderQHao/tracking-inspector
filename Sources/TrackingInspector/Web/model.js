// A disposable presentation of the application-owned recording. No device polling or cursors live here.
class NativeRecordingStore {
  constructor() {
    this.events = [];
    this.sources = [];
    this.paused = false;
    this.frozen = [];
    this.version = -1;
    this.sequence = 0;
    this.trimmed = 0;
    this.missed = 0;
    this.metadataSignature = '';
  }

  applySnapshot(snapshot) {
    const signature = JSON.stringify([snapshot.channels, snapshot.trimmed, snapshot.missed]);
    const changed = snapshot.reset || snapshot.events.length > 0 || signature !== this.metadataSignature;
    this.metadataSignature = signature;
    this.sources = snapshot.channels;
    this.trimmed = snapshot.trimmed;
    this.missed = snapshot.missed;
    if (snapshot.reset) this.events = [];
    this.events = this.events.filter(e => e.arrival >= snapshot.oldestArrival);
    this.events.push(...snapshot.events.map(NativeRecordingStore.row));
    this.version = snapshot.version;
    this.sequence = snapshot.sequence;
    // Retention may evict rows while paused; only clear, session change or deselection invalidates the frozen view.
    const frozen = new Map();
    for (const event of this.frozen) {
      const source = this.sources.find(s => s.id === event.sourceID || s.aliases?.includes(event.sourceID));
      if (!source || source.session !== event.session || !source.acceptedEpochs.includes(event.epoch)) continue;
      const row = source.id === event.sourceID ? event : NativeRecordingStore.row({ ...event,
        sourceID: source.id, deviceName: source.name, epoch: source.epoch });
      if (!frozen.has(row.key)) frozen.set(row.key, row);
    }
    this.frozen = [...frozen.values()];
    return changed;
  }

  static row(raw) {
    const row = { ...raw, key: JSON.stringify([raw.sourceID, raw.session, raw.id]) };
    row.search = JSON.stringify(exportEvent(row)).toLowerCase();
    row.bytes = row.search.length * 2;
    return row;
  }

  get visible() { return this.paused ? this.frozen : this.events; }
  togglePause() {
    this.paused = !this.paused;
    this.frozen = this.paused ? this.events.slice() : [];
  }
  metadata(sourceID = '') { return this.sources.filter(s => !sourceID || s.id === sourceID); }
}

class RecordingPoller {
  constructor(store, request, onChange = () => {}, onError = () => {}) {
    Object.assign(this, { store, request, onChange, onError });
    this.pending = null;
    this.failed = false;
  }
  tick() {
    return this.pending || this.enqueue(() => this.read());
  }
  clear(sourceID) {
    return this.enqueue(async () => {
      await this.request({ command: 'clearRecording', sourceID });
      await this.read();
    });
  }
  enqueue(action) {
    const pending = (this.pending || Promise.resolve()).then(action).catch(error => {
      this.failed = true;
      this.onError(error.message);
      this.onChange();
    }).finally(() => { if (this.pending === pending) this.pending = null; });
    this.pending = pending;
    return pending;
  }
  async read() {
    const snapshot = await this.request({ command: 'recording', version: this.store.version, after: this.store.sequence });
    this.onError('');
    if (this.store.applySnapshot(snapshot) || this.failed) this.onChange();
    this.failed = false;
  }
}

function exportEvent(event) {
  const { id, timestamp, name, payload, sourceID, deviceName, mode, session, app } = event;
  return sourceID ? { sourceID, deviceName, mode, session, app, id, timestamp, name, payload } : { id, timestamp, name, payload };
}

if (typeof module !== 'undefined') module.exports = { NativeRecordingStore, RecordingPoller, exportEvent };
