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
export type Ref = { label?: string | null; gone?: boolean; unit?: string | null; person?: Actor } | null
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
}

export type Val = { text: string; restricted?: boolean; empty?: boolean; typed?: boolean; full?: string }
export type Line =
    | { t: 'change'; label: string; old: Val; new: Val }
    | { t: 'value'; label: string; value: Val }
    | { t: 'heading'; text: string }
    | { t: 'note'; text: string }
export type Entry = {
    key: string
    at: string
    atText: string
    who: Val
    title: string
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
    return v === null || v === undefined || (typeof v === 'string' && v.trim() === '')
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

function currencyFor(col: string, img: Img, opts: BuildOptions, d: TrailDict): string | null {
    if (/_base$/.test(col) || /^(old|new)_amount_base$/.test(col)) return d.baseCurrency
    // 列名里写着币种的(…_usd_per_tonne)—— 它的标签已经说了 "(USD/t)",值本身不再挂币种(币种是数据,不写字面量)
    if (/_usd(_|$)/.test(col)) return null
    const c = img['currency']
    if (typeof c === 'string' && c) return c
    return opts.currency ?? null
}
/** 数量单位的说法:认得的(kg、t、units…)照英文目录说,短的小写字母照原样(它本来就是一个单位),其余按人话说 */
function unitText(d: TrailDict, raw: string): string {
    const known = d.enums['purchase_order_lines#unit']?.[raw]
    if (known) return known
    return /^[a-z]{1,6}$/i.test(raw) ? raw : humanize(raw).toLowerCase()
}
function unitFor(d: TrailDict, col: string, img: Img, refs: Refs | null, opts: BuildOptions): string | null {
    const own = img['unit'] ?? img[col.replace(/quantity|qty/, 'unit')]
    if (typeof own === 'string' && own) return unitText(d, own)
    for (const c of ['inbound_batch_id', 'output_batch_id']) {
        const v = img[c]
        const u = typeof v === 'string' ? refs?.[c]?.[v]?.unit : null
        if (u) return unitText(d, u)
    }
    return opts.unit ? unitText(d, opts.unit) : null
}
function isQuantity(col: string): boolean {
    return /quantity|_qty$|^total_(input|output)$|^basis_(total_)?qty$/.test(col)
}

function personVal(d: TrailDict, a: Actor): Val {
    if (!a) return { text: tx(d, 'who.unknown') }
    switch (a.state) {
        case 'person': return { text: a.name ?? tx(d, 'who.unknown') }
        case 'system': return { text: tx(d, 'who.system') }
        case 'removed': return { text: tx(d, 'who.removed') }
        case 'unlinked': return { text: tx(d, 'who.unlinked') }
        case 'anonymised': return { text: tx(d, 'who.anonymised') }
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
                const ccy = currencyFor(col, img, opts, d)
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
            return jsonVal(d, table, col, v, op, opts)
        case 'array':
            if (Array.isArray(v)) return truncate(v.filter((x) => typeof x === 'string' || typeof x === 'number').map(String).join(', '), true)
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
/** 一行整份影像(新增 / 删除)的逐列行:只印有值、该印的列 */
function valueLines(d: TrailDict, r: TrailRow, image: Img | null, opts: BuildOptions, skip: Set<string> = new Set()): Line[] {
    const out: Line[] = []
    if (!image) return out
    const img = imgOf(r)
    for (const [c, v] of Object.entries(image)) {
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
type Block = { title: string; lines: Line[]; reason?: Val | null; key: boolean; weight: number }

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
// 组装
// ════════════════════════════════════════════════════════════════════════════
function subjectOf(table: string | null): 'po' | 'run' | 'role' | null {
    if (!table) return null
    if (PO_TABLES.has(table)) return 'po'
    if (RUN_TABLES.has(table)) return 'run'
    if (table === 'roles' || table === 'role_permissions') return 'role'
    return null
}

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
            if (l.text === lastHeading) continue
            lastHeading = l.text
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
        const base: Omit<Entry, 'title' | 'lines' | 'reason' | 'keyEvent' | 'titleRestricted'> = {
            key, at, atText: d.formatStamp(at), who: whoOf(d, rs), prelog: rs.some((r) => r.prelog), record }
        if (!visible.length) {
            out.push({ ...base, title: tx(d, 'restricted'), titleRestricted: true, lines: [], reason: null, keyEvent: true })
            continue
        }
        // 任务隐私:整份影像受限的行只说"这一类记录被改过",内容受限
        const blocks: Block[] = []
        const bySubject: Record<string, TrailRow[]> = {}
        const others: TrailRow[] = []
        for (const r of visible) {
            if (r.restricted) { blocks.push({ title: cap(thing(d, r.table)), lines: [{ t: 'value', label: cap(thing(d, r.table)), value: { text: tx(d, 'restricted'), restricted: true } }], key: false, weight: 10 }); continue }
            const s = subjectOf(r.table)
            if (s) (bySubject[s] ??= []).push(r)
            else others.push(r)
        }
        if (bySubject.po) blocks.push(...describePurchaseOrder(d, bySubject.po, opts))
        if (bySubject.run) blocks.push(...describeRun(d, bySubject.run, opts))
        if (bySubject.role) blocks.push(...describeRole(d, bySubject.role, opts))
        for (const r of others) blocks.push(describeGeneric(d, r, opts))
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
            if (b.title !== head.title && !b.lines.some((l) => l.t === 'heading')) lines.push({ t: 'heading', text: b.title })
            lines.push(...b.lines)
            if (!reason && b.reason) reason = b.reason
        }
        if (rs.some((r) => r.hidden)) lines.push({ t: 'note', text: tx(d, 'restrictedPart') })
        out.push({ ...base, title: head.title, titleRestricted: false, lines: dedupeHeadings(lines), reason,
                   keyEvent: meaningful.some((b) => b.key) })
    }
    return out
}

/** record_trail 的一行 → TrailRow */
export function fromRecordTrail(r: {
    entry_no: number; prelog: boolean; seq: number | null; occurred_at: string; table_name: string | null; row_key: Json;
    op: string | null; actor: Json; changed_columns: string[] | null; old: Json; new: Json; ctx: Json; refs: Json;
    row_hidden: boolean; row_restricted: boolean
}): TrailRow {
    return {
        group: 'E' + r.entry_no, order: r.entry_no, prelog: r.prelog, at: r.occurred_at, table: r.table_name,
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
