# Capture protocol v1

The Mac app consumes read-only snapshots emitted by a cooperating Debug app. The emitter should copy events at the analytics SDK boundary, keep capture work off the business thread, and never alter production delivery. Compile the emitter out of Release builds.

## Transports

**USB**: an HTTP listener bound to the device's IPv4 loopback address, TCP port **18765**. macOS connects through usbmuxd. Do not bind the unauthenticated endpoint to all network interfaces.

**Wireless**: a separate opt-in TLS listener with Bonjour service type **`_trackinspect._tcp`**. Its advertised port may be dynamic. Use a stable, anonymous service name so the Mac can remember the selected device. Advertise neither pairing keys nor event data.

TLS parameters:

- TLS 1.2 only.
- Cipher suite `TLS_PSK_WITH_AES_128_GCM_SHA256` (`0x00A8`).
- A cryptographically random 16-byte pre-shared key, shown as 32 hexadecimal characters on the phone.
- PSK identity bytes: UTF-8 `tracking-inspector-v1`.
- Disable TLS session resumption and tickets on both peers; each request must authenticate the current key, even after an earlier successful pairing.
- Apple APIs: `NWProtocolTLS.Options`, `sec_protocol_options_add_pre_shared_key`, `sec_protocol_options_append_tls_ciphersuite`.

The phone generates a new key whenever wireless capture is enabled. Disabling must cancel the listener and all wireless connections, and prevent callbacks from previous listener instances from accepting requests. Leave USB operational. Never fall back to plaintext if TLS fails.

iOS Info.plist requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing `_trackinspect._tcp`. Ask for local network access only when the user enables wireless capture. Keep the app in the foreground; this protocol does not provide background execution.

## Request

```http
GET /events?after=0&session= HTTP/1.1
Host: localhost
Connection: close
```

URL-encode `session`. Send at most 100 events per response. Each request uses a fresh connection. Return an HTTP 200 response with `Content-Type: application/json`, a single byte-accurate `Content-Length`, and `Connection: close`. Chunked encoding and redirects are unsupported. The Mac accepts at most 8 MiB per response and 8 KiB of headers.

## Response

All values below are fictional:

```json
{
  "protocolVersion": 1,
  "session": "random-id-per-app-launch",
  "oldestID": 1,
  "latestID": 1,
  "nextCursor": 1,
  "dropped": 0,
  "capacity": 500,
  "app": { "bundleID": "example.debug", "version": "1.0", "build": "1" },
  "events": [{
    "id": 1,
    "timestamp": 1700000000.125,
    "name": "button_click",
    "payload": {
      "event_info": { "action": "CLICK", "current_page_name": "DEMO_PAGE" },
      "content_info": { "id": "sample-item", "source": "demo" }
    }
  }]
}
```

- `session`: nonempty ID, at most 128 UTF-8 bytes, new for each emitter process.
- Event IDs: increasing integers starting at 1, unique within the session, no greater than JavaScript's safe integer limit minus one.
- `oldestID`: first retained event ID, or `latestID + 1` when empty.
- `latestID`: latest accepted event ID, 0 before the first event.
- `nextCursor`: final returned ID; for an empty response use `latestID`.
- On a session mismatch, ignore `after` and start from the oldest retained event. Otherwise return retained events with IDs greater than `after`, in ascending order.
- `dropped`: capture copies skipped due to backpressure, invalid encoding, or excessive size. Normal retention eviction is reflected in `oldestID`.
- Event `timestamp`: Unix seconds. `payload`: any JSON object; preserve original field names and omitted defaults.
- `app`: optional informational dictionary. `events`, version, session, cursor metadata and each event's `id`, `timestamp`, `name`, `payload` are required.

The UI offers convenience filters for optional `payload.event_info.action` and `current_page_name`. It displays `source_page_name`, `trace_page_name`, and `previous_page_name` when supplied. All other payload fields remain inspectable and searchable.

Recommended emitter limits: 500 events / 4 MiB, 256 KiB per event, a bounded serialization queue, a small connection cap, and request deadlines. The Mac uses a six-second transport timeout and retries after failure.
