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
        let kind = r.kind
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
