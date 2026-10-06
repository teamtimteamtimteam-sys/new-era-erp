# Pending values — the standards the plant still has to supply

**Created by MES-1 (2026-10-06, MES-0 §5 · Q92 · Q93; MES-1 Step 0 Q1 · Q2, Tim).**

This file and the page **Settings › Pending values** (`/settings/pending-values`) are two views of one list.
The page is read from the database view `pending_values` (`db/views/pending_values.sql`): **one arm per value**,
each arm carrying **its own permission code**, and a reader sees only the arms whose code they hold.
Each row on the page is one concrete thing still empty — which value, on which record, and where to fill it.
When the value is supplied, the row disappears by itself (the view stores nothing).

**Rule (Tim, Q2):** every later MES cut that introduces a pending value adds **its arm to `pending_values` and its row
to this file in the same commit.** A value listed here but with no arm, or an arm with no row here, is a defect.

The full catalogue of values the MES group will need (V1–V15 and the qualitative ones) is in
`docs/surveys/MES-0/README.md` §5. Only values whose cut has shipped appear below.

## Live arms

| # | value | where the page sends you | arm reads | permission | supplied by | trigger | added by |
|---|---|---|---|---|---|---|---|
| V5 | Heartbeat interval per gateway (seconds) | the gateway's device page (`/operation/devices/<id>`) | every gateway not retired whose `devices.heartbeat_interval_s` is empty | `module.processing.view` | integrator / device vendor | gateway commissioning | MES-1 |
| V6 | Working hours for the transmission-anomaly listing | `/operation/handovers` (the shift dictionary) | every active shift whose `shifts.starts_at` and `ends_at` are both empty | `module.processing.view` | Tim | shift times decided | MES-1 |

**What "Not yet set" means for V5.** A gateway with no heartbeat interval cannot be judged silent: its status reads
**"Not yet set — silence cannot be judged"**, it raises no `gateway_silent` reminder, and no outage is recorded for it.
Nothing guesses an interval.

**What V6 holds back.** `ingest_transmission_anomalies` lists refused calls, overflow buckets, sequence reuse and
clock-ahead messages today. The **out-of-hours** arm (transmissions outside working hours) is not built until V6 is supplied — there is no
definition of "working hours" to compare against, and inventing one would flag honest night shifts.
