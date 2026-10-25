// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(Tim 2026-10-22,Q15)· 还没有统一导出的表 —— 【点名的】豁免清单
// ════════════════════════════════════════════════════════════════════════════
// scripts/check-table-export.mjs 读它:app/ 下每一处 <DataTable / <EditableTable / <table,
// 要么带 exportSpec(只有 DataTable 能带),要么【整个文件的那一种】在这里点名,带去处与理由。
//   TABLE-EXPORT-2 —— 剩下的列表页:2a(2026-10-22)与 2b-1(2026-10-23)转完,这一类已清零,闸不再收它。
//   TABLE-EXPORT-3 —— 详情页里的表、手搓的财务报表、录入用的可编辑表:3a / 3b / 3c(2026-10-24 → 10-25)转完,这一类已清零,闸不再收它。
//   PERMANENT     —— 永远不导出,理由写在那一条上(Tim 2026-10-22 TABLE-EXPORT-2 Q6:brand-sampler;Tim 2026-10-23 TABLE-EXPORT-3 Q4 · Q8 · Q9 · Q10;
//                   Tim 2026-10-25 TABLE-EXPORT-3b Q3 · TABLE-EXPORT-3c Q2)。新加一条要 Tim 裁定。
// ★ TABLE-EXPORT-3c(Tim 2026-10-25,v1.4.73):这一族收尾 —— 本清单只剩 PERMANENT,闸只收 PERMANENT(scripts/check-table-export.mjs 判据 ⑥)。
// ★ 一个文件转完了却还留在这里,闸会红(STALE)—— 清单只许变短,不许留着过期的条目。
// ★ 本文件由 TABLE-EXPORT-1 一次生成(按路径分类:不在 [动态段]、不在 app/components/ 的 DataTable = 列表页),
//   之后只许手删,不许再整体重生成 —— 重生成会把一个刚漏了 exportSpec 的新表悄悄收进来。
// ════════════════════════════════════════════════════════════════════════════

/** @type {ReadonlyArray<{ file: string, kind: 'DataTable' | 'EditableTable' | 'table', cut: 'PERMANENT', why: string }>} */
export const TABLE_EXPORT_EXEMPTIONS = [
    { file: "app/brand-sampler/Base1.tsx", kind: 'DataTable', cut: 'PERMANENT', why: "temporary design reference with made-up data, not in navigation — never exported (Tim 2026-10-22 TABLE-EXPORT-2 Q6)" },
    { file: "app/finance/bank/import/ImportStatementForm.tsx", kind: 'DataTable', cut: 'PERMANENT', why: "preview of the bank file the user has just chosen, nothing saved yet, first 20 parsed rows only (ImportStatementForm.tsx:419) — an echo of the file they hold (Tim 2026-10-23 TABLE-EXPORT-3 Q4)" },
    { file: "app/finance/electricity/new/NewAllocationForm.tsx", kind: 'DataTable', cut: 'PERMANENT', why: "preview before posting; the posted allocation's lines are exported on its own page (app/finance/electricity/[id]/page.tsx) (Tim 2026-10-23 TABLE-EXPORT-3 Q4)" },
    { file: "app/finance/freight/new/NewFreightForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/finance/fx/bulk/BulkFxGrid.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/finance/invoices/[id]/CreateCreditNoteControl.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/finance/invoices/new/NewInvoiceForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/finance/packs/PackTables.tsx", kind: 'DataTable', cut: 'PERMANENT', why: "covered by the special exports (AP ageing, AR ageing, management pack) — management pack CSV, app/finance/packs/[id]/export/route.ts (Tim 2026-10-23 TABLE-EXPORT-3 Q9)" },
    { file: "app/finance/payables/page.tsx", kind: 'table', cut: 'PERMANENT', why: "covered by the special exports (AP ageing, AR ageing, management pack) — AP ageing CSV, app/finance/payables/export/route.ts (Tim 2026-10-23 TABLE-EXPORT-3 Q9)" },
    { file: "app/finance/payments/new/NewPaymentForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/finance/receivables/page.tsx", kind: 'table', cut: 'PERMANENT', why: "covered by the special exports (AP ageing, AR ageing, management pack) — AR ageing CSV, app/finance/receivables/export/route.ts (Tim 2026-10-23 TABLE-EXPORT-3 Q9)" },
    { file: "app/hr/payroll/PayrollGrid.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/hr/reviews/cycles/page.tsx", kind: 'table', cut: 'PERMANENT', why: "a layout inside a warning box, not a register (Tim 2026-10-23 TABLE-EXPORT-3 Q10)" },
    { file: "app/inbound/[id]/assays/new/AssayForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/operation/orders/new/NewWorkOrderForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/output/[id]/assays/new/OutputAssayForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/purchasing/orders/[id]/amend/AmendOrderForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/purchasing/orders/new/NewOrderForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/safety/incidents/[id]/IncidentBatchesPanel.tsx", kind: 'DataTable', cut: 'PERMANENT', why: "the suggested-batches table only (the linked-batches table in the same file exports): suggestions to act on, not a record; the linked batches export on the incident page (Tim 2026-10-25 TABLE-EXPORT-3c Q2d)" },
    { file: "app/sales/orders/[id]/amend/AmendOrderForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/sales/quotes/new/NewQuoteForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
    { file: "app/stocktakes/[id]/review/ReviewDiffTable.tsx", kind: 'DataTable', cut: 'PERMANENT', why: "preview before posting; the posted lines export on the stocktake page (app/stocktakes/[id]/PostedLinesTable.tsx) (Tim 2026-10-25 TABLE-EXPORT-3c Q2a)" },
    { file: "app/tools/pricing/calculator/CalculatorForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "calculator; nothing is saved (Tim 2026-10-25 TABLE-EXPORT-3b Q3)" },
    { file: "app/tools/pricing/metal-prices/bulk/BulkPricesForm.tsx", kind: 'EditableTable', cut: 'PERMANENT', why: "entry form; the saved record exports from its own page (Tim 2026-10-23 TABLE-EXPORT-3 Q8)" },
]
