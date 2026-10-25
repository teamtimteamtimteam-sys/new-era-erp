# TABLE-EXPORT-3c — Step 0 survey (2026-10-25)

Started from `7fe03e1dfd6b2b60ae31e6fd1b092bfdda664773` (HEAD = origin/main = ls-remote, tree clean).
Read directly (grep / sed / cat by three read-only survey agents, key claims re-checked by hand); no browser sweeps.
Exemption list at start: `node scripts/check-table-export.mjs` → 273 tables, 190 declare export, **TABLE-EXPORT-3 37 · PERMANENT 22**.

## 1 · The 37 entries

"Tables" = `<DataTable` / `<table` definitions in the file (a component drawn N times counts once; N noted).
Masked = a cell the screen draws as 「受限」 (or should — marked ✗).

### Shared components (8 entries, 8 tables)

| File | Tables | Masked | Pages it appears on |
|---|---|---|---|
| `components/batch/ModuleCountPanel.tsx` | 1 | — | `/inbound/[id]/edit` :963 · `/output/[id]/edit` :516 |
| `components/finance/FinanceAttachmentsPanel.tsx` | 1 (file metadata) | — | `/finance/receivables/[saleId]` :316 · `/finance/payments/[id]` :375 · `/finance/expenses/[id]` :407 · `/finance/payables/[batchId]` :270 |
| `components/finance/SettlementHistoryTable.tsx` | 1, **trail**, pushed total row on 3 of 4 callers | — | `/finance/receivables/[saleId]` :313 · `/finance/invoices/[id]` :580 (no total) · `/finance/expenses/[id]` :402 (unpaid only) · `/finance/payables/[batchId]` :265 |
| `components/inventory/MovementTimelineTable.tsx` | 1, **trail** (`inventory_movements` append-only) | — | via `MovementTimeline.tsx:43` → `/inbound/[id]/edit` :1023 · `/output/[id]/edit` :577 |
| `components/metals/MetalContentPanel.tsx` | 1 | — | `/inbound/[id]/edit` :836 · `/output/[id]/edit` :387 |
| `components/pricing/PriceBreakdown.tsx` | 1, **computed, not saved** | — (caller gates) | `/tools/pricing/calculator` (CalculatorForm :260, PERMANENT) · via `AssayImpactPreview` → `/inbound/[id]/assays/new` (entry form) · `/inbound/[id]/assays/[assayId]` :420 · `/inbound/[id]/edit` (RepriceFromContentPanel :77) |
| `components/pricing/TermsRequestsPanel.tsx` | 1 definition, **drawn once per open request** | whole table replaced by a 「受限」 sentence when terms are hidden (`terms_requests_visible.sql:33`; `data.view_prices` / `data.view_purchase_prices`) | `/tools/pricing/formulas` :120 · `/tools/pricing/formulas/[id]/edit` :141 · `/contracts` :313 · `/contracts/[id]` :218 |
| `components/related/RelatedTable.tsx` | 1, keyset-paged 20 a page (`related-records.tsx:108,256-267`; rpc caps `p_limit` 1..100) | — (RLS rows) | via `related-records.tsx:325` → `/related/[subject]/[id]/[target]` · `/documents/[key]` |

### Operation (12 entries, 25 tables)

| File | Tables | Masked |
|---|---|---|
| `blending/[id]/BlendingTables.tsx` | 3 (targets · lines · outcome) | 「受限」 baked into row text (`module.inbound.view` / `module.output.view` per batch) |
| `equipment/[id]/DowntimePanel.tsx` | 1 (also on `/finance/assets/[id]` :502) | — |
| `equipment/[id]/MaintenancePanel.tsx` | 1 (also on `/finance/assets/[id]` :485) | ✗ capital advice reads "— is —%" without `module.finance.view` (:220-226; view nulls the amounts, `equipment_maintenance_advice.sql:33-46`) |
| `equipment/[id]/SparePartsPanel.tsx` | 1 | value column **removed** without `data.view_prices`+`module.inventory.view` (:225, page :182); batch 「受限」 text (page :201); the 「受限」 branch at :122 is unreachable |
| `operation-types/[code]/OperationTypeEditor.tsx` | 2 (fields · linked machines); saved config, the only screen | — |
| `orders/[id]/WorkOrderTables.tsx` | 3 (inputs · outputs · linked runs) | — |
| `processing/[id]/ContaminationPanel.tsx` | 1 | — |
| `processing/[id]/CostPanel.tsx` | 1 (total is a `<p>` below, not a row) | amount `MaskedValue`, `data.view_prices` (:66) |
| `processing/[id]/DischargePanel.tsx` | 3 (batches · module results · channels) | — |
| `processing/[id]/LossPanel.tsx` | 1 | — |
| `processing/[id]/ProcessingTables.tsx` | 5 (WO variance · lineage · inputs · outputs · recovery) | outputs allocated cost + unit cost `MaskedValue`, `data.view_prices` (:227, :233) |
| `processing/[id]/RunRecordPanels.tsx` | 3 (values · events · header corrections — **trail**) | — |

### Other modules (17 entries, 23 tables)

| File | Tables | Masked |
|---|---|---|
| `logistics/containers/[id]/ContainerPanels.tsx` | 2 hand-built (shipments · document checklist, status is a per-row `<select>`) | — |
| `logistics/forwarders/[id]/ForwarderPanels.tsx` | 1 (rate quotes) | — |
| `logistics/forwarders/[id]/page.tsx` | 1 hand-built, no thead (freight documents) | amount 「受限」 via NULL from `freight_document_lookup` (:233-234, `data.view_prices`) |
| `output/[id]/assays/[assayId]/AssayTables.tsx` | 2 (metals · **apply preview**, rpc, unsaved) | — |
| `output/[id]/edit/OutputAssayRowsTable.tsx` | 1 (only screen of the batch) | — |
| `output/[id]/edit/TraceabilityTables.tsx` | 2 (lineage · recovery; a PDF also exists) | — |
| `quality/coa/[id]/CoaContentTables.tsx` | 2 (composition · limits, conditional) | — |
| `quality/disputes/[id]/MetalsTable.tsx` | 1 | — |
| `quality/samples/[id]/SampleTables.tsx` | 2 (custody events — **trail** · assays) | — |
| `safety/incidents/[id]/IncidentBatchesPanel.tsx` | 2 (linked batches · **suggested batches**, rpc, unsaved) | — |
| `safety/incidents/[id]/IncidentUpdatesPanel.tsx` | 1, **trail** (`INCIDENT_UPDATE_IMMUTABLE`) | — |
| `stocktakes/[id]/PostedLinesTable.tsx` | 1 | — |
| `stocktakes/[id]/review/ReviewDiffTable.tsx` | 1, **pre-posting review** (review page redirects unless `open`, :73) | — |
| `suppliers/[id]/edit/AttachmentsPanel.tsx` | 1 (file metadata; only screen) | — |
| `suppliers/[id]/edit/CompliancePanel.tsx` | 1 (only screen) | — |
| `contracts/[id]/TermSection.tsx` | 1 definition, **drawn 8 times** (one per term section, `termSpecs.ts`; page :258 says "seven") | ✗ none — USD/t rates are not masked at all (see Q3) |
| `materials/[id]/edit/AttachmentsPanel.tsx` | 1 (file metadata; only screen) | — |

**Total: 56 table definitions** (8 + 25 + 23). Totals rows inside a table: only `SettlementHistoryTable` (receivables, payables, expenses) — exported last under 3b Q1.
Trails (TABLE-EXPORT-3 Q6): SettlementHistoryTable, MovementTimelineTable, RunRecordPanels header corrections, SampleTables custody, IncidentUpdatesPanel (IncidentBatchesPanel links are near-trail).

## 2 · Decisions taken under existing rulings (not asked)

- **Hand-built tables** (ContainerPanels ×2, forwarders page) rebuilt as `DataTable` (3b precedent: PrepaymentPanel).
- **MaintenancePanel "— is —%"** → 「受限」 on screen and "Restricted" in the file (TABLE-EXPORT-2 Q8).
- **TermsRequestsPanel**: one pair per open request (3b precedent: GST filing requests); a request whose terms are hidden draws no table, so it has nothing to export.
- **Attachment panels** export the metadata (name, type, size, uploaded, notes) — 3b precedent `sales/customers/[id]/edit/AttachmentsPanel.tsx`.
- **ContainerPanels document checklist** exports the saved status (TABLE-EXPORT-3 Q8: an editable table that is the record's only screen).
- **Traceability tables** export despite the PDF (Q1: one pair per table).
- **RelatedTable** gets an export route that loops keyset pages of 100 (TABLE-EXPORT-1 Q8 cap 50,000).
- **Unchecked reads feeding these tables** (`allocsRes.data ?? []` on receivables :115 · payables :113 · expenses :165 · invoices :150 · payments :101; movements on inbound edit :619 · output edit :307; attachments on payments :194-200; supplier edit :96 · :110; materials edit :66) move to `mustRows` — the standing rule in AGENTS.md; otherwise a failed read exports an empty file.

## 3 · Assertions measured false or stale

1. `TABLE-EXPORT-3/step0.md` "shared components 9": now 8 (BatchAuditTrailTable deleted under Q10).
2. Same doc, SparePartsPanel :122 as a masked cell: unreachable — the column is filtered out whenever the value would be NULL (:225).
3. Same doc, CostPanel :177 as a masked cell: it is the total paragraph below the table, not a table cell.
4. Same doc, contracts "1 / 1": one definition, drawn 8 times per contract page.
5. Same doc, "no `.limit()` on the reads feeding them": true as worded, but every read is unpaged under PostgREST `max_rows = 1000` (go-live row 10, READ-ALL-STOPS-AT-1000). The stocktake pages look up all batches unpaged; past 1,000 a counted line would drop out of the review (inference, not measured on live).
6. `app/contracts/[id]/page.tsx:258` says "seven" term tables; `termSpecs.ts` has 8 sections.
7. Brief / my prompt: `TableExportBar` lives in `app/components/ui/table-export.tsx:68`, not `report-export.tsx`.
