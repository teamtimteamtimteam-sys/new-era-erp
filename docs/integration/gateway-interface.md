# Evoltrya OS — Gateway interface

**For equipment vendors and integrators.** Version 1, introduced with system release v1.4.37 (MES-1, 2026-10-06).

This document is the whole contract between a plant gateway and Evoltrya OS. A gateway collects readings from the
devices wired to it (scales, weighbridges, discharge cabinets, controllers, meters, scanners…) and forwards them to
Evoltrya OS over HTTPS. Evoltrya OS **only receives**: it never connects to the gateway, never sends commands, and never
returns any stored data. Everything the gateway gets back is an acknowledgement of what it just sent.

---

## 1. Before you start — what Evoltrya gives you

For each gateway, Evoltrya staff register it under **Operation › Devices** and give you:

| item | example | notes |
|---|---|---|
| **Gateway code** | `DEV-2026-0007` | Identifies the gateway. Sent on every call. |
| **Gateway key** | `ngk_3f9a…` (68 characters) | The gateway's secret. Shown **once** when issued; Evoltrya stores only a one-way hash and cannot show it again. |
| **Device codes** | `DEV-2026-0008`, `DEV-2026-0009` | One per device behind this gateway. A message names the device it came from. |
| **Data class** for each device | `weighing`, `meter_reading`, `connection_test` … | What kind of reading the device sends. |
| **Project URL** and **public API key** | `https://<project>.supabase.co`, `eyJ…` | The public API key is the same for every gateway and is **not** a secret; the gateway key is. |

You give Evoltrya the **heartbeat interval** you will use (seconds). Until that number is entered, Evoltrya shows the
gateway as *"Not yet set — silence cannot be judged"* and cannot tell when it goes quiet.

---

## 2. Transport

* **One endpoint, one method:**
  `POST https://<project>.supabase.co/rest/v1/rpc/ingest_submit`
* **HTTPS only.** TLS 1.2 or later.
* **Headers:**

  ```
  Content-Type: application/json
  apikey: <public API key>
  Authorization: Bearer <public API key>
  ```
* **Body** — always a JSON object with exactly three fields:

  ```json
  {
    "p_gateway": "DEV-2026-0007",
    "p_key":     "ngk_…",
    "p_body":    { … }
  }
  ```

  `p_body` is either a **heartbeat** (§4) or a **batch of messages** (§3).
* **The key never goes in the URL.** Only `POST` is accepted.
* **HTTP status.** A call that reached Evoltrya answers **HTTP 200** with a JSON object, whether it was accepted or
  refused — read `ok` and `code` in the body (§5). Any other HTTP status (4xx/5xx, timeouts, connection errors) means the
  call did **not** reach Evoltrya's ledger: keep the messages and send them again (§6).

### Limits (current values; Evoltrya may change them and will tell you)

| limit | value |
|---|---|
| Size of `p_body` | 262 144 bytes (256 KiB) |
| Messages per call | 500 |
| A message timestamp ahead of Evoltrya's clock before it is flagged | 300 s |

---

## 3. Sending readings — the message envelope

```json
{
  "stream": "main",
  "messages": [
    {
      "seq": 1041,
      "device": "DEV-2026-0008",
      "class": "weighing",
      "payload": { … device-specific … },
      "site_from": "2026-10-06T09:14:02+08:00",
      "site_to":   "2026-10-06T09:14:05+08:00",
      "dataset_ref": "WB-20261006-0031"
    }
  ]
}
```

| field | required | meaning |
|---|---|---|
| `stream` | yes | A name for one numbering sequence, 1–64 characters. Most gateways use a single stream (e.g. `"main"`). If the gateway keeps separate counters (e.g. per port), give each its own stream. |
| `messages` | yes | Array, 1 to 500 items. |
| `seq` | yes | Positive whole number, **unique within (gateway, stream)**, normally increasing by 1. It is the message's identity: Evoltrya uses it to recognise repeats and to detect gaps. **Never reuse a sequence number for different content** (§6). |
| `device` | yes | The device code the reading came from. The device must be registered **behind this gateway**. |
| `class` | yes | The data class (§1). |
| `payload` | yes | The reading itself, any JSON value. Its inside is checked later, by the class's transformer (§7), not at receipt. |
| `site_from`, `site_to` | no | When the reading was taken, by the gateway's clock, ISO 8601 with offset. `site_from` must not be after `site_to`. If `site_to` is more than 300 s ahead of Evoltrya's clock, the message is still accepted but flagged *clock ahead* — please keep the gateway clock on NTP. |
| `dataset_ref` | no | Your own reference (ticket number, batch id…), up to 200 characters. |

**Envelope errors are rejected, not stored.** A message whose envelope is wrong is answered in `rejected` (§5) and
nothing is kept for it — fix the message and send it again with the same `seq`. The other messages in the same call are
unaffected.

---

## 4. Heartbeat

When the gateway has nothing to send, it calls with:

```json
{ "p_gateway": "DEV-2026-0007", "p_key": "ngk_…", "p_body": { "heartbeat": true } }
```

* Send one at least once per heartbeat interval. Any accepted data call also counts as "heard from".
* A heartbeat carries nothing else (no `messages`).
* Answer: `{"ok": true}`.
* If Evoltrya hears nothing for longer than the interval, the gateway is shown as **silent** and staff are reminded.
  When it comes back, the silent period is recorded as an outage on the gateway's page.

---

## 5. Responses

### Accepted call

```json
{
  "ok": true,
  "accepted":   [1041, 1042],
  "duplicates": [1040],
  "rejected":   [ { "index": 3, "seq": 1043, "code": "DEVICE_NOT_ON_THIS_GATEWAY" } ]
}
```

| list | meaning | what the gateway does |
|---|---|---|
| `accepted` | stored, by `seq` | may delete them |
| `duplicates` | already stored earlier with **identical** content | may delete them |
| `rejected` | not stored; `index` is the position in `messages`, `seq` is echoed if it could be read | fix and resend, or alert an operator |

Rejection codes:

| code | meaning |
|---|---|
| `ENVELOPE_INVALID` | `seq` missing or not a positive whole number; `device`/`class` not text; `payload` missing; a timestamp unreadable; `site_from` after `site_to`; `dataset_ref` too long |
| `DEVICE_NOT_ON_THIS_GATEWAY` | the device code is unknown, retired, or registered behind a different gateway (one code for all three, on purpose) |
| `CLASS_UNKNOWN` | the data class is unknown or no longer active |
| `SEQ_REUSED` | this (gateway, stream, seq) was already stored with **different** content |

### Refused call

```json
{ "ok": false, "code": "refused" }
```

The gateway code, the key, or the gateway's status is not accepted (unknown code, wrong key, revoked key, retired
gateway). **The answer never says which** — the exact reason is visible to Evoltrya staff on the gateway's page. Do not
retry a refused call in a loop: check the configuration and contact Evoltrya. Repeated refused calls are logged and,
past a budget, only counted.

### Malformed transmission (only after the key was accepted)

```json
{ "ok": false, "code": "too_large" }     // p_body over the size limit
{ "ok": false, "code": "too_many" }      // more than 500 messages
{ "ok": false, "code": "malformed" }     // p_body not an object; no stream; empty messages; bad heartbeat
```

Nothing from that call is stored. Split or correct the batch and send it again.

---

## 6. Retries and back-fill

* **Keep every message until it appears in `accepted` or `duplicates`.** If a call times out or the connection drops,
  you cannot know whether it was stored — send the **same messages with the same `seq`** again. Already-stored ones come
  back in `duplicates`; nothing is stored twice.
* **Back-fill after an outage:** send the buffered messages in `seq` order, in batches of up to 500, with their original
  `site_from`/`site_to`. There is no time limit on how old a message may be.
* **Gaps:** Evoltrya shows any gap in a stream's sequence on the gateway's page. A gap that is later filled disappears.
  If messages are truly lost, tell Evoltrya — do not renumber.
* **Never reuse a `seq` for different content.** It is answered `SEQ_REUSED` and shown as an anomaly. If the gateway's
  counter is reset (firmware update, replacement), start a **new stream name**.

---

## 7. What happens after receipt

Accepted messages wait in Evoltrya's **capture inbox** with status *received*. Evoltrya staff process the inbox; each
message is then checked by its data class's transformer:

* **transformed** — the reading was valid and was taken into its record;
* **failed** — the payload did not pass the check; staff see the reason, and can retry or discard it with a reason;
* **awaiting transform** — the data class has no transformer yet (it is introduced by a later release). The message is
  kept and will be processed then.

Nothing is ever deleted. None of this changes what the gateway sees — the receipt answer (§5) is final for the gateway.

---

## 8. The `connection_test` class — commissioning check

Use this to prove, end to end, that a device reaches Evoltrya before real readings flow. It creates no business record.

```json
{
  "stream": "commissioning",
  "messages": [
    { "seq": 1, "device": "DEV-2026-0008", "class": "connection_test",
      "payload": { "text": "Scale 1 at intake, cabled 2026-10-06" } }
  ]
}
```

`payload.text` must be text of 1–200 characters (after trimming). After Evoltrya staff process the inbox, the message
shows as *transformed*; any other payload is still accepted at receipt (the envelope was fine) and then shows as
*failed* with the code `CONNECTION_TEST_TEXT_REQUIRED`. Any registered device behind the gateway may send it.

---

## 9. Key rotation

A gateway may hold **up to two active keys** at a time, so a key can be replaced without a gap:

1. Evoltrya issues a **new key** (shown once) — the old one keeps working. (A third key cannot be issued while two are active.)
2. You install the new key on the gateway and confirm a call is accepted.
3. Evoltrya **revokes the old key**. From that moment the old key is refused; the new one continues.

If a key may have leaked, tell Evoltrya: it is revoked immediately and a new one issued. Retiring a gateway revokes all
its keys.

---

## 10. Checklist for commissioning

- [ ] Gateway code, key, device codes and data classes received; heartbeat interval given to Evoltrya
- [ ] Heartbeat answered `{"ok": true}`
- [ ] One `connection_test` message accepted, then shown as transformed
- [ ] Re-sending the same message answered in `duplicates`
- [ ] Gateway clock on NTP (no *clock ahead* flags)
- [ ] Buffering: messages are kept until acknowledged, and survive a gateway restart
