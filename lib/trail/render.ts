// lib/trail/render.ts
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a(Tim 的 Q2 · Q8 · Q9–Q13 · Q17 · Q27 · Q40)· 把读法返回的行造成【英文句子】
// ════════════════════════════════════════════════════════════════════════════
// 【分工,Q40】数据库把 id 解析成单据号、名字、"Restricted";这里只负责造句 —— 用哪一句、字段叫什么、
//   值怎么印(日期 DD/MM/YYYY、金额带币种、枚举说英文、布尔说 Yes / No、空值说 (empty))。
// 【两个读法,一个造句器】record_trail(每一页底部)与 change_log_rows(/settings/change-history)的行,
//   先各自变成 TrailRow,然后走同一个 buildEntries —— 两处读起来是同一种话(Q30)。
// 【一次操作一条】(Q2)同一笔事务的行归成一条记录;标题取这一条里【最有意义】的那件事(关键事件优先),
//   其余的改动排在下面,子行各带一个小标题("Line 1 · …"),理由永远排最后(Q27)。
// 【绝不印机器字】uuid、表名、列名、代码、JSON、"null"、数据库角色名一个都不许到屏幕上(Q41)。
//   这不是靠小心:认不出的列按列名推一个英文名,认不出的枚举值按"下划线换空格"说,认不出的引用说
//   "a <thing>",JSON 列只说 "Details changed" —— scripts/check-trail-wording.mjs 对每一张登记的表、每一列、
//   每一个取值造样本行跑一遍这里,再用机器字检出器扫输出。
// 【一个 import 都没有(只有 import type)】理由同 lib/dates.ts 的决定 ①:那支检查用 Node 的 type-stripping 把本文件
//   import 进去跑。所以目录、日期格式化这些都经 TrailDict 传进来(lib/trail/dict.ts 组装),不在这里 import。
// ════════════════════════════════════════════════════════════════════════════
import type { TrailText, TrailTextKey } from './text'

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json }
export type Img = { [k: string]: Json }
export type Actor = { state: string; name?: string | null } | null
export type Ref = { label?: string | null; gone?: boolean; unit?: string | null; person?: Actor; ended?: boolean; href?: string | null } | null
export type Refs = { [col: string]: { [value: string]: Ref } }
export type RecordRef = {
    table: string; id: string | null; label: string | null; gone: boolean
    doc_key?: string | null; route?: string | null; link_mode?: string | null; currency?: string | null
}

/** 两个读法的一行,归一之后的样子 */
export type TrailRow = {
    group: string            // 同一条记录的键:record_trail 的 entry_no,或 change_log_rows 的 txid
    order: number            // 记录之间的先后(小的在前 = 新的在前)
    prelog: boolean
    at: string               // 时刻(ISO)
    table: string | null
    key: Img | null
    op: string | null
    actor: Actor
    cols: string[] | null
    old: Img | null
    new: Img | null
    ctx: Img | null
    refs: Refs | null
    hidden: boolean          // 读者过不了这一行自己那张表的读规则(Q4)
    restricted: boolean      // 任务隐私:整份影像受限
    record?: RecordRef | null
    /** AUDIT-TRAIL-1c-1(Q16):这一行属于哪一次操作(record_trail 的 op_key)—— 清单页把几条记录合起来时按它并 */
    opKey?: string | null
}

/** href(AUDIT-TRAIL-1c-1,Q33):这个值是一张单据,点得过去 —— 路径由 trail_ref_label 从 document_types 给,这里不拼路由 */
export type Val = { text: string; restricted?: boolean; empty?: boolean; typed?: boolean; full?: string; href?: string }
export type Line =
    | { t: 'change'; label: string; old: Val; new: Val }
    | { t: 'value'; label: string; value: Val }
    | { t: 'heading'; text: string; part?: Val | null }
    | { t: 'note'; text: string }
export type Entry = {
    key: string
    at: string
    atText: string
    who: Val
    title: string
    /** AUDIT-TRAIL-1b-2:标题后面【一个人敲的】那一段(文件名、联系人名字、单据种类、证书编号)—— 画在 data-trail-typed 里,
     *  与字段值里人敲的字同一种待遇(Q8:照原样;冒烟的机器字断言不扫它 —— 一个截图文件名里带着日期不是机器字)。 */
    titlePart: Val | null
    titleRestricted: boolean
    lines: Line[]
    reason: Val | null
    prelog: boolean
    keyEvent: boolean
    record: RecordRef | null
}

export type TrailDict = {
    text: TrailText
    fields: Record<string, Record<string, [string, string]>>
    tables: Record<string, [string, string]>
    enums: Record<string, Record<string, string>>
    /** 机器写的中文取值 → 英文(messages/trail-machine-values.ts,Q8) */
    machine: Record<string, Record<string, string>>
    baseCurrency: string
    /** `YYYY-MM-DD` → `DD/MM/YYYY`(lib/dates.ts 的 formatDate) */
    formatDate: (v: string) => string
    /** 时刻 → `DD/MM/YYYY HH:MM`,新加坡时间(lib/dates.ts 的 formatTrailStamp) */
    formatStamp: (v: string) => string
}

export type BuildOptions = {
    /** 记录的币种(采购单明细、修改史的金额没有自己的币种列)*/
    currency?: string | null
    /** 记录的数量单位(加工单的损耗没有自己的单位列)*/
    unit?: string | null
    /** 这一页是哪一种记录(trail_subjects 的主语);汇总页不传。决定一张表的行从哪一边说、往上一跳够到的要不要点名单据 */
    subject?: string | null
    /** AUDIT-TRAIL-1c-1:这一页那条记录的 id —— 分录页要分得清"这一张分录"与"挂在它上面的另一张分录"(冲销) */
    recordId?: string | null
}

export const TRUNCATE_AT = 120

// ════════════════════════════════════════════════════════════════════════════
// 小工具
// ════════════════════════════════════════════════════════════════════════════
export function fill(tpl: string, vars: Record<string, string | number> = {}): string {
    return tpl.replace(/\{(\w+)\}/g, (_, k: string) => {
        if (k in vars) return String(vars[k])
        const lower = k[0].toLowerCase() + k.slice(1)
        if (lower in vars) {
            const v = String(vars[lower])
            return v ? v[0].toUpperCase() + v.slice(1) : v
        }
        return ''
    })
}
function tx(d: TrailDict, key: TrailTextKey, vars?: Record<string, string | number>): string {
    return fill(d.text[key], vars)
}
function plural(d: TrailDict, one: TrailTextKey, many: TrailTextKey, n: number): string {
    return tx(d, n === 1 ? one : many, { n })
}
export function isRestricted(v: unknown): boolean {
    return !!v && typeof v === 'object' && !Array.isArray(v) && (v as Record<string, unknown>)['$restricted'] === true
}
function isEmpty(v: unknown): boolean {
    return v === null || v === undefined || (typeof v === 'string' && v.trim() === '') || (Array.isArray(v) && v.length === 0)
}
/** 一个认不出的取值 —— 下划线换空格、首字母大写。三个主语的表不许走到这里(完整性检查一臂)。 */
export function humanize(v: string): string {
    const s = v.replace(/[_.]+/g, ' ').trim()
    return s ? s[0].toUpperCase() + s.slice(1) : s
}
function cap(s: string): string {
    return s ? s[0].toUpperCase() + s.slice(1) : s
}
function thing(d: TrailDict, table: string | null): string {
    return (table && d.tables[table]?.[0]) || 'record'
}
function truncate(text: string, typed = false): Val {
    const one = text.replace(/\s+/g, ' ').trim()
    if (one.length <= TRUNCATE_AT) return typed ? { text: one, typed: true } : { text: one }
    const cut = one.slice(0, TRUNCATE_AT).replace(/\s+\S*$/, '') + '…'
    return typed ? { text: cut, full: one, typed: true } : { text: cut, full: one }
}
const NUM2 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const NUM24 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 4 })
const NUM4 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 4 })
function num(v: Json): number | null {
    if (typeof v === 'number') return v
    if (typeof v === 'string' && v.trim() !== '' && !Number.isNaN(Number(v))) return Number(v)
    return null
}

// ════════════════════════════════════════════════════════════════════════════
// 字段与值
// ════════════════════════════════════════════════════════════════════════════
/** 历史表的 old_x / new_x 列,说的是另一张表的那一列(取值的英文、数量的单位都跟它走)*/
const HISTORY_BASE: Record<string, string> = {
    purchase_order_history: 'purchase_orders',
    processing_cost_entry_history: 'processing_cost_entries',
}
const LINE_COLS = new Set(['quantity', 'unit', 'estimated_unit_price', 'estimated_amount_ccy', 'price_status'])

export function fieldMeta(d: TrailDict, table: string, col: string): [string, string] {
    const m = d.fields[table]?.[col]
    if (m) return m
    // 目录里没有的列(将来新加的)—— 按列名推一个英文名,当作一段文字;绝不印列名本身
    return [humanize(col.replace(/_(id|code)$/, '')), 'text']
}
function hiddenKind(kind: string): boolean {
    return kind === 'technical' || kind === 'audit_std' || kind === 'own_key' || kind === 'text_code' || kind === 'uuid_nofk'
}
function enumLabel(d: TrailDict, table: string, col: string, raw: string): string {
    const machine = d.machine[`${table}#${col}`]?.[raw]
    if (machine) return machine
    const direct = d.enums[`${table}#${col}`]?.[raw]
    if (direct) return cap(direct)
    const base = HISTORY_BASE[table]
    const bare = col.replace(/^(old|new)_/, '')
    if (base) {
        const via = d.enums[`${base}#${bare}`]?.[raw] ??
            (LINE_COLS.has(bare) ? d.enums[`purchase_order_lines#${bare}`]?.[raw] : undefined)
        if (via) return cap(via)
    }
    return humanize(raw)
}

/** AUDIT-TRAIL-1c-1:几列【本位币】的价,列名里没有写 _base —— 进料批次的单价(应付之锚:reprice_inbound_batch 按牌价折成本位币
 *  再写进来)与改价史的新旧单价(同一个数)。price_history.currency 是【原币】(original_price 的币种),拿它去标新旧单价,
 *  一次用美元定的价就会被说成"2.50 USD"而它其实是新元 —— 1b 的批次审计记录一直这样说,本刀在同一处修 */
const BASE_PRICE_COLS: Record<string, Set<string>> = {
    inbound_batches: new Set(['unit_price']),
    price_history: new Set(['old_unit_price', 'new_unit_price']),
}
function currencyFor(col: string, img: Img, opts: BuildOptions, d: TrailDict, table?: string): string | null {
    if (/_base$/.test(col) || /^(old|new)_amount_base$/.test(col)) return d.baseCurrency
    if (table && BASE_PRICE_COLS[table]?.has(col)) return d.baseCurrency
    // 列名里写着币种的(…_usd_per_tonne)—— 它的标签已经说了 "(USD/t)",值本身不再挂币种(币种是数据,不写字面量)
    if (/_usd(_|$)/.test(col)) return null
    const c = img['currency']
    if (typeof c === 'string' && c) return c
    return opts.currency ?? null
}
/** 数量单位的说法:认得的(kg、t、units…)照英文目录说,短的小写字母照原样(它本来就是一个单位),其余按人话说 */
function unitText(d: TrailDict, raw: string): string {
    // AUDIT-TRAIL-1b-3:物料的单位存成中文(吨 / 克 / 件 —— 下拉框的取值),那是系统的话,说英文(Q8)
    const machine = d.machine['materials#unit']?.[raw]
    if (machine) return machine
    const known = d.enums['purchase_order_lines#unit']?.[raw]
    if (known) return known
    return /^[a-z]{1,6}$/i.test(raw) ? raw : humanize(raw).toLowerCase()
}
function unitFor(d: TrailDict, col: string, img: Img, refs: Refs | null, opts: BuildOptions): string | null {
    const own = img['unit'] ?? img[col.replace(/quantity|qty/, 'unit')]
    if (typeof own === 'string' && own) return unitText(d, own)
    // AUDIT-TRAIL-1b-2:订单 / 报价的明细行没有自己的单位列 —— 单位长在物料上,trail_ref_label 随物料名一起带回
    for (const c of ['inbound_batch_id', 'output_batch_id', 'material_id']) {
        const v = img[c]
        const u = typeof v === 'string' ? refs?.[c]?.[v]?.unit : null
        if (u) return unitText(d, u)
    }
    return opts.unit ? unitText(d, opts.unit) : null
}
function isQuantity(col: string): boolean {
    return /quantity|_qty$|^qty(_delta)?$|^total_(input|output)$|^basis_(total_)?qty$/.test(col)
}

function personVal(d: TrailDict, a: Actor): Val {
    if (!a) return { text: tx(d, 'who.unknown') }
    switch (a.state) {
        case 'person': return { text: a.name ?? tx(d, 'who.unknown') }
        case 'system': return { text: tx(d, 'who.system') }
        case 'removed': return { text: tx(d, 'who.removed') }
        case 'unlinked': return { text: tx(d, 'who.unlinked') }
        case 'anonymised': return { text: tx(d, 'who.anonymised') }
        // AUDIT-TRAIL-1b-1 折入 1:别的页面上这个读者看到"受限"的人名,这里也是 Restricted(trail_actor 判)
        case 'restricted': return { text: tx(d, 'restricted'), restricted: true }
        default: return { text: tx(d, 'who.unknown') }
    }
}

function refVal(d: TrailDict, table: string, col: string, raw: string, refs: Refs | null): Val {
    const r = refs?.[col]?.[raw]
    const label = fieldMeta(d, table, col)[0].toLowerCase()
    if (r?.person) return personVal(d, r.person)
    if (r && r.label) return { text: r.gone ? tx(d, 'value.sinceDeleted', { label: r.label }) : r.label }
    if (r && r.gone) return { text: tx(d, 'value.goneGeneric', { thing: label }) }
    return { text: tx(d, 'value.unnamed', { thing: label }) }
}

/** 一段 JSON 值 —— 只有认得的形状才说内容,其余只说"有变化"(Q12:绝不印 JSON) */
function jsonVal(d: TrailDict, table: string, col: string, raw: Json, op: string | null, opts: BuildOptions): Val {
    if (table === 'purchase_order_history' && /payment_term$/.test(col) && raw && typeof raw === 'object' && !Array.isArray(raw)) {
        const o = raw as Img
        const parts: string[] = []
        const pct = num(o['percentage'] ?? null)
        if (pct !== null) parts.push(`${NUM4.format(pct)}%`)
        const fixed = num(o['fixed_amount_ccy'] ?? null)
        if (fixed !== null && !isRestricted(o['fixed_amount_ccy'])) parts.push(`${NUM2.format(fixed)}${opts.currency ? ' ' + opts.currency : ''}`)
        if (isRestricted(o['fixed_amount_ccy'])) parts.push(tx(d, 'restricted'))
        if (typeof o['label'] === 'string' && o['label']) parts.push(o['label'])
        if (typeof o['trigger_event'] === 'string') parts.push(enumLabel(d, 'purchase_order_payment_terms', 'trigger_event', o['trigger_event']))
        if (parts.length) return truncate(parts.join(' · '))
    }
    return { text: tx(d, op === 'UPDATE' ? 'value.detailsChanged' : 'value.detailsRecorded') }
}

/** AUDIT-TRAIL-1c-1(Q13):付款申请的 allocations —— 每一项是一张要结清的单据 + 一个单据币种的金额。
 *  单据号由 trail_refs 解析在 refs.allocations 下;解析不出来说 "a document",绝不印 id。 */
const ALLOC_KEYS = ['expense_id', 'inbound_batch_id', 'purchase_order_id', 'freight_document_id']
export function allocationItems(d: TrailDict, raw: Json | undefined, refs: Refs | null): { label: string; value: Val }[] {
    if (!Array.isArray(raw)) return []
    const out: { label: string; value: Val }[] = []
    for (const it of raw) {
        if (!it || typeof it !== 'object' || Array.isArray(it)) continue
        const o = it as Img
        const k = ALLOC_KEYS.find((x) => typeof o[x] === 'string')
        const id = k ? o[k] as string : null
        const ref = id ? refs?.['allocations']?.[id] : null
        const label = ref?.label ? (ref.gone ? tx(d, 'value.sinceDeleted', { label: ref.label }) : ref.label) : tx(d, 'value.unnamed', { thing: 'document' })
        const n = num(o['amount_doc'] ?? null)
        out.push({ label, value: n === null ? { text: tx(d, 'empty'), empty: true } : { text: tx(d, 'pr.docCcy', { amount: NUM2.format(n) }) } })
    }
    return out
}

export function formatValue(d: TrailDict, table: string, col: string, raw: Json | undefined, img: Img,
                            refs: Refs | null, op: string | null, opts: BuildOptions): Val {
    if (isRestricted(raw)) return { text: tx(d, 'restricted'), restricted: true }
    if (isEmpty(raw)) return { text: tx(d, 'empty'), empty: true }
    const v = raw as Json
    const [, kind] = fieldMeta(d, table, col)
    switch (kind) {
        case 'fk_document': case 'fk_other': case 'fk_person': case 'dict': case 'actor':
            if (typeof v === 'string' || typeof v === 'number') {
                if (kind === 'dict' && !refs?.[col]?.[String(v)]) {
                    const e = d.enums[`${table}#${col}`]?.[String(v)]
                    if (e) return { text: cap(e) }
                }
                return refVal(d, table, col, String(v), refs)
            }
            break
        case 'currency':
            if (typeof v === 'string') return { text: refs?.[col]?.[v]?.label ?? v }
            break
        case 'enum': case 'enum_like':
            if (typeof v === 'string') return { text: enumLabel(d, table, col, v) }
            break
        case 'boolean':
            return { text: tx(d, v === true || v === 'true' ? 'value.yes' : 'value.no') }
        case 'date':
            if (typeof v === 'string') return { text: d.formatDate(v) }
            break
        case 'timestamp_audit': case 'time':
            if (typeof v === 'string') return { text: kind === 'time' ? v.slice(0, 5) : d.formatStamp(v) }
            break
        case 'money': {
            const n = num(v)
            if (n !== null) {
                const ccy = currencyFor(col, img, opts, d, table)
                const fine = /unit_cost|unit_price|per_(kg|unit|tonne)|_rate$/.test(col)
                const s = fine ? NUM24.format(n) : NUM2.format(n)
                return { text: ccy ? `${s} ${ccy}` : s }
            }
            break
        }
        case 'number': {
            const n = num(v)
            if (n !== null) {
                const u = isQuantity(col) ? unitFor(d, col, img, refs, opts) : null
                return { text: u ? `${NUM4.format(n)} ${u}` : NUM4.format(n) }
            }
            break
        }
        case 'jsonb':
            if (table === 'payment_requests' && col === 'allocations') {
                const items = allocationItems(d, v, refs)
                if (items.length) return truncate(items.map((i) => `${i.label} · ${i.value.text}`).join('; '))
            }
            return jsonVal(d, table, col, v, op, opts)
        case 'array':
            if (Array.isArray(v)) {
                // AUDIT-TRAIL-1b-2:一组代码(客户 / 供应商的类型)有英文说法时逐个说,不印代码;没有说法的是一组人敲的字,照原样
                const map = d.enums[`${table}#${col}`]
                const items = v.filter((x) => typeof x === 'string' || typeof x === 'number').map(String)
                if (map) return truncate(items.map((x) => map[x] ? cap(map[x]) : humanize(x)).join(', '))
                return truncate(items.join(', '), true)
            }
            break
    }
    if (typeof v === 'string') return truncate(v, true)
    if (typeof v === 'number') return { text: NUM4.format(v) }
    if (typeof v === 'boolean') return { text: tx(d, v ? 'value.yes' : 'value.no') }
    return { text: tx(d, op === 'UPDATE' ? 'value.detailsChanged' : 'value.detailsRecorded') }
}

/** 一次编辑的逐列行:只印看得见、该印的列(Q12);前后值都走 formatValue */
function changeLines(d: TrailDict, r: TrailRow, opts: BuildOptions, skip: Set<string> = new Set()): Line[] {
    const out: Line[] = []
    const img = imgOf(r)
    for (const c of r.cols ?? []) {
        if (skip.has(c)) continue
        const [label, kind] = fieldMeta(d, r.table!, c)
        if (hiddenKind(kind)) continue
        out.push({ t: 'change', label, old: formatValue(d, r.table!, c, r.old?.[c], img, r.refs, r.op, opts),
                   new: formatValue(d, r.table!, c, r.new?.[c], img, r.refs, r.op, opts) })
    }
    return out
}
/** AUDIT-TRAIL-1b-2:一整份影像(建单、新增)按【页面上的先后】列 —— 不按 jsonb 存下来的键序(那是按键长排的,
 *  于是 "Notes" 总在第一行)。只登记这一刀的主语;没登记的表照旧。备注类永远最后。 */
const FIELD_ORDER: Record<string, string[]> = {
    quotes: ['customer_id', 'quote_date', 'valid_until', 'currency', 'fx_rate', 'terms_text', 'notes'],
    sales_orders: ['customer_id', 'order_date', 'currency', 'fx_rate', 'terms_text', 'notes'],
    shipments: ['sales_order_id', 'ship_date', 'container_id', 'notes'],
    customers: ['legal_name', 'short_name', 'country', 'status', 'customer_types', 'tax_id', 'address', 'payment_terms',
        'payment_terms_days', 'incoterm', 'credit_limit_base', 'credit_hold', 'default_tax_code', 'credit_rating', 'notes'],
    suppliers: ['legal_name', 'short_name', 'counterparty_type', 'country', 'supplier_types', 'supplies_goods', 'tax_id', 'address',
        'payment_terms', 'incoterm', 'default_payment_term_template_id', 'default_tax_code', 'tax_residence', 'credit_rating', 'notes'],
    containers: ['container_number', 'lane_id', 'forwarder_id', 'departure_date', 'expected_arrival_date', 'vessel', 'voyage', 'bl_number', 'notes'],
    company_compliance: ['status', 'issuing_body', 'issue_date', 'valid_from', 'valid_until', 'approved_storage_limit_tonnes', 'scope', 'notes'],
    supplier_compliance: ['issuing_body', 'valid_from', 'valid_until', 'document_id', 'notes'],
    commission_agreements: ['agent_supplier_id', 'side', 'basis', 'rate_pct', 'amount_ccy', 'currency', 'recognition_trigger', 'valid_from', 'valid_to', 'remarks'],
    forwarder_rate_quotes: ['amount_ccy', 'currency', 'valid_from', 'valid_to', 'free_days', 'notes'],
    counterparty_contacts: ['role', 'email', 'phone', 'is_primary', 'notes'],
    customer_statements: ['period_start', 'period_end', 'opening_base', 'charges_base', 'credits_base', 'receipts_base', 'closing_base', 'base_currency'],
    collection_chases: ['chased_on', 'reached', 'contacted_person', 'owed_base', 'on_account_base', 'net_due_base', 'base_currency'],
    collection_promises: ['promised_amount_ccy', 'currency', 'promised_date'],
    // AUDIT-TRAIL-1b-3:编辑页上的先后
    materials: ['name', 'kind_code', 'form_code', 'source_code', 'size_format_code', 'chemistry', 'waste_classification_code', 'unit',
        'may_be_processed', 'safety_stock_qty', 'status', 'spec', 'notes'],
    storage_locations: ['name', 'zone', 'is_active', 'notes'],
    metal_prices: ['metal', 'price_date', 'price_usd_per_tonne', 'price_index', 'source', 'source_reference', 'quote_delayed', 'notes'],
    pricing_formulas: ['name', 'direction', 'supplier_id', 'customer_id', 'price_basis', 'average_days', 'price_index',
        'treatment_charge_usd_per_tonne', 'flat_discount_pct', 'is_active', 'notes'],
    tasks: ['title', 'task_type', 'status', 'priority', 'due_date', 'reminder_at', 'tags', 'owner_id', 'description'],
}
function ordered(table: string | null, image: Img): [string, Json][] {
    const entries = Object.entries(image)
    const order = table ? FIELD_ORDER[table] : undefined
    if (!order) return entries
    const rank = (c: string) => { const i = order.indexOf(c); return i >= 0 ? i : /^(notes|remarks|note)$/.test(c) ? 1000 : 500 }
    return entries.map((e, i) => [e, i] as const).sort((a, b) => rank(a[0][0]) - rank(b[0][0]) || a[1] - b[1]).map(([e]) => e)
}
/** 一行整份影像(新增 / 删除)的逐列行:只印有值、该印的列 */
function valueLines(d: TrailDict, r: TrailRow, image: Img | null, opts: BuildOptions, skip: Set<string> = new Set()): Line[] {
    const out: Line[] = []
    if (!image) return out
    const img = imgOf(r)
    for (const [c, v] of ordered(r.table, image)) {
        if (skip.has(c) || isEmpty(v)) continue
        const [label, kind] = fieldMeta(d, r.table!, c)
        if (hiddenKind(kind)) continue
        out.push({ t: 'value', label, value: formatValue(d, r.table!, c, v, img, r.refs, r.op, opts) })
    }
    return out
}
function imgOf(r: TrailRow): Img {
    const out: Img = {}
    for (const src of [r.ctx, r.old, r.new]) {
        if (!src) continue
        for (const [k, v] of Object.entries(src)) if (!isRestricted(v) && v !== null && v !== undefined) out[k] = v
    }
    return out
}
function str(r: TrailRow, col: string, side: 'new' | 'old' | 'any' = 'any'): string | null {
    const v = side === 'new' ? r.new?.[col] : side === 'old' ? r.old?.[col] : (r.new?.[col] ?? r.old?.[col] ?? r.ctx?.[col])
    return typeof v === 'string' ? v : typeof v === 'number' ? String(v) : null
}
function changed(r: TrailRow, col: string): boolean {
    return r.op === 'UPDATE' && (r.cols ?? []).includes(col)
}
function typed(v: Json | undefined): Val | null {
    return typeof v === 'string' && v.trim() ? truncate(v, true) : null
}

// ════════════════════════════════════════════════════════════════════════════
// 一条记录里的一块:一个标题 + 几行 + 可能的理由 + 是不是关键事件
// ════════════════════════════════════════════════════════════════════════════
type Block = { title: string; part?: Val | null; lines: Line[]; reason?: Val | null; key: boolean; weight: number }

// ── 采购单 ──────────────────────────────────────────────────────────────────
const PO_TABLES = new Set(['purchase_orders', 'purchase_order_lines', 'purchase_order_payment_terms', 'purchase_order_line_retentions',
    'pricing_term_commitments', 'po_issues', 'contract_document_terms', 'approval_log', 'purchase_order_history'])

function lineHeading(d: TrailDict, r: TrailRow): string {
    const img = imgOf(r)
    const n = num(img['line_no'] ?? null)
    const base = n !== null ? tx(d, 'po.lineHeading', { n }) : cap(thing(d, 'purchase_order_lines'))
    for (const c of ['material_id', 'asset_id']) {
        const v = img[c]
        if (typeof v === 'string') return `${base} · ${refVal(d, 'purchase_order_lines', c, v, r.refs).text}`
    }
    return base
}
function termHeading(d: TrailDict, r: TrailRow): string {
    const img = imgOf(r)
    const n = num(img['seq'] ?? null)
    const base = n !== null ? tx(d, 'po.termHeading', { n }) : cap(thing(d, 'purchase_order_payment_terms'))
    return typeof img['label'] === 'string' && img['label'] ? `${base} · ${img['label']}` : base
}

/** "Linked to contract CON-…" —— 合同的名字取它解析出来的单据号(refs),不取抄下来的那一列原值 */
function contractLinked(d: TrailDict, r: TrailRow): string {
    const id = str(r, 'contract_id')
    const ref = id ? r.refs?.['contract_id']?.[id] : null
    if (ref?.label) return tx(d, 'po.contractLinked', { code: ref.gone ? tx(d, 'value.sinceDeleted', { label: ref.label }) : ref.label })
    return tx(d, 'po.contractLinkedPlain')
}

function describePurchaseOrder(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block[] {
    const blocks: Block[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const po = by('purchase_orders')
    const lines = by('purchase_order_lines')
    const terms = by('purchase_order_payment_terms')
    const hist = by('purchase_order_history')
    const appr = by('approval_log')
    const created = po.find((r) => r.op === 'INSERT')

    // ① 建单(A01 / A02)—— 这一笔里的明细行、付款计划、修改史(建单的副产物)都算在它里面
    if (created) {
        const n = lines.filter((r) => r.op === 'INSERT').length
        // 建单时单头先以 0 插入,明细行的触发器在同一笔事务里再把总额写上 —— 取这一笔里【最后】写下的那个值
        let total: Json | undefined = created.new?.['estimated_total_ccy']
        for (const r of po) if (r !== created && (r.cols ?? []).includes('estimated_total_ccy')) total = r.new?.['estimated_total_ccy']
        const parts: string[] = []
        if (n > 0) parts.push(plural(d, 'po.lines.one', 'po.lines.many', n))
        if (total !== undefined && total !== null && !isRestricted(total) && num(total) !== null && num(total) !== 0) {
            parts.push(formatValue(d, 'purchase_orders', 'estimated_total_ccy', total, imgOf(created), created.refs, 'INSERT', opts).text)
        }
        const pending = appr.some((a) => str(a, 'decision', 'new') === 'submitted') || str(created, 'approval_status', 'new') === 'pending'
        const title = [tx(d, pending ? 'po.raisedPending' : 'po.raised'), ...parts].join(' · ')
        const ls: Line[] = []
        if (appr.some((a) => str(a, 'decision', 'new') === 'auto_approved')) ls.push({ t: 'note', text: tx(d, 'po.autoApproved') })
        for (const c of by('contract_document_terms')) ls.push({ t: 'note', text: contractLinked(d, c) })
        // 建单本身从不改自己的明细行(实测:建单那一笔里只有单头的总额 / 合同两次 UPDATE)—— 所以同一笔里明细行的
        // UPDATE 只能是一次真的修改(测试里建完就改的那种)。把它照常说出来,理由取修改史上写的那一句,不当作建单的副产物吞掉。
        for (const r of lines.filter((x) => x.op === 'UPDATE')) {
            const cl = changeLines(d, r, opts)
            if (cl.length) ls.push({ t: 'heading', text: `${tx(d, 'po.lineChanged')} · ${lineHeading(d, r)}` }, ...cl)
        }
        const reason = hist.map((h) => typed(h.new?.['amend_reason'])).find((v) => v) ?? null
        blocks.push({ title, lines: ls, reason, key: true, weight: 100 })
        return blocks
    }

    // ② 审批(A03–A05)—— approval_log 的一行就是那一次决定;理由是那个人写的话(机器写的说明换成英文,Q8)
    for (const a of appr) {
        const decision = str(a, 'decision', 'new') ?? ''
        const level = num(a.new?.['level'] ?? null)
        let title: string
        switch (decision) {
            case 'approved': title = level ? tx(d, 'po.approvedLevel', { level }) : tx(d, 'po.approved'); break
            case 'rejected': title = tx(d, 'po.rejected'); break
            case 'auto_approved': title = tx(d, 'po.autoApproved'); break
            case 'submitted': title = tx(d, 'po.submitted'); break
            case 'approval_voided': title = tx(d, 'po.approvalVoided'); break
            default: title = tx(d, 'po.approvalOther', { decision: enumLabel(d, 'approval_log', 'decision', decision) })
        }
        const reason = decision === 'auto_approved' ? null : typed(a.new?.['note'])
        const ls: Line[] = []
        const amt = a.new?.['amount_ccy']
        if (decision === 'approval_voided' || decision === 'approved') {
            if (amt !== undefined && amt !== null) ls.push({ t: 'value', label: fieldMeta(d, 'approval_log', 'amount_ccy')[0],
                value: formatValue(d, 'approval_log', 'amount_ccy', amt, imgOf(a), a.refs, a.op, opts) })
        }
        blocks.push({ title, lines: ls, reason, key: true, weight: 90 })
    }

    // ③ 单头:状态类的关键事件(A06–A09 · A22),其余是字段编辑
    for (const r of po) {
        const ls = changeLines(d, r, opts, new Set(['status', 'approval_status', 'cancel_reason', 'cancelled_at', 'cancelled_by',
            'closed_at', 'deleted_at', 'deleted_by', 'delete_reason', 'approved_at', 'approved_by']))
        const from = str(r, 'status', 'old'), to = str(r, 'status', 'new')
        let ev: string | null = null
        let reason: Val | null = null
        if (r.op === 'DELETE' || (changed(r, 'deleted_at') && r.new?.['deleted_at'])) {
            ev = tx(d, 'po.deleted'); reason = typed(r.new?.['delete_reason'])
        } else if (changed(r, 'status') || (r.prelog && r.cols?.includes('closed_at'))) {
            if (to === 'cancelled') { ev = tx(d, 'po.cancelled'); reason = typed(r.new?.['cancel_reason']) }
            else if (to === 'closed' || (r.prelog && r.new?.['closed_at'])) ev = tx(d, 'po.closed')
            else if (from === 'closed') ev = tx(d, 'po.reopened')
            else if (from === 'confirmed' && to === 'receiving') ev = tx(d, 'po.firstReceipt')
            else if (!appr.length) {
                ev = tx(d, 'po.statusChanged')
                ls.unshift({ t: 'change', label: fieldMeta(d, 'purchase_orders', 'status')[0],
                    old: formatValue(d, 'purchase_orders', 'status', r.old?.['status'], imgOf(r), r.refs, r.op, opts),
                    new: formatValue(d, 'purchase_orders', 'status', r.new?.['status'], imgOf(r), r.refs, r.op, opts) })
            }
        }
        if (ev) blocks.push({ title: ev, lines: ls, reason, key: true, weight: 80 })
        else if (ls.length) blocks.push({ title: tx(d, 'po.edited'), lines: ls, key: false, weight: 30 })
    }

    // ④ 修改史(A10–A17):与真的改动同一笔时只贡献理由与标题;单独出现时(记录开始之前)自己说出改了什么
    const realEdits = blocks.filter((b) => !b.key && b.lines.length).length + lines.length + terms.length
    for (const h of hist) {
        const ct = str(h, 'change_type', 'new') ?? ''
        const reason = typed(h.new?.['amend_reason'])
        if (ct === 'cancelled') {
            if (!blocks.some((b) => b.title === tx(d, 'po.cancelled'))) blocks.push({ title: tx(d, 'po.cancelled'), lines: [], reason, key: true, weight: 80 })
            else blocks.forEach((b) => { if (b.title === tx(d, 'po.cancelled') && !b.reason) b.reason = reason })
            continue
        }
        const ls: Line[] = []
        if (!realEdits) {
            const nlines = num(h.new?.['line_no'] ?? null)
            if (ct.startsWith('line_')) ls.push({ t: 'heading', text: nlines !== null ? tx(d, 'po.lineHeading', { n: nlines }) : cap(thing(d, 'purchase_order_lines')) })
            const seq = num(h.new?.['payment_term_seq'] ?? null)
            if (ct.startsWith('payment_term_')) ls.push({ t: 'heading', text: seq !== null ? tx(d, 'po.termHeading', { n: seq }) : cap(thing(d, 'purchase_order_payment_terms')) })
            ls.push(...historyDiff(d, h, opts))
        }
        blocks.push({ title: tx(d, 'po.amended'), lines: ls, reason, key: true, weight: 70 })
    }

    // ⑤ 明细行(A12–A14)
    for (const r of lines) {
        const head: Line = { t: 'heading', text: lineHeading(d, r) }
        if (r.op === 'INSERT') blocks.push({ title: tx(d, 'po.lineAdded'), lines: [head, ...valueLines(d, r, r.new, opts, new Set(['line_no', 'material_id', 'asset_id', 'purchase_order_id', 'unit']))], key: false, weight: 40 })
        else if (r.op === 'DELETE') blocks.push({ title: tx(d, 'po.lineRemoved'), lines: [head, ...valueLines(d, r, r.old, opts, new Set(['line_no', 'material_id', 'asset_id', 'purchase_order_id', 'unit']))], key: false, weight: 40 })
        else {
            const ls = changeLines(d, r, opts)
            if (ls.length) blocks.push({ title: tx(d, 'po.lineChanged'), lines: [head, ...ls], key: false, weight: 40 })
        }
    }
    // ⑥ 付款计划(A15–A17 · A19)
    for (const r of terms) {
        const head: Line = { t: 'heading', text: termHeading(d, r) }
        if (r.op === 'INSERT') blocks.push({ title: tx(d, 'po.termAdded'), lines: [head, ...valueLines(d, r, r.new, opts, new Set(['seq', 'label', 'purchase_order_id']))], key: false, weight: 40 })
        else if (r.op === 'DELETE') blocks.push({ title: tx(d, 'po.termRemoved'), lines: [head], key: false, weight: 40 })
        else {
            const isDue = changed(r, 'expected_date') || (r.prelog && r.cols?.includes('expected_date_set_at'))
            const ls = r.prelog ? valueLines(d, r, r.new, opts, new Set(['expected_date_set_at', 'expected_date_set_by'])) : changeLines(d, r, opts, new Set(['expected_date_set_at', 'expected_date_set_by']))
            if (ls.length || isDue) blocks.push({ title: tx(d, isDue ? 'po.dueDateSet' : 'po.termChanged'), lines: [head, ...ls], key: !!isDue, weight: isDue ? 60 : 40 })
        }
    }
    // ⑦ 保留金(A20)
    for (const r of by('purchase_order_line_retentions')) {
        const released = (changed(r, 'released_at') && r.new?.['released_at']) || (r.prelog && r.cols?.includes('released_at'))
        const ls = r.op === 'UPDATE' && !r.prelog ? changeLines(d, r, opts, new Set(['released_at', 'released_by']))
            : valueLines(d, r, r.new ?? r.old, opts, new Set(['purchase_order_line_id', 'released_at', 'released_by']))
        blocks.push({ title: tx(d, released ? 'po.retentionReleased' : r.op === 'INSERT' ? 'po.retentionSet' : 'po.retentionChanged'),
            lines: ls, reason: released ? typed(r.new?.['withholding_reason']) : null, key: !!released, weight: released ? 60 : 35 })
    }
    // ⑧ 条款承诺 · 签发 · 合同挂接(A18 · A21 · B38)
    for (const r of by('pricing_term_commitments')) {
        if (r.op !== 'INSERT') continue
        blocks.push({ title: tx(d, 'po.termsCommitted'), lines: valueLines(d, r, r.new, opts, new Set(['purchase_order_line_id', 'committed_at', 'committed_by', 'source_formula_code'])), key: true, weight: 60 })
    }
    for (const r of by('po_issues')) {
        if (r.op !== 'INSERT') continue
        blocks.push({ title: tx(d, 'po.issued', { version: num(r.new?.['version'] ?? null) ?? '' }), lines: [], key: true, weight: 60 })
    }
    for (const r of by('contract_document_terms')) {
        if (r.op !== 'INSERT') continue
        blocks.push({ title: contractLinked(d, r), lines: [], key: true, weight: 60 })
    }

    // 编辑类的几块并成"Purchase order amended · N changes"(Q27:一次操作一条,字段逐行)
    const amended = blocks.find((b) => b.title === tx(d, 'po.amended'))
    if (amended) {
        const edits = blocks.filter((b) => !b.key)
        for (const b of edits) {
            amended.lines.push(...b.lines)
            blocks.splice(blocks.indexOf(b), 1)
        }
        const n = amended.lines.filter((l) => l.t === 'change' || l.t === 'value').length
        if (n) amended.title = `${tx(d, 'po.amended')} · ${plural(d, 'po.changes.one', 'po.changes.many', n)}`
    }
    return blocks
}

/** 修改史一行(记录开始之前那一段)自己说出改了什么:old_x → new_x,不同的才印 */
function historyDiff(d: TrailDict, h: TrailRow, opts: BuildOptions): Line[] {
    const out: Line[] = []
    const n = h.new ?? {}
    const img = { ...n, unit: n['new_unit'] ?? n['old_unit'] ?? null } as Img
    for (const col of Object.keys(n)) {
        if (!col.startsWith('new_')) continue
        const bare = col.slice(4)
        const oldCol = 'old_' + bare
        const o = n[oldCol], v = n[col]
        if (JSON.stringify(o ?? null) === JSON.stringify(v ?? null) && !isRestricted(v)) continue
        if (bare === 'unit') continue
        const [label, kind] = fieldMeta(d, h.table!, col)
        if (hiddenKind(kind)) continue
        out.push({ t: 'change', label, old: formatValue(d, h.table!, oldCol, o, img, h.refs, 'UPDATE', opts),
                   new: formatValue(d, h.table!, col, v, img, h.refs, 'UPDATE', opts) })
    }
    return out
}

// ── 加工单 ──────────────────────────────────────────────────────────────────
const RUN_TABLES = new Set(['processing_runs', 'processing_inputs', 'processing_outputs', 'processing_cost_entries',
    'processing_cost_entry_history', 'batch_processing_cost_allocations', 'processing_run_losses'])

function batchLine(d: TrailDict, r: TrailRow, label: string, qtyCol: string, opts: BuildOptions): Line {
    const img = imgOf(r)
    const bcol = typeof img['inbound_batch_id'] === 'string' ? 'inbound_batch_id' : 'output_batch_id'
    const b = img[bcol]
    const who = typeof b === 'string' ? refVal(d, r.table!, bcol, b, r.refs).text : cap(thing(d, r.table))
    const q = formatValue(d, r.table!, qtyCol, img[qtyCol], img, r.refs, r.op, opts)
    return { t: 'value', label, value: { text: `${who} — ${q.text}`, restricted: q.restricted } }
}

function describeRun(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block[] {
    const blocks: Block[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const run = by('processing_runs')
    const created = run.find((r) => r.op === 'INSERT')
    const firstInput = by('processing_inputs')[0]
    const unit = firstInput ? unitFor(d, 'quantity_consumed', imgOf(firstInput), firstInput.refs, opts) : null
    const o2 = { ...opts, unit: opts.unit ?? unit }

    // ① 加工完成(B14 · Q10):一次提交 = 单 + 投入 + 产出 + 损耗
    if (created) {
        const pd = str(created, 'process_date', 'new')
        const title = pd ? `${tx(d, 'run.completed')} · ${tx(d, 'run.processDate', { date: d.formatDate(pd) })}` : tx(d, 'run.completed')
        const ls: Line[] = []
        for (const r of by('processing_inputs').filter((x) => x.op === 'INSERT')) ls.push(batchLine(d, r, tx(d, 'run.used'), 'quantity_consumed', o2))
        for (const r of by('processing_outputs').filter((x) => x.op === 'INSERT')) ls.push(batchLine(d, r, tx(d, 'run.produced'), 'quantity_produced', o2))
        const loss = created.new?.['loss_qty']
        if (loss !== undefined && loss !== null && num(loss) !== 0) ls.push({ t: 'value', label: tx(d, 'run.loss'), value: formatValue(d, 'processing_runs', 'loss_qty', loss, imgOf(created), created.refs, 'INSERT', o2) })
        for (const c of ['work_order_id', 'equipment_id', 'operation_type_code']) {
            const v = created.new?.[c]
            if (!isEmpty(v)) ls.push({ t: 'value', label: fieldMeta(d, 'processing_runs', c)[0], value: formatValue(d, 'processing_runs', c, v, imgOf(created), created.refs, 'INSERT', o2) })
        }
        const notes = typed(created.new?.['notes'])
        if (notes) ls.push({ t: 'value', label: fieldMeta(d, 'processing_runs', 'notes')[0], value: notes })
        blocks.push({ title, lines: ls, key: true, weight: 100 })
    }

    for (const r of run) {
        if (r === created) continue
        const allocated = (changed(r, 'allocated_at') && r.new?.['allocated_at']) || (r.prelog && r.cols?.includes('allocated_at'))
        const rolledBack = (changed(r, 'status') && str(r, 'status', 'new') === 'reversed') ||
            (changed(r, 'deleted_at') && r.new?.['deleted_at']) || (r.prelog && r.cols?.includes('deleted_at')) || r.op === 'DELETE'
        if (allocated) {
            const basis = str(r, 'allocation_basis')
            const title = basis ? `${tx(d, 'run.allocated')} · ${enumLabel(d, 'processing_runs', 'allocation_basis', basis).toLowerCase()}` : tx(d, 'run.allocated')
            const ls: Line[] = []
            for (const o of by('processing_outputs').filter((x) => x.op === 'UPDATE' && (x.cols ?? []).includes('allocated_cost_base'))) {
                const img = imgOf(o)
                const b = img['output_batch_id']
                const who = typeof b === 'string' ? refVal(d, 'processing_outputs', 'output_batch_id', b, o.refs).text : cap(thing(d, 'processing_outputs'))
                const amt = formatValue(d, 'processing_outputs', 'allocated_cost_base', o.new?.['allocated_cost_base'], img, o.refs, 'UPDATE', o2)
                const per = o.new?.['unit_cost_base']
                const perText = per !== undefined && per !== null && !isRestricted(per) && !amt.restricted
                    ? ` (${formatValue(d, 'processing_outputs', 'unit_cost_base', per, img, o.refs, 'UPDATE', o2).text}${unit ? '/' + unit : ''})` : ''
                ls.push({ t: 'value', label: who, value: { text: amt.text + perText, restricted: amt.restricted } })
            }
            for (const a of by('batch_processing_cost_allocations').filter((x) => x.op === 'INSERT')) {
                ls.push({ t: 'value', label: tx(d, 'run.batchShare'), value: (() => {
                    const img = imgOf(a); const b = img['inbound_batch_id']
                    const who = typeof b === 'string' ? refVal(d, a.table!, 'inbound_batch_id', b, a.refs).text : ''
                    const amt = formatValue(d, a.table!, 'amount_base', a.new?.['amount_base'], img, a.refs, 'INSERT', o2)
                    return { text: who ? `${who} — ${amt.text}` : amt.text, restricted: amt.restricted }
                })() })
            }
            const cap_ = r.new?.['capitalized_cost_base']
            if (cap_ !== undefined && cap_ !== null) ls.push({ t: 'value', label: tx(d, 'run.capitalised'), value: formatValue(d, 'processing_runs', 'capitalized_cost_base', cap_, imgOf(r), r.refs, 'UPDATE', o2) })
            const je = r.new?.['capitalization_entry_id']
            if (typeof je === 'string') ls.push({ t: 'value', label: tx(d, 'run.journal'), value: refVal(d, 'processing_runs', 'capitalization_entry_id', je, r.refs) })
            blocks.push({ title, lines: ls, key: true, weight: 90 })
        } else if (rolledBack) {
            blocks.push({ title: tx(d, 'run.rolledBack'), lines: [], reason: typed(r.new?.['delete_reason']), key: true, weight: 90 })
        } else if (changed(r, 'allocation_basis')) {
            blocks.push({ title: tx(d, 'run.basisChanged'), lines: changeLines(d, r, o2, new Set(['allocation_basis_changed_at'])), key: true, weight: 70 })
        } else {
            const ls = changeLines(d, r, o2)
            if (ls.length) blocks.push({ title: tx(d, 'run.edited'), lines: ls, key: false, weight: 30 })
        }
    }

    // ② 成本条目与它的修改史(B18–B22):同一笔里两边都在时只说一次
    const costs = by('processing_cost_entries')
    const chist = by('processing_cost_entry_history')
    const seen = new Set<string>()
    for (const r of [...costs, ...chist]) {
        const id = r.table === 'processing_cost_entries' ? String(r.key?.['id'] ?? '') : String(r.new?.['entry_id'] ?? '')
        if (id && seen.has(id)) continue
        if (id) seen.add(id)
        const isHist = r.table === 'processing_cost_entry_history'
        const ct = isHist ? (str(r, 'change_type', 'new') ?? '') : ''
        const img = imgOf(r)
        const typeRaw = isHist ? (r.new?.['new_cost_type'] ?? r.new?.['old_cost_type']) : img['cost_type']
        const typeText = typeof typeRaw === 'string' ? enumLabel(d, 'processing_cost_entries', 'cost_type', typeRaw) : ''
        const amtRaw = isHist ? (r.new?.['new_amount_base'] ?? r.new?.['old_amount_base']) : (r.new?.['amount_base'] ?? r.old?.['amount_base'] ?? img['amount_base'])
        const amt = formatValue(d, 'processing_cost_entries', 'amount_base', amtRaw, img, r.refs, r.op, o2)
        const est = (isHist ? r.new?.['new_is_estimate'] : img['is_estimate']) === true ? ` ${tx(d, 'run.estimate')}` : ''
        // 受限的金额不塞进标题里当一个词 —— 它自成一行,画成 Restricted 药丸(Q27)
        const what = [typeText, amt.empty || amt.restricted ? '' : amt.text].filter(Boolean).join(' ') + est
        let key: TrailTextKey
        if (isHist) key = ct === 'create' ? 'run.costAdded' : ct === 'delete' ? 'run.costRemoved' : ct === 'restore' ? 'run.costRestored' : 'run.costChanged'
        else if (r.op === 'INSERT') key = 'run.costAdded'
        else if (r.op === 'DELETE' || (changed(r, 'deleted_at') && r.new?.['deleted_at'])) key = 'run.costRemoved'
        else if (changed(r, 'deleted_at')) key = 'run.costRestored'
        else if (changed(r, 'relieved_at') && r.new?.['relieved_at']) key = 'run.costRelieved'
        else key = 'run.costChanged'
        const ls = key === 'run.costChanged'
            ? (isHist ? historyDiff(d, r, o2) : changeLines(d, r, o2, new Set(['deleted_at'])))
            : amt.restricted ? [{ t: 'value' as const, label: fieldMeta(d, 'processing_cost_entries', 'amount_base')[0], value: amt }] : []
        const title = key === 'run.costChanged' || !what.trim() ? tx(d, key) : `${tx(d, key)} · ${what.trim()}`
        blocks.push({ title, lines: ls, reason: key === 'run.costAdded' ? typed(img['notes']) : null, key: key !== 'run.costChanged', weight: 60 })
    }
    // ③ 损耗(B14 的一部分;单独改时)
    if (!created) {
        for (const r of by('processing_run_losses')) {
            const ls = r.op === 'UPDATE' ? changeLines(d, r, o2) : valueLines(d, r, r.new ?? r.old, o2, new Set(['run_id']))
            blocks.push({ title: tx(d, r.op === 'INSERT' ? 'run.lossRecorded' : r.op === 'DELETE' ? 'run.lossRemoved' : 'run.lossChanged'), lines: ls, key: false, weight: 40 })
        }
        // 投入 / 产出单独出现(记录开始之前、或将来的更正)
        for (const r of [...by('processing_inputs'), ...by('processing_outputs')]) {
            if (r.op === 'UPDATE' && (r.cols ?? []).every((c) => ['allocated_cost_base', 'unit_cost_base', 'cost_incomplete'].includes(c))
                && blocks.some((b) => b.title.startsWith(tx(d, 'run.allocated')))) continue
            const ls = r.op === 'UPDATE' ? changeLines(d, r, o2) : [batchLine(d, r, tx(d, r.table === 'processing_inputs' ? 'run.used' : 'run.produced'),
                r.table === 'processing_inputs' ? 'quantity_consumed' : 'quantity_produced', o2)]
            if (ls.length) blocks.push({ title: tx(d, 'run.edited'), lines: ls, key: false, weight: 30 })
        }
    }
    return blocks
}

// ── 角色 ────────────────────────────────────────────────────────────────────
function permName(d: TrailDict, r: TrailRow): string {
    const code = typeof r.key?.['permission_code'] === 'string' ? r.key['permission_code'] as string
        : str(r, 'permission_code')
    return code ? refVal(d, 'role_permissions', 'permission_code', code, r.refs).text : cap(thing(d, 'permissions'))
}
function describeRole(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block[] {
    const blocks: Block[] = []
    const roles = rows.filter((r) => r.table === 'roles')
    const perms = rows.filter((r) => r.table === 'role_permissions')
    const added = perms.filter((r) => r.op === 'INSERT').map((r) => permName(d, r)).sort()
    const removed = perms.filter((r) => r.op === 'DELETE').map((r) => permName(d, r)).sort()
    const created = roles.find((r) => r.op === 'INSERT')
    const prelog = perms.length > 0 && perms.every((r) => r.prelog)
    if (created) {
        const ls = valueLines(d, created, created.new, opts, new Set(['is_active', 'is_system']))
        if (added.length) ls.push({ t: 'value', label: tx(d, 'role.lineGiven'), value: truncate(added.join(' · ')) })
        const title = added.length ? `${tx(d, 'role.created')} · ${plural(d, 'role.perms.one', 'role.perms.many', added.length)}` : tx(d, 'role.created')
        blocks.push({ title, lines: ls, key: true, weight: 100 })
    } else if (perms.length) {
        if (prelog) {
            blocks.push({ title: `${tx(d, 'role.permsSet')} · ${plural(d, 'role.perms.one', 'role.perms.many', added.length)}`,
                lines: [{ t: 'note', text: tx(d, 'role.notKept') }, { t: 'value', label: tx(d, 'role.lineGiven'), value: truncate(added.join(' · ')) }],
                key: true, weight: 90 })
        } else {
            const parts = [added.length ? tx(d, 'role.added', { n: added.length }) : '', removed.length ? tx(d, 'role.removed', { n: removed.length }) : ''].filter(Boolean)
            const ls: Line[] = []
            if (added.length) ls.push({ t: 'value', label: tx(d, 'role.lineAdded'), value: truncate(added.join(' · ')) })
            if (removed.length) ls.push({ t: 'value', label: tx(d, 'role.lineRemoved'), value: truncate(removed.join(' · ')) })
            blocks.push({ title: [tx(d, 'role.permsChanged'), parts.join(', ')].filter(Boolean).join(' · '), lines: ls, key: true, weight: 90 })
        }
    }
    for (const r of roles) {
        if (r === created) continue
        if (r.op === 'DELETE' || (changed(r, 'deleted_at') && r.new?.['deleted_at']) || (r.prelog && r.cols?.includes('deleted_at'))) {
            blocks.push({ title: tx(d, 'role.deleted'), lines: [], key: true, weight: 80 }); continue
        }
        const ls = changeLines(d, r, opts, new Set(['is_active']))
        if (changed(r, 'is_active')) blocks.push({ title: tx(d, r.new?.['is_active'] === true ? 'role.reactivated' : 'role.deactivated'), lines: ls, key: true, weight: 80 })
        else if (ls.length) blocks.push({ title: tx(d, 'role.edited'), lines: ls, key: false, weight: 30 })
    }
    return blocks
}

// ── 任何别的表(汇总页;Q9 的 K01–K04)──────────────────────────────────────
function describeGeneric(d: TrailDict, r: TrailRow, opts: BuildOptions): Block {
    const t = thing(d, r.table)
    if (r.op && r.op.startsWith('ACCOUNT_')) {
        const key = `account.${r.op}` as TrailTextKey
        const email = str(r, 'email')
        return { title: key in d.text ? tx(d, key) : tx(d, 'generic.edited', { thing: t }),
                 lines: email ? [{ t: 'value', label: 'Email', value: { text: email, typed: true } }] : [], key: true, weight: 50 }
    }
    if (r.op === 'TRUNCATE') return { title: tx(d, 'generic.truncated', { thing: t }), lines: [], key: true, weight: 50 }
    if (r.op === 'INSERT') return { title: tx(d, 'generic.created', { thing: t }), lines: valueLines(d, r, r.new, opts), key: true, weight: 45 }
    if (r.op === 'DELETE') return { title: tx(d, 'generic.deleted', { thing: t }), lines: valueLines(d, r, r.old, opts), key: true, weight: 45 }
    if (changed(r, 'deleted_at') && r.new?.['deleted_at']) {
        return { title: tx(d, 'generic.deleted', { thing: t }), lines: changeLines(d, r, opts, new Set(['deleted_at', 'deleted_by', 'delete_reason'])),
                 reason: typed(r.new?.['delete_reason']), key: true, weight: 45 }
    }
    const lifecycle = (r.cols ?? []).some((c) => /(^|_)(status|stage|state)$/.test(c) || /^(approved|decided|revoked|closed|cancelled|posted|reversed|voided|executed|withdrawn|issued|released)_at$/.test(c))
    return { title: tx(d, 'generic.edited', { thing: t }), lines: changeLines(d, r, opts), key: lifecycle, weight: 20 }
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1:批次 · 分录 · 审批 · 工单 · 盘点 · 设备 · 交接班 · 仓库申请
// ════════════════════════════════════════════════════════════════════════════
/** 主语 → 它的表(根表 + trail_subject_members 里 shown = true 的那些)。
 *  ★ 与 db/functions/trail_subjects.sql / trail_subject_members.sql 逐项相等 —— scripts/check-trail-wording.mjs 比对,
 *    一边加了表、另一边没跟上就红。页面据此知道自己是哪一种记录(AuditTrail.tsx 的 subject)。 */
export const SUBJECT_TABLES: Record<string, string[]> = {
    purchase_order: ['purchase_orders', 'purchase_order_lines', 'purchase_order_payment_terms', 'purchase_order_line_retentions',
        'pricing_term_commitments', 'po_issues', 'contract_document_terms', 'approval_log', 'purchase_order_history'],
    processing_run: ['processing_runs', 'processing_inputs', 'processing_outputs', 'processing_cost_entries', 'processing_cost_entry_history',
        'batch_processing_cost_allocations', 'processing_run_losses', 'warehouse_requests', 'approval_log'],
    role: ['roles', 'role_permissions'],
    inbound_batch: ['inbound_batches', 'inbound_batch_metals', 'assay_results', 'assay_result_metals', 'inbound_batch_safety_states',
        'price_history', 'receipt_price_requests', 'approval_log', 'prepayment_applications', 'pricing_term_commitments',
        'pricing_term_commitment_metals', 'inventory_movements', 'stocktake_lines', 'stocktake_counts', 'processing_inputs',
        'batch_processing_cost_allocations', 'certificates_of_destruction', 'cod_issues', 'warehouse_requests', 'freight_allocations',
        'payment_allocations', 'finance_attachments', 'purchase_order_history', 'processing_cost_entry_history', 'work_order_history',
        'journal_entries'],
    output_batch: ['output_batches', 'output_batch_metals', 'assay_results', 'assay_result_metals', 'output_batch_safety_states',
        'inventory_movements', 'processing_outputs', 'processing_inputs', 'stocktake_lines', 'stocktake_counts', 'warehouse_requests',
        'approval_log', 'sales_records', 'sales_record_movements', 'sales_attribution_log', 'invoice_lines', 'payment_allocations',
        'sales_order_reservations', 'shipment_lines', 'traceability_report_issues', 'sales_settlements', 'processing_cost_entry_history',
        'work_order_history', 'sales_order_history', 'journal_entries'],
    work_order: ['work_orders', 'work_order_lines', 'work_order_expected_outputs', 'work_order_history', 'approval_log'],
    stocktake: ['stocktakes', 'stocktake_lines', 'stocktake_counts', 'approval_log', 'journal_entries'],
    equipment: ['fixed_assets', 'equipment_maintenance', 'equipment_downtime', 'equipment_service_intervals', 'shift_handover_equipment_refs'],
    shift_handover: ['shift_handovers', 'shift_handover_items', 'shift_handover_equipment_refs'],
    warehouse_request: ['warehouse_requests', 'approval_log'],
    // AUDIT-TRAIL-1b-2
    quote: ['quotes', 'quote_lines', 'qt_issues', 'quote_history'],
    sales_order: ['sales_orders', 'sales_order_lines', 'sales_order_reservations', 'shipping_releases', 'shipping_release_lines',
        'approval_log', 'so_issues', 'sales_order_history', 'contract_document_terms'],
    shipment: ['shipments', 'shipment_lines', 'shipment_issues'],
    customer: ['customers', 'counterparty_contacts', 'customer_attachments', 'customer_credit_history', 'customer_statements',
        'statement_issues', 'collection_chases', 'collection_chase_documents', 'collection_promises'],
    commission_agreement: ['commission_agreements'],
    supplier: ['suppliers', 'supplier_compliance', 'supplier_attachments', 'counterparty_contacts', 'supplier_status_history', 'approval_log'],
    container: ['containers', 'container_milestones', 'container_documents'],
    forwarder: ['suppliers', 'forwarder_details', 'forwarder_rate_quotes'],
    lane: ['lanes', 'lane_document_requirements'],
    port: ['ports', 'lanes'],
    company_licence: ['company_compliance'],
    // AUDIT-TRAIL-1b-3
    material: ['materials', 'material_attachments', 'material_required_metals'],
    storage_location: ['storage_locations', 'storage_location_allowed_classes'],
    metal_price: ['metal_prices'],
    pricing_formula: ['pricing_formulas', 'pricing_formula_metals', 'pricing_formula_history', 'terms_requests', 'approval_log'],
    task: ['tasks', 'task_nodes', 'task_participants', 'task_history'],
    processing_settings: ['processing_settings'],
    pricing_settings: ['pricing_settings'],
    receiving_settings: ['receiving_settings'],
    // AUDIT-TRAIL-1c-1
    journal_entry: ['journal_entries', 'journal_lines', 'journal_requests', 'approval_log'],
    invoice: ['invoices', 'invoice_lines', 'invoice_issues', 'invoice_requests', 'approval_log', 'credit_notes', 'payment_allocations', 'journal_entries'],
    credit_note: ['credit_notes', 'credit_note_lines', 'cn_issues', 'invoice_requests', 'approval_log', 'journal_entries'],
    payment: ['payments', 'payment_allocations', 'finance_attachments', 'payment_requests', 'approval_log', 'journal_entries'],
    payment_request: ['payment_requests', 'approval_log', 'payments', 'bank_transfers', 'wht_remittances', 'journal_entries'],
    expense: ['expenses', 'payment_allocations', 'finance_attachments', 'prepayment_applications', 'expense_claims', 'approval_log',
        'fixed_asset_cost_entries', 'journal_entries'],
    payable: ['inbound_batches', 'payment_allocations', 'freight_allocations', 'prepayment_applications', 'finance_attachments', 'price_history',
        'journal_entries'],
}

type Family = 'po' | 'run' | 'role' | 'batch' | 'journal' | 'approval' | 'wo' | 'stocktake' | 'equipment' | 'handover' | 'wr' | 'so'
    | 'quote' | 'shipment' | 'customer' | 'commission' | 'supplier' | 'container' | 'lane' | 'licence'
    | 'material' | 'location' | 'metalPrice' | 'formula' | 'task' | 'settings' | 'fin'
const PAGE_FAMILY: Record<string, Family> = {
    purchase_order: 'po', processing_run: 'run', role: 'role', inbound_batch: 'batch', output_batch: 'batch', work_order: 'wo',
    stocktake: 'stocktake', equipment: 'equipment', shift_handover: 'handover', warehouse_request: 'wr',
    quote: 'quote', sales_order: 'so', shipment: 'shipment', customer: 'customer', commission_agreement: 'commission',
    supplier: 'supplier', forwarder: 'supplier', container: 'container', lane: 'lane', port: 'lane', company_licence: 'licence',
    material: 'material', storage_location: 'location', metal_price: 'metalPrice', pricing_formula: 'formula', task: 'task',
    processing_settings: 'settings', pricing_settings: 'settings', receiving_settings: 'settings',
    // AUDIT-TRAIL-1c-1
    journal_entry: 'fin', invoice: 'fin', credit_note: 'fin', payment: 'fin', payment_request: 'fin', expense: 'fin', payable: 'fin',
}
const BATCH_TABLES = new Set(['inbound_batches', 'output_batches', 'inbound_batch_metals', 'output_batch_metals', 'assay_results',
    'assay_result_metals', 'inbound_batch_safety_states', 'output_batch_safety_states', 'price_history', 'receipt_price_requests',
    'prepayment_applications', 'pricing_term_commitment_metals', 'inventory_movements', 'certificates_of_destruction', 'cod_issues',
    'freight_allocations', 'payment_allocations', 'finance_attachments', 'sales_records', 'sales_record_movements', 'sales_attribution_log',
    'invoice_lines', 'sales_order_reservations', 'shipment_lines', 'traceability_report_issues', 'sales_settlements'])
/** 这三张属于加工单;但在批次页上,它们说的是"这个批次被用了 / 被产出 / 分到了成本",从批次这一边说 */
const BATCH_VIEW_OF_RUN = new Set(['processing_inputs', 'processing_outputs', 'batch_processing_cost_allocations'])
const WO_TABLES = new Set(['work_orders', 'work_order_lines', 'work_order_expected_outputs', 'work_order_history'])
const ST_TABLES = new Set(['stocktakes', 'stocktake_lines', 'stocktake_counts'])
const EQ_TABLES = new Set(['fixed_assets', 'equipment_maintenance', 'equipment_downtime', 'equipment_service_intervals'])
const HO_TABLES = new Set(['shift_handovers', 'shift_handover_items', 'shift_handover_equipment_refs'])
/** 往上一跳够到的那几种:在别的记录的页上出现时,标题后面点名它属于哪一张单据("Purchase order amended · PO-2026-0010")。
 *  写进标题而不是另起一个小标题 —— 一条记录里后面几块的标题本身就是小标题,再加一个会把它们的标题挤掉。 */
const HEADED = new Set<Family>(['po', 'run', 'wo', 'so'])

function familyOf(r: TrailRow, subject?: string | null): Family | null {
    const t = r.table
    if (!t) return null
    // AUDIT-TRAIL-1c-1:账上那七页上的每一行都从 describeFinance 说 —— 别的页上同一张表的说法不动
    if (subject && FIN_SUBJECTS.has(subject)) return 'fin'
    if ((subject === 'inbound_batch' || subject === 'output_batch') && BATCH_VIEW_OF_RUN.has(t)) return 'batch'
    // AUDIT-TRAIL-1b-2:预留、合同条款在订单页上从订单这一边说;发货单明细在发货单页上从发货单这一边说
    //   (在批次页、采购单页、汇总页上仍照 1b-1 的说法)
    if (subject === 'sales_order' && (t === 'sales_order_reservations' || t === 'contract_document_terms')) return 'so'
    if (subject === 'shipment' && t === 'shipment_lines') return 'shipment'
    if (t === 'counterparty_contacts') return subject === 'supplier' || (!subject && !imgOf(r)['customer_id']) ? 'supplier' : 'customer'
    if (t === 'approval_log') return str(r, 'subject_type') === 'purchase_order' ? 'po' : 'approval'
    if (PO_TABLES.has(t)) return 'po'
    if (RUN_TABLES.has(t)) return 'run'
    if (t === 'roles' || t === 'role_permissions') return 'role'
    if (t === 'shift_handover_equipment_refs' && subject === 'equipment') return 'equipment'
    if (BATCH_TABLES.has(t)) return 'batch'
    if (WO_TABLES.has(t)) return 'wo'
    if (ST_TABLES.has(t)) return 'stocktake'
    if (EQ_TABLES.has(t)) return 'equipment'
    if (HO_TABLES.has(t)) return 'handover'
    if (t === 'warehouse_requests') return 'wr'
    if (t === 'journal_entries') return 'journal'
    if (SO_TABLES.has(t)) return 'so'
    if (QUOTE_TABLES.has(t)) return 'quote'
    if (t === 'shipments' || t === 'shipment_issues') return 'shipment'
    if (CUSTOMER_TABLES.has(t)) return 'customer'
    if (t === 'commission_agreements') return 'commission'
    if (SUPPLIER_TABLES.has(t)) return 'supplier'
    if (CONTAINER_TABLES.has(t)) return 'container'
    if (LANE_TABLES.has(t)) return 'lane'
    if (t === 'company_compliance') return 'licence'
    // AUDIT-TRAIL-1b-3
    if (MATERIAL_TABLES.has(t)) return 'material'
    if (t === 'storage_locations' || t === 'storage_location_allowed_classes') return 'location'
    if (t === 'metal_prices') return 'metalPrice'
    if (FORMULA_TABLES.has(t)) return 'formula'
    if (TASK_TABLES.has(t)) return 'task'
    if (SETTINGS_TITLE[t]) return 'settings'
    return null
}

/** "PO-2026-0010" —— 一组往上一跳够到的行属于哪一张单据(取它指着那张单据的那一列解析出来的单号) */
const DOC_COLS: [string, string][] = [['purchase_order_id', 'purchase_orders'], ['run_id', 'processing_runs'],
    ['work_order_id', 'work_orders'], ['sales_order_id', 'sales_orders']]
function docLabel(rows: TrailRow[]): string | null {
    for (const r of rows) {
        if (r.table === 'approval_log') {
            const code = docCode(str(r, 'subject_code'))
            if (code) return code
            continue
        }
        const img = imgOf(r)
        for (const [c] of DOC_COLS) {
            const v = img[c]
            const label = typeof v === 'string' ? r.refs?.[c]?.[v]?.label : null
            if (label) return label
        }
    }
    return null
}

/** 审批留痕抄下来的单据号(subject_code)—— 是人认得的编号才用;一个 id 形状的值宁可不说 */
function docCode(v: string | null): string | null {
    return v && !/^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(v) ? v : null
}
/** 一个字典代码(金属、安全状态)→ 它的名字;解析不出来说 "a metal",绝不印代码本身 */
function dictName(d: TrailDict, r: TrailRow, col: string): string {
    const raw = r.key?.[col] ?? imgOf(r)[col]
    return typeof raw === 'string' || typeof raw === 'number' ? refVal(d, r.table!, col, String(raw), r.refs).text
        : tx(d, 'value.unnamed', { thing: fieldMeta(d, r.table!, col)[0].toLowerCase() })
}
/** 一个指着别处的值 → 它解析出来的名字;解析不出来就是 null(调用方决定说什么)*/
function refLabel(r: TrailRow, col: string): string | null {
    const v = imgOf(r)[col]
    if (typeof v !== 'string' && typeof v !== 'number') return null
    const ref = r.refs?.[col]?.[String(v)]
    return ref?.label ?? null
}
function refEnded(r: TrailRow, col: string): boolean {
    const v = imgOf(r)[col]
    return typeof v === 'string' && !!r.refs?.[col]?.[v]?.ended
}
function qtyText(d: TrailDict, r: TrailRow, col: string, opts: BuildOptions): string {
    const img = imgOf(r)
    const v = formatValue(d, r.table!, col, img[col], img, r.refs, r.op, opts)
    return v.empty || v.restricted ? '' : v.text
}
function withPart(title: string, part: string | null | undefined): string {
    return part ? `${title} · ${part}` : title
}
function isSet(r: TrailRow, col: string): boolean {
    return (changed(r, col) && !isEmpty(r.new?.[col] ?? null)) || (r.prelog && (r.cols ?? []).includes(col))
}
function isCleared(r: TrailRow, col: string): boolean {
    return changed(r, col) && isEmpty(r.new?.[col] ?? null) && !isEmpty(r.old?.[col] ?? null)
}

/** 同一笔事务里【先删后插】的同一行(整组替换:金属、安全状态、物料的化验要求)→ 一次改动;前后一样的整个不算。
 *  AUDIT-TRAIL-1b-3:只认【删在前、插在后】这一种顺序,并且保留行的先后。先插后删(同一次操作里加上又拿掉,
 *  例如建库位时勾了一个分类、随后那一次保存把它换掉)不是一次"整组替换",两行都照常说 —— 第一版不分先后,
 *  于是线上那一次回滚的证明里库位的分类改动整个不见了。 */
function netReplace(rows: TrailRow[]): TrailRow[] {
    const firstDelete = new Map<string, number>()
    rows.forEach((r, i) => { if (r.op === 'DELETE' && r.key && !firstDelete.has(JSON.stringify(r.key))) firstDelete.set(JSON.stringify(r.key), i) })
    const paired = new Set<number>()
    const out: TrailRow[] = []
    rows.forEach((r, i) => {
        if (r.op === 'INSERT' && r.key) {
            const k = JSON.stringify(r.key)
            const di = firstDelete.get(k)
            if (di !== undefined && di < i) {
                paired.add(di)
                const before = rows[di]
                const cols = Object.keys({ ...(before.old ?? {}), ...(r.new ?? {}) })
                    .filter((c) => JSON.stringify(before.old?.[c] ?? null) !== JSON.stringify(r.new?.[c] ?? null))
                if (cols.length) out.push({ ...r, op: 'UPDATE', cols, old: before.old, refs: mergeRefs(before.refs, r.refs) })
                return
            }
        }
        out.push(r)
    })
    return out.filter((r) => !(r.op === 'DELETE' && paired.has(rows.indexOf(r))))
}

/** absorbsApproval:这一块自己已经说出了那一步(供应商的"送审 / 批准 / 驳回"),同一笔里的审批留痕并进来时不再另起一行说明 */
type Block2 = Block & { recordId?: string; approvalFor?: string; absorbsApproval?: boolean }

// ── 审批(任何一种单据)──────────────────────────────────────────────────────
function approvalThing(d: TrailDict, subjectType: string): string {
    const t = subjectType.endsWith('s') ? subjectType : subjectType + 's'
    return d.tables[t]?.[0] ?? 'record'
}
/** 这几种单据的审批留痕里,note 那一格是【数据库自己写的】中文句子,不是一个人写的话(Q8:机器写的中文不上屏):
 *  post_stocktake 写"盘点过账:N 行有差异……",release_work_order 在审批关着时写"审批流未启用……"。
 *  自动批准的说明(auto_approved)一律同理。人写的理由(批准 / 驳回时填的)照原样说。 */
const MACHINE_NOTE_SUBJECTS = new Set(['stocktake', 'work_order'])
function describeApproval(d: TrailDict, rows: TrailRow[]): Block2[] {
    const out: Block2[] = []
    for (const a of rows) {
        if (a.op !== 'INSERT') { out.push(describeGeneric(d, a, {})); continue }
        const st = str(a, 'subject_type') ?? ''
        const code = docCode(str(a, 'subject_code'))
        const what = cap(approvalThing(d, st)) + (code ? ` ${code}` : '')
        const decision = str(a, 'decision', 'new') ?? ''
        const level = num(a.new?.['level'] ?? null)
        let title: string
        switch (decision) {
            case 'submitted': title = tx(d, 'approval.submitted', { thing: what }); break
            case 'approved': title = level ? tx(d, 'approval.approvedLevel', { thing: what, level }) : tx(d, 'approval.approved', { thing: what }); break
            case 'rejected': title = tx(d, 'approval.rejected', { thing: what }); break
            case 'auto_approved': title = tx(d, 'approval.auto', { thing: what }); break
            default: title = tx(d, 'approval.other', { thing: what, decision: enumLabel(d, 'approval_log', 'decision', decision).toLowerCase() })
        }
        out.push({ title, lines: [], reason: decision === 'auto_approved' || MACHINE_NOTE_SUBJECTS.has(st) ? null : typed(a.new?.['note']), key: true, weight: 50,
                   approvalFor: str(a, 'subject_id') ?? undefined })
    }
    return out
}

// ── 分录 ────────────────────────────────────────────────────────────────────
function describeJournal(d: TrailDict, rows: TrailRow[], opts: BuildOptions, reversals: Set<string>): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        const code = str(r, 'code') ?? ''
        const id = typeof r.key?.['id'] === 'string' ? r.key['id'] as string : ''
        const by = refLabel(r, 'reversed_by')
        if (r.op === 'INSERT') {
            const ls = valueLines(d, r, r.new, opts, new Set(['code', 'status', 'reversed_by', 'source_id', 'memo']))
            const memo = typed(r.new?.['memo'])
            if (memo) ls.push({ t: 'value', label: fieldMeta(d, 'journal_entries', 'memo')[0], value: memo })
            if (str(r, 'status') === 'reversed' && by && !reversals.has(id)) ls.push({ t: 'note', text: tx(d, 'journal.laterReversed', { by }) })
            out.push({ title: tx(d, reversals.has(id) ? 'journal.reversal' : 'journal.posted', { code }), lines: ls, key: true, weight: 70, recordId: id })
        } else if (r.op === 'UPDATE' && changed(r, 'status') && str(r, 'status', 'new') === 'reversed') {
            out.push({ title: tx(d, 'journal.reversedBy', { code, by: by ?? tx(d, 'value.unnamed', { thing: thing(d, 'journal_entries') }) }),
                       lines: [], key: true, weight: 80, recordId: id })
        } else {
            out.push({ ...describeGeneric(d, r, opts), title: withPart(tx(d, 'journal.edited'), code) })
        }
    }
    return out
}

// ── 批次(进料 / 产出)与挂在它上面的一切 ───────────────────────────────────
function describeBatch(d: TrailDict, rows0: TrailRow[], opts: BuildOptions, subject?: string | null): Block2[] {
    const out: Block2[] = []
    const onBatch = subject === 'inbound_batch' || subject === 'output_batch'
    const rows = netReplace(rows0)
    const by = (...ts: string[]) => rows.filter((r) => ts.includes(r.table!))
    const skipBatch = onBatch ? ['inbound_batch_id', 'output_batch_id'] : []

    // ① 批次本身
    for (const r of by('inbound_batches', 'output_batches')) {
        const inbound = r.table === 'inbound_batches'
        const img = imgOf(r)
        if (r.op === 'INSERT') {
            const ls = valueLines(d, r, r.new, opts, new Set(['quantity', 'remaining_qty', 'unit', 'status', 'stage', 'code',
                'deleted_at', 'deleted_by', 'delete_reason', 'pricing_status']))
            if (inbound && isEmpty(img['purchase_order_line_id'] ?? null)) ls.unshift({ t: 'note', text: tx(d, 'batch.noPurchaseOrder') })
            out.push({ title: withPart(tx(d, inbound ? 'batch.received' : 'batch.outputCreated'), qtyText(d, r, 'quantity', opts)),
                       lines: ls, key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        if (isSet(r, 'deleted_at')) {
            out.push({ title: tx(d, 'batch.writtenOff'), lines: [], reason: typed(r.new?.['delete_reason']), key: true, weight: 95 })
            continue
        }
        if (isSet(r, 'import_permit_verified_at')) {
            out.push({ title: tx(d, 'batch.permitVerified'), lines: valueLines(d, r, { import_permit_ref: r.new?.['import_permit_ref'] ?? null }, opts),
                       key: true, weight: 60 })
            continue
        }
        if (isSet(r, 'source_reason_recorded_at')) {
            const ls = valueLines(d, r, { source_reason_code: r.new?.['source_reason_code'] ?? null }, opts)
            out.push({ title: tx(d, 'batch.sourceReason'), lines: ls, reason: typed(r.new?.['source_reason_note']), key: true, weight: 60 })
            continue
        }
        const skip = new Set(['remaining_qty', 'deleted_at', 'deleted_by', 'delete_reason', 'import_permit_verified_at',
            'import_permit_verified_by', 'source_reason_recorded_at', 'source_reason_recorded_by'])
        let title: string | null = null
        if (changed(r, 'stage')) {
            const to = enumLabel(d, 'inbound_batches', 'stage', str(r, 'stage', 'new') ?? '')
            const from = enumLabel(d, 'inbound_batches', 'stage', str(r, 'stage', 'old') ?? '')
            const order = ['Awaiting processing', 'Processing started', 'Fully processed']
            title = order.indexOf(to) < order.indexOf(from) ? tx(d, 'batch.stageBack')
                : to === 'Fully processed' ? tx(d, 'batch.stageDone') : tx(d, 'batch.stageStarted')
            skip.add('stage')
        } else if (changed(r, 'pricing_status') && str(r, 'pricing_status', 'new') === 'final') {
            title = tx(d, 'batch.priceFinal')
        }
        const ls = changeLines(d, r, opts, skip)
        if (title) out.push({ title, lines: ls, key: true, weight: 60 })
        else if (ls.length) out.push({ title: tx(d, 'batch.edited'), lines: ls, key: false, weight: 30 })
    }

    // ② 库存流水
    for (const r of by('inventory_movements')) {
        const type = str(r, 'movement_type')
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const ls = valueLines(d, r, r.new, opts, new Set(['movement_type', 'occurred_at', 'notes', 'run_id', ...skipBatch]))
        const run = refLabel(r, 'run_id')
        if (run) ls.push({ t: 'value', label: fieldMeta(d, 'inventory_movements', 'run_id')[0], value: { text: run } })
        const notes = typed(r.new?.['notes'])
        if (notes) ls.push({ t: 'value', label: fieldMeta(d, 'inventory_movements', 'notes')[0], value: notes })
        if (refEnded(r, 'run_id')) ls.push({ t: 'note', text: tx(d, 'batch.runRolledBack') })
        out.push({ title: tx(d, 'batch.movement', { type: type ? enumLabel(d, 'inventory_movements', 'movement_type', type) : '' }),
                   lines: ls, key: true, weight: 40 })
    }

    // ③ 价格
    for (const r of by('price_history')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const img = imgOf(r)
        const ls: Line[] = [{ t: 'change', label: fieldMeta(d, 'inbound_batches', 'unit_price')[0],
            old: formatValue(d, 'price_history', 'old_unit_price', r.new?.['old_unit_price'], img, r.refs, 'INSERT', opts),
            new: formatValue(d, 'price_history', 'new_unit_price', r.new?.['new_unit_price'], img, r.refs, 'INSERT', opts) }]
        ls.push(...valueLines(d, r, r.new, opts, new Set(['old_unit_price', 'new_unit_price', 'notes', ...skipBatch])))
        out.push({ title: tx(d, 'batch.priceChanged'), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 70 })
    }

    // ④ 加工:这个批次被用了、被产出了、分到了成本(批次这一边的说法)
    for (const r of by('processing_inputs', 'processing_outputs', 'batch_processing_cost_allocations')) {
        const run = refLabel(r, 'run_id') ?? tx(d, 'value.unnamed', { thing: thing(d, 'processing_runs') })
        const ended = refEnded(r, 'run_id')
        let title: string
        let ls: Line[]
        if (r.table === 'processing_inputs') {
            title = r.op === 'INSERT' ? tx(d, 'batch.usedIn', { run }) : tx(d, 'batch.useChanged')
            ls = r.op === 'UPDATE' ? changeLines(d, r, opts) : valueLines(d, r, r.new ?? r.old, opts, new Set(['run_id', ...skipBatch]))
        } else if (r.table === 'processing_outputs') {
            const costOnly = r.op === 'UPDATE' && (r.cols ?? []).every((c) => ['allocated_cost_base', 'unit_cost_base', 'cost_incomplete'].includes(c))
            title = r.op === 'INSERT' ? tx(d, 'batch.producedBy', { run }) : costOnly ? tx(d, 'batch.costFrom', { run }) : tx(d, 'batch.useChanged')
            ls = r.op === 'UPDATE' ? changeLines(d, r, opts) : valueLines(d, r, r.new ?? r.old, opts, new Set(['run_id', ...skipBatch]))
        } else {
            title = tx(d, 'batch.costFrom', { run })
            ls = r.op === 'UPDATE' ? changeLines(d, r, opts) : valueLines(d, r, r.new ?? r.old, opts, new Set(['run_id', ...skipBatch]))
        }
        if (ended) ls.push({ t: 'note', text: tx(d, 'batch.runRolledBack') })
        out.push({ title, lines: ls, key: r.op !== 'UPDATE', weight: 80 })
    }

    // ⑤ 金属含量(整组替换已经并成了改动)
    for (const r of by('inbound_batch_metals', 'output_batch_metals', 'pricing_term_commitment_metals')) {
        const metal = dictName(d, r, 'metal')
        const skip = new Set(['metal', 'commitment_id', ...skipBatch])
        if (r.table === 'pricing_term_commitment_metals') {
            out.push({ title: withPart(tx(d, 'po.termsCommitted'), metal), lines: r.op === 'UPDATE' ? changeLines(d, r, opts, skip) : valueLines(d, r, r.new ?? r.old, opts, skip), key: false, weight: 35 })
            continue
        }
        const title = tx(d, r.op === 'INSERT' ? 'batch.metalRecorded' : r.op === 'DELETE' ? 'batch.metalRemoved' : 'batch.metalsChanged')
        const ls = r.op === 'UPDATE' ? changeLines(d, r, opts, skip) : valueLines(d, r, r.op === 'DELETE' ? r.old : r.new, opts, skip)
        out.push({ title: withPart(title, metal), lines: ls, key: false, weight: 45 })
    }

    // ⑥ 化验与它的金属
    const assays = by('assay_results')
    const assayMetals = by('assay_result_metals')
    for (const r of assays) {
        const skip = new Set(['applied_at', 'applied_by', 'deleted_at', 'code', ...skipBatch])
        const code = str(r, 'code')
        if (r.op === 'INSERT') {
            const ls = valueLines(d, r, r.new, opts, skip)
            const id = typeof r.key?.['id'] === 'string' ? r.key['id'] : null
            for (const m of assayMetals.filter((x) => x.op === 'INSERT' && str(x, 'assay_result_id') === id)) {
                const pct = formatValue(d, 'assay_result_metals', 'content_pct', m.new?.['content_pct'], imgOf(m), m.refs, 'INSERT', opts)
                ls.push({ t: 'value', label: dictName(d, m, 'metal'), value: pct.empty || pct.restricted ? pct : { text: `${pct.text}%` } })
            }
            out.push({ title: withPart(tx(d, 'batch.assayRecorded'), code), lines: ls, key: true, weight: 75 })
            continue
        }
        if (r.op === 'DELETE' || isSet(r, 'deleted_at')) { out.push({ title: withPart(tx(d, 'batch.assayDeleted'), code), lines: [], key: true, weight: 75 }); continue }
        if (isSet(r, 'applied_at')) { out.push({ title: withPart(tx(d, 'batch.assayApplied'), code), lines: changeLines(d, r, opts, skip), key: true, weight: 75 }); continue }
        if (isCleared(r, 'applied_at')) { out.push({ title: withPart(tx(d, 'batch.assayWithdrawn'), code), lines: changeLines(d, r, opts, skip), key: true, weight: 75 }); continue }
        const ls = changeLines(d, r, opts, skip)
        if (ls.length) out.push({ title: withPart(tx(d, 'batch.assayChanged'), code), lines: ls, key: false, weight: 40 })
    }
    for (const m of assayMetals) {
        if (m.op === 'INSERT' && assays.some((a) => a.op === 'INSERT' && a.key?.['id'] === str(m, 'assay_result_id'))) continue
        const metal = dictName(d, m, 'metal')
        const ls = m.op === 'UPDATE' ? changeLines(d, m, opts, new Set(['metal', 'assay_result_id']))
            : valueLines(d, m, m.op === 'DELETE' ? m.old : m.new, opts, new Set(['metal', 'assay_result_id']))
        out.push({ title: withPart(tx(d, 'batch.assayChanged'), metal), lines: ls, key: false, weight: 40 })
    }

    // ⑦ 安全状态(整组替换:前后一样的已经抵消)
    for (const r of by('inbound_batch_safety_states', 'output_batch_safety_states')) {
        const state = dictName(d, r, 'safety_state_code')
        const title = tx(d, r.op === 'DELETE' ? 'batch.safetyRemoved' : 'batch.safetyAdded')
        out.push({ title: withPart(title, state), lines: [], key: false, weight: 45 })
    }

    // ⑧ 收货定价申请 · 预付款 · 运费 · 付款 · 附件
    for (const r of by('receipt_price_requests')) {
        const id = typeof r.key?.['id'] === 'string' ? r.key['id'] as string : undefined
        const skip = new Set(['status', 'decided_at', 'decided_by', 'withdrawn_at', 'withdrawn_by', 'withdraw_reason', 'snapshot',
            'decision_notes', 'notes', ...skipBatch])
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'batch.priceRequested'), lines: valueLines(d, r, r.new, opts, skip), reason: typed(r.new?.['notes']),
                       key: true, weight: 70, recordId: id })
        } else if (isSet(r, 'withdrawn_at')) {
            out.push({ title: tx(d, 'batch.priceRequestWithdrawn'), lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 70, recordId: id })
        } else {
            const st = changed(r, 'status') ? str(r, 'status', 'new') : null
            out.push({ title: st ? withPart(tx(d, 'batch.priceRequestChanged'), enumLabel(d, 'receipt_price_requests', 'status', st)) : tx(d, 'batch.priceRequestChanged'),
                       lines: changeLines(d, r, opts, skip), reason: typed(r.new?.['decision_notes']), key: !!st, weight: 70, recordId: id })
        }
    }
    const simple: [string, TrailTextKey][] = [['prepayment_applications', 'batch.prepayment'], ['freight_allocations', 'batch.freight'],
        ['payment_allocations', 'batch.payment'], ['sales_settlements', 'batch.settlement'], ['sales_attribution_log', 'batch.saleAttributed'],
        ['sales_record_movements', 'batch.saleStock'], ['invoice_lines', 'batch.invoiced']]
    for (const [t, key] of simple) {
        for (const r of by(t)) {
            if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
            const ls = valueLines(d, r, r.new, opts, new Set(['note', 'notes', 'sales_record_id', ...skipBatch]))
            out.push({ title: tx(d, key), lines: ls, reason: typed(r.new?.['note'] ?? r.new?.['notes']), key: t !== 'sales_record_movements',
                       weight: t === 'sales_record_movements' ? 15 : 50 })
        }
    }
    for (const r of by('finance_attachments')) {
        // AUDIT-TRAIL-1b-2:文件名是一个人敲的字 —— 标题后面 typed 的那一段,不拼进标题(与客户 / 供应商附件同一条)
        const part = typed(str(r, 'file_name'))
        if (r.op === 'INSERT') out.push({ title: tx(d, 'batch.attachmentAdded'), part, lines: [], key: false, weight: 30 })
        else if (r.op === 'DELETE' || isSet(r, 'deleted_at')) out.push({ title: tx(d, 'batch.attachmentRemoved'), part, lines: [], key: false, weight: 30 })
        else out.push(describeGeneric(d, r, opts))
    }

    // ⑨ 销毁证书与它的签发
    for (const r of by('certificates_of_destruction')) {
        const code = str(r, 'code')
        // 证书在整批加工完的那一刻自己生下来(pending),签发是后来的另一件事
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, str(r, 'status', 'new') === 'issued' ? 'batch.codIssued' : 'batch.codPending'), code),
                                          lines: valueLines(d, r, r.new, opts, new Set(['code', 'status', 'snapshot', ...skipBatch])), key: true, weight: 75 })
        else if (changed(r, 'status') && str(r, 'status', 'new') === 'issued')
            out.push({ title: withPart(tx(d, 'batch.codIssued'), code), lines: [], key: true, weight: 75 })
        else if (isSet(r, 'voided_at')) out.push({ title: withPart(tx(d, 'batch.codVoided'), code), lines: [], reason: typed(r.new?.['void_reason']), key: true, weight: 75 })
        else {
            const ls = changeLines(d, r, opts, new Set(['snapshot']))
            if (ls.length) out.push({ title: withPart(tx(d, 'batch.codChanged'), code), lines: ls, key: false, weight: 40 })
        }
    }
    for (const r of by('cod_issues')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'batch.codPdf'), refLabel(r, 'cod_id')), lines: [], key: true, weight: 60 })
    }

    // ⑩ 销售 · 预留 · 发货 · 追溯报告
    for (const r of by('sales_records')) {
        if (r.op === 'INSERT') {
            const ls = valueLines(d, r, r.new, opts, new Set(['quantity', 'notes', 'cogs_entry_id', ...skipBatch]))
            if (isEmpty(imgOf(r)['cogs_entry_id'] ?? null)) ls.push({ t: 'note', text: tx(d, 'batch.noCogs') })
            out.push({ title: withPart(tx(d, 'batch.sold'), qtyText(d, r, 'quantity', opts)), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 85 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'batch.saleChanged'), lines: ls, key: false, weight: 40 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('sales_order_reservations')) {
        const skip = new Set(['released_at', 'released_by', 'consumed_at', 'consumed_by', 'release_reason', ...skipBatch])
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'batch.reserved'), qtyText(d, r, 'qty', opts)), lines: valueLines(d, r, r.new, opts, new Set([...skip, 'qty'])), key: true, weight: 60 })
        else if (isSet(r, 'released_at')) out.push({ title: tx(d, 'batch.reservationReleased'), lines: [], reason: typed(r.new?.['release_reason']), key: true, weight: 60 })
        else if (isSet(r, 'consumed_at')) out.push({ title: tx(d, 'batch.reservationUsed'), lines: [], key: true, weight: 55 })
        else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('shipment_lines')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'batch.shipped'), refLabel(r, 'shipment_id')),
                   lines: valueLines(d, r, r.new, opts, new Set(['shipment_id', 'reservation_id', 'sales_record_id', ...skipBatch])), key: true, weight: 80 })
    }
    for (const r of by('traceability_report_issues')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'batch.reportIssued'), str(r, 'code')), lines: [], key: true, weight: 60 })
    }
    return out
}

// ── 工单 ────────────────────────────────────────────────────────────────────
function describeWorkOrder(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const wo = by('work_orders')
    const hist = by('work_order_history')
    const created = wo.find((r) => r.op === 'INSERT')
    const statusBlock = (r: TrailRow, to: string | null): Block2 | null => {
        const id = typeof r.key?.['id'] === 'string' ? r.key['id'] as string : undefined
        if (to === 'released') return { title: tx(d, 'wo.released'), lines: [], key: true, weight: 90, recordId: id }
        if (to === 'closed') return { title: tx(d, 'wo.closed'), lines: [], reason: typed(r.new?.['close_reason']), key: true, weight: 90, recordId: id }
        if (to === 'cancelled') return { title: tx(d, 'wo.cancelled'), lines: [], reason: typed(r.new?.['cancel_reason']), key: true, weight: 90, recordId: id }
        return null
    }
    if (created) {
        const ls = valueLines(d, created, created.new, opts, new Set(['code', 'status', 'closed_at', 'closed_by', 'close_reason', 'cancelled_at', 'cancelled_by', 'cancel_reason']))
        for (const l of by('work_order_lines').filter((x) => x.op === 'INSERT')) {
            ls.push({ t: 'value', label: refLabel(l, 'material_id') ?? cap(thing(d, 'work_order_lines')), value: formatValue(d, 'work_order_lines', 'planned_qty', l.new?.['planned_qty'], imgOf(l), l.refs, 'INSERT', opts) })
        }
        for (const e of by('work_order_expected_outputs').filter((x) => x.op === 'INSERT')) {
            ls.push({ t: 'value', label: refLabel(e, 'material_id') ?? cap(thing(d, 'work_order_expected_outputs')), value: formatValue(d, 'work_order_expected_outputs', 'expected_qty', e.new?.['expected_qty'], imgOf(e), e.refs, 'INSERT', opts) })
        }
        out.push({ title: tx(d, 'wo.created'), lines: ls, key: true, weight: 100, recordId: typeof created.key?.['id'] === 'string' ? created.key['id'] as string : undefined })
    }
    for (const r of wo) {
        if (r === created) continue
        const b = changed(r, 'status') ? statusBlock(r, str(r, 'status', 'new')) : null
        if (b) { out.push(b); continue }
        const ls = changeLines(d, r, opts, new Set(['closed_at', 'closed_by', 'cancelled_at', 'cancelled_by']))
        if (ls.length) out.push({ title: tx(d, 'wo.edited'), lines: ls, key: false, weight: 30 })
    }
    const statusSeen = out.some((b) => b.weight >= 90)
    for (const h of hist) {
        const ct = str(h, 'change_type', 'new') ?? ''
        if (ct === 'created' && created) continue
        if (['released', 'closed', 'cancelled'].includes(ct) && statusSeen) continue
        if (ct === 'created') { out.push({ title: tx(d, 'wo.created'), lines: [], key: true, weight: 100 }); continue }
        if (['released', 'closed', 'cancelled'].includes(ct)) {
            out.push({ title: tx(d, ct === 'released' ? 'wo.released' : ct === 'closed' ? 'wo.closed' : 'wo.cancelled'), lines: [], reason: typed(h.new?.['amend_reason']), key: true, weight: 90 })
            continue
        }
        const known = d.enums['work_order_history#change_type']?.[ct]
        out.push({ title: withPart(tx(d, 'wo.amended'), known ? known.toLowerCase() : null), lines: woHistoryDiff(d, h, opts),
                   reason: typed(h.new?.['amend_reason']), key: true, weight: 70 })
    }
    if (!created) {
        for (const r of [...by('work_order_lines'), ...by('work_order_expected_outputs')]) {
            const lineT = r.table === 'work_order_lines'
            const key: TrailTextKey = lineT ? (r.op === 'INSERT' ? 'wo.lineAdded' : r.op === 'DELETE' ? 'wo.lineRemoved' : 'wo.lineChanged')
                : (r.op === 'INSERT' ? 'wo.expectedAdded' : r.op === 'DELETE' ? 'wo.expectedRemoved' : 'wo.expectedChanged')
            const skip = new Set(['work_order_id', 'material_id'])
            const ls = r.op === 'UPDATE' ? changeLines(d, r, opts, skip) : valueLines(d, r, r.op === 'DELETE' ? r.old : r.new, opts, skip)
            out.push({ title: withPart(tx(d, key), refLabel(r, 'material_id')), lines: ls, key: false, weight: 40 })
        }
    }
    return out
}
function woHistoryDiff(d: TrailDict, h: TrailRow, opts: BuildOptions): Line[] {
    const out: Line[] = []
    const n = h.new ?? {}
    for (const bare of ['qty', 'scheduled_date', 'notes']) {
        const o = n['old_' + bare], v = n['new_' + bare]
        if (JSON.stringify(o ?? null) === JSON.stringify(v ?? null)) continue
        out.push({ t: 'change', label: cap(fieldMeta(d, 'work_order_history', 'new_' + bare)[0].replace(/^New /, '')),
            old: formatValue(d, 'work_order_history', 'old_' + bare, o, n, h.refs, 'UPDATE', opts),
            new: formatValue(d, 'work_order_history', 'new_' + bare, v, n, h.refs, 'UPDATE', opts) })
    }
    return out
}

// ── 盘点 ────────────────────────────────────────────────────────────────────
function describeStocktake(d: TrailDict, rows: TrailRow[], opts: BuildOptions, subject?: string | null): Block2[] {
    const out: Block2[] = []
    const onBatch = subject === 'inbound_batch' || subject === 'output_batch'
    const by = (t: string) => rows.filter((r) => r.table === t)
    for (const r of by('stocktakes')) {
        const id = typeof r.key?.['id'] === 'string' ? r.key['id'] as string : undefined
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'st.started'), lines: valueLines(d, r, r.new, opts, new Set(['code', 'status', 'posted_at', 'cancelled_at', 'cancelled_by', 'cancel_reason', 'deleted_at', 'deleted_by', 'delete_reason'])),
                       key: true, weight: 100, recordId: id })
        } else if ((changed(r, 'status') && str(r, 'status', 'new') === 'posted') || (r.prelog && (r.cols ?? []).includes('posted_at'))) {
            out.push({ title: tx(d, 'st.posted'), lines: [], key: true, weight: 90, recordId: id })
        } else if ((changed(r, 'status') && str(r, 'status', 'new') === 'cancelled') || (r.prelog && (r.cols ?? []).includes('cancelled_at'))) {
            out.push({ title: tx(d, 'st.cancelled'), lines: [], reason: typed(r.new?.['cancel_reason']), key: true, weight: 90, recordId: id })
        } else {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'st.edited'), lines: ls, key: false, weight: 30 })
        }
    }
    // 清点:一次录数 = stocktake_counts 的一行(只增不改)+ stocktake_lines 那一格被覆盖。两边都在就只说一次(以清点为准)
    const counts = by('stocktake_counts')
    const countedLines = new Set(counts.map((c) => str(c, 'stocktake_line_id')))
    for (const r of [...counts, ...by('stocktake_lines')]) {
        if (r.table === 'stocktake_lines' && countedLines.has(typeof r.key?.['id'] === 'string' ? r.key['id'] as string : '')) continue
        const batchCol = typeof imgOf(r)['inbound_batch_id'] === 'string' ? 'inbound_batch_id' : 'output_batch_id'
        const skip = new Set(['stocktake_id', 'stocktake_line_id', 'inbound_batch_id', 'output_batch_id', 'counted_at', 'counted_by'])
        const ls = r.op === 'UPDATE' ? changeLines(d, r, opts, skip) : valueLines(d, r, r.op === 'DELETE' ? r.old : r.new, opts, skip)
        if (r.op === 'DELETE') { out.push({ title: tx(d, 'st.lineRemoved'), lines: ls, key: false, weight: 40 }); continue }
        if (onBatch) {
            out.push({ title: tx(d, 'batch.counted', { code: refLabel(r, 'stocktake_id') ?? tx(d, 'value.unnamed', { thing: thing(d, 'stocktakes') }) }),
                       lines: ls, key: true, weight: 60 })
        } else {
            out.push({ title: withPart(tx(d, r.op === 'UPDATE' ? 'st.recount' : 'st.count'), refLabel(r, batchCol)), lines: ls, key: false, weight: 50 })
        }
    }
    return out
}

// ── 设备(资产卡 · 保养维修 · 停机 · 保养周期 · 交接班里提到的停机)──────────────
function describeEquipment(d: TrailDict, rows: TrailRow[], opts: BuildOptions, subject?: string | null): Block2[] {
    const out: Block2[] = []
    const onPage = subject === 'equipment'
    const by = (t: string) => rows.filter((r) => r.table === t)
    const skipEq = onPage ? ['equipment_id'] : []
    for (const r of by('fixed_assets')) {
        if (r.op === 'INSERT') out.push({ title: tx(d, 'eq.cardCreated'), lines: valueLines(d, r, r.new, opts), key: true, weight: 90 })
        else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'eq.cardEdited'), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('equipment_maintenance')) {
        const skip = new Set(['kind', 'notes', ...skipEq])
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, str(r, 'kind') === 'repair' ? 'eq.repair' : 'eq.service'), lines: valueLines(d, r, r.new, opts, skip),
                       reason: typed(r.new?.['notes']), key: true, weight: 80 })
        } else if (r.op === 'DELETE') {
            out.push({ title: tx(d, 'eq.workRemoved'), lines: valueLines(d, r, r.old, opts, skip), key: true, weight: 70 })
        } else if (changed(r, 'capitalised') && r.new?.['capitalised'] === true) {
            out.push({ title: tx(d, 'eq.capitalised'), lines: changeLines(d, r, opts, new Set(['capitalised', 'capitalisation_reason'])),
                       reason: typed(r.new?.['capitalisation_reason']), key: true, weight: 70 })
        } else {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'eq.workChanged'), lines: ls, key: false, weight: 40 })
        }
    }
    for (const r of by('equipment_downtime')) {
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'eq.down'), lines: valueLines(d, r, r.new, opts, new Set(['duration', 'notes', ...skipEq])),
                       reason: typed(r.new?.['notes']), key: true, weight: 80 })
        } else if (isSet(r, 'ended_at')) {
            out.push({ title: tx(d, 'eq.up'), lines: valueLines(d, r, { ended_at: r.new?.['ended_at'] ?? null }, opts), key: true, weight: 80 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, new Set(['duration']))
            if (ls.length) out.push({ title: tx(d, 'eq.downChanged'), lines: ls, key: false, weight: 40 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('equipment_service_intervals')) {
        const kind = str(r, 'kind')
        const skip = new Set(['kind', ...skipEq])
        const key: TrailTextKey = r.op === 'INSERT' ? 'eq.intervalSet' : r.op === 'DELETE' ? 'eq.intervalRemoved' : 'eq.intervalChanged'
        const ls = r.op === 'UPDATE' ? changeLines(d, r, opts, skip) : valueLines(d, r, r.op === 'DELETE' ? r.old : r.new, opts, skip)
        out.push({ title: withPart(tx(d, key), kind ? enumLabel(d, 'equipment_service_intervals', 'kind', kind) : null), lines: ls, key: r.op !== 'UPDATE', weight: 50 })
    }
    for (const r of by('shift_handover_equipment_refs')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'eq.handoverNote'), lines: valueLines(d, r, r.new, opts), key: false, weight: 30 })
    }
    return out
}

// ── 交接班 ──────────────────────────────────────────────────────────────────
function describeHandover(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const items = by('shift_handover_items')
    const refs = by('shift_handover_equipment_refs')
    const itemLine = (r: TrailRow): Line => ({ t: 'value', label: refLabel(r, 'item_type_code') ?? cap(thing(d, 'shift_handover_items')),
        value: typed(r.new?.['body'] ?? r.old?.['body']) ?? { text: tx(d, 'empty'), empty: true } })
    const refLine = (r: TrailRow): Line => ({ t: 'value', label: fieldMeta(d, 'shift_handover_equipment_refs', 'downtime_id')[0],
        value: formatValue(d, 'shift_handover_equipment_refs', 'downtime_id', imgOf(r)['downtime_id'], imgOf(r), r.refs, r.op, opts) })
    const created = by('shift_handovers').find((r) => r.op === 'INSERT')
    if (created) {
        const ls = valueLines(d, created, created.new, opts, new Set(['notes', 'acknowledged_at', 'acknowledged_by', 'submitted_at', 'submitted_by']))
        ls.push(...items.filter((r) => r.op === 'INSERT').map(itemLine), ...refs.filter((r) => r.op === 'INSERT').map(refLine))
        out.push({ title: tx(d, 'ho.submitted'), lines: ls, reason: typed(created.new?.['notes']), key: true, weight: 100 })
    }
    for (const r of by('shift_handovers')) {
        if (r === created) continue
        if (isSet(r, 'acknowledged_at')) { out.push({ title: tx(d, 'ho.acknowledged'), lines: [], key: true, weight: 90 }); continue }
        const ls = changeLines(d, r, opts)
        if (ls.length) out.push({ title: tx(d, 'ho.edited'), lines: ls, key: false, weight: 30 })
    }
    if (!created) {
        for (const r of items) out.push({ title: tx(d, 'ho.item'), lines: [itemLine(r)], key: false, weight: 40 })
        for (const r of refs) out.push({ title: tx(d, 'ho.downtime'), lines: [refLine(r)], key: false, weight: 40 })
    }
    return out
}

// ── 仓库申请(注销 · 加工回滚 · 证书作废)──────────────────────────────────
function wrKind(d: TrailDict, r: TrailRow): string {
    const k = str(r, 'kind') ?? ''
    return tx(d, k.startsWith('write_off') ? 'wr.kind.writeOff' : k === 'rollback' ? 'wr.kind.rollback' : k === 'cod_void' ? 'wr.kind.codVoid' : 'wr.kind.other')
}
function describeWarehouseRequest(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        const id = typeof r.key?.['id'] === 'string' ? r.key['id'] as string : undefined
        const kind = wrKind(d, r)
        const skip = new Set(['kind', 'status', 'label', 'reason', 'snapshot', 'decided_at', 'decided_by', 'decision_notes', 'executed_at',
            'result_entry_ids', 'withdrawn_at', 'withdrawn_by', 'withdraw_reason'])
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'wr.raised', { kind }), lines: valueLines(d, r, r.new, opts, skip), reason: typed(r.new?.['reason']),
                       key: true, weight: 90, recordId: id })
        } else if (isSet(r, 'withdrawn_at') || (changed(r, 'status') && str(r, 'status', 'new') === 'withdrawn')) {
            out.push({ title: tx(d, 'wr.withdrawn', { kind }), lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 90, recordId: id })
        } else if (changed(r, 'status') && str(r, 'status', 'new') === 'approved') {
            out.push({ title: tx(d, 'wr.approved', { kind }), lines: changeLines(d, r, opts, skip), reason: typed(r.new?.['decision_notes']), key: true, weight: 90, recordId: id })
        } else if (changed(r, 'status') && str(r, 'status', 'new') === 'rejected') {
            out.push({ title: tx(d, 'wr.rejected', { kind }), lines: [], reason: typed(r.new?.['decision_notes']), key: true, weight: 90, recordId: id })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, skip)
            if (ls.length) out.push({ title: tx(d, 'wr.changed', { kind }), lines: ls, key: false, weight: 40, recordId: id })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-2:报价 · 销售订单 · 发货单 · 客户 · 佣金协议 · 供应商与货代 · 集装箱 · 航段与港口 · 公司执照
// ════════════════════════════════════════════════════════════════════════════
/** 一句事件史的 detail 由写它的函数拼成"单号 · 其余"(SHP-2026-0001 · 12/12、INV-2026-0006 · 作废理由)。
 *  打头的是一个单号就放进标题;其余照原样作为一行"Details"(它常常夹着一个人写的理由,Q8:照原样)。 */
const DOC_CODE = /^[A-Z][A-Z0-9]{1,7}(?:-[A-Z0-9]{1,8})?-\d{4}-\d{2,}$/
function splitDetail(detail: string | null): { code: string | null; rest: string | null } {
    if (!detail || !detail.trim()) return { code: null, rest: null }
    const parts = detail.split(' · ')
    if (DOC_CODE.test(parts[0].trim())) return { code: parts[0].trim(), rest: parts.slice(1).join(' · ').trim() || null }
    return { code: null, rest: detail.trim() }
}
function detailLine(d: TrailDict, text: string | null): Line[] {
    const v = typed(text)
    return v ? [{ t: 'value', label: tx(d, 'label.details'), value: v }] : []
}
/** 签发档那一句的 "v2" → 2 */
function versionOf(detail: string | null): number | null {
    const m = detail?.trim().match(/^v(\d+)$/)
    return m ? Number(m[1]) : null
}
function idOf(r: TrailRow): string | undefined {
    return typeof r.key?.['id'] === 'string' ? r.key['id'] as string : undefined
}
function isDeleted(r: TrailRow): boolean {
    return r.op === 'DELETE' || isSet(r, 'deleted_at')
}
/** 订单 / 报价明细行的小标题:"Line 1 · 物料" */
function docLineHeading(d: TrailDict, r: TrailRow, table: string): string {
    const img = imgOf(r)
    const n = num(img['line_no'] ?? null)
    const base = n !== null ? tx(d, 'po.lineHeading', { n }) : cap(thing(d, table))
    const m = img['material_id']
    return typeof m === 'string' ? `${base} · ${refVal(d, table, 'material_id', m, r.refs).text}` : base
}
/** 明细行的逐行(新增时):数量 @ 单价 */
function docLineValue(d: TrailDict, r: TrailRow, table: string, opts: BuildOptions): Line {
    const img = imgOf(r)
    const q = formatValue(d, table, 'quantity', img['quantity'], img, r.refs, r.op, opts)
    const p = formatValue(d, table, 'unit_price', img['unit_price'], img, r.refs, r.op, opts)
    return { t: 'value', label: docLineHeading(d, r, table), value: { text: [q.text, p.empty ? '' : `@ ${p.text}`].filter(Boolean).join(' '), restricted: p.restricted } }
}

/** 明细按行号排(存下来的先后不一定是行号的先后)*/
function byLineNo(rows: TrailRow[]): TrailRow[] {
    return [...rows].sort((a, b) => (num(imgOf(a)['line_no'] ?? null) ?? 0) - (num(imgOf(b)['line_no'] ?? null) ?? 0))
}
/** 订单 / 报价的一行明细 → 一块。【行写进标题】("Line changed · Line 1 · 物料"),不另起一个小标题 ——
 *  一块排在别的事件后面时,它的标题就是它在那一条记录里的小标题;小标题若只剩 "Line 1",就说不出它是加了、改了还是删了。 */
function docLineBlocks(d: TrailDict, rows: TrailRow[], table: string, parentCol: string, opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const skip = new Set(['line_no', 'material_id', parentCol])
    for (const r of rows) {
        const which = docLineHeading(d, r, table)
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'po.lineAdded'), which), lines: valueLines(d, r, r.new, opts, skip), key: false, weight: 40 })
        else if (r.op === 'DELETE') out.push({ title: withPart(tx(d, 'po.lineRemoved'), which), lines: valueLines(d, r, r.old, opts, skip), key: false, weight: 40 })
        else {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: withPart(tx(d, 'po.lineChanged'), which), lines: ls, key: false, weight: 40 })
        }
    }
    return out
}
/** 建单那一次操作里,明细又被改过 / 删过:一个小标题("Line changed · Line 1 · 物料")+ 逐列 */
function sameOpLineEdits(d: TrailDict, rows: TrailRow[], table: string, opts: BuildOptions): Line[] {
    const out: Line[] = []
    for (const r of rows) {
        if (r.op === 'UPDATE') {
            const cl = changeLines(d, r, opts)
            if (cl.length) out.push({ t: 'heading', text: withPart(tx(d, 'po.lineChanged'), docLineHeading(d, r, table)) }, ...cl)
        } else if (r.op === 'DELETE') out.push({ t: 'heading', text: withPart(tx(d, 'po.lineRemoved'), docLineHeading(d, r, table)) })
    }
    return out
}
/** 新增的明细合起来的总额(数量 × 单价)—— 与采购单"raised · 1 line · 305,550.00 SGD"同一种写法。
 *  任一行受限或读不出数、或不知道币种,就不说总额(一个少算了的总额比没有总额坏)。 */
function docTotal(lines: TrailRow[], opts: BuildOptions): string[] {
    let sum = 0
    for (const r of lines) {
        const img = r.new ?? {}
        const q = num(img['quantity'] ?? null), p = num(img['unit_price'] ?? null)
        if (q === null || p === null || isRestricted(img['unit_price'])) return []
        sum += q * p
    }
    return opts.currency ? [`${NUM2.format(sum)} ${opts.currency}`] : []
}

// ── 报价 ────────────────────────────────────────────────────────────────────
const QUOTE_TABLES = new Set(['quotes', 'quote_lines', 'qt_issues', 'quote_history'])
function describeQuote(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const q = by('quotes'), lines = by('quote_lines'), iss = by('qt_issues'), hist = by('quote_history')
    const created = q.find((r) => r.op === 'INSERT')
    const histCreated = hist.find((h) => str(h, 'change_type', 'new') === 'created')
    const types = new Set(hist.map((h) => str(h, 'change_type', 'new')))
    // ① 建单(报价本身的新增与事件史的 created 是同一笔事务写的 —— 并成一句)
    if (created || histCreated) {
        const ins = lines.filter((r) => r.op === 'INSERT')
        const ls: Line[] = created ? valueLines(d, created, created.new, opts, new Set(['code', 'status', 'converted_order_id', 'decline_reason',
            'deleted_at', 'deleted_by', 'delete_reason'])) : []
        ls.push(...byLineNo(ins).map((r) => docLineValue(d, r, 'quote_lines', opts)))
        // 同一次操作里又改过、删过的明细(与采购单建单那一条同一个做法)—— 照常说出来,不当成建单的副产物吞掉
        ls.push(...sameOpLineEdits(d, lines, 'quote_lines', opts))
        const parts = ins.length ? [plural(d, 'po.lines.one', 'po.lines.many', ins.length), ...docTotal(ins, opts)] : []
        out.push({ title: [tx(d, 'qt.created'), ...parts].join(' · '), lines: ls, key: true, weight: 100 })
    }
    // ② 事件史:签发 · 谢绝 · 转成订单
    for (const h of hist) {
        const ct = str(h, 'change_type', 'new') ?? ''
        const detail = str(h, 'detail', 'new')
        if (ct === 'created') continue
        if (ct === 'issued') {
            const v = versionOf(detail) ?? num(iss.find((i) => i.op === 'INSERT')?.new?.['version'] ?? null)
            out.push({ title: v !== null ? tx(d, 'qt.issued', { version: v }) : tx(d, 'qt.issuedPlain'), lines: v !== null ? [] : detailLine(d, detail), key: true, weight: 90 })
        } else if (ct === 'declined') {
            out.push({ title: tx(d, 'qt.declined'), lines: [], reason: typed(detail), key: true, weight: 90 })
        } else if (ct === 'converted') {
            const { code, rest } = splitDetail(detail)
            out.push({ title: code ? tx(d, 'qt.converted', { code }) : tx(d, 'qt.convertedPlain'), lines: detailLine(d, rest), key: true, weight: 90 })
        } else {
            out.push({ title: tx(d, 'qt.statusChanged'), lines: detailLine(d, detail), key: true, weight: 80 })
        }
    }
    // ③ 签发档(记录开始之后,与事件史同一笔 —— 事件史在就只说一次)
    if (!types.has('issued')) for (const r of iss) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'qt.issued', { version: num(r.new?.['version'] ?? null) ?? '' }), lines: [], key: true, weight: 90 })
    }
    // ④ 报价本身的改动
    for (const r of q) {
        if (r === created) continue
        if (isDeleted(r)) { out.push({ title: tx(d, 'qt.deleted'), lines: [], reason: typed(r.new?.['delete_reason']), key: true, weight: 90 }); continue }
        const skip = new Set(['status', 'converted_order_id', 'decline_reason'])
        const ls = changeLines(d, r, opts, skip)
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        if (to && !types.has(to === 'converted' ? 'converted' : to)) {
            ls.unshift({ t: 'change', label: fieldMeta(d, 'quotes', 'status')[0], old: formatValue(d, 'quotes', 'status', r.old?.['status'], imgOf(r), r.refs, r.op, opts),
                new: formatValue(d, 'quotes', 'status', r.new?.['status'], imgOf(r), r.refs, r.op, opts) })
            out.push({ title: tx(d, 'qt.statusChanged'), lines: ls, reason: typed(r.new?.['decline_reason']), key: true, weight: 70 })
        } else if (ls.length) out.push({ title: tx(d, 'qt.edited'), lines: ls, key: false, weight: 30 })
    }
    // ⑤ 明细(建单那一笔之外)
    if (!created && !histCreated) out.push(...docLineBlocks(d, lines, 'quote_lines', 'quote_id', opts))
    return out
}

// ── 销售订单(它的事件史就是这一页的主线;预留、签发档、状态戳与事件史同一笔写的,只说一次)──────────────
const SO_TABLES = new Set(['sales_orders', 'sales_order_lines', 'sales_order_history', 'so_issues', 'shipping_releases', 'shipping_release_lines'])
const SO_AMEND = new Set(['header_update', 'line_update', 'line_add', 'line_remove', 'line_added', 'line_changed', 'line_removed'])
/** 订单事件史的一行 → 一块。在订单页上是主线;在产出批次页上是往上一跳够到的那几行(标题后面点名订单)。 */
function soHistoryBlock(d: TrailDict, h: TrailRow, opts: BuildOptions): Block2 {
    const ct = str(h, 'change_type', 'new') ?? ''
    const detail = str(h, 'detail', 'new')
    const { code, rest } = splitDetail(detail)
    const k = (key: TrailTextKey, lines: Line[] = [], reason: Val | null = null, weight = 80): Block2 => ({ title: tx(d, key), lines, reason, key: true, weight })
    switch (ct) {
        case 'created': return k('so.created', [], null, 100)   // detail 是单号本身(或一句数据库写的补记)—— 不上屏
        case 'converted_from_quote': return { ...k('so.createdFromQuote', [], null, 100), title: code || detail ? tx(d, 'so.createdFromQuote', { code: code ?? detail ?? '' }) : tx(d, 'so.created') }
        case 'confirmed': return k('so.confirmed', detailLine(d, detail))
        case 'closed': return k('so.closed', detailLine(d, detail))
        case 'cancelled': return k('so.cancelled', [], typed(detail), 90)
        case 'issued': {
            const v = versionOf(detail)
            return v !== null ? { ...k('so.issued'), title: tx(d, 'so.issued', { version: v }) } : k('so.issuedPlain', detailLine(d, detail))
        }
        case 'reserved': return k('so.reserved', detailLine(d, detail), null, 70)
        case 'released': return k('so.released', detailLine(d, detail), null, 70)
        case 'invoiced': return { ...k('so.invoiced', detailLine(d, rest)), title: withPart(tx(d, 'so.invoiced'), code) }
        case 'invoice_voided': return { ...k('so.invoiceVoided', [], typed(rest)), title: withPart(tx(d, 'so.invoiceVoided'), code) }
        case 'shipped': return { ...k('so.shipped', detailLine(d, rest)), title: withPart(tx(d, 'so.shipped'), code) }
        case 'credit_noted': return { ...k('so.creditNoted', detailLine(d, rest)), title: withPart(tx(d, 'so.creditNoted'), code) }
    }
    // 改单的四种(与 SO-1 留下的三个空位):小标题说第几行,下面是前后值,理由是改单时填的那一句
    const ls: Line[] = []
    const n = h.new ?? {}
    // 第几行写进标题(不另起小标题 —— 排在别的事件后面时,小标题只剩 "Line 1" 就说不出这是一次改单)
    const lineNo = num(n['line_no'] ?? null)
    for (const bare of ['quantity', 'unit_price', 'notes', 'terms_text']) {
        const o = n['old_' + bare], v = n['new_' + bare]
        if (JSON.stringify(o ?? null) === JSON.stringify(v ?? null)) continue
        ls.push({ t: 'change', label: cap(fieldMeta(d, 'sales_order_history', 'new_' + bare)[0].replace(/^New /, '')),
            old: formatValue(d, 'sales_order_history', 'old_' + bare, o, n, h.refs, 'UPDATE', opts),
            new: formatValue(d, 'sales_order_history', 'new_' + bare, v, n, h.refs, 'UPDATE', opts) })
    }
    ls.push(...detailLine(d, detail))
    const what: TrailTextKey = ct === 'line_add' || ct === 'line_added' ? 'po.lineAdded' : ct === 'line_remove' || ct === 'line_removed' ? 'po.lineRemoved'
        : ct === 'header_update' ? 'so.headerChanged' : 'po.lineChanged'
    const title = SO_AMEND.has(ct) ? withPart(tx(d, 'so.amended'), tx(d, what).toLowerCase()) : tx(d, 'so.amended')
    return { title: withPart(title, lineNo !== null ? tx(d, 'po.lineHeading', { n: lineNo }) : null), lines: ls,
             reason: typed(n['amend_reason']), key: true, weight: 70 }
}
function describeSalesOrder(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const so = by('sales_orders'), lines = by('sales_order_lines'), hist = by('sales_order_history'), iss = by('so_issues')
    const resv = by('sales_order_reservations'), rel = by('shipping_releases'), relLines = by('shipping_release_lines')
    const created = so.find((r) => r.op === 'INSERT')
    const types = new Set(hist.map((h) => str(h, 'change_type', 'new') ?? ''))
    const fromQuote = hist.find((h) => str(h, 'change_type', 'new') === 'converted_from_quote')
    // ① 建单:订单的新增 + 事件史的 created / converted_from_quote(同一笔、同一时刻)+ 这一笔里的明细与合同
    if (created || types.has('created') || fromQuote) {
        const ins = lines.filter((r) => r.op === 'INSERT')
        const ls: Line[] = created ? valueLines(d, created, created.new, opts, new Set(['code', 'status', 'confirmed_at', 'closed_at', 'cancelled_at',
            'cancel_reason', 'deleted_at', 'deleted_by', 'delete_reason', 'contract_id'])) : []
        ls.push(...byLineNo(ins).map((r) => docLineValue(d, r, 'sales_order_lines', opts)))
        // 同一次操作里又改过的明细:改单的事件史在的话由它说(带理由);不在就照常说出来
        if (![...types].some((t) => SO_AMEND.has(t))) ls.push(...sameOpLineEdits(d, lines, 'sales_order_lines', opts))
        for (const c of by('contract_document_terms').filter((x) => x.op === 'INSERT')) ls.push({ t: 'note', text: contractLinked(d, c) })
        const { code } = splitDetail(str(fromQuote ?? created ?? hist[0], 'detail', 'new'))
        const head = fromQuote && code ? tx(d, 'so.createdFromQuote', { code }) : tx(d, 'so.created')
        out.push({ title: [head, ...(ins.length ? [plural(d, 'po.lines.one', 'po.lines.many', ins.length), ...docTotal(ins, opts)] : [])].join(' · '), lines: ls, key: true, weight: 100,
                   recordId: created ? idOf(created) : undefined })
    }
    // ② 事件史的其余每一行(它就是这张单的主线)
    for (const h of hist) {
        const ct = str(h, 'change_type', 'new') ?? ''
        if (ct === 'created' || ct === 'converted_from_quote') continue
        out.push(soHistoryBlock(d, h, opts))
    }
    // ③ 订单本身的改动:状态由事件史说了的就不再说;其余是字段编辑
    for (const r of so) {
        if (r === created) continue
        if (isDeleted(r)) { out.push({ title: tx(d, 'so.deleted'), lines: [], reason: typed(r.new?.['delete_reason']), key: true, weight: 90 }); continue }
        // 改单的事件史(header_update)已经带着备注 / 条款的前后值与理由 —— 订单那一行同一次的改动不再说第二遍
        const skip = new Set(['status', 'confirmed_at', 'closed_at', 'cancelled_at', 'cancel_reason',
            ...(types.has('header_update') ? ['notes', 'terms_text'] : [])])
        const ls = changeLines(d, r, opts, skip)
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        if (to && !types.has(to)) {
            const key: TrailTextKey = to === 'confirmed' ? 'so.confirmed' : to === 'closed' ? 'so.closed' : to === 'cancelled' ? 'so.cancelled' : 'so.statusChanged'
            if (key === 'so.statusChanged') ls.unshift({ t: 'change', label: fieldMeta(d, 'sales_orders', 'status')[0],
                old: formatValue(d, 'sales_orders', 'status', r.old?.['status'], imgOf(r), r.refs, r.op, opts),
                new: formatValue(d, 'sales_orders', 'status', r.new?.['status'], imgOf(r), r.refs, r.op, opts) })
            out.push({ title: tx(d, key), lines: ls, reason: to === 'cancelled' ? typed(r.new?.['cancel_reason']) : null, key: true, weight: 85 })
        } else if (ls.length) out.push({ title: tx(d, 'so.edited'), lines: ls, key: false, weight: 30 })
    }
    // ④ 明细:改单那几种事件史已经带着前后值与理由 —— 在它们旁边的明细行改动不再逐列说第二遍
    if (!created && ![...types].some((t) => SO_AMEND.has(t))) out.push(...docLineBlocks(d, lines, 'sales_order_lines', 'sales_order_id', opts))
    // ⑤ 预留:事件史的 reserved / released / shipped 已经说了的,不说第二遍
    if (!hist.length) for (const r of resv) {
        const batch = refLabel(r, 'output_batch_id')
        const ls: Line[] = [{ t: 'value', label: fieldMeta(d, 'sales_order_reservations', 'sales_order_line_id')[0],
            value: formatValue(d, 'sales_order_reservations', 'sales_order_line_id', imgOf(r)['sales_order_line_id'], imgOf(r), r.refs, r.op, opts) }]
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'so.reserved'), [batch, qtyText(d, r, 'qty', opts)].filter(Boolean).join(' — ')), lines: ls, key: true, weight: 60 })
        else if (isSet(r, 'released_at')) out.push({ title: withPart(tx(d, 'so.released'), batch), lines: ls, reason: typed(r.new?.['release_reason']), key: true, weight: 60 })
        else if (isSet(r, 'consumed_at')) out.push({ title: withPart(tx(d, 'batch.reservationUsed'), batch), lines: ls, key: true, weight: 55 })
        else out.push(describeGeneric(d, r, opts))
    }
    // ⑥ 签发档(事件史的 issued 在就只说一次)
    if (!types.has('issued')) for (const r of iss) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'so.issued', { version: num(r.new?.['version'] ?? null) ?? '' }), lines: [], key: true, weight: 80 })
    }
    // ⑦ 发货放行(APR-5b):请求 · 撤回 · 批准 / 驳回(审批并进这一句)
    for (const r of rel) {
        const id = idOf(r)
        const skip = new Set(['status', 'label', 'decided_at', 'decided_by', 'decision_notes', 'withdrawn_at', 'withdrawn_by', 'withdraw_reason', 'sales_order_id'])
        if (r.op === 'INSERT') {
            const ls = valueLines(d, r, r.new, opts, skip)
            for (const l of relLines.filter((x) => x.op === 'INSERT')) ls.push({ t: 'value', label: fieldMeta(d, 'shipping_release_lines', 'sales_order_line_id')[0],
                value: formatValue(d, 'shipping_release_lines', 'sales_order_line_id', imgOf(l)['sales_order_line_id'], imgOf(l), l.refs, 'INSERT', opts) })
            out.push({ title: tx(d, 'so.releaseRequested'), lines: ls, key: true, weight: 80, recordId: id })
        } else if (isSet(r, 'withdrawn_at') || (changed(r, 'status') && str(r, 'status', 'new') === 'withdrawn')) {
            out.push({ title: tx(d, 'so.releaseWithdrawn'), lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 80, recordId: id })
        } else if (changed(r, 'status') && ['approved', 'rejected'].includes(str(r, 'status', 'new') ?? '')) {
            out.push({ title: tx(d, str(r, 'status', 'new') === 'approved' ? 'so.releaseApproved' : 'so.releaseRejected'), lines: [],
                       reason: typed(r.new?.['decision_notes']), key: true, weight: 80, recordId: id })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, skip)
            if (ls.length) out.push({ title: tx(d, 'so.releaseChanged'), lines: ls, key: false, weight: 40, recordId: id })
        } else out.push(describeGeneric(d, r, opts))
    }
    if (!rel.some((r) => r.op === 'INSERT')) for (const r of relLines) out.push(describeGeneric(d, r, opts))
    // ⑧ 合同挂接(建单那一笔之外)
    if (!created) for (const r of by('contract_document_terms')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: contractLinked(d, r), lines: [], key: true, weight: 60 })
    }
    return out
}

// ── 发货单 ──────────────────────────────────────────────────────────────────
function describeShipment(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const created = by('shipments').find((r) => r.op === 'INSERT')
    const lineLine = (r: TrailRow): Line => ({ t: 'value', label: refLabel(r, 'output_batch_id') ?? cap(thing(d, 'shipment_lines')),
        value: formatValue(d, 'shipment_lines', 'qty', imgOf(r)['qty'], imgOf(r), r.refs, r.op, opts) })
    if (created) {
        const ls = valueLines(d, created, created.new, opts, new Set(['code']))
        ls.push(...by('shipment_lines').filter((r) => r.op === 'INSERT').map(lineLine))
        out.push({ title: withPart(tx(d, 'shp.created'), str(created, 'code')), lines: ls, reason: null, key: true, weight: 100 })
    }
    for (const r of by('shipments')) {
        if (r === created) continue
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        if (changed(r, 'container_id')) {
            const to = refLabel({ ...r, old: null }, 'container_id')
            const from = refLabel({ ...r, new: null, ctx: null }, 'container_id')
            out.push(isEmpty(r.new?.['container_id'] ?? null)
                ? { title: withPart(tx(d, 'shp.containerCleared'), from), lines: changeLines(d, r, opts, new Set(['container_id'])), key: true, weight: 70 }
                : { title: withPart(tx(d, 'shp.containerSet'), to), lines: changeLines(d, r, opts, new Set(['container_id'])), key: true, weight: 70 })
            continue
        }
        const ls = changeLines(d, r, opts)
        if (ls.length) out.push({ title: tx(d, 'shp.edited'), lines: ls, key: false, weight: 30 })
    }
    if (!created) for (const r of by('shipment_lines')) {
        out.push(r.op === 'INSERT' ? { title: tx(d, 'shp.lineAdded'), lines: [lineLine(r)], key: false, weight: 40 } : describeGeneric(d, r, opts))
    }
    for (const r of by('shipment_issues')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'shp.issued', { version: num(r.new?.['version'] ?? null) ?? '' }), lines: [], key: true, weight: 80 })
    }
    return out
}

// ── 联系人与附件(客户与供应商共用)────────────────────────────────────────
// 名字与文件名是一个人敲的字 —— 作为标题后面的 typed 那一段(part),不拼进标题
function describeContact(d: TrailDict, r: TrailRow, opts: BuildOptions): Block2 {
    const part = typed(str(r, 'name'))
    const skip = new Set(['name', 'customer_id', 'supplier_id', 'deleted_at', 'name_inferred'])
    if (r.op === 'INSERT') return { title: tx(d, 'contact.added'), part, lines: valueLines(d, r, r.new, opts, skip), key: true, weight: 45 }
    if (isDeleted(r)) return { title: tx(d, 'contact.removed'), part, lines: [], key: true, weight: 45 }
    return { title: tx(d, 'contact.changed'), part, lines: changeLines(d, r, opts, new Set(['deleted_at'])), key: false, weight: 40 }
}
function describeAttachment(d: TrailDict, r: TrailRow, opts: BuildOptions): Block2 {
    const part = typed(str(r, 'file_name'))
    if (r.op === 'INSERT') return { title: tx(d, 'batch.attachmentAdded'), part, lines: valueLines(d, r, r.new, opts, new Set(['file_name', 'customer_id', 'supplier_id', 'material_id', 'deleted_at'])), key: true, weight: 35 }
    if (isDeleted(r)) return { title: tx(d, 'batch.attachmentRemoved'), part, lines: [], key: true, weight: 35 }
    return { title: tx(d, 'att.changed'), part, lines: changeLines(d, r, opts), key: false, weight: 30 }
}

// ── 客户 ────────────────────────────────────────────────────────────────────
const CUSTOMER_TABLES = new Set(['customers', 'customer_attachments', 'customer_credit_history', 'customer_statements', 'statement_issues',
    'collection_chases', 'collection_chase_documents', 'collection_promises'])
const CREDIT_COLS = ['credit_limit_base', 'credit_hold']
function describeCustomer(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const credit = by('customer_credit_history')
    for (const r of by('customers')) {
        if (r.op === 'INSERT') { out.push({ title: tx(d, 'cus.created'), lines: valueLines(d, r, r.new, opts, new Set(['code', 'deleted_at'])), key: true, weight: 100 }); continue }
        if (isDeleted(r)) { out.push({ title: tx(d, 'cus.deleted'), lines: [], key: true, weight: 90 }); continue }
        // 信用两列由信用史那一行说(同一笔事务,CFO 的那一块);这里只说其余的字段
        const ls = changeLines(d, r, opts, new Set(credit.length ? [...CREDIT_COLS, 'status'] : ['status']))
        if (changed(r, 'status')) {
            ls.unshift({ t: 'change', label: fieldMeta(d, 'customers', 'status')[0], old: formatValue(d, 'customers', 'status', r.old?.['status'], imgOf(r), r.refs, r.op, opts),
                new: formatValue(d, 'customers', 'status', r.new?.['status'], imgOf(r), r.refs, r.op, opts) })
            out.push({ title: tx(d, 'cus.statusChanged'), lines: ls, key: true, weight: 80 })
        } else if (ls.length) out.push({ title: tx(d, 'cus.edited'), lines: ls, key: false, weight: 30 })
    }
    for (const h of credit) {
        const n = h.new ?? {}
        const holdMoved = JSON.stringify(n['old_credit_hold'] ?? null) !== JSON.stringify(n['new_credit_hold'] ?? null)
        const limitMoved = JSON.stringify(n['old_credit_limit_base'] ?? null) !== JSON.stringify(n['new_credit_limit_base'] ?? null)
        const key: TrailTextKey = holdMoved && !limitMoved ? (n['new_credit_hold'] === true ? 'cus.holdOn' : 'cus.holdOff') : limitMoved && !holdMoved ? 'cus.limitChanged' : 'cus.creditChanged'
        const ls: Line[] = []
        for (const bare of ['credit_limit_base', 'credit_hold']) {
            const o = n['old_' + bare], v = n['new_' + bare]
            if (JSON.stringify(o ?? null) === JSON.stringify(v ?? null)) continue
            ls.push({ t: 'change', label: fieldMeta(d, 'customers', bare)[0], old: formatValue(d, 'customer_credit_history', 'old_' + bare, o, n, h.refs, 'UPDATE', opts),
                new: formatValue(d, 'customer_credit_history', 'new_' + bare, v, n, h.refs, 'UPDATE', opts) })
        }
        out.push({ title: tx(d, key), lines: ls, key: true, weight: 85 })
    }
    for (const r of by('counterparty_contacts')) out.push(describeContact(d, r, opts))
    for (const r of by('customer_attachments')) out.push(describeAttachment(d, r, opts))
    for (const r of by('customer_statements')) {
        const code = str(r, 'code')
        if (r.op === 'INSERT') {
            out.push({ title: withPart(tx(d, 'cus.statementIssued'), code), lines: valueLines(d, r, r.new, opts, new Set(['code', 'customer_id', 'issued_at', 'issued_by',
                'superseded_at', 'superseded_by', 'superseded_reason'])), key: true, weight: 80 })
        } else if (isSet(r, 'superseded_at')) {
            out.push({ title: withPart(tx(d, 'cus.statementSuperseded'), code), lines: [], reason: typed(r.new?.['superseded_reason']), key: true, weight: 75 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('statement_issues')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'cus.statementPdf', { version: num(r.new?.['version'] ?? null) ?? '' }), refLabel(r, 'statement_id')), lines: [], key: true, weight: 70 })
    }
    const docs = by('collection_chase_documents')
    for (const r of by('collection_chases')) {
        const code = str(r, 'code')
        if (r.op === 'INSERT') {
            const ch = str(r, 'channel')
            const ls = valueLines(d, r, r.new, opts, new Set(['code', 'customer_id', 'channel', 'summary', 'superseded_at', 'superseded_by', 'superseded_reason']))
            for (const x of docs.filter((y) => y.op === 'INSERT')) {
                const st = str(x, 'subject_type'), sc = str(x, 'subject_code')
                ls.push({ t: 'value', label: st ? enumLabel(d, 'collection_chase_documents', 'subject_type', st) : cap(thing(d, 'collection_chase_documents')),
                          value: sc && DOC_CODE.test(sc) ? { text: sc } : { text: tx(d, 'value.unnamed', { thing: thing(d, 'collection_chase_documents') }) } })
            }
            const summary = typed(r.new?.['summary'])
            if (summary) ls.push({ t: 'value', label: fieldMeta(d, 'collection_chases', 'summary')[0], value: summary })
            out.push({ title: withPart(withPart(tx(d, 'cus.chased'), code), ch ? enumLabel(d, 'collection_chases', 'channel', ch).toLowerCase() : null), lines: ls, key: true, weight: 80 })
        } else if (isSet(r, 'superseded_at')) {
            out.push({ title: withPart(tx(d, 'cus.chaseSuperseded'), code), lines: [], reason: typed(r.new?.['superseded_reason']), key: true, weight: 75 })
        } else out.push(describeGeneric(d, r, opts))
    }
    if (!by('collection_chases').some((r) => r.op === 'INSERT')) for (const r of docs) out.push(describeGeneric(d, r, opts))
    for (const r of by('collection_promises')) {
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'cus.promise'), lines: valueLines(d, r, r.new, opts, new Set(['chase_id', 'outcome', 'outcome_note', 'outcome_recorded_at', 'outcome_recorded_by'])), key: true, weight: 70 })
        } else if (isSet(r, 'outcome_recorded_at') || changed(r, 'outcome')) {
            const o = str(r, 'outcome', 'new')
            out.push({ title: withPart(tx(d, 'cus.promiseOutcome'), o ? enumLabel(d, 'collection_promises', 'outcome', o) : null), lines: [], reason: typed(r.new?.['outcome_note']), key: true, weight: 70 })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

// ── 佣金协议 ────────────────────────────────────────────────────────────────
function describeCommission(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    return rows.map((r) => r.op === 'INSERT' ? { title: tx(d, 'cm.created'), lines: valueLines(d, r, r.new, opts, new Set(['deleted_at'])), key: true, weight: 100 }
        : isDeleted(r) ? { title: tx(d, 'cm.deleted'), lines: [], key: true, weight: 90 }
        : { title: tx(d, 'cm.edited'), lines: changeLines(d, r, opts), key: false, weight: 30 })
}

// ── 供应商(与货代:账上同一行 suppliers)────────────────────────────────────
const SUPPLIER_TABLES = new Set(['suppliers', 'supplier_compliance', 'supplier_attachments', 'supplier_status_history', 'forwarder_details', 'forwarder_rate_quotes'])
/** 一步状态变动 → 一句话(supplier_status_moves() 里的每一步都有它的说法)*/
function supplierMove(from: string | null, to: string | null): TrailTextKey {
    switch (to) {
        case 'pending_review': return 'sup.submitted'
        case 'approved': return 'sup.approved'
        case 'rejected': return 'sup.rejected'
        case 'active': return from === 'suspended' ? 'sup.reinstated' : 'sup.activated'
        case 'suspended': return 'sup.suspended'
        case 'blacklisted': return 'sup.blacklisted'
        case 'archived': return 'sup.archived'
        case 'draft': return from === 'archived' ? 'sup.restored' : 'sup.backToDraft'
    }
    return 'sup.statusChanged'
}
function describeSupplier(d: TrailDict, rows: TrailRow[], opts: BuildOptions, subject?: string | null): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const hist = by('supplier_status_history')
    for (const r of by('suppliers')) {
        const fwd = subject === 'forwarder' || str(r, 'counterparty_type') === 'forwarder'
        const id = idOf(r)
        // 建档这一块【不】带 recordId:同一次操作里的送审 / 批准由下面每一步自己接住审批留痕(absorbsApproval)
        if (r.op === 'INSERT') { out.push({ title: tx(d, fwd ? 'fwd.created' : 'sup.created'), lines: valueLines(d, r, r.new, opts, new Set(['code', 'status', 'approved_at', 'approved_by', 'deleted_at'])), key: true, weight: 100 }); continue }
        if (isDeleted(r)) { out.push({ title: tx(d, fwd ? 'fwd.deleted' : 'sup.deleted'), lines: [], key: true, weight: 90, recordId: id }); continue }
        // 状态:有状态史就由它说(一步一块,带着那一步的说明);没有状态史(记录开始之前的批准戳)就由这一行说
        if (changed(r, 'status') || (r.prelog && (r.cols ?? []).includes('approved_at'))) {
            const rest = changeLines(d, r, opts, new Set(['status', 'approved_at', 'approved_by']))
            if (!hist.length) {
                const to = r.prelog ? 'approved' : str(r, 'status', 'new')
                out.push({ title: tx(d, supplierMove(str(r, 'status', 'old'), to)), lines: rest, key: true, weight: 90, recordId: id, absorbsApproval: true })
            } else if (rest.length) out.push({ title: tx(d, fwd ? 'fwd.edited' : 'sup.edited'), lines: rest, key: false, weight: 30 })
            continue
        }
        const ls = changeLines(d, r, opts, new Set(['approved_at', 'approved_by']))
        if (ls.length) out.push({ title: tx(d, fwd ? 'fwd.edited' : 'sup.edited'), lines: ls, key: false, weight: 30 })
    }
    // 状态史:一步一块。只有一步时它的说明是理由;一次操作里走了几步(送审又批准),每一步的说明各自一行 ——
    //   一条记录只有一个理由的位置,第二步的那一句不能被挤掉
    for (const h of hist) {
        const note = typed(h.new?.['note'])
        const several = hist.length > 1
        out.push({ title: tx(d, supplierMove(str(h, 'from_status', 'new'), str(h, 'to_status', 'new'))),
                   lines: several && note ? [{ t: 'value', label: fieldMeta(d, 'supplier_status_history', 'note')[0], value: note }] : [],
                   reason: several ? null : note, key: true, weight: 90, recordId: str(h, 'supplier_id') ?? undefined, absorbsApproval: true })
    }
    for (const r of by('supplier_compliance')) {
        const kind = refLabel(r, 'cert_type_code'), part = typed(str(r, 'cert_no'))
        const skip = new Set(['supplier_id', 'deleted_at', 'cert_no', 'cert_type_code'])
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'sup.certAdded'), kind), part, lines: valueLines(d, r, r.new, opts, skip), key: true, weight: 60 })
        else if (isDeleted(r)) out.push({ title: withPart(tx(d, 'sup.certRemoved'), kind), part, lines: [], key: true, weight: 60 })
        else out.push({ title: withPart(tx(d, 'sup.certChanged'), kind), part, lines: changeLines(d, r, opts, new Set(['supplier_id', 'deleted_at'])), key: false, weight: 40 })
    }
    for (const r of by('counterparty_contacts')) out.push(describeContact(d, r, opts))
    for (const r of by('supplier_attachments')) out.push(describeAttachment(d, r, opts))
    for (const r of by('forwarder_details')) {
        const skip = new Set(['supplier_id'])
        out.push(r.op === 'INSERT' ? { title: tx(d, 'fwd.detailsSet'), lines: valueLines(d, r, r.new, opts, skip), key: false, weight: 50 }
            : r.op === 'DELETE' ? describeGeneric(d, r, opts) : { title: tx(d, 'fwd.detailsChanged'), lines: changeLines(d, r, opts, skip), key: false, weight: 40 })
    }
    for (const r of by('forwarder_rate_quotes')) {
        const lane = refLabel(r, 'lane_id')
        const skip = new Set(['supplier_id', 'lane_id', 'deleted_at'])
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'fwd.quoteAdded'), lane), lines: valueLines(d, r, r.new, opts, skip), key: true, weight: 60 })
        else if (isDeleted(r)) out.push({ title: withPart(tx(d, 'fwd.quoteRemoved'), lane), lines: [], key: true, weight: 60 })
        else out.push({ title: withPart(tx(d, 'fwd.quoteChanged'), lane), lines: changeLines(d, r, opts, skip), key: false, weight: 40 })
    }
    return out
}

// ── 集装箱 ──────────────────────────────────────────────────────────────────
const CONTAINER_TABLES = new Set(['containers', 'container_milestones', 'container_documents'])
function describeContainer(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    for (const r of by('containers')) {
        if (r.op === 'INSERT') { out.push({ title: withPart(tx(d, 'ctr.created'), str(r, 'code')), lines: valueLines(d, r, r.new, opts, new Set(['code', 'deleted_at', 'deleted_by', 'delete_reason'])), key: true, weight: 100 }); continue }
        if (isDeleted(r)) { out.push({ title: tx(d, 'ctr.deleted'), lines: [], reason: typed(r.new?.['delete_reason']), key: true, weight: 90 }); continue }
        const ls = changeLines(d, r, opts)
        if (ls.length) out.push({ title: tx(d, 'ctr.edited'), lines: ls, key: false, weight: 30 })
    }
    for (const r of by('container_milestones')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const m = str(r, 'milestone') ?? ''
        const note = str(r, 'note')
        // 拆箱时 detach_shipment_from_container 写的那一行:"detached SHP-…: 理由"(数据库拼的,不是一个人写的句子)
        const det = m === 'other' ? note?.match(/^detached (\S+): ([\s\S]*)$/) : null
        if (det) { out.push({ title: tx(d, 'ctr.detached', { code: det[1] }), lines: [], reason: typed(det[2]), key: true, weight: 70 }); continue }
        const ls = valueLines(d, r, { event_date: r.new?.['event_date'] ?? null }, opts)
        const n = typed(note)
        if (n) ls.push({ t: 'value', label: fieldMeta(d, 'container_milestones', 'note')[0], value: n })
        out.push({ title: withPart(tx(d, 'ctr.milestone'), m ? enumLabel(d, 'container_milestones', 'milestone', m) : null), lines: ls, key: true, weight: 70 })
    }
    for (const r of by('container_documents')) {
        const part = typed(str(r, 'document_type'))
        const skip = new Set(['container_id', 'document_type', 'status', 'na_reason'])
        if (r.op === 'INSERT') { out.push({ title: tx(d, 'ctr.docAdded'), part, lines: valueLines(d, r, r.new, opts, skip), key: true, weight: 45 }); continue }
        if (r.op === 'DELETE') { out.push({ title: tx(d, 'ctr.docRemoved'), part, lines: [], key: true, weight: 45 }); continue }
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        const key: TrailTextKey = to === 'received' ? 'ctr.docReceived' : to === 'not_applicable' ? 'ctr.docNa' : to === 'pending' ? 'ctr.docPending' : 'ctr.docChanged'
        out.push({ title: tx(d, key), part, lines: changeLines(d, r, opts, skip), reason: to === 'not_applicable' ? typed(r.new?.['na_reason']) : null,
                   key: !!to, weight: to ? 60 : 40 })
    }
    return out
}

// ── 航段与港口 ──────────────────────────────────────────────────────────────
const LANE_TABLES = new Set(['lanes', 'ports', 'lane_document_requirements'])
function laneName(d: TrailDict, r: TrailRow): string {
    const img = imgOf(r)
    const end = (c: string) => typeof img[c] === 'string' ? refVal(d, 'lanes', c, img[c] as string, r.refs).text : '?'
    return `${end('origin_port_id')} → ${end('destination_port_id')}`
}
function describeLane(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    for (const r of by('lanes')) {
        const name = laneName(d, r)
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'lane.created'), name), lines: [], key: true, weight: 100 })
        else if (isDeleted(r)) out.push({ title: withPart(tx(d, 'lane.deleted'), name), lines: [], key: true, weight: 90 })
        else if (isSet(r, 'checklist_reviewed_at')) out.push({ title: withPart(tx(d, 'lane.reviewed'), name), lines: [], key: true, weight: 70 })
        else out.push({ title: withPart(tx(d, 'lane.edited'), name), lines: changeLines(d, r, opts), key: false, weight: 30 })
    }
    for (const r of by('lane_document_requirements')) {
        const part = typed(str(r, 'document_type'))
        const skip = new Set(['lane_id', 'document_type', 'deleted_at'])
        if (r.op === 'INSERT') out.push({ title: tx(d, 'lane.reqAdded'), part, lines: valueLines(d, r, r.new, opts, skip), key: true, weight: 60 })
        else if (isDeleted(r)) out.push({ title: tx(d, 'lane.reqRemoved'), part, lines: [], key: true, weight: 60 })
        else out.push({ title: tx(d, 'lane.reqChanged'), part, lines: changeLines(d, r, opts, skip), key: false, weight: 40 })
    }
    for (const r of by('ports')) {
        const name = [str(r, 'code'), str(r, 'name')].filter(Boolean).join(' ') || null
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'port.created'), name), lines: valueLines(d, r, r.new, opts, new Set(['code', 'name', 'deleted_at'])), key: true, weight: 100 })
        else if (isDeleted(r)) out.push({ title: withPart(tx(d, 'port.deleted'), name), lines: [], key: true, weight: 90 })
        else out.push({ title: withPart(tx(d, 'port.edited'), name), lines: changeLines(d, r, opts), key: false, weight: 30 })
    }
    return out
}

// ── 公司执照 ────────────────────────────────────────────────────────────────
function describeLicence(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    return rows.map((r) => {
        const kind = refLabel(r, 'cert_type_code'), part = typed(str(r, 'cert_no'))
        if (r.op === 'INSERT') return { title: withPart(tx(d, 'lic.created'), kind), part, lines: valueLines(d, r, r.new, opts, new Set(['deleted_at', 'cert_no', 'cert_type_code'])), key: true, weight: 100 }
        if (isDeleted(r)) return { title: withPart(tx(d, 'lic.deleted'), kind), part, lines: [], key: true, weight: 90 }
        const ls = changeLines(d, r, opts)
        return changed(r, 'status') ? { title: withPart(tx(d, 'lic.statusChanged'), kind), part, lines: ls, key: true, weight: 80 }
            : { title: withPart(tx(d, 'lic.edited'), kind), part, lines: ls, key: false, weight: 30 }
    })
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-3:物料 · 库位 · 金属价格 · 定价公式与条款申请 · 任务 · 三个阈值面板
// ════════════════════════════════════════════════════════════════════════════
/** 一组字典代码(金属、废物分类)的名字,按字母排 —— "Added: Cobalt · Nickel" */
function codeNames(d: TrailDict, rows: TrailRow[], col: string): string {
    return rows.map((r) => dictName(d, r, col)).sort().join(' · ')
}
/** 建档那一次操作里的一组子行(允许分类、化验要求):第一次"拿掉"之前插进去的算【建档时的那一组】,
 *  之后插的与拿掉的算【同一次操作里随后的改动】—— 与报价 / 订单建单那一笔里又改明细同一个说法(1b-2 的决定 22) */
function splitAtFirstRemoval(rows: TrailRow[]): { atCreation: TrailRow[]; added: TrailRow[]; removed: TrailRow[] } {
    const cut = rows.findIndex((r) => r.op === 'DELETE')
    const ins = rows.map((r, i) => [r, i] as const).filter(([r]) => r.op === 'INSERT')
    return { atCreation: ins.filter(([, i]) => cut < 0 || i < cut).map(([r]) => r), added: ins.filter(([, i]) => cut >= 0 && i > cut).map(([r]) => r),
             removed: rows.filter((r) => r.op === 'DELETE') }
}
/** "加了几条 · 拿掉几条"那一组两行(与角色的授权同一种写法) */
function addedRemovedLines(d: TrailDict, added: string, removed: string): Line[] {
    const ls: Line[] = []
    if (added) ls.push({ t: 'value', label: tx(d, 'role.lineAdded'), value: truncate(added) })
    if (removed) ls.push({ t: 'value', label: tx(d, 'role.lineRemoved'), value: truncate(removed) })
    return ls
}

// ── 物料:主档 · 附件 · 化验要求(哪些金属必须化验 —— 页面上那一块叫 "Assay requirement")──────────
const MATERIAL_TABLES = new Set(['materials', 'material_attachments', 'material_required_metals'])
function describeMaterial(d: TrailDict, rows0: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    // 化验要求是"整组换掉"写的(先删后插)—— 同一笔里前后一样的那几条不算改动
    const rows = netReplace(rows0)
    const by = (t: string) => rows.filter((r) => r.table === t)
    const metals = by('material_required_metals')
    const created = by('materials').find((r) => r.op === 'INSERT')
    const split = splitAtFirstRemoval(metals)
    const addedM = created ? split.added : metals.filter((r) => r.op === 'INSERT'), removedM = split.removed
    for (const r of by('materials')) {
        if (r === created) {
            const ls = valueLines(d, r, r.new, opts, new Set(['code', 'deleted_at']))
            if (split.atCreation.length) ls.push({ t: 'value', label: tx(d, 'mat.assayFor'), value: truncate(codeNames(d, split.atCreation, 'metal')) })
            out.push({ title: tx(d, 'mat.created'), lines: ls, key: true, weight: 100 })
            continue
        }
        // 删掉那一次:同一行同一次操作里别的列也改过(一次操作 = 一笔事务,两次编辑并成一行)—— 那几列照样说出来
        if (isDeleted(r)) { out.push({ title: tx(d, 'mat.deleted'), lines: r.op === 'UPDATE' ? changeLines(d, r, opts, new Set(['deleted_at'])) : [], key: true, weight: 90 }); continue }
        const ls = changeLines(d, r, opts, new Set(['status', 'deleted_at']))
        if (changed(r, 'status')) {
            ls.unshift({ t: 'change', label: fieldMeta(d, 'materials', 'status')[0], old: formatValue(d, 'materials', 'status', r.old?.['status'], imgOf(r), r.refs, r.op, opts),
                new: formatValue(d, 'materials', 'status', r.new?.['status'], imgOf(r), r.refs, r.op, opts) })
            out.push({ title: tx(d, 'mat.statusChanged'), lines: ls, key: true, weight: 80 })
        } else if (ls.length) out.push({ title: tx(d, 'mat.edited'), lines: ls, key: false, weight: 30 })
    }
    if (addedM.length || removedM.length) {
        out.push({ title: tx(d, 'mat.assayChanged'), lines: addedRemovedLines(d, codeNames(d, addedM, 'metal'), codeNames(d, removedM, 'metal')), key: true, weight: 60 })
    }
    for (const r of metals) if (r.op === 'UPDATE') out.push(describeGeneric(d, r, opts))
    for (const r of by('material_attachments')) out.push(describeAttachment(d, r, opts))
    return out
}

// ── 库位:主档 · 允许存放的物料分类(页面上那一块叫 "Allowed material classes")──────────────────
function describeLocation(d: TrailDict, rows0: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const rows = netReplace(rows0)
    const by = (t: string) => rows.filter((r) => r.table === t)
    const cls = by('storage_location_allowed_classes')
    const created = by('storage_locations').find((r) => r.op === 'INSERT')
    const split = splitAtFirstRemoval(cls)
    const addedC = created ? split.added : cls.filter((r) => r.op === 'INSERT'), removedC = split.removed
    for (const r of by('storage_locations')) {
        if (r === created) {
            const ls = valueLines(d, r, r.new, opts, new Set(['code', 'is_active']))
            if (split.atCreation.length) ls.push({ t: 'value', label: tx(d, 'loc.classesLine'), value: truncate(codeNames(d, split.atCreation, 'classification_code')) })
            // 库位号是一个人敲的字(写在货架上的那个号)—— 与证书编号同一种待遇:标题后面 typed 的那一段
            out.push({ title: tx(d, 'loc.created'), part: typed(str(r, 'code')), lines: ls, key: true, weight: 100 })
            continue
        }
        const ls = changeLines(d, r, opts, new Set(['is_active']))
        if (changed(r, 'is_active')) out.push({ title: tx(d, r.new?.['is_active'] === true ? 'loc.reactivated' : 'loc.deactivated'), lines: ls, key: true, weight: 80 })
        else if (ls.length) out.push({ title: tx(d, 'loc.edited'), lines: ls, key: false, weight: 30 })
    }
    if (addedC.length || removedC.length) {
        const parts = [addedC.length ? tx(d, 'role.added', { n: addedC.length }) : '', removedC.length ? tx(d, 'role.removed', { n: removedC.length }) : ''].filter(Boolean)
        out.push({ title: [tx(d, 'loc.classesChanged'), parts.join(', ')].join(' · '),
                   lines: addedRemovedLines(d, codeNames(d, addedC, 'classification_code'), codeNames(d, removedC, 'classification_code')), key: true, weight: 60 })
    }
    for (const r of cls) if (r.op === 'UPDATE') out.push(describeGeneric(d, r, opts))
    return out
}

// ── 金属价格(一条报价)──────────────────────────────────────────────────────
function describeMetalPrice(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    return rows.map((r) => {
        if (r.op === 'INSERT') return { title: tx(d, 'mp.created'), lines: valueLines(d, r, r.new, opts, new Set(['deleted_at'])), key: true, weight: 100 }
        if (isDeleted(r)) return { title: tx(d, 'mp.deleted'), lines: r.op === 'UPDATE' ? changeLines(d, r, opts, new Set(['deleted_at'])) : [], key: true, weight: 90 }
        if (r.op === 'DELETE') return describeGeneric(d, r, opts)
        return { title: tx(d, 'mp.edited'), lines: changeLines(d, r, opts, new Set(['deleted_at'])), key: false, weight: 30 }
    })
}

// ── 定价公式:公式本身 · 应付金属 · 修改史 · 条款申请(与它的审批)───────────────────────────────
//   公式的每一次改动都有两份:change_log 里那一行(全部列)与 pricing_formula_history 那一行(同一笔事务,AFTER 触发器写)。
//   记录开始之后由前者说、修改史不再说第二遍;记录开始之前只有修改史(与建行那一刻),由它说。
const FORMULA_TABLES = new Set(['pricing_formulas', 'pricing_formula_metals', 'pricing_formula_history', 'terms_requests'])
const PF_HISTORY_COLS = ['name', 'direction', 'price_basis', 'average_days', 'treatment_charge_usd_per_tonne', 'flat_discount_pct', 'is_active']
function pfHistoryLines(d: TrailDict, h: TrailRow, opts: BuildOptions, created: boolean): Line[] {
    const out: Line[] = []
    const n = h.new ?? {}
    for (const bare of PF_HISTORY_COLS) {
        const o = n['old_' + bare], v = n['new_' + bare]
        if (created) {
            if (isEmpty(v ?? null)) continue
            out.push({ t: 'value', label: fieldMeta(d, 'pricing_formulas', bare)[0], value: formatValue(d, 'pricing_formula_history', 'new_' + bare, v, n, h.refs, 'INSERT', opts) })
            continue
        }
        if (JSON.stringify(o ?? null) === JSON.stringify(v ?? null)) continue
        out.push({ t: 'change', label: fieldMeta(d, 'pricing_formulas', bare)[0],
            old: formatValue(d, 'pricing_formula_history', 'old_' + bare, o, n, h.refs, 'UPDATE', opts),
            new: formatValue(d, 'pricing_formula_history', 'new_' + bare, v, n, h.refs, 'UPDATE', opts) })
    }
    return out
}
/** 送给 CFO 的是哪一种申请 —— 公式那一页上只会有前三种 */
function trSentKey(kind: string | null): TrailTextKey {
    return kind === 'formula_create' ? 'tr.sentNew' : kind === 'formula_change' ? 'tr.sentChange' : kind === 'formula_reactivate' ? 'tr.sentReactivate' : 'tr.sentOther'
}
function describeFormula(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const pf = by('pricing_formulas'), metals = by('pricing_formula_metals'), hist = by('pricing_formula_history'), reqs = by('terms_requests')
    const logged = pf.some((r) => !r.prelog), loggedMetals = metals.some((r) => !r.prelog)
    const created = pf.find((r) => r.op === 'INSERT')
    const histCreate = hist.find((h) => str(h, 'change_type', 'new') === 'create')
    const metalLine = (r: TrailRow): Line => ({ t: 'value', label: tx(d, 'pf.payableFor', { metal: dictName(d, r, 'metal') }),
        value: formatValue(d, 'pricing_formula_metals', 'payable_pct', imgOf(r)['payable_pct'], imgOf(r), r.refs, r.op, opts) })
    // ① 建立:公式那一行(或只有修改史的 create)+ 同一笔里的应付金属
    if (created || histCreate) {
        const ls = created ? valueLines(d, created, created.new, opts, new Set(['code', 'deleted_at'])) : pfHistoryLines(d, histCreate!, opts, true)
        ls.push(...metals.filter((r) => r.op === 'INSERT').map(metalLine))
        out.push({ title: tx(d, 'pf.created'), lines: ls, key: true, weight: 100 })
    }
    // ② 公式本身的改动
    for (const r of pf) {
        if (r === created) continue
        if (isDeleted(r)) { out.push({ title: tx(d, 'pf.deleted'), lines: r.op === 'UPDATE' ? changeLines(d, r, opts, new Set(['deleted_at', 'is_active'])) : [], key: true, weight: 90 }); continue }
        if (changed(r, 'deleted_at')) { out.push({ title: tx(d, 'pf.restored'), lines: changeLines(d, r, opts, new Set(['deleted_at'])), key: true, weight: 90 }); continue }
        const ls = changeLines(d, r, opts, new Set(['is_active']))
        if (changed(r, 'is_active')) out.push({ title: tx(d, r.new?.['is_active'] === true ? 'pf.reactivated' : 'pf.deactivated'), lines: ls, key: true, weight: 80 })
        else if (ls.length) out.push({ title: tx(d, 'pf.edited'), lines: ls, key: false, weight: 30 })
    }
    // ③ 修改史(只在 change_log 没有那一行的时候说 —— 记录开始之前)
    for (const h of hist) {
        const ct = str(h, 'change_type', 'new') ?? ''
        if (ct === 'create') continue
        if (ct === 'metal_set' || ct === 'metal_clear') {
            if (loggedMetals || created || histCreate) continue
            const n = h.new ?? {}
            const metal = dictName(d, h, 'metal')
            out.push({ title: withPart(tx(d, ct === 'metal_set' ? 'pf.metalSet' : 'pf.metalRemoved'), metal), lines: ct === 'metal_set' ? [{ t: 'change',
                label: fieldMeta(d, 'pricing_formula_metals', 'payable_pct')[0],
                old: formatValue(d, 'pricing_formula_history', 'old_payable_pct', n['old_payable_pct'], n, h.refs, 'UPDATE', opts),
                new: formatValue(d, 'pricing_formula_history', 'new_payable_pct', n['new_payable_pct'], n, h.refs, 'UPDATE', opts) }] : [],
                key: false, weight: 45 })
            continue
        }
        if (logged) continue
        if (ct === 'delete') out.push({ title: tx(d, 'pf.deleted'), lines: [], key: true, weight: 90 })
        else if (ct === 'restore') out.push({ title: tx(d, 'pf.restored'), lines: [], key: true, weight: 90 })
        else {
            const ls = pfHistoryLines(d, h, opts, false)
            const act = ls.find((l) => l.t === 'change' && l.label === fieldMeta(d, 'pricing_formulas', 'is_active')[0])
            const n = h.new ?? {}
            if (act) out.push({ title: tx(d, n['new_is_active'] === true ? 'pf.reactivated' : 'pf.deactivated'), lines: ls.filter((l) => l !== act), key: true, weight: 80 })
            else out.push({ title: tx(d, 'pf.edited'), lines: ls, key: false, weight: 30 })
        }
    }
    // ④ 应付金属(建立那一笔之外)
    if (!created && !histCreate) for (const r of metals) {
        const metal = dictName(d, r, 'metal')
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'pf.metalSet'), metal), lines: valueLines(d, r, r.new, opts, new Set(['formula_id', 'metal'])), key: false, weight: 45 })
        else if (r.op === 'DELETE') out.push({ title: withPart(tx(d, 'pf.metalRemoved'), metal), lines: [], key: false, weight: 45 })
        else out.push({ title: withPart(tx(d, 'pf.metalSet'), metal), lines: changeLines(d, r, opts, new Set(['formula_id', 'metal'])), key: false, weight: 45 })
    }
    // ⑤ 条款申请:送给 CFO · 撤回 · 批准 / 驳回(审批留痕并进这一句)
    for (const r of reqs) {
        const id = idOf(r)
        const kind = str(r, 'kind')
        const part = typed(str(r, 'label'))
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, trSentKey(kind)), part, lines: [], reason: typed(r.new?.['reason']), key: true, weight: 85, recordId: id, absorbsApproval: true })
        } else if (isSet(r, 'withdrawn_at') || (changed(r, 'status') && str(r, 'status', 'new') === 'withdrawn')) {
            out.push({ title: tx(d, 'tr.withdrawn'), part, lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 85, recordId: id })
        } else if (changed(r, 'status') && ['approved', 'rejected'].includes(str(r, 'status', 'new') ?? '')) {
            out.push({ title: tx(d, str(r, 'status', 'new') === 'approved' ? 'tr.approved' : 'tr.rejected'), part, lines: [],
                       reason: typed(r.new?.['decision_notes']), key: true, weight: 95, recordId: id, absorbsApproval: true })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, new Set(['proposed', 'snapshot', 'fingerprint', 'formula_id', 'contract_id', 'kind', 'label']))
            if (ls.length) out.push({ title: tx(d, 'tr.changed'), part, lines: ls, key: false, weight: 40, recordId: id })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

// ── 任务(Q3:私人任务也是)────────────────────────────────────────────────
//   团队任务的每一次改动有两份:change_log 里那一行(任务 / 步骤 / 参与者本身)与 task_history 那一行(同一笔、触发器写)。
//   同一件事只说一次 —— 认【这一件事落在哪一行上】:任务表头 = 任务那一行;一个步骤 = 那个步骤的 id;一个参与者 = 那个员工。
//   记录开始之后由 change_log 那一行说(它有全部的列);它不在(记录开始之前)才由修改史说。
//   私人任务没有修改史(触发器只在团队任务上写),所以它的每一件事都由 change_log 那一行说。
const TASK_TABLES = new Set(['tasks', 'task_nodes', 'task_participants', 'task_history'])
const TASK_HEADER = ['title', 'description', 'status', 'priority', 'due_date', 'reminder_at', 'tags']
function stepTitle(r: TrailRow, titles: Map<string, string>): Val | null {
    const own = str(r, 'title') ?? str(r, 'new_node_title') ?? str(r, 'old_node_title')
    const nodeId = r.table === 'task_history' ? str(r, 'node_id') : idOf(r) ?? null
    return typed(own ?? (nodeId ? titles.get(nodeId) ?? null : null))
}
function describeTask(d: TrailDict, rows: TrailRow[], opts: BuildOptions, titles: Map<string, string>): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const tasks = by('tasks'), nodes = by('task_nodes'), parts = by('task_participants'), hist = by('task_history')
    const loggedTask = tasks.some((r) => !r.prelog && r.op === 'UPDATE')
    const loggedNodes = new Set(nodes.filter((r) => !r.prelog).map((r) => idOf(r) ?? ''))
    const histNodes = new Set(hist.map((h) => str(h, 'node_id') ?? '').filter(Boolean))
    const histPeople = new Set(hist.filter((h) => /^participant_/.test(str(h, 'change_type', 'new') ?? '')).map((h) => str(h, 'employee_id') ?? ''))
    const created = tasks.find((r) => r.op === 'INSERT')
    const nodeIns = nodes.filter((r) => r.op === 'INSERT')
    for (const r of tasks) {
        if (r === created) {
            const ls = valueLines(d, r, r.new, opts, new Set(['code', 'deleted_at']))
            for (const n of nodeIns) ls.push({ t: 'value', label: tx(d, 'task.stepLine'), value: stepTitle(n, titles) ?? { text: tx(d, 'empty'), empty: true } })
            out.push({ title: tx(d, 'task.created'), lines: ls, key: true, weight: 100 })
            continue
        }
        if (isDeleted(r)) { out.push({ title: tx(d, 'task.deleted'), lines: r.op === 'UPDATE' ? changeLines(d, r, opts, new Set(['deleted_at'])) : [], key: true, weight: 90 }); continue }
        const ls = changeLines(d, r, opts, new Set(['task_type', 'deleted_at']))
        if (changed(r, 'task_type') && str(r, 'task_type', 'new') === 'team') { out.push({ title: tx(d, 'task.promoted'), lines: ls, key: true, weight: 85 }); continue }
        if (changed(r, 'task_type')) ls.unshift(...changeLines(d, r, opts, new Set((r.cols ?? []).filter((c) => c !== 'task_type'))))
        if (changed(r, 'owner_id')) { out.push({ title: tx(d, 'task.ownerTransferred'), lines: ls, key: true, weight: 80 }); continue }
        if (ls.length) out.push({ title: tx(d, 'task.edited'), lines: ls, key: changed(r, 'status'), weight: changed(r, 'status') ? 70 : 30 })
    }
    // 步骤(change_log 那一行在就由它说;记录开始之前的建行 / 打勾戳,修改史说了的就不再说)
    for (const r of nodes) {
        const nid = idOf(r) ?? ''
        if (r.prelog && histNodes.has(nid)) continue
        if (created && r.op === 'INSERT') continue
        const part = stepTitle(r, titles)
        const skip = new Set(['task_id', 'parent_id', 'parent_depth', 'depth', 'sort_order', 'done_at', 'done_by', 'title'])
        if (r.op === 'INSERT') out.push({ title: tx(d, 'task.stepAdded'), part, lines: valueLines(d, r, r.new, opts, skip), key: true, weight: 50 })
        else if (r.op === 'DELETE') out.push({ title: tx(d, 'task.stepRemoved'), part, lines: valueLines(d, r, { target_date: r.old?.['target_date'] ?? null, done: r.old?.['done'] ?? null }, opts), key: true, weight: 50 })
        else if (isSet(r, 'done_at') || (changed(r, 'done') && r.new?.['done'] === true)) out.push({ title: tx(d, 'task.stepDone'), part, lines: [], key: true, weight: 55 })
        else if (changed(r, 'done')) out.push({ title: tx(d, 'task.stepUndone'), part, lines: [], key: true, weight: 55 })
        else if (changed(r, 'title')) out.push({ title: tx(d, 'task.stepRenamed'), part: typed(str(r, 'title', 'new')), lines: changeLines(d, r, opts, new Set([...skip].filter((c) => c !== 'title'))), key: true, weight: 50 })
        else if (changed(r, 'target_date')) out.push({ title: tx(d, 'task.stepRedated'), part, lines: changeLines(d, r, opts, skip), key: true, weight: 50 })
        else if (changed(r, 'sort_order')) out.push({ title: tx(d, 'task.stepMoved'), part, lines: [], key: true, weight: 40 })
        else { const ls = changeLines(d, r, opts, skip); if (ls.length) out.push({ title: tx(d, 'task.stepChanged'), part, lines: ls, key: true, weight: 40 }) }
    }
    // 参与者(修改史在就由它说 —— 它分得清"自己走"与"被移出")
    for (const r of parts) {
        const who = refLabel(r, 'employee_id')
        if (histPeople.has(str(r, 'employee_id') ?? '')) continue
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'task.participantAdded'), who), lines: [], key: true, weight: 50 })
        else if (isSet(r, 'removed_at')) out.push({ title: withPart(tx(d, str(r, 'removed_by') === str(r, 'employee_id') ? 'task.participantLeft' : 'task.participantRemoved'), who), lines: [], key: true, weight: 50 })
        else out.push(describeGeneric(d, r, opts))
    }
    // 修改史(上面那几行没说的那一件事)
    for (const h of hist) {
        const ct = str(h, 'change_type', 'new') ?? ''
        const n = h.new ?? {}
        const nid = str(h, 'node_id') ?? ''
        const part = stepTitle(h, titles)
        const who = refLabel(h, 'employee_id')
        const diff = (bares: string[], base: string, prefix = ''): Line[] => bares.flatMap((bare) => {
            const o = n['old_' + prefix + bare], v = n['new_' + prefix + bare]
            if (JSON.stringify(o ?? null) === JSON.stringify(v ?? null)) return []
            return [{ t: 'change' as const, label: fieldMeta(d, base, bare)[0],
                old: formatValue(d, 'task_history', 'old_' + prefix + bare, o, n, h.refs, 'UPDATE', opts),
                new: formatValue(d, 'task_history', 'new_' + prefix + bare, v, n, h.refs, 'UPDATE', opts) }]
        })
        switch (ct) {
            case 'header_update':
                if (!loggedTask) out.push({ title: tx(d, 'task.edited'), lines: diff(TASK_HEADER, 'tasks'), key: !isEmpty(n['new_status'] ?? null), weight: !isEmpty(n['new_status'] ?? null) ? 70 : 30 })
                break
            case 'promoted_from_personal':
                if (!tasks.some((r) => changed(r, 'task_type'))) out.push({ title: tx(d, 'task.promoted'), lines: [], key: true, weight: 85 })
                break
            case 'owner_transferred':
                if (!tasks.some((r) => changed(r, 'owner_id'))) out.push({ title: withPart(tx(d, 'task.ownerTransferred'), who), lines: [], key: true, weight: 80 })
                break
            case 'task_deleted':
                if (!tasks.some((r) => isDeleted(r))) out.push({ title: tx(d, 'task.deleted'), lines: [], key: true, weight: 90 })
                break
            case 'participant_added': case 'participant_removed': case 'participant_left':
                out.push({ title: withPart(tx(d, ct === 'participant_added' ? 'task.participantAdded' : ct === 'participant_left' ? 'task.participantLeft' : 'task.participantRemoved'), who), lines: [], key: true, weight: 50 })
                break
            default: {
                if (loggedNodes.has(nid) || (created && ct === 'node_added')) break
                const key: TrailTextKey = ct === 'node_added' ? 'task.stepAdded' : ct === 'node_removed' ? 'task.stepRemoved' : ct === 'node_renamed' ? 'task.stepRenamed'
                    : ct === 'node_redated' ? 'task.stepRedated' : ct === 'node_done' ? 'task.stepDone' : ct === 'node_undone' ? 'task.stepUndone'
                    : ct === 'node_reordered' ? 'task.stepMoved' : 'task.stepChanged'
                // 加上的步骤:它的计划日期是一个值,不是一次"(空) → 日期"的改动
                const added: Line[] = ct === 'node_added' && !isEmpty(n['new_node_target_date'] ?? null)
                    ? [{ t: 'value', label: fieldMeta(d, 'task_nodes', 'target_date')[0],
                         value: formatValue(d, 'task_history', 'new_node_target_date', n['new_node_target_date'], n, h.refs, 'INSERT', opts) }] : []
                // 删掉的步骤:它最后的计划日期与打没打勾(原来那一段"变更记录"在删除那一行上印着 "un-ticked" —— 一个都不丢)
                const removed: Line[] = ct === 'node_removed' ? (['old_node_target_date', 'old_node_done'] as const).filter((c) => n[c] !== null && n[c] !== undefined)
                    .map((c) => ({ t: 'value' as const, label: fieldMeta(d, 'task_history', c)[0], value: formatValue(d, 'task_history', c, n[c], n, h.refs, 'DELETE', opts) })) : []
                const ls = ct === 'node_renamed' ? diff(['title'], 'task_nodes', 'node_') : ct === 'node_redated' ? diff(['target_date'], 'task_nodes', 'node_')
                    : ct === 'node_removed' ? removed : added
                out.push({ title: tx(d, key), part: ct === 'node_renamed' ? typed(str(h, 'new_node_title')) ?? part : part, lines: ls, key: true, weight: ct === 'node_done' || ct === 'node_undone' ? 55 : 50 })
            }
        }
    }
    return out
}

// ── 三个阈值面板(每一块只看它自己编辑的那几列,M6)───────────────────────────
const SETTINGS_TITLE: Record<string, TrailTextKey> = {
    processing_settings: 'set.processing', pricing_settings: 'set.pricing', receiving_settings: 'set.receiving',
}
function describeSettings(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    return rows.map((r) => r.op === 'UPDATE'
        ? { title: tx(d, SETTINGS_TITLE[r.table!]), lines: changeLines(d, r, opts), key: true, weight: 60 }
        : describeGeneric(d, r, opts))
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-1:账上的单据 —— 分录 · 发票 · 贷项通知 · 收付款 · 付款申请 · 费用 · 应付(Tim 2026-10-03,AT-1c Step 0)
// ════════════════════════════════════════════════════════════════════════════
// 【一个家族说完这七页】这几页上的每一张表(分录、核销、附件、审批、批次……)都从这里说,不分给 1b 的 batch / journal /
//   approval 家族 —— 那几个家族在批次页、加工单页上的说法(fixture 238、⑥ ⑦ 两臂的金句)一个字都不动。
// 【一次操作一条】冲销(Q31 · Q33):原单的状态翻成 reversed 与冲销的那一张新单(镜像)在同一笔事务里 —— 只说一句
//   "Payment reversed · PMT-…" / "Journal reversed",冲销那一张是下面的【一行】(链到它),它的行不在这里(Q33)。
//   记录开始之前没有"原单翻状态"那一行(只有冲销那一张的建行),所以那时由镜像的建行说同一句(Q31:读自镜像的建立)。
// 【申请】送去批 · 批准 · 驳回 · 撤回;审批关着时申请生下来就是 approved —— 下面一行灰字
//   "Approved automatically (approvals were switched off)"(Q32);审批留痕并进申请那一句,不另起一行。
export const FIN_SUBJECTS = new Set(['journal_entry', 'invoice', 'credit_note', 'payment', 'payment_request', 'expense', 'payable'])

/** 整页的冲销关系(与上面认冲销分录同一个做法:看整页,不只看这一条)—— 镜像 id → 原单 {id, code, href} */
export type FinCtx = {
    paymentMirror: Map<string, { code: string | null; href: string | null }>
    paymentOrigin: Map<string, { code: string | null }>
    expenseMirror: Map<string, { code: string | null; href: string | null }>
    expenseOrigin: Map<string, { code: string | null }>
    /** 冲销分录 id → 它冲的那一张原分录的单号(原分录今天的 reversed_by 指着它) */
    journalOrigin: Map<string, string | null>
}
export function finContext(rows: TrailRow[]): FinCtx {
    const c: FinCtx = { paymentMirror: new Map(), paymentOrigin: new Map(), expenseMirror: new Map(), expenseOrigin: new Map(), journalOrigin: new Map() }
    for (const r of rows) {
        const img = imgOf(r)
        if (r.table === 'journal_entries' && typeof img['reversed_by'] === 'string' && !c.journalOrigin.has(img['reversed_by'] as string)) {
            c.journalOrigin.set(img['reversed_by'] as string, typeof img['code'] === 'string' ? img['code'] as string : null)
        }
        for (const [table, col, mirror, origin] of [['payments', 'reversed_by_payment', c.paymentMirror, c.paymentOrigin],
                                                    ['expenses', 'reversed_by_expense', c.expenseMirror, c.expenseOrigin]] as const) {
            if (r.table !== table) continue
            const m = img[col]
            if (typeof m !== 'string') continue
            const ref = r.refs?.[col]?.[m]
            if (!mirror.has(m)) mirror.set(m, { code: ref?.label ?? null, href: ref?.href ?? null })
            if (!origin.has(m)) origin.set(m, { code: typeof img['code'] === 'string' ? img['code'] as string : null })
        }
    }
    return c
}

/** 一个指着单据的值 → 单号 + 链接(trail_ref_label 给的 href;拿不到就只有字) */
function docVal(d: TrailDict, r: TrailRow, table: string, col: string): Val | null {
    const v = imgOf(r)[col]
    if (typeof v !== 'string') return null
    const ref = r.refs?.[col]?.[v]
    if (ref?.label) return ref.href && !ref.gone ? { text: ref.label, href: ref.href } : { text: ref.gone ? tx(d, 'value.sinceDeleted', { label: ref.label }) : ref.label }
    return refVal(d, table, col, v, r.refs)
}
/** 冲销单的备注是 "REVERSAL: <原单号> — <人写的那一句>"(冲销函数拼的)—— 只把人写的那一句当理由;机器拼的那一截不上屏 */
function reversalReason(text: string | null): Val | null {
    if (!text) return null
    const m = text.match(/^REVERSAL:\s*([\s\S]*)$/)
    if (!m) return typed(text)
    const rest = m[1].replace(/^[A-Z][A-Z0-9]{1,7}-\d{4}-\d{2,}\s*(—|-|:)?\s*/, '').trim()
    if (!rest || DOC_CODE.test(rest)) return null
    return typed(rest)
}
/** 页头横幅用的同一句(字,不是 Val) */
export function reversalReasonText(text: string | null): string | null {
    return reversalReason(text)?.full ?? reversalReason(text)?.text ?? null
}
/** 申请的编号(付款申请:PREQ-…)进标题;分录 / 发票申请没有编号,只有提交函数拼的标签("manual journal #3"、
 *  "INV-2026-0008 · void")—— 系统写的英文,不是人敲的字,所以是标题后面那一段,但不标 typed */
function labelPart(r: TrailRow): { code: string | null; part: Val | null } {
    const l = str(r, 'code') ?? str(r, 'label')
    if (!l) return { code: null, part: null }
    return DOC_CODE.test(l) ? { code: l, part: null } : { code: null, part: { text: l } }
}
function vline(d: TrailDict, r: TrailRow, col: string, opts: BuildOptions, label?: string): Line[] {
    const v = imgOf(r)[col]
    if (isEmpty(v ?? null)) return []
    return [{ t: 'value', label: label ?? fieldMeta(d, r.table!, col)[0], value: formatValue(d, r.table!, col, v, imgOf(r), r.refs, r.op, opts) }]
}
function vlines(d: TrailDict, r: TrailRow, cols: string[], opts: BuildOptions): Line[] {
    return cols.flatMap((c) => vline(d, r, c, opts))
}
/** 分录的一行:"Cash at Bank – SGD   Debit 1,000.00 SGD"(借贷是本位币;原币不同时括号里说原币)*/
function journalLineLine(d: TrailDict, r: TrailRow): Line {
    const img = imgOf(r)
    const acc = refLabel(r, 'account_id') ?? cap(fieldMeta(d, 'journal_lines', 'account_id')[0])
    const dr = num(img['debit'] ?? null) ?? 0, cr = num(img['credit'] ?? null) ?? 0
    const amt = `${NUM2.format(dr > 0 ? dr : cr)} ${d.baseCurrency}`
    let text = tx(d, dr > 0 ? 'je.debit' : 'je.credit', { amount: amt })
    const ccy = img['currency'], a = num(img['amount_ccy'] ?? null)
    if (typeof ccy === 'string' && ccy !== d.baseCurrency && a !== null) text += ` (${NUM2.format(a)} ${ccy})`
    return { t: 'value', label: acc, value: { text } }
}
function reqKind(r: TrailRow): string {
    return str(r, 'kind') ?? ''
}
const PR_KINDS = ['payment_out', 'payment_reversal', 'bank_transfer', 'bank_transfer_reversal', 'wht_remittance', 'wht_remittance_reversal'] as const
type PrKind = typeof PR_KINDS[number]
/** 六种付款申请各自的说法(字面量写全 —— check-trail-wording 按字面认"这个键有人用") */
const PR_TEXT: Record<'sent' | 'approved' | 'done', Record<PrKind, TrailTextKey>> = {
    sent: { payment_out: 'pr.sent.payment_out', payment_reversal: 'pr.sent.payment_reversal', bank_transfer: 'pr.sent.bank_transfer',
        bank_transfer_reversal: 'pr.sent.bank_transfer_reversal', wht_remittance: 'pr.sent.wht_remittance', wht_remittance_reversal: 'pr.sent.wht_remittance_reversal' },
    approved: { payment_out: 'pr.approved.payment_out', payment_reversal: 'pr.approved.payment_reversal', bank_transfer: 'pr.approved.bank_transfer',
        bank_transfer_reversal: 'pr.approved.bank_transfer_reversal', wht_remittance: 'pr.approved.wht_remittance', wht_remittance_reversal: 'pr.approved.wht_remittance_reversal' },
    done: { payment_out: 'pr.done.payment_out', payment_reversal: 'pr.done.payment_reversal', bank_transfer: 'pr.done.bank_transfer',
        bank_transfer_reversal: 'pr.done.bank_transfer_reversal', wht_remittance: 'pr.done.wht_remittance', wht_remittance_reversal: 'pr.done.wht_remittance_reversal' },
}
function prKey(prefix: 'pr.sent.' | 'pr.approved.' | 'pr.done.', kind: string): TrailTextKey {
    const k = (PR_KINDS as readonly string[]).includes(kind) ? kind as PrKind : 'payment_out'
    return PR_TEXT[prefix === 'pr.sent.' ? 'sent' : prefix === 'pr.approved.' ? 'approved' : 'done'][k]
}

function describeFinance(d: TrailDict, rows0: TrailRow[], opts: BuildOptions, reversals: Set<string>, fc: FinCtx): Block2[] {
    const out: Block2[] = []
    const rows = netReplace(rows0)
    const by = (t: string) => rows.filter((r) => r.table === t)
    const subject = opts.subject ?? ''
    const rootId = opts.recordId ?? null
    const auto = (id: string | undefined) => !!id && by('approval_log').some((a) => str(a, 'subject_id') === id && str(a, 'decision', 'new') === 'auto_approved')

    // ── ① 分录 ────────────────────────────────────────────────────────────────
    const jes = by('journal_entries')
    const reversedInGroup = new Set(jes.filter((r) => changed(r, 'reversed_by') && str(r, 'reversed_by', 'new')).map((r) => str(r, 'reversed_by', 'new') as string))
    for (const r of jes) {
        const id = idOf(r) ?? ''
        const code = str(r, 'code')
        const isRoot = subject === 'journal_entry' && id === rootId
        if (r.op === 'INSERT') {
            if (reversals.has(id)) {
                // 一张冲销分录。原分录翻状态的那一行在同一条里 → 由那一行说(Q33:冲销是它下面的【一行】)——
                //   除非这一页就是这张冲销分录自己:那时它是主角,原分录那一行不另说(见下)
                if (reversedInGroup.has(id) && !isRoot) continue
                const ls: Line[] = []
                const orig = fc.journalOrigin.get(id)
                if (orig) ls.push({ t: 'value', label: tx(d, 'je.reversesLine'), value: { text: orig } })
                if (isRoot) ls.push(...rows.filter((x) => x.table === 'journal_lines' && x.op === 'INSERT').map((x) => journalLineLine(d, x)))
                out.push({ title: withPart(tx(d, 'je.reversalPosted'), code), lines: ls, reason: reversalReason(str(r, 'memo')), key: true, weight: isRoot ? 100 : 55, recordId: id })
                continue
            }
            const ls: Line[] = []
            if (isRoot) {
                ls.push(...vlines(d, r, ['entry_date', 'source_type'], opts))
                const memo = typed(r.new?.['memo'])
                if (memo) ls.push({ t: 'value', label: fieldMeta(d, 'journal_entries', 'memo')[0], value: memo })
                ls.push(...rows.filter((x) => x.table === 'journal_lines' && x.op === 'INSERT').map((x) => journalLineLine(d, x)))
            }
            out.push({ title: withPart(tx(d, 'je.posted'), code), lines: ls, key: true, weight: isRoot ? 100 : 55, recordId: id })
        } else if (r.op === 'UPDATE' && changed(r, 'status') && str(r, 'status', 'new') === 'reversed') {
            const rev = str(r, 'reversed_by', 'new')
            // 冲销分录自己的页:它的建立那一句已经说了"Reverses JE-…"
            if (subject === 'journal_entry' && rev && rev === rootId) continue
            const revRow = rev ? jes.find((x) => idOf(x) === rev && x.op === 'INSERT') : undefined
            const ls: Line[] = []
            const v = docVal(d, r, 'journal_entries', 'reversed_by')
            if (v) ls.push({ t: 'value', label: tx(d, 'je.reversedByLine'), value: v })
            out.push({ title: isRoot ? tx(d, 'je.reversed') : tx(d, 'je.reversedOther', { code: code ?? '' }).replace(/\s+/g, ' '),
                       lines: ls, reason: revRow ? reversalReason(str(revRow, 'memo')) : null, key: true, weight: isRoot ? 95 : 55, recordId: id })
        } else {
            out.push({ ...describeGeneric(d, r, opts), title: withPart(tx(d, 'journal.edited'), code), weight: 25 })
        }
    }
    // 分录的行:只在它那张分录的建立里说(上面);一行单独出现(不该发生 —— 行只增不改)就照通用的说
    for (const r of by('journal_lines')) {
        const parent = str(r, 'entry_id')
        if (r.op === 'INSERT' && jes.some((x) => x.op === 'INSERT' && idOf(x) === parent)) continue
        out.push(describeGeneric(d, r, opts))
    }

    // ── ② 申请:人工分录 / 冲销 · 作废 / 贷项 · 六种付款申请 ─────────────────────────────────────
    for (const t of ['journal_requests', 'invoice_requests', 'payment_requests'] as const) {
        // 一张申请在【同一次操作】里建出来又被改(提交函数先插 submitted、再写金额;审批关着时当场翻成 approved)——
        //   那是一件事:改的那几列并进建立的影像,不另起一句("Request changed")
        const inserted = new Map<string, TrailRow>()
        for (const r of by(t)) if (r.op === 'INSERT' && idOf(r)) inserted.set(idOf(r)!, { ...r, new: { ...(r.new ?? {}) } })
        for (const r of by(t)) {
            const ins = r.op === 'UPDATE' && idOf(r) ? inserted.get(idOf(r)!) : undefined
            if (ins) { Object.assign(ins.new!, r.new ?? {}); ins.refs = mergeRefs(ins.refs, r.refs) }
        }
        for (const r0 of by(t)) {
            if (r0.op === 'UPDATE' && idOf(r0) && inserted.has(idOf(r0)!)) continue
            const r = r0.op === 'INSERT' && idOf(r0) ? inserted.get(idOf(r0)!) ?? r0 : r0
            const id = idOf(r)
            const kind = reqKind(r)
            const { code, part } = labelPart(r)
            const keyOf = (what: 'sent' | 'approved' | 'rejected' | 'withdrawn'): TrailTextKey => {
                if (t === 'journal_requests') {
                    const rev = kind === 'reversal'
                    return ({ sent: rev ? 'jr.sentReversal' : 'jr.sentEntry', approved: rev ? 'jr.approvedReversal' : 'jr.approvedEntry',
                              rejected: rev ? 'jr.rejectedReversal' : 'jr.rejectedEntry', withdrawn: rev ? 'jr.withdrawnReversal' : 'jr.withdrawnEntry' } as const)[what]
                }
                if (t === 'invoice_requests') {
                    const v = kind === 'void'
                    return ({ sent: v ? 'ir.sentVoid' : 'ir.sentCredit', approved: v ? 'ir.approvedVoid' : 'ir.approvedCredit',
                              rejected: v ? 'ir.rejectedVoid' : 'ir.rejectedCredit', withdrawn: v ? 'ir.withdrawnVoid' : 'ir.withdrawnCredit' } as const)[what]
                }
                return what === 'sent' ? prKey('pr.sent.', kind) : what === 'approved' ? prKey('pr.approved.', kind) : what === 'rejected' ? 'pr.rejected' : 'pr.withdrawn'
            }
            const skip = new Set(['code', 'label', 'kind', 'status', 'decided_at', 'decided_by', 'decision_notes', 'withdrawn_at', 'withdrawn_by',
                'withdraw_reason', 'paid_at', 'paid_by', 'lines', 'allocations', 'reason', 'notes', 'result_journal_entry_id', 'result_credit_note_id',
                'result_payment_id', 'result_transfer_id', 'counterparty_type', 'invoice_id', 'target_entry_id', 'credits_bank', 'memo'])
            const to = changed(r, 'status') ? str(r, 'status', 'new') : null
            if (r.op === 'INSERT') {
                const ls = valueLines(d, r, r.new, opts, skip)
                if (t === 'payment_requests') for (const a of allocationItems(d, r.new?.['allocations'], r.refs)) ls.push({ t: 'value', label: a.label, value: a.value })
                // Q32:审批关着时申请生下来就是 approved —— 标题说"批了",下面一行说是自动批的(与采购单同一句)
                // 只认两样:一行 auto_approved 留痕,或一张【插进来时】就是 approved 的付款申请(它的提交函数直接这样插)——
                //   不认"并进来之后的状态":一笔事务里提交又被人批了(线上的回滚证明就是这样),那是人批的,不是自动的
                const isAuto = auto(id) || (t === 'payment_requests' && str(r0, 'status', 'new') === 'approved')
                if (isAuto) ls.unshift({ t: 'note', text: tx(d, 'po.autoApproved') })
                // 一张冲销申请的 memo 是【为什么冲】(理由);一张人工分录申请的 memo 是那张分录的摘要(一个字段)
                const reversalAsk = t === 'journal_requests' && kind === 'reversal'
                if (t === 'journal_requests' && !reversalAsk) ls.push(...vline(d, r, 'memo', opts))
                // 同一次操作里建出来又被决定了(只有一笔事务做完全程才会这样)—— 标题说它最后到了哪一步
                const end = str(r, 'status', 'new')
                const what: 'sent' | 'approved' | 'rejected' = isAuto || end === 'approved' || end === 'paid' ? 'approved' : end === 'rejected' ? 'rejected' : 'sent'
                out.push({ title: withPart(tx(d, keyOf(what)), code), part, lines: ls,
                           reason: typed(r.new?.['reason'] ?? r.new?.['notes'] ?? (reversalAsk ? r.new?.['memo'] : null)), key: true, weight: 85, recordId: id, absorbsApproval: true })
            } else if (to === 'withdrawn' || isSet(r, 'withdrawn_at')) {
                out.push({ title: withPart(tx(d, keyOf('withdrawn')), code), part, lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 85, recordId: id, absorbsApproval: true })
            } else if (t === 'payment_requests' && (to === 'paid' || isSet(r, 'paid_at'))) {
                const ls: Line[] = []
                for (const c of ['result_payment_id', 'result_journal_entry_id']) {
                    const v = docVal(d, r, 'payment_requests', c)
                    if (v) ls.push({ t: 'value', label: fieldMeta(d, 'payment_requests', c)[0], value: v })
                }
                out.push({ title: withPart(tx(d, prKey('pr.done.', kind)), code), lines: ls, key: true, weight: 95, recordId: id, absorbsApproval: true })
            } else if (to === 'approved' || to === 'rejected') {
                out.push({ title: withPart(tx(d, keyOf(to)), code), part, lines: [], reason: typed(r.new?.['decision_notes']), key: true, weight: 90, recordId: id, absorbsApproval: true })
            } else if (r.op === 'UPDATE') {
                const ls = changeLines(d, r, opts, new Set(['decided_at', 'decided_by', 'amount_base', 'paid_at', 'paid_by']))
                if (ls.length) out.push({ title: withPart(tx(d, 'pr.changed'), code), part, lines: ls, key: false, weight: 35, recordId: id })
            } else out.push(describeGeneric(d, r, opts))
        }
    }
    // 审批留痕:并进它批的那张申请(foldApprovals);申请那一行不在这一条里(记录开始之前的决定)就自成一句
    out.push(...describeApproval(d, by('approval_log')))

    // ── ③ 发票 · 签发档 · 贷项通知 ───────────────────────────────────────────────────────
    const invLines = by('invoice_lines')
    for (const r of by('invoices')) {
        const code = str(r, 'code')
        if (r.op === 'INSERT') {
            const ls = vlines(d, r, ['customer_id', 'kind', 'sales_order_id', 'issue_date', 'due_date', 'currency'], opts)
            for (const l of invLines.filter((x) => x.op === 'INSERT')) ls.push(invoiceLineLine(d, l, opts))
            out.push({ title: withPart(tx(d, 'inv.issued'), code), lines: ls, key: true, weight: subject === 'invoice' ? 100 : 60 })
        } else if ((changed(r, 'status') && str(r, 'status', 'new') === 'void') || isSet(r, 'voided_at')) {
            out.push({ title: withPart(tx(d, 'inv.voided'), subject === 'invoice' ? null : code), lines: [], reason: typed(r.new?.['void_reason']), key: true, weight: 95 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'inv.edited'), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    const voidInGroup = by('invoices').some((r) => changed(r, 'status') || isSet(r, 'voided_at'))
    for (const r of invLines) {
        if (r.op === 'INSERT' && by('invoices').some((x) => x.op === 'INSERT')) continue
        // 作废那一笔里每一行的 invoice_voided 翻成 true —— 那是作废的副作用,不另说
        if (r.op === 'UPDATE' && voidInGroup && (r.cols ?? []).every((c) => c === 'invoice_voided')) continue
        const ls = r.op === 'UPDATE' ? changeLines(d, r, opts) : [invoiceLineLine(d, r, opts)]
        if (ls.length) out.push({ title: tx(d, 'inv.lineChanged'), lines: ls, key: false, weight: 30 })
    }
    for (const r of by('invoice_issues')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'inv.pdfIssued', { version: num(r.new?.['version'] ?? null) ?? '' }), lines: [], key: true, weight: 60 })
    }
    const cnLines = by('credit_note_lines')
    for (const r of by('credit_notes')) {
        const code = str(r, 'code')
        if (r.op !== 'INSERT') { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'cnote.changed'), lines: ls, key: false, weight: 30 }); continue }
        const ls = vlines(d, r, subject === 'credit_note' ? ['invoice_id', 'note_date', 'currency'] : ['note_date'], opts)
        for (const l of cnLines.filter((x) => x.op === 'INSERT')) ls.push(creditLineLine(d, l, opts))
        out.push({ title: withPart(tx(d, 'cnote.issued'), code), lines: ls, reason: typed(r.new?.['reason']), key: true, weight: subject === 'credit_note' ? 100 : 75 })
    }
    for (const r of cnLines) {
        if (r.op === 'INSERT' && by('credit_notes').some((x) => x.op === 'INSERT')) continue
        out.push({ title: tx(d, 'cnote.changed'), lines: r.op === 'UPDATE' ? changeLines(d, r, opts) : [creditLineLine(d, r, opts)], key: false, weight: 30 })
    }
    for (const r of by('cn_issues')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'cnote.pdfIssued', { version: num(r.new?.['version'] ?? null) ?? '' }), lines: [], key: true, weight: 60 })
    }

    // ── ④ 收付款(Q31)───────────────────────────────────────────────────────────────
    const allocs = by('payment_allocations')
    const pays = by('payments')
    for (const r of pays) {
        const id = idOf(r) ?? ''
        const code = str(r, 'code')
        const inbound = str(r, 'direction') === 'in'
        if (r.op === 'INSERT' && fc.paymentMirror.has(id)) {
            // 一笔冲销(镜像单)的建立:说成原单被冲销(Q31),镜像单号是下面一行
            const orig = fc.paymentOrigin.get(id)
            out.push({ title: withPart(tx(d, inbound ? 'pay.reversedIn' : 'pay.reversedOut'), orig?.code ?? null),
                       lines: [{ t: 'value', label: tx(d, 'pay.reversingLine'), value: fc.paymentMirror.get(id)?.href && code ? { text: code, href: fc.paymentMirror.get(id)!.href! } : { text: code ?? tx(d, 'value.unnamed', { thing: thing(d, 'payments') }) } }],
                       reason: reversalReason(str(r, 'notes')), key: true, weight: subject === 'payment' ? 95 : 65, recordId: id })
            continue
        }
        if (r.op === 'INSERT') {
            const ls = subject === 'payment' && id === rootId
                ? vlines(d, r, ['payment_date', 'counterparty_type', 'customer_id', 'supplier_id', 'employee_id', 'amount_ccy', 'amount_base', 'fx_rate', 'bank_account_code'], opts)
                : vlines(d, r, ['amount_ccy'], opts)
            for (const a of allocs.filter((x) => x.op === 'INSERT' && str(x, 'payment_id') === id)) ls.push(allocationLine(d, a, opts, 'payment'))
            out.push({ title: withPart(tx(d, inbound ? 'pay.recordedIn' : 'pay.recordedOut'), code), lines: ls, reason: typed(r.new?.['notes']),
                       key: true, weight: subject === 'payment' && id === rootId ? 100 : 65, recordId: id })
            continue
        }
        if (changed(r, 'reversed_by_payment') || (changed(r, 'status') && str(r, 'status', 'new') === 'reversed')) {
            const m = str(r, 'reversed_by_payment', 'new')
            if (m && pays.some((x) => x.op === 'INSERT' && idOf(x) === m)) continue    // 镜像单的建立已经说了
            const v = docVal(d, r, 'payments', 'reversed_by_payment')
            out.push({ title: withPart(tx(d, inbound ? 'pay.reversedIn' : 'pay.reversedOut'), code), lines: v ? [{ t: 'value', label: tx(d, 'pay.reversingLine'), value: v }] : [], key: true, weight: 90, recordId: id })
            continue
        }
        const ls = changeLines(d, r, opts)
        if (ls.length) out.push({ title: withPart(tx(d, 'pay.changed'), code), lines: ls, key: false, weight: 30 })
    }
    for (const r of allocs) {
        if (r.op === 'INSERT' && pays.some((x) => x.op === 'INSERT' && idOf(x) === str(r, 'payment_id') && !fc.paymentMirror.has(idOf(x) ?? ''))) continue
        if (r.op === 'DELETE') { out.push({ title: tx(d, 'pay.allocationRemoved'), lines: [allocationLine(d, r, opts, subject)], key: true, weight: 50 }); continue }
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'pay.allocatedTo'), refLabel(r, 'payment_id')), lines: [allocationLine(d, r, opts, subject)], key: true, weight: 60 })
    }

    // ── ⑤ 付款申请的结果:转账 · 代扣税缴纳(在"付了"那一句里只说一次)─────────────────────────────────
    const doneBlock = out.find((b) => PR_KINDS.some((k) => b.title.startsWith(tx(d, PR_TEXT.done[k]))))
    for (const r of by('bank_transfers')) {
        const ls = r.op === 'INSERT' ? vlines(d, r, ['transfer_date', 'from_account', 'to_account', 'amount_out', 'amount_in', 'bank_reference'], opts)
            : isSet(r, 'reversed_at') ? vlines(d, r, ['reversal_entry_id'], opts) : changeLines(d, r, opts)
        if (doneBlock) { doneBlock.lines.push(...ls); continue }
        out.push({ title: tx(d, r.op === 'INSERT' ? 'pr.done.bank_transfer' : isSet(r, 'reversed_at') ? 'pr.done.bank_transfer_reversal' : 'pr.changed'), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 70 })
    }
    for (const r of by('wht_remittances')) {
        const ls = r.op === 'INSERT' ? vlines(d, r, ['period_month', 'amount_base', 'remitted_on', 'filed_reference'], opts) : changeLines(d, r, opts)
        if (doneBlock) { doneBlock.lines.push(...ls); continue }
        out.push({ title: withPart(tx(d, r.op === 'INSERT' ? 'pr.done.wht_remittance' : 'pr.changed'), str(r, 'code')), lines: ls, key: true, weight: 70 })
    }

    // ── ⑥ 费用 · 报销单 · 资本化 · 定金冲抵 ───────────────────────────────────────────────
    const exps = by('expenses')
    for (const r of exps) {
        const id = idOf(r) ?? ''
        const code = str(r, 'code')
        if (r.op === 'INSERT' && fc.expenseMirror.has(id)) {
            const orig = fc.expenseOrigin.get(id)
            const href = fc.expenseMirror.get(id)?.href
            out.push({ title: withPart(tx(d, 'exp.reversed'), orig?.code ?? null),
                       lines: [{ t: 'value', label: tx(d, 'pay.reversingLine'), value: href && code ? { text: code, href } : { text: code ?? tx(d, 'value.unnamed', { thing: thing(d, 'expenses') }) } }],
                       reason: reversalReason(str(r, 'notes')), key: true, weight: subject === 'expense' ? 95 : 65, recordId: id })
            continue
        }
        if (r.op === 'INSERT') {
            const root = subject === 'expense' && id === rootId
            const ls = root ? vlines(d, r, ['expense_date', 'supplier_id', 'payee_name', 'employee_id', 'account_code', 'amount_ccy', 'tax_ccy', 'amount_base',
                'payment_status', 'bank_account_code', 'wht_nature', 'wht_rate_pct', 'wht_amount_ccy', 'purchase_order_line_id'], opts) : vlines(d, r, ['amount_ccy'], opts)
            out.push({ title: withPart(tx(d, 'exp.recorded'), code), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: root ? 100 : 65, recordId: id })
            continue
        }
        if (changed(r, 'reversed_by_expense') || (changed(r, 'status') && str(r, 'status', 'new') === 'reversed')) {
            const m = str(r, 'reversed_by_expense', 'new')
            if (m && exps.some((x) => x.op === 'INSERT' && idOf(x) === m)) continue
            const v = docVal(d, r, 'expenses', 'reversed_by_expense')
            out.push({ title: withPart(tx(d, 'exp.reversed'), code), lines: v ? [{ t: 'value', label: tx(d, 'pay.reversingLine'), value: v }] : [], key: true, weight: 90, recordId: id })
            continue
        }
        const ls = changeLines(d, r, opts)
        if (ls.length) out.push({ title: withPart(tx(d, 'exp.changed'), code), lines: ls, key: changed(r, 'payment_status'), weight: 30 })
    }
    for (const r of by('expense_claims')) {
        const id = idOf(r)
        const code = str(r, 'code')
        const to = changed(r, 'status') ? str(r, 'status', 'new') : (r.prelog && (r.cols ?? []).includes('decided_at')) ? str(r, 'status', 'new') : null
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'exp.claimSubmitted'), code), lines: vlines(d, r, ['employee_id', 'spend_date', 'account_code', 'amount_ccy'], opts),
                                          reason: typed(r.new?.['description']), key: true, weight: 70, recordId: id, absorbsApproval: true })
        else if (to === 'approved' || to === 'rejected') out.push({ title: withPart(tx(d, to === 'approved' ? 'exp.claimApproved' : 'exp.claimRejected'), code), lines: [],
                                          reason: typed(r.new?.['decision_notes']), key: true, weight: 80, recordId: id, absorbsApproval: true })
        else if (to === 'withdrawn' || isSet(r, 'withdrawn_at')) out.push({ title: withPart(tx(d, 'exp.claimWithdrawn'), code), lines: [], key: true, weight: 80, recordId: id, absorbsApproval: true })
        else if (r.op === 'UPDATE') { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: withPart(tx(d, 'exp.claimChanged'), code), lines: ls, key: false, weight: 30, recordId: id }) }
        else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('fixed_asset_cost_entries')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'exp.capitalised'), refLabel(r, 'asset_id')), lines: vlines(d, r, ['amount_ccy', 'amount_base'], opts), key: true, weight: 60 })
    }
    for (const r of by('prepayment_applications')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const ls = vlines(d, r, [subject === 'expense' ? 'purchase_order_id' : 'expense_id', 'amount_ccy', 'amount_base'], opts)
        out.push({ title: tx(d, subject === 'expense' ? 'exp.prepaymentReleased' : 'batch.prepayment'), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 60 })
    }
    for (const r of by('finance_attachments')) {
        const part = typed(str(r, 'file_name'))
        if (r.op === 'INSERT') out.push({ title: tx(d, 'batch.attachmentAdded'), part, lines: vlines(d, r, ['doc_type'], opts), key: false, weight: 30 })
        else if (r.op === 'DELETE' || isSet(r, 'deleted_at')) out.push({ title: tx(d, 'batch.attachmentRemoved'), part, lines: [], key: false, weight: 30 })
        else { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'batch.attachmentAdded'), part, lines: ls, key: false, weight: 20 }) }
    }

    // ── ⑦ 应付(Q5:批次只说钱的那一面 —— root_columns 已经把仓库那一面挡在读法那一层)──────────────────────
    const prices = by('price_history')
    for (const r of by('inbound_batches')) {
        if (r.op === 'INSERT') {
            out.push({ title: withPart(tx(d, 'batch.received'), qtyText(d, r, 'quantity', opts)),
                       lines: vlines(d, r, ['supplier_id', 'purchase_order_id', 'unit_price', 'arrival_date'], opts), key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        if (isSet(r, 'deleted_at')) { out.push({ title: tx(d, 'batch.writtenOff'), lines: [], reason: typed(r.new?.['delete_reason']), key: true, weight: 95 }); continue }
        const skip = new Set(['deleted_at', 'deleted_by', 'delete_reason'])
        if (prices.length) { for (const c of ['unit_price', 'pricing_status']) skip.add(c) }
        const ls = changeLines(d, r, opts, skip)
        const priced = changed(r, 'unit_price') && !prices.length
        if (ls.length) out.push({ title: tx(d, priced ? 'pab.priceSet' : 'pab.edited'), lines: ls, key: priced, weight: priced ? 60 : 30 })
    }
    for (const r of prices) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const img = imgOf(r)
        const ls: Line[] = [{ t: 'change', label: fieldMeta(d, 'inbound_batches', 'unit_price')[0],
            old: formatValue(d, 'price_history', 'old_unit_price', r.new?.['old_unit_price'], img, r.refs, 'INSERT', opts),
            new: formatValue(d, 'price_history', 'new_unit_price', r.new?.['new_unit_price'], img, r.refs, 'INSERT', opts) }]
        out.push({ title: tx(d, 'batch.priceChanged'), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 70 })
    }
    for (const r of by('freight_allocations')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'batch.freight'), refLabel(r, 'freight_document_id')), lines: vlines(d, r, ['amount_base'], opts), key: true, weight: 50 })
    }

    // 别的表(这几页的登记表之外不该出现;出现了照通用的说,不丢)
    const known = new Set(['journal_entries', 'journal_lines', 'journal_requests', 'invoice_requests', 'payment_requests', 'approval_log', 'invoices',
        'invoice_lines', 'invoice_issues', 'credit_notes', 'credit_note_lines', 'cn_issues', 'payments', 'payment_allocations', 'bank_transfers',
        'wht_remittances', 'expenses', 'expense_claims', 'fixed_asset_cost_entries', 'prepayment_applications', 'finance_attachments',
        'inbound_batches', 'price_history', 'freight_allocations'])
    for (const r of rows) if (r.table && !known.has(r.table)) out.push(describeGeneric(d, r, opts))
    return out
}
function invoiceLineLine(d: TrailDict, r: TrailRow, opts: BuildOptions): Line {
    const img = imgOf(r)
    const n = num(img['line_no'] ?? null)
    const desc = typeof img['description'] === 'string' ? img['description'] as string : null
    const q = formatValue(d, 'invoice_lines', 'quantity', img['quantity'], img, r.refs, r.op, opts)
    const p = formatValue(d, 'invoice_lines', 'unit_price', img['unit_price'], img, r.refs, r.op, opts)
    const label = [n !== null ? tx(d, 'po.lineHeading', { n }) : cap(thing(d, 'invoice_lines')), desc].filter(Boolean).join(' · ')
    return { t: 'value', label, value: { text: [q.text, p.empty ? '' : `@ ${p.text}`].filter(Boolean).join(' '), restricted: p.restricted } }
}
function creditLineLine(d: TrailDict, r: TrailRow, opts: BuildOptions): Line {
    const img = imgOf(r)
    const what = refLabel(r, 'invoice_line_id') ?? cap(thing(d, 'credit_note_lines'))
    const amt = formatValue(d, 'credit_note_lines', 'amount', img['amount'], img, r.refs, r.op, opts)
    const kind = typeof img['kind'] === 'string' ? enumLabel(d, 'credit_note_lines', 'kind', img['kind'] as string) : null
    return { t: 'value', label: what, value: { text: [amt.text, kind].filter(Boolean).join(' · '), restricted: amt.restricted } }
}
/** 一行核销:在收付款页上说它冲的是哪一张单据;在单据页上说是哪一笔款 */
function allocationLine(d: TrailDict, r: TrailRow, opts: BuildOptions, subject: string): Line {
    const img = imgOf(r)
    const amt = formatValue(d, 'payment_allocations', 'allocated_base', img['allocated_base'], img, r.refs, r.op, opts)
    if (subject === 'payment') {
        for (const c of ['invoice_id', 'expense_id', 'inbound_batch_id', 'purchase_order_id', 'freight_document_id', 'sales_record_id']) {
            const v = img[c]
            if (typeof v === 'string') return { t: 'value', label: refVal(d, 'payment_allocations', c, v, r.refs).text, value: amt }
        }
    }
    return { t: 'value', label: tx(d, 'pay.allocated'), value: amt }
}

/** 审批与它批的那件事在同一笔事务里(工单放行、盘点过账、仓库申请的决定)→ 并成一句:审批落成那一块下面的一行说明 */
function foldApprovals(blocks: Block2[]): Block2[] {
    const out: Block2[] = []
    for (const b of blocks) {
        if (b.approvalFor) {
            const target = blocks.find((x) => x !== b && x.recordId === b.approvalFor)
            if (target) {
                // 一块自己已经说出了那一步(absorbsApproval):审批的标题与说明都不再说一遍 —— 供应商的状态史与审批留痕
                //   由同一句 p_note 写成,那一句已经是这一块的理由(或它的 Note 行)
                if (!target.absorbsApproval) {
                    target.lines.push({ t: 'note', text: b.title })
                    if (!target.reason && b.reason) target.reason = b.reason
                }
                continue
            }
        }
        out.push(b)
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════
// 组装
// ════════════════════════════════════════════════════════════════════════════
function whoOf(d: TrailDict, rows: TrailRow[]): Val {
    const visible = rows.filter((r) => !r.hidden)
    if (!visible.length) return { text: tx(d, 'restricted'), restricted: true }
    const withPerson = visible.find((r) => r.actor?.state === 'person') ?? visible.find((r) => r.actor && r.actor.state !== 'unknown') ?? visible[0]
    return personVal(d, withPerson.actor)
}

/** 同一笔事务里对同一行的几次编辑 → 一次(列取并集,旧值取第一次的,新值取最后一次的)。
 *  "Line 1" 在一次修改里被改了两处,读起来是一条"Line 1"下面两行,不是两个"Line 1"。 */
function mergeUpdates(rows: TrailRow[]): TrailRow[] {
    const out: TrailRow[] = []
    const seen = new Map<string, TrailRow>()
    for (const r of rows) {
        if (r.op !== 'UPDATE' || r.hidden || r.restricted || !r.table || !r.key || r.prelog) { out.push(r); continue }
        const k = r.table + '|' + JSON.stringify(r.key)
        const prev = seen.get(k)
        if (!prev) {
            const copy = { ...r, cols: [...(r.cols ?? [])], old: { ...(r.old ?? {}) }, new: { ...(r.new ?? {}) } }
            seen.set(k, copy)
            out.push(copy)
            continue
        }
        for (const c of r.cols ?? []) {
            if (!prev.cols!.includes(c)) { prev.cols!.push(c); prev.old![c] = r.old?.[c] ?? null }
            prev.new![c] = r.new?.[c] ?? null
        }
        prev.refs = mergeRefs(prev.refs, r.refs)
    }
    return out
}
function mergeRefs(a: Refs | null, b: Refs | null): Refs | null {
    if (!a) return b
    if (!b) return a
    const out: Refs = { ...a }
    for (const [c, m] of Object.entries(b)) out[c] = { ...(out[c] ?? {}), ...m }
    return out
}
function dedupeHeadings(lines: Line[]): Line[] {
    const out: Line[] = []
    let lastHeading: string | null = null
    for (const l of lines) {
        if (l.t === 'heading') {
            const k = l.text + '\u0000' + (l.part?.text ?? '')
            if (k === lastHeading) continue
            lastHeading = k
        }
        out.push(l)
    }
    return out
}
function commonRecord(rs: TrailRow[]): RecordRef | null {
    const count = new Map<string, { n: number; r: RecordRef }>()
    for (const x of rs) {
        if (!x.record || !x.record.id) continue
        const k = x.record.table + '|' + x.record.id
        const c = count.get(k)
        if (c) c.n++
        else count.set(k, { n: 1, r: x.record })
    }
    let best: { n: number; r: RecordRef } | null = null
    for (const c of count.values()) if (!best || c.n > best.n) best = c
    return best?.r ?? rs.find((x) => x.record)?.record ?? null
}

export function buildEntries(d: TrailDict, rows: TrailRow[], opts: BuildOptions = {}): Entry[] {
    // 一张冲销分录:它自己没有任何一列说"我是冲销"(只有原分录的 reversed_by 指着它)。整页的行里,凡是被别的分录
    // 今天的 reversed_by 指着的,就是冲销 —— 结构上认,绝不读 memo(fixture 181 D 臂)
    const reversals = new Set<string>()
    for (const r of rows) {
        const by = r.table === 'journal_entries' ? (r.ctx?.['reversed_by'] ?? r.new?.['reversed_by']) : null
        if (typeof by === 'string') reversals.add(by)
    }
    // AUDIT-TRAIL-1b-3:任务修改史的"打勾 / 改日期"那几行只带着步骤的 id,不带名字 —— 名字从整页的行里找
    //   (步骤那一行今天的样子、它的新增影像、修改史里写着的新旧名字),与上面认冲销分录同一个做法:看整页,不只看这一条
    const stepTitles = new Map<string, string>()
    for (const r of rows) {
        if (r.table === 'task_nodes') {
            const id = typeof r.key?.['id'] === 'string' ? r.key['id'] as string : null
            const t = [r.ctx?.['title'], r.new?.['title'], r.old?.['title']].find((x) => typeof x === 'string' && x)
            if (id && typeof t === 'string' && !stepTitles.has(id)) stepTitles.set(id, t)
        } else if (r.table === 'task_history') {
            const id = r.new?.['node_id']
            const t = [r.new?.['new_node_title'], r.new?.['old_node_title']].find((x) => typeof x === 'string' && x)
            if (typeof id === 'string' && typeof t === 'string' && !stepTitles.has(id)) stepTitles.set(id, t)
        }
    }
    const fc = opts.subject && FIN_SUBJECTS.has(opts.subject) ? finContext(rows) : null
    const groups = new Map<string, TrailRow[]>()
    for (const r of rows) {
        const g = groups.get(r.group)
        if (g) g.push(r)
        else groups.set(r.group, [r])
    }
    const out: Entry[] = []
    for (const [key, rs] of [...groups.entries()].sort((a, b) => a[1][0].order - b[1][0].order)) {
        const at = rs.reduce((m, r) => (r.at > m ? r.at : m), rs[0].at)
        const visible = mergeUpdates(rs.filter((r) => !r.hidden))
        const record = commonRecord(rs)
        const base: Omit<Entry, 'title' | 'titlePart' | 'lines' | 'reason' | 'keyEvent' | 'titleRestricted'> = {
            key, at, atText: d.formatStamp(at), who: whoOf(d, rs), prelog: rs.some((r) => r.prelog), record }
        if (!visible.length) {
            out.push({ ...base, title: tx(d, 'restricted'), titlePart: null, titleRestricted: true, lines: [], reason: null, keyEvent: true })
            continue
        }
        // 任务隐私:整份影像受限的行只说"这一类记录被改过",内容受限
        let blocks: Block2[] = []
        const byFamily = new Map<Family, TrailRow[]>()
        const others: TrailRow[] = []
        for (const r of visible) {
            if (r.restricted) { blocks.push({ title: cap(thing(d, r.table)), lines: [{ t: 'value', label: cap(thing(d, r.table)), value: { text: tx(d, 'restricted'), restricted: true } }], key: false, weight: 10 }); continue }
            const f = familyOf(r, opts.subject)
            if (f) byFamily.set(f, [...(byFamily.get(f) ?? []), r])
            else others.push(r)
        }
        const pageFamily = opts.subject ? PAGE_FAMILY[opts.subject] : null
        for (const [f, list] of byFamily) {
            let bs: Block2[]
            switch (f) {
                case 'po': bs = describePurchaseOrder(d, list, opts); break
                case 'run': bs = describeRun(d, list, opts); break
                case 'role': bs = describeRole(d, list, opts); break
                case 'batch': bs = describeBatch(d, list, opts, opts.subject); break
                case 'journal': bs = describeJournal(d, list, opts, reversals); break
                case 'approval': bs = describeApproval(d, list); break
                case 'wo': bs = describeWorkOrder(d, list, opts); break
                case 'stocktake': bs = describeStocktake(d, list, opts, opts.subject); break
                case 'equipment': bs = describeEquipment(d, list, opts, opts.subject); break
                case 'handover': bs = describeHandover(d, list, opts); break
                case 'wr': bs = describeWarehouseRequest(d, list, opts); break
                case 'so': bs = describeSalesOrder(d, list, opts); break
                case 'quote': bs = describeQuote(d, list, opts); break
                case 'shipment': bs = describeShipment(d, list, opts); break
                case 'customer': bs = describeCustomer(d, list, opts); break
                case 'commission': bs = describeCommission(d, list, opts); break
                case 'supplier': bs = describeSupplier(d, list, opts, opts.subject); break
                case 'container': bs = describeContainer(d, list, opts); break
                case 'lane': bs = describeLane(d, list, opts); break
                case 'licence': bs = describeLicence(d, list, opts); break
                case 'material': bs = describeMaterial(d, list, opts); break
                case 'location': bs = describeLocation(d, list, opts); break
                case 'metalPrice': bs = describeMetalPrice(d, list, opts); break
                case 'formula': bs = describeFormula(d, list, opts); break
                case 'task': bs = describeTask(d, list, opts, stepTitles); break
                case 'settings': bs = describeSettings(d, list, opts); break
                case 'fin': bs = describeFinance(d, list, opts, reversals, fc ?? finContext(rows)); break
                default: bs = []
            }
            // 别的记录的事(往上一跳够到的、审批、分录)永远不当这一条的标题 —— 这一页自己那件事在,标题就是它
            if (pageFamily && pageFamily !== f) for (const b of bs) b.weight = Math.min(b.weight, 60)
            // 往上一跳够到的(批次页上的采购单审批、加工单的成本修改、工单的修改史):标题后面点名它属于哪一张单据
            if (pageFamily && pageFamily !== f && HEADED.has(f)) {
                const lab = docLabel(list)
                if (lab) for (const b of bs) if (!b.title.includes(lab)) b.title = `${b.title} · ${lab}`
            }
            blocks.push(...bs)
        }
        for (const r of others) blocks.push(describeGeneric(d, r, opts))
        blocks = foldApprovals(blocks)
        const meaningful = blocks.filter((b) => b.lines.length || b.key || b.reason)
        if (!meaningful.length) {
            // 一行都印不出来(只动了隐藏列)—— 仍然说出发生过一次编辑,不留一条空记录
            const t0 = visible[0]
            meaningful.push({ title: tx(d, 'generic.edited', { thing: thing(d, t0.table) }), lines: [], key: false, weight: 0 })
        }
        meaningful.sort((a, b) => b.weight - a.weight)
        const [head, ...rest] = meaningful
        const lines: Line[] = [...head.lines]
        let reason = head.reason ?? null
        for (const b of rest) {
            if ((b.title !== head.title || b.part) && !b.lines.some((l) => l.t === 'heading')) lines.push({ t: 'heading', text: b.title, part: b.part ?? null })
            lines.push(...b.lines)
            if (!reason && b.reason) reason = b.reason
        }
        if (rs.some((r) => r.hidden)) lines.push({ t: 'note', text: tx(d, 'restrictedPart') })
        out.push({ ...base, title: head.title, titlePart: head.part ?? null, titleRestricted: false, lines: dedupeHeadings(lines), reason,
                   keyEvent: meaningful.some((b) => b.key) })
    }
    return out
}

/** record_trail 的一行 → TrailRow */
export function fromRecordTrail(r: {
    entry_no: number; prelog: boolean; seq: number | null; occurred_at: string; table_name: string | null; row_key: Json;
    op: string | null; actor: Json; changed_columns: string[] | null; old: Json; new: Json; ctx: Json; refs: Json;
    row_hidden: boolean; row_restricted: boolean; op_key?: string | null
}): TrailRow {
    return {
        group: 'E' + r.entry_no, order: r.entry_no, prelog: r.prelog, at: r.occurred_at, table: r.table_name, opKey: r.op_key ?? null,
        key: (r.row_key as Img) ?? null, op: r.op, actor: (r.actor as Actor) ?? null, cols: r.changed_columns,
        old: (r.old as Img) ?? null, new: (r.new as Img) ?? null, ctx: (r.ctx as Img) ?? null, refs: (r.refs as Refs) ?? null,
        hidden: r.row_hidden, restricted: r.row_restricted,
    }
}

/** change_log_rows 的一行 → TrailRow(order 由调用方按页内先后给)*/
export function fromChangeLog(r: {
    seq: number; occurred_at: string; table_name: string; row_key: Json; op: string; actor: Json;
    changed_columns: string[] | null; old: Json; new: Json; row_restricted: boolean; txid: number; belongs_to: Json; refs: Json
}, order: number): TrailRow {
    return {
        group: 'T' + r.txid, order, prelog: false, at: r.occurred_at, table: r.table_name, key: (r.row_key as Img) ?? null,
        op: r.op, actor: (r.actor as Actor) ?? null, cols: r.changed_columns, old: (r.old as Img) ?? null,
        new: (r.new as Img) ?? null, ctx: null, refs: (r.refs as Refs) ?? null, hidden: false, restricted: r.row_restricted,
        record: (r.belongs_to as RecordRef) ?? null,
    }
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-1(Q16):清单页把几条记录合成一块时,【一次操作只说一次】
// ════════════════════════════════════════════════════════════════════════════
/** 一行的身份:记录开始之后是它的 seq(全库唯一);之前是 表 · 键 · 操作 · 时刻 · 改了哪几列(拼回来的行没有 seq)。
 *  受限的行(读者看不见)没有表、没有键 —— 不去重(两条记录各看不见一行,不能断言那是同一行) */
export function mergeKey(r: TrailRow, seq: number | null | undefined): string | null {
    if (!r.table || r.hidden) return null
    if (seq !== null && seq !== undefined) return `L|${seq}`
    return `P|${r.table}|${JSON.stringify(r.key)}|${r.op}|${r.at}|${(r.cols ?? []).join(',')}`
}
export type ListRecord = { subject: string; id: string; label: string }
/** 几条记录读回来的行(已按 mergeKey 去重)→ 一次操作一条:同一个 op_key 的行交给同一次 buildEntries,
 *  Record 一栏列出这次操作碰到的每一条记录(按清单上的先后)。没有 op_key 的行(旧读法)按"记录 · 条"各自成条。 */
export function mergeByOperation(d: TrailDict, items: { row: TrailRow; rec: ListRecord }[]): (Entry & { recordText: string; recordHref: null })[] {
    const ops = new Map<string, { rows: TrailRow[]; recs: ListRecord[] }>()
    for (const { row, rec } of items) {
        const k = row.opKey ?? `${rec.subject}:${rec.id}:${row.group}`
        const g = ops.get(k) ?? { rows: [], recs: [] }
        g.rows.push({ ...row, group: k, order: 0 })
        if (!g.recs.some((x) => x.subject === rec.subject && x.id === rec.id)) g.recs.push(rec)
        ops.set(k, g)
    }
    const out: (Entry & { recordText: string; recordHref: null })[] = []
    for (const [k, g] of ops) {
        const [first] = g.recs
        for (const e of buildEntries(d, g.rows, { subject: first.subject, recordId: first.id })) {
            out.push({ ...e, key: k, recordText: g.recs.map((x) => x.label).join(' · '), recordHref: null })
        }
    }
    return out
}
