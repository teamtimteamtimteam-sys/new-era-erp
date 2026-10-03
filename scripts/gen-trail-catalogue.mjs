#!/usr/bin/env node
// scripts/gen-trail-catalogue.mjs
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a(Tim 的 Q7 · Q11 · Q12)· 审计记录的【英文目录】—— 字段名、记录类型名、取值的英文说法
// ════════════════════════════════════════════════════════════════════════════
// 【它产出什么】lib/trail/catalogue.generated.ts —— 一个【不 import 任何东西】的文件
//   (理由同 lib/dates.ts 的决定 ①:scripts/check-trail-wording.mjs 用 Node 的 type-stripping 把它 import 进去跑):
//   · TRAIL_FIELDS[表][列] = [英文标签, 种类]   种类决定怎么把值说成人话(见 lib/trail/render.ts 的 formatValue)
//   · TRAIL_TABLES[表]     = [单数英文名, 区域]  汇总页的 Record type 与 Area
//   · TRAIL_ENUMS['表#列'][取值] = 英文说法
//
// 【标签从哪里来 —— Q11 的先后,一条不改】
//   ① 这一页自己用的那个标签(labels.csv 里 label_confidence = high / medium,是勘察在页面上【量到】挨着那一列的键);
//   ② 目录里别处的同义措辞(label_confidence = text-only)—— 只在它不是"一个状态词冒充一个时刻"的时候用;
//   ③ labels.csv 的提议(proposed_label_if_missing),或按列名推(与提议同一套规则)。
//   ④ 本刀三个主语的表,另有一份【人工核过的】覆盖(OVERRIDES)—— 勘察的自动匹配在那几张表上错过几处
//      (付款计划的 label 被配成了 "Category",供应商被配成了 "Supplier (optional)"),交回报告逐条列出。
//
// 【取值的英文从哪里来】scripts/check-i18n.mjs 的 MANIFEST 里登记过的"前缀 ↔ 表.列"(kind:'enum',真源是
//   db/tables 的 CHECK)—— 那正是页面用来显示这一列的键;键的英文从 messages/en.ts 现读。没登记的,用 ENUM_OVERRIDES;
//   再没有,界面按"把下划线换成空格、首字母大写"说(lib/trail/render.ts 的 humanize),并且【三个主语的表不许走到这一步】——
//   check-trail-wording 的完整性一臂会红。
//   ★ 数据里【机器写的中文】(inbound_batches.stage)的英文不在这里,在 messages/trail-machine-values.ts(Q8)——
//     这个生成物里不许有中文字面量(check-cjk-rendered 会把它当成上屏的硬串)。
// 【键用 '表#列'】不用 '表.列':check-i18n 会把 'contracts.kind' 这种长得像消息键的字面量当成一个键去对 en / zh。
//
// 用法:node scripts/gen-trail-catalogue.mjs            只比对:生成物与仓库里的不一致 → 退 1(在 npm run build 里)
//       node scripts/gen-trail-catalogue.mjs --write    重写 lib/trail/catalogue.generated.ts
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const OUT = join(ROOT, 'lib/trail/catalogue.generated.ts')
const LABELS = join(ROOT, 'docs/surveys/AUDIT-TRAIL-0/labels.csv')

// ── 读 labels.csv(带引号的逗号)─────────────────────────────────────────────
function parseCsv(text) {
    const rows = []
    let row = [], cell = '', q = false
    for (let i = 0; i < text.length; i++) {
        const c = text[i]
        if (q) {
            if (c === '"' && text[i + 1] === '"') { cell += '"'; i++ }
            else if (c === '"') q = false
            else cell += c
        } else if (c === '"') q = true
        else if (c === ',') { row.push(cell); cell = '' }
        else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = '' }
        else if (c !== '\r') cell += c
    }
    if (cell || row.length) { row.push(cell); rows.push(row) }
    const [head, ...body] = rows
    return body.filter((r) => r.length === head.length).map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])))
}

// ── 列名 → 英文(与 labels.csv 的提议同一套规则)──────────────────────────────
const WORD = { ccy: '', id: '', pct: '%', qty: 'quantity', fx: 'FX', gst: 'GST', po: 'PO', so: 'SO', uen: 'UEN',
    nric: 'NRIC', url: 'URL', iban: 'IBAN', swift: 'SWIFT', kpi: 'KPI', wht: 'WHT', cod: 'COD', usd: 'USD', sgd: 'SGD',
    ot: 'overtime', em: 'EM' }
export function deriveLabel(col) {
    let c = col
    let suffix = ''
    if (/_at$/.test(c)) { c = c.replace(/_at$/, ''); suffix = ' on' }
    else if (/_on$/.test(c)) { c = c.replace(/_on$/, ''); suffix = ' on' }
    else if (/_by$/.test(c)) { c = c.replace(/_by$/, ''); suffix = ' by' }
    c = c.replace(/_(id|code)$/, '').replace(/_base$/, '').replace(/_ccy$/, '')
    const words = c.split('_').filter(Boolean).map((w) => (w in WORD ? WORD[w] : w)).filter((w) => w !== '')
    let s = words.join(' ') + suffix
    s = s.replace(/\s+/g, ' ').trim()
    return s ? s[0].toUpperCase() + s.slice(1) : col
}
function clean(label) {
    if (!label) return ''
    let s = label.replace(/:\s*$/, '').replace(/\s*\(optional\)\s*$/i, '').replace(/\s*\(est\.\)\s*$/i, '').trim()
    if (/[{}]/.test(s) || s.length > 40 || s.length < 2) return ''
    if (/^\(.*\)$/.test(s)) return ''
    return s[0].toUpperCase() + s.slice(1)
}

// ── 本刀三个主语的表:人工核过的标签(页面上的说法优先;交回报告逐条列出)──────────
const OVERRIDES = {
    purchase_orders: {
        code: 'Purchase order number', supplier_id: 'Supplier', order_date: 'Order date', expected_delivery_date: 'Expected delivery',
        currency: 'Currency', fx_rate: 'FX rate', estimated_total_ccy: 'Estimated total', status: 'Status',
        approval_status: 'Approval status', approved_at: 'Approved on', approved_by: 'Approved by', incoterm: 'Incoterm',
        terms_text: 'Terms text', notes: 'Notes', closed_at: 'Closed on', cancelled_at: 'Cancelled on',
        cancel_reason: 'Cancellation reason', deleted_at: 'Deleted on', deleted_by: 'Deleted by', delete_reason: 'Reason for deletion',
        cancelled_by: 'Cancelled by', contract_id: 'Contract', tax_total_ccy: 'GST', delivery_location: 'Delivery location',
        category: 'Category', gross_total_ccy: 'Total including GST', carries_tax: 'Carries GST',
    },
    purchase_order_lines: {
        purchase_order_id: 'Purchase order', line_no: 'Line', material_id: 'Material', quantity: 'Quantity', unit: 'Unit',
        pricing_formula_id: 'Pricing formula', estimated_unit_price: 'Estimated unit price', estimated_amount_ccy: 'Estimated amount',
        expected_assay: 'Expected assay', notes: 'Notes', price_source: 'Price source', price_provenance: 'How the price was set',
        asset_id: 'Machine', deep_discharge_judgement_code: 'Deep discharge judgement', tax_code: 'Tax code',
        tax_rate_pct: 'Tax rate %', tax_amount_ccy: 'Tax amount', price_status: 'Price status',
    },
    purchase_order_payment_terms: {
        purchase_order_id: 'Purchase order', seq: 'Instalment', label: 'Description', percentage: 'Percentage',
        fixed_amount_ccy: 'Fixed amount', trigger_event: 'Due on', due_date: 'Due date', notes: 'Notes',
        expected_date: 'Expected date', expected_date_set_by: 'Expected date set by', expected_date_set_at: 'Expected date set on',
    },
    purchase_order_line_retentions: {
        purchase_order_line_id: 'Line', percentage: 'Retention %', fixed_amount_ccy: 'Retention amount',
        retention_months: 'Retention period (months)', anchor_event: 'Counted from', notes: 'Notes',
        released_at: 'Released on', released_by: 'Released by', released_amount_ccy: 'Amount released',
        withheld_amount_ccy: 'Amount withheld', withholding_reason: 'Reason for withholding',
    },
    pricing_term_commitments: {
        purchase_order_line_id: 'Line', inbound_batch_id: 'Batch', source_formula_id: 'Pricing formula',
        source_formula_code: 'Formula number', source_formula_name: 'Formula name', price_basis: 'Price basis',
        average_days: 'Averaging days', treatment_charge_usd_per_tonne: 'Treatment charge (USD/t)',
        flat_discount_pct: 'Flat discount %', committed_at: 'Committed on', committed_by: 'Committed by', price_index: 'Price index',
    },
    po_issues: { purchase_order_id: 'Purchase order', version: 'Version', issued_at: 'Issued on', issued_by: 'Issued by' },
    contract_document_terms: {
        purchase_order_id: 'Purchase order', sales_order_id: 'Sales order', contract_id: 'Contract', contract_code: 'Contract number',
        contract_title: 'Contract title', incoterm: 'Incoterm', currency: 'Currency', payment_terms_days: 'Payment terms (days)',
        grade_specs: 'Grade specifications', linked_at: 'Linked on', linked_by: 'Linked by', pricing_terms: 'Pricing terms',
        settlement_terms: 'Settlement terms',
    },
    approval_log: {
        subject_type: 'Document type', subject_code: 'Document number', decision: 'Decision', level: 'Level',
        actor_user_id: 'Decided by', decided_at: 'Decided on', note: 'Note', amount_ccy: 'Amount', currency: 'Currency',
        fx_rate: 'FX rate', amount_base: 'Amount (base currency)', is_reconstructed: 'Reconstructed',
        reconstruction_note: 'Reconstruction note', self_decided: 'Decided on own document',
    },
    purchase_order_history: {
        purchase_order_id: 'Purchase order', purchase_order_line_id: 'Line', line_no: 'Line', change_type: 'Change',
        old_order_date: 'Order date', new_order_date: 'Order date',
        old_expected_delivery_date: 'Expected delivery', new_expected_delivery_date: 'Expected delivery',
        old_fx_rate: 'FX rate', new_fx_rate: 'FX rate', old_estimated_total_ccy: 'Estimated total',
        new_estimated_total_ccy: 'Estimated total', old_incoterm: 'Incoterm', new_incoterm: 'Incoterm',
        old_terms_text: 'Terms text', new_terms_text: 'Terms text', old_notes: 'Notes', new_notes: 'Notes',
        old_quantity: 'Quantity', new_quantity: 'Quantity', old_unit: 'Unit', new_unit: 'Unit',
        old_estimated_unit_price: 'Estimated unit price', new_estimated_unit_price: 'Estimated unit price',
        old_estimated_amount_ccy: 'Estimated amount', new_estimated_amount_ccy: 'Estimated amount', amend_reason: 'Reason',
        changed_at: 'Changed on', changed_by: 'Changed by', old_delivery_location: 'Delivery location',
        new_delivery_location: 'Delivery location', old_price_status: 'Price status', new_price_status: 'Price status',
        payment_term_seq: 'Instalment', old_payment_term: 'Instalment', new_payment_term: 'Instalment',
    },
    processing_runs: {
        code: 'Processing run number', process_date: 'Process date', total_input: 'Total input', total_output: 'Total output',
        loss_qty: 'Loss', notes: 'Notes', status: 'Status', deleted_at: 'Rolled back on', allocation_basis: 'Allocation basis',
        material_cost_base: 'Material cost', process_cost_base: 'Process cost', total_cost_base: 'Total cost',
        allocation_snapshot: 'Allocation details', allocated_at: 'Costs allocated on', allocated_by: 'Costs allocated by',
        capitalized_cost_base: 'Capitalised cost', capitalization_entry_id: 'Capitalisation journal',
        allocation_basis_changed_at: 'Allocation basis changed on', work_order_id: 'Work order', deleted_by: 'Rolled back by',
        delete_reason: 'Reason', equipment_id: 'Equipment', operation_type_code: 'Operation',
    },
    processing_inputs: {
        run_id: 'Processing run', inbound_batch_id: 'Batch used', quantity_consumed: 'Quantity used', output_batch_id: 'Batch used',
    },
    processing_outputs: {
        run_id: 'Processing run', output_batch_id: 'Batch produced', quantity_produced: 'Quantity produced',
        allocated_cost_base: 'Allocated cost', unit_cost_base: 'Unit cost', cost_incomplete: 'Cost incomplete',
    },
    processing_cost_entries: {
        run_id: 'Processing run', cost_type: 'Cost type', amount_base: 'Amount', is_estimate: 'Estimate', notes: 'Notes',
        deleted_at: 'Removed on', remitted_at: 'Remitted on', remitted_journal_entry_id: 'Remittance journal',
        relieved_at: 'Relieved on', relief_expense_id: 'Relieving expense',
    },
    processing_cost_entry_history: {
        entry_id: 'Cost entry', run_id: 'Processing run', change_type: 'Change', old_amount_base: 'Amount',
        new_amount_base: 'Amount', old_cost_type: 'Cost type', new_cost_type: 'Cost type', old_is_estimate: 'Estimate',
        new_is_estimate: 'Estimate', changed_at: 'Changed on', changed_by: 'Changed by',
    },
    batch_processing_cost_allocations: {
        run_id: 'Processing run', inbound_batch_id: 'Batch', amount_base: 'Amount', basis_qty: 'Basis quantity',
        basis_total_qty: 'Basis total',
    },
    processing_run_losses: { run_id: 'Processing run', loss_category_code: 'Loss category', quantity: 'Quantity', notes: 'Notes' },
    roles: {
        code: 'Role code', name_en: 'Name (English)', name_zh: 'Name (Chinese)', description_en: 'Description (English)',
        description_zh: 'Description (Chinese)', is_system: 'System role', is_active: 'Active', deleted_at: 'Deleted on',
    },
    role_permissions: { role_id: 'Role', permission_code: 'Permission' },
    // ── AUDIT-TRAIL-1b-1:批次 · 工单 · 盘点 · 设备 · 交接班 · 仓库申请的表(每一列对着它所在的那一页核过;
    //    生成的那个说法错了或读不顺的才写在这里 —— 例如停机的 reason 被配成了 "On kilograms",维修的 description 是
    //    表单上的提示句 "Say what was done.",发票行的 unit 被配成了 "Unit price")────────────────────────────────
    assay_result_metals: { assay_result_id: 'Assay' },
    assay_results: { applied_at: 'Applied on', certificate_ref: 'Certificate reference', code: 'Assay number',
        lab_name: 'Laboratory', sample_ref: 'Sample reference', superseded_by: 'Replaced by' },
    certificates_of_destruction: { code: 'Certificate number', completed_on: 'Processing completed on',
        replaced_by_cod_id: 'Replaced by certificate', snapshot: 'Certificate details', void_reason: 'Reason voided' },
    cod_issues: { cod_id: 'Certificate' },
    equipment_downtime: { ended_at: 'Came back up', started_at: 'Went down', reason: 'Reason', duration: 'Duration' },
    equipment_maintenance: { description: 'What was done', expense_id: 'Expense', performed_by_employee_id: 'Done by (employee)',
        performed_by_name: 'Done by (name)', performed_by_supplier_id: 'Done by (supplier)', performed_on: 'Done on',
        capitalised_expense_id: 'Capitalised through expense' },
    equipment_service_intervals: { lead_days: 'Warn this many days before', lead_kg: 'Warn this many kilograms before' },
    finance_attachments: { claim_id: 'Claim', doc_type: 'Document type' },
    fixed_assets: { code: 'Asset number', cost_base: 'Cost (base currency)', cost_ccy: 'Cost', in_service_date: 'In service from',
        planned_in_service_date: 'Planned in service from', useful_life_months: 'Useful life (months)' },
    freight_allocations: { basis_qty: 'Allocation basis (quantity)', freight_document_id: 'Freight document', in_stock_ratio: 'Share still in stock' },
    inbound_batch_metals: { source_assay_id: 'From assay' },
    output_batch_metals: { source_assay_id: 'From assay' },
    inbound_batches: { arrival_date: 'Arrival date', delete_reason: 'Reason written off', deleted_at: 'Written off on',
        deleted_by: 'Written off by', purchase_order_id: 'Purchase order', supplier_id: 'Supplier', unit_price: 'Unit price',
        deep_discharge_actual_code: 'Deep discharge (actual)' },
    output_batches: { delete_reason: 'Reason written off', deleted_at: 'Written off on', deleted_by: 'Written off by',
        output_date: 'Output date', awaiting_operation_type_code: 'Awaiting operation' },
    inventory_movements: { qty_delta: 'Quantity change' },
    invoice_lines: { unit: 'Unit', line_no: 'Line', amount_base: 'Amount (base currency)', tax_base: 'Tax (base currency)', sales_record_id: 'Sale' },
    // AUDIT-TRAIL-1b-2(Tim 的裁定,折进 1b-2):code 此前生成成 "Journal entrie number",1b-1 的交回把它列成了对的
    journal_entries: { entry_date: 'Entry date', reversed_by: 'Reversed by', code: 'Journal number', source_type: 'Source' },
    payment_allocations: { allocated_base: 'Allocated (base currency)', allocated_ccy: 'Allocated (document currency)', allocated_pay: 'Allocated (payment currency)',
        withheld_base: 'Withheld (base currency)', withheld_pay: 'Withheld (payment currency)', freight_document_id: 'Freight document', sales_record_id: 'Sale' },
    prepayment_applications: { purchase_order_id: 'Purchase order', journal_entry_id: 'Journal', amount_base: 'Amount (base currency)' },
    receipt_price_requests: { assay_result_id: 'Assay', label: 'Request', unit_price_ccy: 'Unit price', result_journal_entry_id: 'Journal',
        snapshot: 'Request details' },
    // AUDIT-TRAIL-1b-2 加了 line_no / detail —— 写在这同一行里:一个对象字面量里同一张表写两次,后一次整个盖掉前一次
    //   (1b-2 第一版就是这么把这里的 amend_reason 弄丢的,生成物里一度读回 "Amend reason")
    sales_order_history: { amend_reason: 'Reason', line_no: 'Line', detail: 'Details' },
    sales_order_reservations: { release_reason: 'Release reason' },
    sales_records: { cogs_entry_id: 'Cost-of-sales journal', customer_id: 'Customer', price_provenance: 'How the price was set' },
    sales_settlements: { amount_usd: 'Amount (USD)', gross_weight_kg: 'Gross weight (kg)', settlement_weight_kg: 'Settlement weight (kg)' },
    shift_handover_items: { body: 'Details', item_type_code: 'Type' },
    shift_handovers: { incoming_employee_id: 'Incoming', outgoing_employee_id: 'Outgoing' },
    shipment_lines: { location_id: 'Location' },
    stocktakes: { cancelled_at: 'Cancelled on', posted_at: 'Posted on' },
    warehouse_requests: { cod_id: 'Certificate of destruction', run_id: 'Processing run', label: 'Request', executed_at: 'Carried out on',
        snapshot: 'Request details' },
    work_order_history: { amend_reason: 'Reason' },
    // ── AUDIT-TRAIL-1b-2:报价 · 订单 · 发货 · 客户 · 佣金 · 供应商 · 物流的表(每一列对着它所在的那一页核过 ——
    //    编辑它的那张表单的标签优先,详情页上的列头其次;生成的说法错了、读不顺、或是 Title Case 的才写在这里。
    //    Step 0 §f 点名的几个在这一段:联系人的名字被配成 "File"、集装箱的 code 与 container_number 都叫
    //    "Container number"、佣金的 valid_to 叫 "Valid"、对账单的 base_currency 叫 "By currency")────────────────
    quotes: { quote_date: 'Quotation date', decline_reason: 'Reason declined', delete_reason: 'Reason for deletion',
        converted_order_id: 'Converted to' },
    quote_lines: { line_no: 'Line', price_provenance: 'How the price was set' },
    quote_history: { detail: 'Details', change_type: 'Event' },
    sales_orders: { delete_reason: 'Reason for deletion' },
    sales_order_lines: { line_no: 'Line', price_provenance: 'How the price was set' },
    shipping_releases: { label: 'Release', amount_base: 'Invoiced amount', decision_notes: 'Decision notes' },
    shipping_release_lines: { release_id: 'Shipping release', invoice_line_id: 'Invoice line' },
    shipments: { ship_date: 'Shipped on' },
    customers: { legal_name: 'Legal name', short_name: 'Short name', country: 'Country', payment_terms: 'Payment terms',
        credit_rating: 'Credit rating', credit_hold: 'Credit hold' },
    counterparty_contacts: { name: 'Name', is_primary: 'Primary contact', name_inferred: 'Name taken from older records',
        deleted_at: 'Removed on' },
    customer_attachments: { doc_category: 'Category', file_name: 'File' },
    supplier_attachments: { doc_category: 'Category', file_name: 'File' },
    customer_credit_history: { new_credit_limit_base: 'Credit limit', old_credit_limit_base: 'Previous credit limit',
        new_credit_hold: 'Credit hold', old_credit_hold: 'Previous credit hold' },
    customer_statements: { base_currency: 'Base currency', by_currency: 'Amounts by currency', buckets: 'Ageing',
        closing_base: 'Closing balance', opening_base: 'Opening balance', charges_base: 'Charges', credits_base: 'Credits',
        receipts_base: 'Receipts', lines: 'Statement lines', superseded_reason: 'Reason superseded' },
    statement_issues: { statement_id: 'Statement' },
    collection_chases: { base_currency: 'Base currency', net_due_base: 'Net due', owed_buckets: 'Owed by age',
        reached: 'Reached the customer', summary: 'What was said', superseded_reason: 'Reason corrected',
        superseded_at: 'Corrected on', superseded_by: 'Corrected by' },
    collection_chase_documents: { subject_type: 'Document type' },
    collection_promises: { promised_amount_base: 'Promised amount (base currency)' },
    commission_agreements: { agent_supplier_id: 'Agent', recognition_trigger: 'Obligation arises', valid_to: 'Valid to',
        deleted_at: 'Deleted on', remarks: 'Clause / remarks' },
    suppliers: { legal_name: 'Legal name', short_name: 'Short name', country: 'Country', payment_terms: 'Payment terms',
        credit_rating: 'Credit rating', deleted_at: 'Deleted on' },
    supplier_compliance: { cert_no: 'Certificate number', cert_type_code: 'Certificate type', issuing_body: 'Issuing body',
        valid_from: 'Valid from', valid_until: 'Valid until', document_id: 'Certificate document' },
    supplier_status_history: { from_status: 'Previous status', to_status: 'New status' },
    containers: { code: 'Container code', expected_arrival_date: 'Expected arrival', delete_reason: 'Reason for deletion' },
    container_documents: { document_type: 'Document type' },
    forwarder_rate_quotes: { supplier_id: 'Forwarder' },
    forwarder_details: { supplier_id: 'Forwarder' },
    lanes: { deleted_at: 'Removed on' },
    lane_document_requirements: { deleted_at: 'Removed on' },
    ports: { code: 'Port code', name: 'Port name', deleted_at: 'Removed on' },
    company_compliance: { cert_no: 'Licence number', cert_type_code: 'Licence kind' },
    // ── AUDIT-TRAIL-1b-3:物料 · 库位 · 金属价格 · 公式与条款申请 · 任务 · 三个阈值面板的表(每一列对着它所在的那一页核过 ——
    //    编辑它的表单的标签优先,列表页的列头其次;交回报告逐条列出)。Step 0 §f 点名、住在这几张表上的四个在这一段:
    //    task_id 被配成了升级按钮上那句 "Make this a team task"、metal_prices.source 被配成了下拉框的占位 "Choose a source"、
    //    阈值的两列读成 "Wo input overrun %"、pricing_settings.notes_en 读成 "Notes en"(同形状的 notes_zh、
    //    wo_output_shortfall_pct 一起改)───────────────────────────────────────────────────────────────
    materials: { code: 'Code', may_be_processed: 'May be fed to a processing run', safety_stock_qty: 'Safety stock threshold' },
    material_attachments: { doc_category: 'Category', file_name: 'File' },
    material_required_metals: { metal: 'Assay required for' },
    storage_locations: { is_active: 'Active' },
    storage_location_allowed_classes: { classification_code: 'Allowed material class' },
    metal_prices: { source: 'Source', price_date: 'Price date', price_usd_per_tonne: 'Price (USD/t)', source_reference: 'Evidence reference', quote_delayed: 'Delayed figure' },
    pricing_formulas: { code: 'Code', average_days: 'Averaging days', is_active: 'In use' },
    pricing_formula_history: {
        old_name: 'Previous formula name', new_name: 'New formula name', old_average_days: 'Previous averaging days',
        new_average_days: 'New averaging days', old_treatment_charge_usd_per_tonne: 'Previous treatment charge (USD/t)',
        new_treatment_charge_usd_per_tonne: 'New treatment charge (USD/t)', old_is_active: 'Was in use', new_is_active: 'Now in use',
    },
    terms_requests: { kind: 'Request type', label: 'Request', proposed: 'Proposed terms', snapshot: 'Terms before',
        withdraw_reason: 'Withdrawal reason', executed_at: 'Applied on' },
    tasks: { code: 'Task number' },
    task_nodes: { task_id: 'Task', title: 'Step title', parent_id: 'Parent step', done_at: 'Ticked on', done_by: 'Ticked by' },
    task_participants: { task_id: 'Task', employee_id: 'Participant', removed_at: 'Taken off on', removed_by: 'Taken off by' },
    task_history: {
        task_id: 'Task', employee_id: 'Participant', old_reminder_at: 'Previous reminder', new_reminder_at: 'New reminder',
        old_node_title: 'Previous step title', new_node_title: 'New step title', old_node_target_date: 'Previous step target date',
        new_node_target_date: 'New step target date', old_node_done: 'Step was ticked', new_node_done: 'Step now ticked',
        old_sort_order: 'Previous position', new_sort_order: 'New position',
    },
    processing_settings: { wo_input_overrun_pct: 'Input overrun (%)', wo_output_shortfall_pct: 'Output shortfall (%)' },
    pricing_settings: { metal_price_change_warn_pct: 'Warn above (%)', notes_en: 'Notes (EN)', notes_zh: 'Notes (ZH)',
        default_metal_index: 'Default price index', metal_quote_stale_days: 'Quote goes stale after (days)' },
    receiving_settings: { grn_short_pct: 'Short delivery (%)', grn_over_pct: 'Over-delivery (%)', grn_assay_tolerance_pct: 'Assay tolerance (%)' },
    // ── AUDIT-TRAIL-1c-1:账上的单据(七个主语显示的每一张表、每一列,对着它所在的那一页核过 —— 表单的标签优先,
    //    详情页的字段名其次;交回报告逐条列出)。生成器配错的那几类(AT-1c Step 0 §g):状态 "All"、种类 "Reason type"、
    //    付款申请的 payment_id 读成 "Planned payment date"、转账的 to_account 读成 "Accounts"、"Number receipt reason"、
    //    三处 tax_code 读成 "Tax ID"、"Wht remittance number"、同一张表里两列都叫 "Amount"(本位币那一列补上"(base currency)")、
    //    时刻读成一个状态词("Decided" → Decided on)──────────────────────────────────────────────────────
    journal_lines: { amount_ccy: 'Amount (original currency)', entry_id: 'Journal', tax_code: 'Tax code', line_memo: 'Line memo' },
    journal_requests: { entry_date: 'Entry date', kind: 'Request type', label: 'Request', lines: 'Journal lines', credits_bank: 'Pays out of a bank account',
        result_journal_entry_id: 'Posted as', target_entry_id: 'Journal to reverse', withdraw_reason: 'Withdrawal reason' },
    invoices: { status: 'Status', kind: 'Invoice type', bill_to_snapshot: 'Bill-to details', entry_id: 'Journal', terms_text: 'Terms',
        subtotal_base: 'Subtotal (base currency)', tax_base: 'Tax (base currency)', total_base: 'Total (base currency)' },
    invoice_issues: { invoice_id: 'Invoice' },
    invoice_requests: { kind: 'Request type', label: 'Request', doc_date: 'Document date', amount_base: 'Amount (base currency)',
        result_credit_note_id: 'Credit note issued', result_journal_entry_id: 'Posted as', withdraw_reason: 'Withdrawal reason' },
    credit_notes: { entry_id: 'Journal' },
    credit_note_lines: { kind: 'Credit type', tax_base: 'Tax (base currency)', tax_code: 'Tax code' },
    payments: { amount_base: 'Amount (base currency)', journal_entry_id: 'Journal', reversed_by_payment: 'Reversed by' },
    payment_requests: { allocations: 'Documents to settle', amount_base: 'Amount (base currency)', amount_in: 'Amount in (destination currency)',
        bank_account_code: 'Bank account', to_account_code: 'To account', decided_at: 'Decided on', withdrawn_at: 'Withdrawn on',
        payment_id: 'Payment to reverse', transfer_id: 'Transfer to reverse', wht_remittance_id: 'Remittance to reverse',
        result_payment_id: 'Payment made', result_transfer_id: 'Transfer made', result_journal_entry_id: 'Posted as',
        period_month: 'Withholding month', filed_reference: 'IRAS filing reference', planned_date: 'Planned payment date' },
    bank_transfers: { amount_out: 'Amount out (source currency)', amount_in: 'Amount in (destination currency)', to_account: 'To account',
        journal_entry_id: 'Journal', reversal_entry_id: 'Reversal journal' },
    wht_remittances: { code: 'WHT remittance number', period_month: 'Withholding month', filed_reference: 'IRAS filing reference',
        journal_entry_id: 'Journal' },
    expenses: { amount_base: 'Amount (base currency)', tax_base: 'Tax (base currency)', tax_code: 'Tax code', journal_entry_id: 'Journal',
        reversed_by_expense: 'Reversed by', wht_payee_residence: 'WHT payee residence' },
    expense_claims: { no_receipt_reason: 'Why there is no receipt', tax_code: 'Tax code' },
    fixed_asset_cost_entries: { amount_base: 'Amount (base currency)', expense_id: 'From expense' },
}
// AUDIT-TRAIL-1b-2:勘察把几列自由文本认成了"像枚举"(enum_like)—— 页面上它们是一个随手填的输入框,
//   审计记录就照原样说(一个人敲的字,Q8),而不是去找一张并不存在的取值表。
const KIND_OVERRIDES = {
    counterparty_contacts: { role: 'text' },
    container_documents: { document_type: 'text' },
    lane_document_requirements: { document_type: 'text' },
    // AUDIT-TRAIL-1b-3:任务修改史里的优先级被认成了一段文字 —— 它与 tasks.priority 是同一组取值(High / Medium / Low)
    task_history: { old_priority: 'enum_like', new_priority: 'enum_like' },
    // AUDIT-TRAIL-1c-1:付款申请的两个户被认成了"内部代码"(藏起来)—— 它们是哪个户付、付到哪个户,页面上印着;
    //   与收付款、费用、转账上的同一列一样,说成户名(下面 ENUM_OVERRIDES)
    payment_requests: { bank_account_code: 'enum', to_account_code: 'enum' },
}
// 三个主语的表里【本来就不该印的列】(Q12:单据编号自己在标题里,内部代码不上屏)
const HIDE = {
    roles: ['code', 'sort_order'],
    approval_log: ['subject_type', 'subject_code', 'is_reconstructed', 'seq'],
    purchase_order_history: ['purchase_order_id', 'purchase_order_line_id', 'change_type', 'changed_at', 'changed_by'],
    processing_cost_entry_history: ['entry_id', 'run_id', 'change_type', 'changed_at', 'changed_by'],
    contract_document_terms: ['contract_code'],
    purchase_orders: ['code'],
    processing_runs: ['code'],
    // AUDIT-TRAIL-1b-1:单号在标题里已经说了;历史表的主键、类型、时刻、人由标题与"谁 · 何时"两栏说;散列不是人话
    inbound_batches: ['code'], output_batches: ['code'], work_orders: ['code'], stocktakes: ['code'],
    work_order_history: ['work_order_id', 'change_type', 'changed_at', 'changed_by'],
    sales_order_history: ['sales_order_id', 'change_type', 'changed_at', 'changed_by'],
    cod_issues: ['sha256'], traceability_report_issues: ['sha256'], finance_attachments: ['mime_type'],
    // AUDIT-TRAIL-1b-2:报价与订单的单号在页头(它们的事件不拿单号做标题);签发档的散列不是人话;
    //   附件的 MIME 类型(application/pdf)是机器字,文件名已经说了它是什么。
    //   ★ 发货单、对账单、催收的单号【不】藏:它们的事件标题里要说出是哪一张("Goods shipped · SHP-…"),
    //     藏起来的列样本里是一个 id,机器字检查当场抓到过(本刀第一版)。
    quotes: ['code'], sales_orders: ['code'],
    qt_issues: ['sha256'], so_issues: ['sha256'], shipment_issues: ['sha256'], statement_issues: ['sha256'],
    customer_attachments: ['file_type'], supplier_attachments: ['file_type'],
    quote_history: ['quote_id', 'change_type', 'changed_at', 'changed_by'],
    customer_credit_history: ['customer_id', 'changed_at', 'changed_by'],
    supplier_status_history: ['supplier_id', 'changed_at', 'changed_by'],
    // AUDIT-TRAIL-1b-3:公式与任务的编号在页头;两张修改史的主键、类型、时刻、人由标题与"谁 · 何时"两栏说;
    //   金属价格那一格"异常判词"是系统在录入那一刻算的一段 JSON(列表上画成徽章),不是一个人的改动;
    //   条款申请的指纹是散列;步骤的 parent_depth 是一个生成列(与 depth / sort_order 同类)
    pricing_formulas: ['code'], tasks: ['code'],
    pricing_formula_history: ['formula_id', 'change_type', 'changed_at', 'changed_by'],
    task_history: ['task_id', 'change_type', 'changed_at', 'changed_by', 'node_id'],
    metal_prices: ['anomaly_check'], terms_requests: ['fingerprint'], task_nodes: ['parent_depth'],
    // AUDIT-TRAIL-1c-1:两张签发档的散列不是人话(与 1b-2 的另外四张同一条)
    invoice_issues: ['sha256'], cn_issues: ['sha256'],
}

// ── 记录类型的英文名(单数)与区域 ─────────────────────────────────────────────
const TABLE_NAMES = {
    purchase_orders: 'purchase order', purchase_order_lines: 'purchase order line',
    purchase_order_payment_terms: 'payment instalment', purchase_order_line_retentions: 'retention',
    pricing_term_commitments: 'committed pricing terms', po_issues: 'purchase order issue',
    contract_document_terms: 'contract link', approval_log: 'approval decision', purchase_order_history: 'purchase order change',
    processing_runs: 'processing record', processing_inputs: 'processing input', processing_outputs: 'processing output',
    processing_cost_entries: 'processing cost', processing_cost_entry_history: 'processing cost change',
    batch_processing_cost_allocations: 'processing cost allocation', processing_run_losses: 'processing loss',
    roles: 'role', role_permissions: 'role permission', user_roles: 'role assignment', permissions: 'permission',
    employees: 'employee', 'auth.users': 'login account', inbound_batches: 'inbound batch', output_batches: 'output batch',
    finance_settings: 'finance setting', cod_verification_failures: 'certificate check attempt',
    performance_reviews: 'performance review', contracts: 'contract', employment_history: 'employment change',
    employee_accounts: 'additional login', inventory_movements: 'stock movement', journal_entries: 'journal entry',
    journal_lines: 'journal line', sales_orders: 'sales order', sales_order_lines: 'sales order line', quotes: 'quote',
    fx_rates: 'exchange rate', public_holidays: 'public holiday', leave_requests: 'leave request', tasks: 'task',
    task_nodes: 'task step', task_participants: 'task participant', task_history: 'task change', work_orders: 'work order',
    stocktakes: 'stocktake', stocktake_lines: 'stocktake line', suppliers: 'supplier', customers: 'customer',
    materials: 'material', invoices: 'invoice', payments: 'payment', expenses: 'expense', fixed_assets: 'fixed asset',
    qt_issues: 'quote issue', so_issues: 'sales order issue', price_history: 'batch price change',
    // AUDIT-TRAIL-1b-1
    certificates_of_destruction: 'certificate of destruction', cod_issues: 'certificate PDF issue',
    traceability_report_issues: 'traceability report', warehouse_requests: 'warehouse request',
    equipment_maintenance: 'service or repair', equipment_downtime: 'downtime', equipment_service_intervals: 'service interval',
    shift_handovers: 'shift handover', shift_handover_items: 'handover item', shift_handover_equipment_refs: 'handover downtime note',
    stocktake_counts: 'stocktake count', work_order_history: 'work order change', sales_order_history: 'sales order change',
    sales_attribution_log: 'sale attribution', sales_record_movements: 'sale stock movement',
    // AUDIT-TRAIL-1b-2
    quote_history: 'quote event', quote_lines: 'quote line', qt_issues: 'quote PDF issue', so_issues: 'sales order PDF issue',
    shipments: 'shipment', shipment_lines: 'shipment line', shipment_issues: 'delivery note issue',
    shipping_releases: 'shipping release', shipping_release_lines: 'shipping release line',
    counterparty_contacts: 'contact', customer_attachments: 'customer attachment', customer_credit_history: 'credit change',
    customer_statements: 'statement of account', statement_issues: 'statement PDF issue', collection_chases: 'payment chase',
    collection_chase_documents: 'chased document', collection_promises: 'payment promise', commission_agreements: 'commission agreement',
    supplier_compliance: 'compliance certificate', supplier_attachments: 'supplier attachment', supplier_status_history: 'supplier status change',
    containers: 'container', container_milestones: 'container milestone', container_documents: 'container document',
    forwarder_details: 'forwarder logistics details', forwarder_rate_quotes: 'rate quote', lanes: 'lane',
    lane_document_requirements: 'required lane document', ports: 'port', company_compliance: 'company licence',
    // AUDIT-TRAIL-1b-3
    material_attachments: 'material attachment', material_required_metals: 'assay requirement',
    storage_locations: 'storage location', storage_location_allowed_classes: 'allowed material class', metal_prices: 'metal price',
    pricing_formulas: 'pricing formula', pricing_formula_metals: 'payable metal', pricing_formula_history: 'pricing formula change',
    terms_requests: 'terms request', processing_settings: 'variance threshold setting', pricing_settings: 'price anomaly setting',
    receiving_settings: 'discrepancy threshold setting',
    // AUDIT-TRAIL-1c-1
    journal_requests: 'journal request', invoice_requests: 'invoice request', invoice_issues: 'invoice PDF issue',
    invoice_lines: 'invoice line', credit_notes: 'credit note', credit_note_lines: 'credit note line', cn_issues: 'credit note PDF issue',
    payment_requests: 'payment request', payment_allocations: 'payment allocation', bank_transfers: 'bank transfer',
    wht_remittances: 'WHT remittance', expense_claims: 'expense claim', fixed_asset_cost_entries: 'asset cost entry',
    prepayment_applications: 'prepayment release', freight_allocations: 'freight allocation', finance_attachments: 'finance attachment',
}
// 区域:按表名开头认(先长后短),认不出的归 Other。区域名与导航模块的英文说法一致。
const AREA_RULES = [
    [/^(company_profile|list_ledger)/, 'Finance'],
    [/^(counterparty_contact|qt_issue|so_issue|statement_issue)/, 'Sales'],
    [/^(document_relation|document_type|import_batch)/, 'Settings'],
    [/^(handover|shift|maintenance_setting)/, 'Processing'],
    [/^hr_setting/, 'HR'],
    [/^index_market/, 'Pricing'],
    [/^(laborator|price_history)/, 'Receiving'],
    [/^(waste_classification)/, 'Materials'],
    [/^(certificate_type)/, 'Output'],
    [/^(purchase_order|po_issues|pricing_term_commitments|company_compliance)/, 'Purchasing'],
    [/^(processing|batch_processing|work_order|equipment|shift_handover|operation)/, 'Processing'],
    [/^(inbound|receipt|assay|receiving)/, 'Receiving'],
    [/^(output|certificates_of_destruction|traceability|cod_)/, 'Output'],
    [/^(inventory|storage_location|warehouse_request|stock)/, 'Inventory'],
    [/^stocktake/, 'Stocktakes'],
    [/^(sales|quote|shipment|shipping|customer|collection|commission|credit_note|cn_)/, 'Sales'],
    [/^(supplier|forwarder)/, 'Suppliers'],
    [/^(material|substance|battery|loss_|deep_discharge|output_batch_purpose)/, 'Materials'],
    [/^(pricing|metal_price|formula|terms_request)/, 'Pricing'],
    [/^contract/, 'Contracts'],
    [/^(container|lane|port|logistics|freight)/, 'Logistics'],
    [/^(employee|employment|leave|attendance|payroll|salary|overtime|performance|review|kpi|medical|training|department|position|holiday|public_holiday)/, 'HR'],
    [/^(task)/, 'Tasks'],
    [/^(role|permission|user_role|approval_log|auth\.users|dictionar|notification|cod_verification)/, 'Settings'],
    [/^(journal|account|payment|invoice|expense|finance|fx_|bank|gst|tax|wht|period_close|year_close|fixed_asset|asset|cash|management_pack|prepayment|currenc|wht|payroll_payment|self_approval|revaluation|depreciation|expense_claim|claims?)/, 'Finance'],
]
function areaOf(table) {
    for (const [re, a] of AREA_RULES) if (re.test(table)) return a
    return 'Other'
}
function humanTable(t) {
    if (TABLE_NAMES[t]) return TABLE_NAMES[t]
    const words = t.split('_')
    let last = words.pop()
    if (/ies$/.test(last)) last = last.replace(/ies$/, 'y')
    else if (/(sses|xes|ches|shes)$/.test(last)) last = last.replace(/es$/, '')
    else if (/s$/.test(last) && !/(ss|us|is)$/.test(last)) last = last.replace(/s$/, '')
    return [...words, last].map((w) => (w in WORD && WORD[w] ? WORD[w] : w)).join(' ')
}

// ── 取值的英文 ───────────────────────────────────────────────────────────────
// 【没登记在 check-i18n 里、而这一刀三个主语要用的】—— 措辞写在这里,交回报告列出。
const ENUM_OVERRIDES = {
    'approval_log#decision': {
        submitted: 'Submitted for approval', approved: 'Approved', rejected: 'Rejected', auto_approved: 'Approved automatically',
        approval_voided: 'Approval withdrawn', recalled: 'Recalled', withdrawn: 'Withdrawn', countersigned: 'Countersigned',
        executed: 'Carried out', cancelled: 'Cancelled', returned: 'Returned for changes', posted: 'Posted',
        acknowledged: 'Acknowledged',
    },
    'pricing_term_commitments#price_basis': { spot: 'Spot price', average: 'Average price' },
    'purchase_order_history#change_type': {
        header_update: 'Order details changed', line_add: 'Line added', line_update: 'Line changed', line_remove: 'Line removed',
        payment_term_add: 'Instalment added', payment_term_update: 'Instalment changed', payment_term_remove: 'Instalment removed',
        cancelled: 'Cancelled',
    },
    'processing_cost_entry_history#change_type': {
        create: 'Cost recorded', update: 'Cost changed', delete: 'Cost removed', restore: 'Cost restored',
    },
    'processing_runs#allocation_basis': { weight: 'by weight', metal_value: 'by metal value' },
    'processing_runs#status': { committed: 'Completed', reversed: 'Rolled back' },
    'purchase_order_lines#price_source': { manual: 'Entered by hand', formula: 'From a pricing formula', quote: 'From a quote', contract: 'From the contract', computed: 'Calculated' },
    'purchase_order_lines#unit': { kg: 'kg', t: 't', unit: 'units', units: 'units', pcs: 'pieces', l: 'litres' },
    // ── AUDIT-TRAIL-1b-1 ──────────────────────────────────────────────────────────────────────────────
    'certificates_of_destruction#status': { pending: 'Pending', issued: 'Issued', void: 'Void' },
    'inbound_batch_metals#content_source': { assay: 'From an assay', manual: 'Entered by hand' },
    'output_batch_metals#content_source': { assay: 'From an assay', manual: 'Entered by hand' },
    'finance_attachments#doc_type': { invoice: 'Invoice', contract: 'Contract', receipt: 'Receipt', bank_slip: 'Bank slip',
        weighbridge: 'Weighbridge ticket', other: 'Other' },
    'equipment_service_intervals#kind': { service: 'Service', repair: 'Repair' },
    'equipment_service_intervals#disposition': { warn: 'Warn', ignore: 'Ignore' },
    'journal_entries#status': { posted: 'Posted', reversed: 'Reversed' },
    'price_history#rate_type': { tt_buy: 'TT buying rate', tt_sell: 'TT selling rate', mid: 'Mid rate' },
    'sales_records#price_source': { computed: 'Calculated', manual: 'Entered by hand' },
    'sales_settlements#settling_party_used': { ours: 'Our assay', counterparty: "Counterparty's assay", umpire: 'Umpire assay' },
    'sales_settlements#weight_basis_used': { as_received: 'As received', dry: 'Dry' },
    'stocktakes#status': { open: 'Open', posted: 'Posted', cancelled: 'Cancelled' },
    // ── AUDIT-TRAIL-1b-2 ──────────────────────────────────────────────────────────────────────────────
    'quotes#status': { draft: 'Draft', issued: 'Issued', declined: 'Declined', converted: 'Converted to an order' },
    'quote_history#change_type': { created: 'Created', issued: 'Issued', declined: 'Declined', converted: 'Converted to an order' },
    'sales_orders#status': { draft: 'Draft', confirmed: 'Confirmed', partially_shipped: 'Partially shipped', shipped: 'Shipped',
        closed: 'Closed', cancelled: 'Cancelled' },
    'quote_lines#price_source': { computed: 'Calculated', manual: 'Entered by hand' },
    'sales_order_lines#price_source': { computed: 'Calculated', manual: 'Entered by hand' },
    'shipping_releases#status': { submitted: 'Waiting for approval', approved: 'Approved', rejected: 'Rejected', withdrawn: 'Withdrawn' },
    'customers#status': { draft: 'Draft', active: 'Active', inactive: 'Inactive' },
    'customers#customer_types': { cathode_maker: 'Cathode material maker', battery_factory: 'Battery factory', trader: 'Trader', other: 'Other' },
    'suppliers#supplier_types': { dismantler: 'Dismantler', battery_factory_scrap: 'Battery plant scrap', recycler: 'Recycler',
        trader: 'Trader', equipment_vendor: 'Equipment vendor' },
    'suppliers#status': { draft: 'Draft', pending_review: 'Pending review', approved: 'Approved', rejected: 'Rejected', active: 'Active',
        suspended: 'Suspended', blacklisted: 'Blacklisted', archived: 'Archived' },
    'supplier_status_history#from_status': { draft: 'Draft', pending_review: 'Pending review', approved: 'Approved', rejected: 'Rejected',
        active: 'Active', suspended: 'Suspended', blacklisted: 'Blacklisted', archived: 'Archived' },
    'supplier_status_history#to_status': { draft: 'Draft', pending_review: 'Pending review', approved: 'Approved', rejected: 'Rejected',
        active: 'Active', suspended: 'Suspended', blacklisted: 'Blacklisted', archived: 'Archived' },
    'suppliers#counterparty_type': { goods_supplier: 'Goods supplier', forwarder: 'Forwarder / carrier', service_vendor: 'Service vendor' },
    'suppliers#tax_residence': { resident: 'Singapore tax resident', non_resident: 'Non-resident' },
    'customer_attachments#doc_category': { 'hazardous-waste-permit': 'Hazardous waste permit', 'import-license': 'Import licence',
        'export-license': 'Export licence', 'basel-document': 'Basel document', contract: 'Contract', other: 'Other' },
    'supplier_attachments#doc_category': { 'hazardous-waste-permit': 'Hazardous waste permit', 'import-license': 'Import licence',
        'export-license': 'Export licence', 'basel-document': 'Basel document', contract: 'Contract', other: 'Other' },
    'container_documents#status': { pending: 'Pending', received: 'Received', not_applicable: 'Not applicable' },
    // ── AUDIT-TRAIL-1b-3 ──────────────────────────────────────────────────────────────────────────────
    //   物料的状态是一段自由文本(线上只有 draft);附件的分类照附件面板的说法(materials.attachments.cat.*);
    //   价格基准照公式列表的说法;条款申请的种类与状态:页面上那几句是卡片标题("…is waiting for the CFO")与小写的
    //   "waiting",放进一行"Status: waiting → approved"读不通 —— 这里给它们短而完整的说法
    'materials#status': { draft: 'Draft', active: 'Active', inactive: 'Inactive' },
    'material_attachments#doc_category': { 'spec-sheet': 'Spec sheet', msds: 'MSDS', coa: 'COA', datasheet: 'Datasheet', other: 'Other' },
    'pricing_formulas#price_basis': { spot: 'Spot', average: 'Average' },
    'pricing_formula_history#old_price_basis': { spot: 'Spot', average: 'Average' },
    'pricing_formula_history#new_price_basis': { spot: 'Spot', average: 'Average' },
    'pricing_formula_history#old_direction': { purchase: 'Purchase', sale: 'Sale', both: 'Both' },
    'pricing_formula_history#new_direction': { purchase: 'Purchase', sale: 'Sale', both: 'Both' },
    'pricing_formula_history#change_type': { create: 'Created', update: 'Edited', delete: 'Deleted', restore: 'Restored',
        metal_set: 'Payable % set', metal_clear: 'Payable % removed' },
    'terms_requests#kind': { formula_create: 'New pricing formula', formula_change: 'Change to a pricing formula',
        formula_reactivate: 'Pricing formula back in use', contract_activate: 'Contract activation' },
    'terms_requests#status': { submitted: 'Waiting for the CFO', approved: 'Approved', rejected: 'Rejected', withdrawn: 'Withdrawn' },
    'task_history#old_status': { todo: 'To Do', in_progress: 'In Progress', done: 'Done' },
    'task_history#new_status': { todo: 'To Do', in_progress: 'In Progress', done: 'Done' },
    'task_history#old_priority': { high: 'High', medium: 'Medium', low: 'Low' },
    'task_history#new_priority': { high: 'High', medium: 'Medium', low: 'Low' },
    // ── AUDIT-TRAIL-1c-1 ──────────────────────────────────────────────────────────────────────────────
    //   银行户:四处 CHECK 只认 1000 / 1010 —— 两个系统科目,说成科目的名字(db/tables/accounts.sql 的引导数据,
    //   一个专有名词,不是一个币种判断)
    'payments#bank_account_code': { '1000': 'Cash at Bank – SGD', '1010': 'Cash at Bank – USD' },
    'expenses#bank_account_code': { '1000': 'Cash at Bank – SGD', '1010': 'Cash at Bank – USD' },
    'bank_transfers#from_account': { '1000': 'Cash at Bank – SGD', '1010': 'Cash at Bank – USD' },
    'bank_transfers#to_account': { '1000': 'Cash at Bank – SGD', '1010': 'Cash at Bank – USD' },
    'payment_requests#bank_account_code': { '1000': 'Cash at Bank – SGD', '1010': 'Cash at Bank – USD' },
    'payment_requests#to_account_code': { '1000': 'Cash at Bank – SGD', '1010': 'Cash at Bank – USD' },
    // 数量单位:与采购明细同一组说法(这两列没有 CHECK,不填就按"下划线换空格"说成 "Kg")
    'inbound_batches#unit': { kg: 'kg', t: 't', unit: 'units', units: 'units', pcs: 'pieces', l: 'litres' },
    'invoice_lines#unit': { kg: 'kg', t: 't', unit: 'units', units: 'units', pcs: 'pieces', l: 'litres' },
    'payments#status': { posted: 'Posted', reversed: 'Reversed' },
    'payments#counterparty_type': { customer: 'Customer', supplier: 'Supplier', employee: 'Employee' },
    'payment_requests#counterparty_type': { customer: 'Customer', supplier: 'Supplier', employee: 'Employee' },
    'invoices#kind': { sale: 'From a sale', order: 'From a sales order' },
    'invoices#status': { issued: 'Issued', void: 'Void' },
    'journal_requests#kind': { entry: 'Manual journal', reversal: 'Reversal' },
    'journal_requests#status': { submitted: 'Waiting for approval', approved: 'Approved and posted', rejected: 'Rejected', withdrawn: 'Withdrawn' },
    'expenses#wht_payee_residence': { resident: 'Singapore tax resident', non_resident: 'Non-resident' },
    'expense_claims#status': { submitted: 'Waiting for approval', withdrawn: 'Withdrawn', approved: 'Approved', rejected: 'Rejected' },
    'work_order_history#change_type': { created: 'Created', released: 'Released', closed: 'Closed', cancelled: 'Cancelled',
        header_update: 'Details changed', line_add: 'Input line added', line_update: 'Input line changed', line_remove: 'Input line removed',
        expected_add: 'Expected output added', expected_update: 'Expected output changed', expected_remove: 'Expected output removed' },
}

function flatten(o, p = '', out = {}) {
    for (const [k, v] of Object.entries(o)) {
        if (typeof v === 'string') out[p + k] = v
        else if (v && typeof v === 'object') flatten(v, p + k + '.', out)
    }
    return out
}

function sqlCheckValues(table, col) {
    const f = join(ROOT, 'db/tables', table + '.sql')
    if (!existsSync(f)) return null
    const src = readFileSync(f, 'utf8').replace(/--[^\n]*/g, '')
    const re1 = new RegExp(`\\b${col}\\b[^,;]*?CHECK\\s*\\(\\s*\\(?"?${col}"?\\)?\\s*IN\\s*\\(([^)]*)\\)`, 's')
    const re2 = new RegExp(`CHECK\\s*\\(\\s*\\(?"?${col}"?\\)?\\s*IN\\s*\\(([^)]*)\\)`, 's')
    const re3 = new RegExp(`"?${col}"?\\s*=\\s*ANY\\s*\\(\\s*\\(?ARRAY\\[([^\\]]*)\\]`, 's')
    const m = src.match(re1) || src.match(re2) || src.match(re3)
    if (!m) return null
    return [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1])
}

async function main() {
    const write = process.argv.includes('--write')
    const rows = parseCsv(readFileSync(LABELS, 'utf8'))
    if (rows.length < 2900) {
        console.error(`✗ gen-trail-catalogue:labels.csv 只读出 ${rows.length} 行(应当 ≈ 2962)—— 一个瞎掉的读取不能产出一份"完整"的目录`)
        process.exit(3)
    }
    const en = flatten((await import(join(ROOT, 'messages/en.ts'))).default)
    const i18nSrc = readFileSync(join(ROOT, 'scripts/check-i18n.mjs'), 'utf8')
    const registry = {}
    // 两种写法都认:sqlCheckIn(...) 与 sqlEnum(...)(同一张 CHECK 的两个读法);一列可以有几个前缀,全收
    for (const m of i18nSrc.matchAll(/'([A-Za-z0-9_.]+)':\s*\{\s*kind:\s*'enum',\s*values:\s*\(\)\s*=>\s*sql(?:CheckIn|Enum)\(\s*'db\/tables\/([a-z0-9_]+)\.sql',\s*'([a-z0-9_]+)'\s*\)/g)) {
        ;(registry[`${m[2]}.${m[3]}`] ??= []).push(m[1])
    }
    if (Object.keys(registry).length < 40) {
        console.error(`✗ gen-trail-catalogue:从 check-i18n 的 MANIFEST 里只认出 ${Object.keys(registry).length} 个"前缀 ↔ 表.列"(应当 ≥ 40)—— 解析器瞎了`)
        process.exit(3)
    }

    const fields = {}
    const tables = {}
    const enums = {}
    for (const r of rows) {
        const t = r.table, c = r.column
        tables[t] ??= [humanTable(t), areaOf(t)]
        let kind = KIND_OVERRIDES[t]?.[c] ?? r.kind
        if ((HIDE[t] ?? []).includes(c)) kind = 'technical'
        let label = OVERRIDES[t]?.[c]
        if (!label) {
            const conf = r.label_confidence
            const txt = clean(r.label_text)
            const stampish = ['timestamp_audit', 'actor', 'date', 'money', 'number', 'boolean'].includes(r.kind)
            if ((conf === 'high' || conf === 'medium') && txt) label = txt
            else if (conf === 'text-only' && txt && !stampish && !/^(Deleted|Closed|Approved|Cancelled|Active)$/i.test(txt)) label = txt
            else label = clean(r.proposed_label_if_missing) || deriveLabel(c)
        }
        ;(fields[t] ??= {})[c] = [label, kind]
        if (kind === 'enum' || kind === 'enum_like') {
            const key = `${t}#${c}`
            const vals = sqlCheckValues(t, c)
            const prefixes = registry[`${t}.${c}`] ?? []
            const map = {}
            if (vals) for (const v of vals) for (const pre of prefixes) if (!map[v] && en[pre + v]) map[v] = en[pre + v]
            Object.assign(map, ENUM_OVERRIDES[key] ?? {})
            if (Object.keys(map).length) enums[key] = map
        }
    }
    for (const [key, map] of Object.entries(ENUM_OVERRIDES)) enums[key] = { ...(enums[key] ?? {}), ...map }
    tables['auth.users'] = [humanTable('auth.users'), 'Settings']

    const sortObj = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
    const body = [
        '// lib/trail/catalogue.generated.ts —— 由 scripts/gen-trail-catalogue.mjs 生成,不要手改(改生成器,再 --write)。',
        '// 真源:docs/surveys/AUDIT-TRAIL-0/labels.csv · scripts/check-i18n.mjs 的 enum 登记 · messages/en.ts · 生成器里的人工覆盖。',
        '// 【英文专用】审计记录只说英文(Tim 的 Q7),所以这里不走 t(),也不进 check-i18n 的"两边都要有"。',
        '// 本文件一个 import 都没有 —— scripts/check-trail-wording.mjs 用 Node 的 type-stripping 直接 import 它。',
        '',
        '/** [表][列] = [英文标签, 种类] */',
        `export const TRAIL_FIELDS: Record<string, Record<string, [string, string]>> = ${JSON.stringify(sortObj(Object.fromEntries(Object.entries(fields).map(([t, v]) => [t, sortObj(v)]))), null, 0)}`,
        '',
        '/** [表] = [单数英文名(句中用小写), 区域] */',
        `export const TRAIL_TABLES: Record<string, [string, string]> = ${JSON.stringify(sortObj(tables), null, 0)}`,
        '',
        "/** ['表#列'][取值] = 英文(机器写的中文取值不在这里,见 messages/trail-machine-values.ts) */",
        `export const TRAIL_ENUMS: Record<string, Record<string, string>> = ${JSON.stringify(sortObj(enums), null, 0)}`,
        '',
    ].join('\n')

    const current = existsSync(OUT) ? readFileSync(OUT, 'utf8') : ''
    if (write) {
        writeFileSync(OUT, body)
        console.log(`✓ gen-trail-catalogue:写出 ${OUT}(${Object.keys(fields).length} 张表 · ${rows.length} 列 · ${Object.keys(enums).length} 个取值表)`)
        return
    }
    if (current !== body) {
        console.error('✗ gen-trail-catalogue:lib/trail/catalogue.generated.ts 与生成器的产出不一致 —— 跑 node scripts/gen-trail-catalogue.mjs --write')
        process.exit(1)
    }
    console.log(`✓ gen-trail-catalogue:目录与真源一致(${Object.keys(fields).length} 张表 · ${rows.length} 列 · ${Object.keys(enums).length} 个取值表)`)
}

main().catch((e) => { console.error(e); process.exit(2) })
