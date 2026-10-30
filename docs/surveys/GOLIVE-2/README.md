# GOLIVE-2 — go-live readiness rows 9, 10, 13 and the contract-term copies (`v1.4.84`, 2026-10-30)

Tim's rulings of 2026-10-30 (Q1–Q6), on top of the rulings in force (row 9 2026-10-21, row 10 2026-10-22, row 13 2026-10-24, contract copies 2026-10-29).
Every number below says how it was measured and by whom it was read.

## Part 1 — SYSTEM-MAP-4 close-out
- `readings/part1-prod-check.txt` — one throwaway cfo clone on production, nothing pressed (`SM4_CLOSEOUT_EXIT=0`).
- `readings/part1-readback.txt` — read-back as postgres: 0 throwaway users / roles / grants, one cfo holder, 11 roles, approvals finance/cfo/1000, reconciliation 0.00.

## Row 9 — supplier-portal uploads straight to storage
- Survey: the old route read the whole file into the function (`request.formData()`), which Vercel caps at 4.5 MB before the app.
  The portal-uploads INSERT / SELECT policies only ask "own uploading row, this path, under 10 minutes" — they hold for a request from the browser, so
  **no policy, bucket or migration change**.
- Code: `app/portal/certificates/UploadForm.tsx` (browser half), `actions.ts` (begin / finish / abandon), `lib/sniffFileType.ts` (shared header sniff).
- Live proof: `readings/live-proof-upload.txt`.

## Row 10 — every read pages through
- `scan-unpaged-reads.mjs`, `readings/step0-read-chains.jsonl` — the Step 0 census (AST, 2,097 chains).
- `seed/relation-counts.*` — which relations pass 1,000 rows on the year seed (read as the seed admin).
- `seed/per-parent-max.*` — the most rows one parent holds, per (relation, parent column) a per-parent read filters on (seed admin; NULL parents excluded).
- `codemod-unpaged-reads.mjs` + `readings/codemod.txt` — the one-off rewrite (459 wraps; 11 builder-variable files restored and done by hand).
- `readings/row10-tally.txt` — the final count: **451 reads through `lib/readAll.ts`** (375 `.from` · 76 `.rpc`; 329 `readAll` · 122 `readAllIn`), **7 exempt** with reasons (the 5 of the codemod pass + the 2 change-history `rpc(fn, …)` passthroughs, bounded by construction).
- Build check: `scripts/check-unpaged-reads.mjs` (coverage AST = lexical 2,027 at the end; injections add / overcap / unlist / blind each red; same reading under `NODE_ENV=production`).

## Row 13 — change history and dictionaries
Local year seed (`db/seeds/chain-walk-year.sql`), newest 7,602 change rows regrouped 15 to a transaction so show=500 reads what live reads
(`seed/reshape-top-like-live.sql`; live: newest 501 operations = 7,602 rows, `readings/step0-live-counts-b.txt`). Inside the database, as the seed cfo / admin.

| target (Tim Q2) | before (HEAD rebuild) | after (HEAD + migration) | limit |
|---|---|---|---|
| change history show=20 | 1,401 ms (4 calls) | **123 ms** (1 call) | ≤ 300 ms |
| change history show=500 | 29,976 ms (77 calls) | **2,649 ms** (1 call) | ≤ 3,000 ms |
| count a 366-day export | — (no count existed) | **20 ms** | ≤ 1,000 ms |
| a 50,000-row export | 121,847 ms (change_log_rows, 200 a call) | **15,772 ms** (86 blocks of 500 operations) | ≤ 30,000 ms |
| dictionaries | 180 count requests (14 ms of database work) | **1 call, 10 ms** | 1 call ≤ 100 ms |

`seed/targets-before-after.txt` (the table above), `seed/explain-change-log-rows.txt` (EXPLAIN ANALYZE BUFFERS of the per-call txid grouping),
`seed/compare-before-after.py` + `.txt` — **70 of 70 identical** (7 roles × 9 change-history cases + dictionaries; HEAD rebuild vs the same rebuild with the
migration applied, same data, same time zone). The first comparison ran against a separately seeded rebuild and differed only in `created_at` of one live
row (seeded 24 s apart); a clone created with `TEMPLATE` lost the database's `TimeZone` setting and differed everywhere — both recorded, both explained, neither a function difference.

## Contract copies (Q4 · Q5 · Q6)
- Survey: `contract_document_terms` (frozen copy, jsonb) readable by any side reader; `terms_requests_visible` handed out contract snapshots (`ELSE true`);
  `sale_settlement_compute` caller-rights and executable by every logged-in user, returning settlement amounts.
- Fixture 304 (A–G, two fault injections). Live today: 0 contracts, 0 copies, 0 contract requests (`readings/step0-live-contract-copies.txt`).

## Live proof (`next start` of the final code, reading live; one reader at a time; nothing pressed)
- `readings/live-proof-upload.txt` (U, `GL2_PROOF_EXIT=0`): the page states 10 MB (V39 10,485,760); 390 / 1440 px no sideways scroll; an 11 MB file is refused by
  name (`PORTAL_UPLOAD_TOO_LARGE`) with 0 storage requests and 0 rows; a 9,441,505-byte PDF lands on `?submitted=1` (49.5 s over this machine's link), the
  browser's storage POST carried it and the largest request to the app was 163 bytes; one row `submitted` with file_size 9,441,505 and a stored object of
  9,441,505 bytes; all removed by the cleanup plan. **Earlier runs found two defects, both fixed before the final run:** the form's `router.push` + `router.refresh`
  aborted its own navigation (`?submitted=1` RSC request `ERR_ABORTED`; the person saw no notice) → a full-page navigation (`live-proof-upload-run2.txt`); and a
  proof-script wait that could not say where it landed (`live-proof-run1-11mb-timeout.txt`).
- `readings/live-proof-pages.txt` (C / D, `GL2_PROOF_EXIT=0`): seven roles. Live, not the yardstick: change history show=20 3–13 s, **show=500 70–79 s** (admin,
  cfo; was 107 s), dictionaries 11–22 s (was 28–46 s); cfo export of one day 4,230 recorded changes = postgres base-table count, 797 file rows, 46 s; 730 days →
  400. **The first page run found live's `statement_timeout = 8 s` for authenticated** (one call for 501 operations hit 57014 on the free instance) → the page and
  the export read in blocks (`lib/trail/changeLogFilters.ts` readChangeLog). `live-proof-pages-run2-stale-build.txt` ran on a stale build and does not count.
- `readings/live-proof-copies.txt` (M): 0 copies, 0 contract requests, 0 contracts on live — nothing to read; fixture 304 proves the masking.
- `readings/live-largest-operations.txt`: the largest operation on live is 88 rows.

## Verify order
`readings/gate-offline.txt` · `backup.txt` (12:58) · `dry-run.*` (3 min 22 s; the index build held change_log's SHARE lock that long, blocking writes) · `apply.txt` (broken window from 14:48:48 CST) · gate runs: `gate-full-run1-before-training-fix.txt` (green, superseded by a code change) · `gate-full-run2-stopped.txt` · `gate-full-run3-dead-socket.txt` (a live-phase psql with no backend for 36 min) · `gate-full-run4-timeout-124.txt` · `gate-full.txt` (final) · smoke `smoke-run1-training-500.txt` (/hr/training 500 — a cast hid the codemod's wrap from tsc; fixed) · `types.txt` · `tsc.txt` · `build.txt` · `i18n.txt` · `swallow.txt` · `layout-*.txt` · `live-proof-*.txt` · `cod-bytes.txt` · `fresh-clone-build.txt`.
