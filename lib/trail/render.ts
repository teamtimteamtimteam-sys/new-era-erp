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
    /** AUDIT-TRAIL-1c-3:银行户 → 它的本币(lib/currencyMap.ts 的 currencyOfBank —— 全仓唯一写着币种代码的那一份)。
     *  行内转账的两条腿各是各的币种:付出的那一条按出款户,收到的那一条按入款户 */
    bankCurrency?: (code: string) => string | undefined
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
    // AUDIT-TRAIL-1c-3:月结的借贷合计与年结的净结果是本位币(总账口径)—— 那两张表没有币种列,锁期那一行也没有;
    //   不说出来,线上锁期那一段印的是 "Total debits: 757,013.37"(线上的回滚证明读出来的)
    period_closes: new Set(['total_debits', 'total_credits']),
    year_closes: new Set(['net_result']),
    // AUDIT-TRAIL-1d-1:月薪(员工、履历、调薪申请)是本位币 —— 三张表都没有币种列(工资按本位币发,ROLE-1 · APR-9)
    employees: new Set(['monthly_salary']),
    employment_history: new Set(['old_monthly_salary', 'new_monthly_salary']),
    salary_change_requests: new Set(['old_monthly_salary', 'new_monthly_salary']),
    // AUDIT-TRAIL-1d-2:医疗报销的金额是本位币(那一列叫 amount_sgd,页面上的币种由消息参数带;表里没有币种列)
    medical_claims: new Set(['amount_sgd']),
    // AUDIT-TRAIL-1d-3:评审里的新月薪是本位币(与员工、履历同一条;那张表没有币种列)
    performance_reviews: new Set(['new_monthly_salary']),
}
function currencyFor(col: string, img: Img, opts: BuildOptions, d: TrailDict, table?: string): string | null {
    if (/_base$/.test(col) || /^(old|new)_amount_base$/.test(col)) return d.baseCurrency
    // AUDIT-TRAIL-1c-3:行内转账两条腿各按自己那个户的本币(此前两条都挂着单据币种 —— 一笔 SGD → USD 的转账,收到的那一条
    //   读成 "1,000.00 SGD",而它是 USD);一张转账申请的 amount_in 同理(按入款户)
    const leg = table === 'bank_transfers' ? (col === 'amount_out' ? 'from_account' : col === 'amount_in' ? 'to_account' : null)
        : table === 'payment_requests' && col === 'amount_in' ? 'to_account_code' : null
    if (leg && d.bankCurrency) {
        const acct = img[leg]
        const c = typeof acct === 'string' ? d.bankCurrency(acct) : undefined
        if (c) return c
    }
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
            // AUDIT-TRAIL-1d-2:一个年份(leave_year、accrual_year、claim_year)是一个名字,不是一个量 —— "2027",不是 "2,027"
            if (n !== null && Number.isInteger(n) && /(^|_)year$/.test(col)) return { text: String(n) }
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
    // AUDIT-TRAIL-1d-2:假期表与假别表上的先后
    public_holidays: ['holiday_date', 'name_en', 'name_zh', 'is_in_lieu', 'country', 'is_active', 'notes'],
    leave_types: ['name_en', 'name_zh', 'is_paid', 'is_accrued', 'default_days_per_year', 'requires_certificate_after_days', 'allows_half_day',
        'requires_approval', 'gender_restriction', 'is_active', 'description_en', 'description_zh', 'notes'],
    // AUDIT-TRAIL-1d-3:评分刻度那一页上的先后
    review_rating_scale: ['name_en', 'name_zh', 'description_en', 'description_zh', 'is_probation_pass', 'is_active', 'notes'],
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
/** U1-B:一段理由被遮(受限标记)时说「受限」—— typed() 会把标记读成"没写",那一行理由于是悄悄消失(U1-A 在请假事由上的同一句) */
function typedOrRestricted(d: TrailDict, v: Json | undefined): Val | null {
    return isRestricted(v) ? { text: tx(d, 'restricted'), restricted: true } : typed(v)
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
        // U1-B(Q25):关闭 / 重开的人与理由有了自己的列 —— 理由说成那一条的 Reason,人与时刻就是这一条本身,都不再逐列印
        const ls = changeLines(d, r, opts, new Set(['status', 'approval_status', 'cancel_reason', 'cancelled_at', 'cancelled_by',
            'closed_at', 'deleted_at', 'deleted_by', 'delete_reason', 'approved_at', 'approved_by',
            'closed_by', 'close_reason', 'reopened_at', 'reopened_by', 'reopen_reason']))
        const from = str(r, 'status', 'old'), to = str(r, 'status', 'new')
        let ev: string | null = null
        let reason: Val | null = null
        if (r.op === 'DELETE' || (changed(r, 'deleted_at') && r.new?.['deleted_at'])) {
            ev = tx(d, 'po.deleted'); reason = typed(r.new?.['delete_reason'])
        } else if (changed(r, 'status') || (r.prelog && r.cols?.includes('closed_at'))) {
            if (to === 'cancelled') { ev = tx(d, 'po.cancelled'); reason = typed(r.new?.['cancel_reason']) }
            else if (to === 'closed' || (r.prelog && r.new?.['closed_at'])) { ev = tx(d, 'po.closed'); reason = typed(r.new?.['close_reason']) }
            else if (from === 'closed') { ev = tx(d, 'po.reopened'); reason = typed(r.new?.['reopen_reason']) }
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
        // U1-B(Q25):关闭与重开从此也各有一行修改史(理由在 amend_reason)—— 与取消同一个形状:并进那一条,不另说一次"修改"
        const statusEv = ct === 'cancelled' ? 'po.cancelled' : ct === 'closed' ? 'po.closed' : ct === 'reopened' ? 'po.reopened' : null
        if (statusEv) {
            if (!blocks.some((b) => b.title === tx(d, statusEv))) blocks.push({ title: tx(d, statusEv), lines: [], reason, key: true, weight: 80 })
            else blocks.forEach((b) => { if (b.title === tx(d, statusEv) && !b.reason) b.reason = reason })
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
            // U1-B(Q20):买的时候的深度放电判断是一行上的【质量判断】,不是一次改单 —— 自己一条关键事件,不并进"修改"
            if (changed(r, 'deep_discharge_judgement_code')) blocks.push({ title: tx(d, 'po.deepDischargeJudged'), lines: [head, ...ls], key: true, weight: 60 })
            else if (ls.length) blocks.push({ title: tx(d, 'po.lineChanged'), lines: [head, ...ls], key: false, weight: 40 })
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
    'processing_cost_entry_history', 'batch_processing_cost_allocations', 'processing_run_losses',
    // MES-4a(2026-10-07):一炉的值、异常事件、平衡结算、抬头更正 —— 全部只追加
    'processing_run_values', 'processing_run_events', 'processing_run_closures', 'processing_run_corrections',
    // MES-4b(2026-10-07):交叉污染抽检(只追加)—— 在产出批页上也从加工单这一边说("… · PROC-…")
    'contamination_checks',
    // MES-5a-1(2026-10-08):逐模组放电结果 · 通道分配 · 拆去隔离的模组(全部只追加)—— 在批次页与放电柜页上也从加工单这一边说
    'discharge_module_results', 'discharge_channel_assignments', 'discharge_module_splits'])

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
        // MES-4a(Q7–Q9 · Q16 · Q31):开始 / 结束 / 班次 / 配方版本 / 它更正的那一张,与工单、机器、工序同一种说法
        for (const c of ['work_order_id', 'equipment_id', 'operation_type_code', 'started_at', 'ended_at', 'shift_code', 'recipe_version_id', 'corrects_run_id']) {
            const v = created.new?.[c]
            if (!isEmpty(v)) ls.push({ t: 'value', label: fieldMeta(d, 'processing_runs', c)[0], value: formatValue(d, 'processing_runs', c, v, imgOf(created), created.refs, 'INSERT', o2) })
        }
        // MES-4a(Q11 · Q16):提交时一并记下的参数与指标 —— 只说几个(每一个是哪个字段、什么值在这一单的"参数与指标"那一块)
        const nVals = by('processing_run_values').filter((x) => x.op === 'INSERT').length
        if (nVals) ls.push({ t: 'value', label: tx(d, 'run.values'), value: { text: plural(d, 'run.values.one', 'run.values.many', nVals) } })
        const notes = typed(created.new?.['notes'])
        if (notes) ls.push({ t: 'value', label: fieldMeta(d, 'processing_runs', 'notes')[0], value: notes })
        blocks.push({ title, lines: ls, key: true, weight: 100 })
    }

    // MES-4a(Q30):抬头更正 —— 一行更正(哪一格、理由)与 processing_runs 那一次 UPDATE 同一笔:
    //   标题由更正说("Run header corrected · Start time"),前后值由那一次 UPDATE 的列说(时刻、班次名、机器号都已解析成人话),理由最后。
    const corrections = by('processing_run_corrections').filter((x) => x.op === 'INSERT')
    const fieldPart = (c: TrailRow): Val | null => {
        const f = str(c, 'field', 'new')
        return f ? { text: enumLabel(d, 'processing_run_corrections', 'field', f) } : null
    }
    let correctionUsed = false
    for (const r of run) {
        if (r === created) continue
        if (corrections.length && r.op === 'UPDATE' && !correctionUsed && !changed(r, 'allocated_at') && !changed(r, 'status')
            && !changed(r, 'deleted_at') && !changed(r, 'allocation_basis')) {
            correctionUsed = true
            const c0 = corrections[0]
            blocks.push({ title: tx(d, 'run.headerCorrected'), part: fieldPart(c0), lines: changeLines(d, r, o2),
                          reason: typed(c0.new?.['reason']), key: true, weight: 75 })
            continue
        }
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

    // MES-4a:一行更正没有配上 processing_runs 那一次 UPDATE(那一行这个读者看不见)时,照样说出它与理由
    for (const c of corrections.slice(correctionUsed ? 1 : 0)) {
        blocks.push({ title: tx(d, 'run.headerCorrected'), part: fieldPart(c), lines: [], reason: typed(c.new?.['reason']), key: true, weight: 75 })
    }
    // MES-4a(Q11 · Q29):提交之后记的值 —— 记一个 / 更正一个(更正 = 新的一行指着旧的,理由在理由那一格)。
    //   字段名由 trail_refs 按(工序 + 字段代号)解析(组合外键,MES-4a 给它补了一支)—— 解析得出就挂在标题后面;
    //   字段已不在(gone)或读不到时只说光标题(绝不印代号)。
    if (!created) {
        for (const r of by('processing_run_values')) {
            if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
            const corrected = str(r, 'corrects_id', 'new') !== null
            const name = refLabel(r, 'field_code')
            blocks.push({ title: tx(d, corrected ? 'run.valueCorrected' : 'run.valueRecorded'), part: name ? { text: name } : null,
                          lines: valueLines(d, r, r.new, o2, new Set(['run_id', 'field_code', 'correction_reason'])),
                          reason: corrected ? typed(r.new?.['correction_reason']) : null, key: true, weight: 55 })
        }
    }
    // MES-4a(Q15):异常事件 —— 记一件 / 更正一件 / 撤回一件(撤回 = 一行 withdrawn 的更正,带理由)
    for (const r of by('processing_run_events')) {
        if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
        const corrected = str(r, 'corrects_id', 'new') !== null
        const withdrawn = r.new?.['withdrawn'] === true
        const ty = str(r, 'event_type_code')
        const part = ty ? formatValue(d, 'processing_run_events', 'event_type_code', ty, imgOf(r), r.refs, 'INSERT', o2) : null
        const key: TrailTextKey = withdrawn ? 'run.eventWithdrawn' : corrected ? 'run.eventCorrected' : 'run.eventRecorded'
        blocks.push({ title: tx(d, key), part,
                      lines: withdrawn ? [] : valueLines(d, r, r.new, o2, new Set(['run_id', 'event_type_code', 'withdrawn', 'correction_reason'])),
                      reason: corrected ? typed(r.new?.['correction_reason']) : null, key: true, weight: 55 })
    }
    // MES-4a(Q19 · Q20):物料平衡结算 —— 投入 = 产出 + 具名损耗 + 余数;余数在容差外时那一段解释就是理由
    for (const r of by('processing_run_closures')) {
        if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
        const within = r.new?.['within_tolerance']
        const title = within === true ? `${tx(d, 'run.balanceClosed')} · ${tx(d, 'run.withinTolerance')}` : tx(d, 'run.balanceClosed')
        blocks.push({ title, lines: valueLines(d, r, r.new, o2, new Set(['run_id', 'explanation', 'within_tolerance'])),
                      reason: typed(r.new?.['explanation']), key: true, weight: 80 })
    }
    // MES-4b(Q21 · Q23):交叉污染抽检 —— 抽了 / 这一班没抽(理由)/ 更正(新的一行指着旧的,理由在理由那一格)。标题后面挂流的名字。
    for (const r of by('contamination_checks')) {
        if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
        const corrected = str(r, 'corrects_id', 'new') !== null
        const notSampled = str(r, 'kind', 'new') === 'not_sampled'
        const st = str(r, 'stream_code')
        const part = st ? formatValue(d, 'contamination_checks', 'stream_code', st, imgOf(r), r.refs, 'INSERT', o2) : null
        const key: TrailTextKey = corrected ? 'run.contaminationCorrected' : notSampled ? 'run.contaminationNotSampled' : 'run.contaminationRecorded'
        blocks.push({ title: tx(d, key), part,
                      lines: valueLines(d, r, r.new, o2, new Set(['run_id', 'stream_code', 'kind', 'correction_reason', 'not_sampled_reason'])),
                      reason: corrected ? typed(r.new?.['correction_reason']) : notSampled ? typed(r.new?.['not_sampled_reason']) : null,
                      key: true, weight: 55 })
    }
    // MES-5a-1(Q7 · Q9 · Q11):逐模组放电 —— 一个模组的结果(记 / 更正,理由在理由那一格)、一个通道分配(分配 / 更正 / 撤下)、
    //   一个模组拆去隔离。标题后面挂模组编号("… · M03");判定、处置、电压与时刻是值行。
    for (const r of by('discharge_module_results')) {
        if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
        const corrected = str(r, 'corrects_id', 'new') !== null
        const m = str(r, 'module_ref', 'new')
        blocks.push({ title: tx(d, corrected ? 'run.dischargeResultCorrected' : 'run.dischargeResultRecorded'), part: m ? { text: m } : null,
                      lines: valueLines(d, r, r.new, o2, new Set(['run_id', 'module_ref', 'correction_reason', 'corrects_id'])),
                      reason: corrected ? typed(r.new?.['correction_reason']) : null, key: true, weight: 55 })
    }
    for (const r of by('discharge_channel_assignments')) {
        if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
        const corrected = str(r, 'corrects_id', 'new') !== null
        const withdrawn = r.new?.['withdrawn'] === true
        const m = str(r, 'module_ref', 'new')
        const key: TrailTextKey = withdrawn ? 'run.dischargeChannelWithdrawn' : corrected ? 'run.dischargeChannelCorrected' : 'run.dischargeChannelAssigned'
        blocks.push({ title: tx(d, key), part: m ? { text: m } : null,
                      lines: withdrawn ? [] : valueLines(d, r, r.new, o2, new Set(['run_id', 'module_ref', 'withdrawn', 'correction_reason', 'corrects_id'])),
                      reason: corrected ? typed(r.new?.['correction_reason']) : null, key: true, weight: 50 })
    }
    for (const r of by('discharge_module_splits')) {
        if (r.op !== 'INSERT') { blocks.push(describeGeneric(d, r, o2)); continue }
        const m = str(r, 'module_ref', 'new')
        blocks.push({ title: tx(d, 'run.dischargeModuleSplit'), part: m ? { text: m } : null,
                      lines: valueLines(d, r, r.new, o2, new Set(['split_run_id', 'module_ref'])), key: true, weight: 60 })
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
            // MES-4a(Q28):只追加 —— 改一个数是新的一行指着旧的(corrects_id),理由在理由那一格。UPDATE / DELETE 只出现在 MES-4a 之前的记录里。
            const corrected = r.op === 'INSERT' && str(r, 'corrects_id', 'new') !== null
            const ls = r.op === 'UPDATE' ? changeLines(d, r, o2)
                : valueLines(d, r, r.new ?? r.old, o2, new Set(['run_id', 'correction_reason', ...(r.op === 'INSERT' ? ['loss_category_code'] : [])]))
            const cat = r.op === 'INSERT' ? str(r, 'loss_category_code') : null
            const part = cat ? formatValue(d, 'processing_run_losses', 'loss_category_code', cat, imgOf(r), r.refs, 'INSERT', o2) : null
            blocks.push({ title: tx(d, corrected ? 'run.lossCorrected' : r.op === 'INSERT' ? 'run.lossRecorded' : r.op === 'DELETE' ? 'run.lossRemoved' : 'run.lossChanged'),
                          part, lines: ls, reason: corrected ? typed(r.new?.['correction_reason']) : null, key: corrected, weight: 40 })
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
        'batch_processing_cost_allocations', 'processing_run_losses', 'warehouse_requests', 'approval_log',
        'processing_run_values', 'processing_run_events', 'processing_run_closures', 'processing_run_corrections', 'contamination_checks',
        'discharge_module_results', 'discharge_channel_assignments', 'discharge_module_splits', 'electricity_allocation_lines',
        'electricity_allocation_reversals'],
    role: ['roles', 'role_permissions', 'user_roles'],
    inbound_batch: ['inbound_batches', 'inbound_batch_metals', 'assay_results', 'assay_result_metals', 'inbound_batch_safety_states', 'receipt_ceiling_checks', 'label_prints',
        'price_history', 'receipt_price_requests', 'approval_log', 'prepayment_applications', 'pricing_term_commitments',
        'pricing_term_commitment_metals', 'inventory_movements', 'stocktake_lines', 'stocktake_counts', 'processing_inputs',
        'batch_processing_cost_allocations', 'certificates_of_destruction', 'cod_issues', 'warehouse_requests', 'freight_allocations',
        'payment_allocations', 'finance_attachments', 'purchase_order_history', 'processing_cost_entry_history', 'work_order_history',
        'journal_entries', 'discharge_module_results', 'discharge_module_splits',
        // MES-6a-1:样品、它的保管记录与化验争议也出现在它们那一批上(家在样品 / 争议自己那里)
        'samples', 'sample_events', 'assay_disputes'],
    output_batch: ['output_batches', 'output_batch_metals', 'assay_results', 'assay_result_metals', 'output_batch_safety_states', 'receipt_ceiling_checks', 'label_prints',
        'inventory_movements', 'processing_outputs', 'processing_inputs', 'stocktake_lines', 'stocktake_counts', 'warehouse_requests',
        'approval_log', 'sales_records', 'sales_record_movements', 'sales_attribution_log', 'invoice_lines', 'payment_allocations',
        'sales_order_reservations', 'shipment_lines', 'traceability_report_issues', 'sales_settlements', 'processing_cost_entry_history',
        'work_order_history', 'sales_order_history', 'journal_entries', 'contamination_checks', 'discharge_module_results', 'discharge_module_splits',
        // MES-6a-1
        'samples', 'sample_events', 'assay_disputes'],
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
    company_licence: ['company_compliance', 'licence_storage_limits'],
    // AUDIT-TRAIL-1b-3
    material: ['materials', 'material_attachments', 'material_required_metals'],
    storage_location: ['storage_locations', 'storage_location_allowed_classes', 'label_prints'],
    metal_price: ['metal_prices'],
    pricing_formula: ['pricing_formulas', 'pricing_formula_metals', 'pricing_formula_history', 'terms_requests', 'approval_log'],
    task: ['tasks', 'task_nodes', 'task_participants', 'task_history'],
    processing_settings: ['processing_settings'],
    pricing_settings: ['pricing_settings'],
    receiving_settings: ['receiving_settings'],
    // AUDIT-TRAIL-1c-1
    journal_entry: ['journal_entries', 'journal_lines', 'journal_requests', 'approval_log', 'fixed_asset_depreciation'],
    invoice: ['invoices', 'invoice_lines', 'invoice_issues', 'invoice_requests', 'approval_log', 'credit_notes', 'payment_allocations', 'journal_entries'],
    credit_note: ['credit_notes', 'credit_note_lines', 'cn_issues', 'invoice_requests', 'approval_log', 'journal_entries'],
    payment: ['payments', 'payment_allocations', 'finance_attachments', 'payment_requests', 'approval_log', 'journal_entries'],
    payment_request: ['payment_requests', 'approval_log', 'payments', 'bank_transfers', 'wht_remittances', 'journal_entries'],
    expense: ['expenses', 'payment_allocations', 'finance_attachments', 'prepayment_applications', 'expense_claims', 'approval_log',
        'fixed_asset_cost_entries', 'journal_entries', 'medical_claims'],
    payable: ['inbound_batches', 'payment_allocations', 'freight_allocations', 'prepayment_applications', 'finance_attachments', 'price_history',
        'journal_entries'],
    // AUDIT-TRAIL-1c-2
    sale: ['sales_records', 'sales_record_movements', 'sales_attribution_log', 'invoice_lines', 'payment_allocations', 'finance_attachments',
        'journal_entries'],
    freight: ['freight_documents', 'freight_allocations', 'payment_allocations', 'journal_entries'],
    fixed_asset: ['fixed_assets', 'fixed_asset_history', 'fixed_asset_cost_entries', 'fixed_asset_depreciation', 'fixed_asset_depreciation_anchors',
        'asset_disposal_requests', 'approval_log', 'equipment_maintenance', 'equipment_downtime', 'equipment_service_intervals',
        'shift_handover_equipment_refs', 'journal_entries'],
    bank_statement: ['bank_statements', 'bank_statement_lines', 'bank_line_matches', 'bank_reconciliations', 'bank_reconciliation_variance_items'],
    gst_period: ['gst_periods', 'gst_return_boxes', 'gst_filing_requests', 'approval_log'],
    fx_rate: ['fx_rates', 'fx_rate_history'],
    management_pack: ['management_packs'],
    contract: ['contracts', 'contract_grade_specs', 'contract_insurance_obligations', 'contract_volume_commitments', 'contract_pricing_terms',
        'contract_settlement_terms', 'contract_refining_charges', 'contract_penalty_elements', 'terms_requests', 'approval_log',
        'contract_document_terms'],
    // AUDIT-TRAIL-1c-3
    finance_lock: ['finance_settings', 'period_closes'],
    finance_gst: ['finance_settings'],
    company_profile: ['company_profile'],
    year_close: ['year_closes', 'journal_entries'],
    journal_request: ['journal_requests', 'approval_log', 'journal_entries'],
    expense_claim: ['expense_claims', 'approval_log', 'finance_attachments', 'expenses'],
    my_expense_claim: ['expense_claims', 'approval_log', 'finance_attachments', 'expenses'],
    bank_transfer: ['bank_transfers', 'journal_entries', 'payment_requests', 'approval_log'],
    wht_remittance: ['wht_remittances', 'journal_entries', 'payment_requests', 'approval_log'],
    cash_forecast: ['cash_forecasts'],
    cash_forecast_line: ['cash_forecast_lines'],
    bank_import_profile: ['bank_import_profiles'],
    // AUDIT-TRAIL-1d-1
    account: ['auth.users', 'user_roles', 'employee_accounts', 'employee_account_history', 'employees'],
    approval_policy: ['finance_settings', 'finance_settings_history'],
    employee: ['employees', 'employment_history', 'salary_change_requests', 'approval_log', 'training_records', 'employee_accounts',
        'employee_account_history', 'auth.users', 'user_roles'],
    department: ['departments'],
    training_record: ['training_records'],
    import_batch: ['import_batches'],
    dictionary_substances: ['substances'],
    dictionary_battery_chemistries: ['battery_chemistries'],
    dictionary_material_kinds: ['material_kinds'],
    dictionary_inbound_safety_states: ['inbound_safety_states'],
    dictionary_nea_waste_categories: ['nea_waste_categories'],
    dictionary_dangerous_goods_codes: ['dangerous_goods_codes'],
    dictionary_label_templates: ['label_templates'],
    dictionary_laboratories: ['laboratories'],
    dictionary_inbound_source_reasons: ['inbound_source_reasons'],
    // AUDIT-TRAIL-1d-2
    leave_request: ['leave_requests', 'leave_consumption', 'approval_log'],
    my_leave_request: ['leave_requests', 'leave_consumption', 'approval_log'],
    leave_grant: ['leave_grants'],
    leave_types: ['leave_types'],
    public_holidays: ['public_holidays'],
    medical_claim: ['medical_claims', 'approval_log', 'expenses', 'journal_entries', 'payment_allocations'],
    my_medical_claim: ['medical_claims', 'approval_log', 'expenses', 'journal_entries', 'payment_allocations'],
    overtime_batch: ['overtime_batches', 'overtime_lines', 'approval_log'],
    attendance_period: ['attendance_periods', 'attendance_lines'],
    // AUDIT-TRAIL-1d-3
    payroll_period: ['payroll_periods', 'payroll_lines', 'payroll_requests', 'approval_log', 'journal_entries'],
    performance_review: ['performance_reviews', 'review_goals', 'approval_log'],
    my_review: ['performance_reviews', 'review_goals', 'approval_log'],
    review_cycle: ['review_cycles'],
    review_rating_scale: ['review_rating_scale'],
    kpi_entry: ['kpi_entries'],
    // MES-1(2026-10-06):设备(网关钥匙是它的成员)· 采集上限(单行设置)。收件箱、传输日志与中断不进变更记录(MES-0 Q14)。
    device: ['devices', 'gateway_keys', 'instrument_calibrations', 'discharge_module_results', 'meter_readings'],
    // MES-2(2026-10-06):地磅单 —— 它的两磅(含更正)、分出去的份、照片
    weighbridge_ticket: ['weighbridge_tickets', 'weighings', 'weighbridge_ticket_shares', 'weighbridge_ticket_photos'],
    // MES-5a-2(2026-10-08):一张电费单的分摊与它的各炉一行 · 分摊的设定(V25)
    // MES-5b-2(2026-10-09):+ 一张电费单的撤回(住在那张单下,也出现在它覆盖过的每一炉上)
    electricity_allocation: ['electricity_allocations', 'electricity_allocation_lines', 'electricity_allocation_reversals'],
    electricity_settings: ['electricity_settings'],
    ingest_settings: ['ingest_settings'],
    // MES-5b-3(2026-10-09):一份配料计划 · 它的目标品位 · 它的候选批次
    blending_plan: ['blending_plans', 'blending_plan_targets', 'blending_plan_lines'],
    // MES-6a-1(2026-10-09):一份样品与它的保管记录 · 一件化验争议 · 质量的设定(V16)
    sample: ['samples', 'sample_events'],
    assay_dispute: ['assay_disputes'],
    quality_settings: ['quality_settings'],
    // MES-4a(2026-10-07):一道工序的配置(字段 · 机器 · 配方 · 版本)· 两本新字典
    // MES-5b-2(2026-10-09,并入 MES5B1-V37-NOT-ON-OPERATION-TRAIL):+ 每一种产出形态的预期得率(V37)
    operation_type: ['operation_types', 'operation_type_fields', 'operation_type_equipment', 'process_recipes', 'process_recipe_versions',
        'operation_type_output_forms'],
    dictionary_processing_event_types: ['processing_event_types'],
    dictionary_shifts: ['shifts'],
    // MES-4b(2026-10-07):两本新字典(电芯结构 · 交叉污染流)
    dictionary_cell_constructions: ['cell_constructions'],
    dictionary_contamination_streams: ['contamination_streams'],
}

type Family = 'po' | 'run' | 'role' | 'batch' | 'journal' | 'approval' | 'wo' | 'stocktake' | 'equipment' | 'handover' | 'wr' | 'so'
    | 'quote' | 'shipment' | 'customer' | 'commission' | 'supplier' | 'container' | 'lane' | 'licence'
    | 'material' | 'location' | 'metalPrice' | 'formula' | 'task' | 'settings' | 'fin'
    | 'access' | 'hr' | 'policy' | 'dict' | 'import' | 'time' | 'pay' | 'review' | 'kpi' | 'device' | 'ticket' | 'optype' | 'energy'
const PAGE_FAMILY: Record<string, Family> = {
    purchase_order: 'po', processing_run: 'run', role: 'role', inbound_batch: 'batch', output_batch: 'batch', work_order: 'wo',
    stocktake: 'stocktake', equipment: 'equipment', shift_handover: 'handover', warehouse_request: 'wr',
    quote: 'quote', sales_order: 'so', shipment: 'shipment', customer: 'customer', commission_agreement: 'commission',
    supplier: 'supplier', forwarder: 'supplier', container: 'container', lane: 'lane', port: 'lane', company_licence: 'licence',
    material: 'material', storage_location: 'location', metal_price: 'metalPrice', pricing_formula: 'formula', task: 'task',
    processing_settings: 'settings', pricing_settings: 'settings', receiving_settings: 'settings',
    // AUDIT-TRAIL-1c-1
    journal_entry: 'fin', invoice: 'fin', credit_note: 'fin', payment: 'fin', payment_request: 'fin', expense: 'fin', payable: 'fin',
    // AUDIT-TRAIL-1c-2
    sale: 'fin', freight: 'fin', fixed_asset: 'fin', bank_statement: 'fin', gst_period: 'fin', fx_rate: 'fin', management_pack: 'fin', contract: 'fin',
    // AUDIT-TRAIL-1c-3
    finance_lock: 'fin', finance_gst: 'fin', company_profile: 'fin', year_close: 'fin', journal_request: 'fin', expense_claim: 'fin',
    my_expense_claim: 'fin', bank_transfer: 'fin', wht_remittance: 'fin', cash_forecast: 'fin', cash_forecast_line: 'fin', bank_import_profile: 'fin',
    // AUDIT-TRAIL-1d-1
    account: 'access', approval_policy: 'policy', employee: 'hr', department: 'hr', training_record: 'hr', import_batch: 'import',
    dictionary_substances: 'dict', dictionary_battery_chemistries: 'dict', dictionary_material_kinds: 'dict',
    dictionary_inbound_safety_states: 'dict', dictionary_laboratories: 'dict', dictionary_inbound_source_reasons: 'dict',
    dictionary_nea_waste_categories: 'dict',
    dictionary_dangerous_goods_codes: 'dict', dictionary_label_templates: 'dict',
    // AUDIT-TRAIL-1d-2(假别与公共假期是 M11 集合,与六本字典同一种说法:"<Thing> added / changed / deactivated")
    leave_request: 'time', my_leave_request: 'time', leave_grant: 'time', medical_claim: 'time', my_medical_claim: 'time',
    overtime_batch: 'time', attendance_period: 'time', leave_types: 'dict', public_holidays: 'dict',
    // AUDIT-TRAIL-1d-3(评分刻度是 M11 集合,与字典同一种说法:"Rating added / changed / deactivated")
    payroll_period: 'pay', performance_review: 'review', my_review: 'review', review_cycle: 'review', review_rating_scale: 'dict',
    kpi_entry: 'kpi',
    // MES-1
    device: 'device', ingest_settings: 'settings',
    // MES-2
    weighbridge_ticket: 'ticket',
    // MES-4a
    operation_type: 'optype', dictionary_processing_event_types: 'dict', dictionary_shifts: 'dict',
    // MES-4b
    dictionary_cell_constructions: 'dict', dictionary_contamination_streams: 'dict',
    // MES-5a-2
    electricity_allocation: 'energy', electricity_settings: 'settings',
    // MES-6a-1
    quality_settings: 'settings',
}
const BATCH_TABLES = new Set(['inbound_batches', 'output_batches', 'inbound_batch_metals', 'output_batch_metals', 'assay_results',
    'assay_result_metals', 'inbound_batch_safety_states', 'output_batch_safety_states', 'price_history', 'receipt_price_requests',
    'prepayment_applications', 'pricing_term_commitment_metals', 'inventory_movements', 'certificates_of_destruction', 'cod_issues',
    'freight_allocations', 'payment_allocations', 'finance_attachments', 'sales_records', 'sales_record_movements', 'sales_attribution_log',
    'invoice_lines', 'sales_order_reservations', 'shipment_lines', 'traceability_report_issues', 'sales_settlements',
    'receipt_ceiling_checks', 'label_prints'])
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
    // AUDIT-TRAIL-1d-2(Q37):医疗报销在费用页上也从报销单这一边说("Medical claim approved · MC-…");
    //   报销单页上它够到的费用、分录、核销从账上那一边说(describeFinance —— 与费用页同一种话)
    if (t === 'medical_claims') return 'time'
    if ((subject === 'medical_claim' || subject === 'my_medical_claim') && (t === 'expenses' || t === 'journal_entries' || t === 'payment_allocations')) return 'fin'
    // AUDIT-TRAIL-1c-1:账上那七页上的每一行都从 describeFinance 说 —— 别的页上同一张表的说法不动
    if (subject && FIN_SUBJECTS.has(subject)) return 'fin'
    // AUDIT-TRAIL-1d-3:工资期页上这一期的分录从工资期这一边说("Payroll posted" · "Salaries paid" · "CPF paid" …)
    if (subject === 'payroll_period' && t === 'journal_entries') return 'pay'
    // AUDIT-TRAIL-1d-1:审批方针那一页上,那一行设置与它的修改史从方针这一边说;账号页上那名员工(只剩 user_id 一列,M10)从账号这一边说
    if (subject === 'approval_policy' && (t === 'finance_settings' || t === 'finance_settings_history')) return 'policy'
    if (t === 'finance_settings_history') return 'policy'
    if (subject === 'account' && t === 'employees') return 'access'
    if ((subject === 'inbound_batch' || subject === 'output_batch') && BATCH_VIEW_OF_RUN.has(t)) return 'batch'
    // AUDIT-TRAIL-1b-2:预留、合同条款在订单页上从订单这一边说;发货单明细在发货单页上从发货单这一边说
    //   (在批次页、采购单页、汇总页上仍照 1b-1 的说法)
    if (subject === 'sales_order' && (t === 'sales_order_reservations' || t === 'contract_document_terms')) return 'so'
    if (subject === 'shipment' && t === 'shipment_lines') return 'shipment'
    if (t === 'counterparty_contacts') return subject === 'supplier' || (!subject && !imgOf(r)['customer_id']) ? 'supplier' : 'customer'
    // AUDIT-TRAIL-1d-2:请假、医疗报销、加班的审批照它那一页的话说("Leave approved"、"Overtime sent back" —— Q35)
    if (t === 'approval_log') {
        const st = str(r, 'subject_type') ?? ''
        // AUDIT-TRAIL-1d-3:工资申请与评审的审批同样照它那一页的话说("Payroll posting approved" · "Review approved")
        return st === 'purchase_order' ? 'po' : TIME_APPROVALS.has(st) ? 'time' : st === 'payroll_request' ? 'pay' : st === 'performance_review' ? 'review' : 'approval'
    }
    if (PO_TABLES.has(t)) return 'po'
    if (RUN_TABLES.has(t)) return 'run'
    if (t === 'roles' || t === 'role_permissions') return 'role'
    if (t === 'shift_handover_equipment_refs' && subject === 'equipment') return 'equipment'
    // MES-3b:库位页上它的标签从库位这一边说(在别处 —— 批次页、变更记录总表 —— 照批次那一族的说法,两边是同一句话)
    if (subject === 'storage_location' && t === 'label_prints') return 'location'
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
    if (t === 'company_compliance' || t === 'licence_storage_limits') return 'licence'
    // AUDIT-TRAIL-1b-3
    if (MATERIAL_TABLES.has(t)) return 'material'
    if (t === 'storage_locations' || t === 'storage_location_allowed_classes') return 'location'
    if (t === 'metal_prices') return 'metalPrice'
    if (FORMULA_TABLES.has(t)) return 'formula'
    if (TASK_TABLES.has(t)) return 'task'
    if (SETTINGS_TITLE[t]) return 'settings'
    // AUDIT-TRAIL-1d-1
    if (ACCESS_TABLES.has(t)) return 'access'
    if (HR1_TABLES.has(t)) return 'hr'
    if (DICT_TABLES.has(t)) return 'dict'
    if (t === 'import_batches') return 'import'
    // AUDIT-TRAIL-1d-2
    if (TIME_TABLES.has(t)) return 'time'
    if (t === 'leave_types' || t === 'public_holidays') return 'dict'
    // AUDIT-TRAIL-1d-3
    if (PAY_TABLES.has(t)) return 'pay'
    if (REVIEW_TABLES.has(t)) return 'review'
    if (t === 'kpi_entries') return 'kpi'
    // MES-1
    if (t === 'devices' || t === 'gateway_keys' || t === 'instrument_calibrations' || t === 'meter_readings') return 'device'
    // MES-5a-2:一张电费单的分摊与分给一炉的那一份 —— 在分摊页、加工单页、变更记录总表上都照这一族说
    if (t === 'electricity_allocations' || t === 'electricity_allocation_lines' || t === 'electricity_allocation_reversals') return 'energy'
    // MES-2
    if (t === 'weighbridge_tickets' || t === 'weighings' || t === 'weighbridge_ticket_shares' || t === 'weighbridge_ticket_photos') return 'ticket'
    if (t === 'review_rating_scale') return 'dict'
    // MES-4a:工序页上那几张(工序这一行本身只在工序页上从工序这一边说;在别处照旧走通用的说法)
    if (OPTYPE_TABLES.has(t) || (t === 'operation_types' && subject === 'operation_type')) return 'optype'
    return null
}
const OPTYPE_TABLES = new Set(['operation_type_fields', 'operation_type_equipment', 'process_recipes', 'process_recipe_versions'])

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
type Block2 = Block & { recordId?: string; approvalFor?: string; absorbsApproval?: boolean; whtReversal?: boolean }

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
        out.push({ title, lines: [], reason: decision === 'auto_approved' || MACHINE_NOTE_SUBJECTS.has(st) ? null : typedOrRestricted(d, a.new?.['note']), key: true, weight: 50,
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

    // ⑦ 安全状态。MES-3a(Q22 · Q25):一条状态被【结束】(UPDATE 填上 ended_at,理由必填),不再被删;
    //   回滚把加工结束掉的那一条重新开出来(INSERT,reopened_from_id 指回原行)。DELETE 只会出现在 MES-3a 之前的记录里。
    for (const r of by('inbound_batch_safety_states', 'output_batch_safety_states')) {
        const state = dictName(d, r, 'safety_state_code')
        if (r.op === 'UPDATE' && isSet(r, 'ended_at')) {
            out.push({ title: withPart(tx(d, 'batch.safetyEnded'), state), lines: [], reason: typed(r.new?.['end_reason']), key: true, weight: 46 })
            continue
        }
        if (r.op === 'UPDATE') continue
        const title = r.op === 'DELETE' ? 'batch.safetyRemoved'
            : (r.new?.['reopened_from_id'] ? 'batch.safetyReopened' : 'batch.safetyAdded')
        // MES-3a:记下 / 重新开出一个安全状态从此常常是一次单独的保存(只加变了的那一条),它自己就是那件事 —— key
        out.push({ title: withPart(tx(d, title), state), lines: [], key: true, weight: 45 })
    }
    // ⑦b MES-3a(Q10):进厂那一刻库存上限怎么判的 —— 一批一行,只追加
    for (const r of by('receipt_ceiling_checks')) {
        if (r.op !== 'INSERT') continue
        const outcome = enumLabel(d, 'receipt_ceiling_checks', 'outcome', String(r.new?.['outcome'] ?? ''))
        out.push({ title: withPart(tx(d, 'batch.ceilingChecked'), outcome),
                   lines: valueLines(d, r, r.new, opts, new Set(['outcome', 'inbound_batch_id', 'output_batch_id'])), key: false, weight: 44 })
    }

    // ⑦c MES-3b(Q7):这一批的标签 —— 发去打印了 / 补印(与理由)
    out.push(...describeLabelPrints(d, by('label_prints'), opts))

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
    // U1-B(Q15):一段停机可以作废(带理由)、可以更正;永远不删。作废先问 —— 那一次 UPDATE 不是"恢复运行",也不是"更正"。
    //   更正:之前已经有过的结束时刻被改掉,同样是更正(isSet 只问"有了值",那会把它说成第二次"恢复运行")。
    const downVoid = new Set(['duration', 'voided_at', 'voided_by', 'void_reason', 'updated_at', 'updated_by'])
    for (const r of by('equipment_downtime')) {
        const downStart = imgOf(r)['started_at']
        const which: Line[] = downStart !== undefined ? valueLines(d, r, { started_at: downStart }, opts) : []
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'eq.down'), lines: valueLines(d, r, r.new, opts, new Set(['duration', 'notes', ...skipEq])),
                       reason: typed(r.new?.['notes']), key: true, weight: 80 })
        } else if (isSet(r, 'voided_at')) {
            out.push({ title: tx(d, 'eq.downVoided'), lines: which, reason: typed(r.new?.['void_reason']), key: true, weight: 85 })
        } else if (isSet(r, 'ended_at') && isEmpty(r.old?.['ended_at'] ?? null)) {
            out.push({ title: tx(d, 'eq.up'), lines: valueLines(d, r, { ended_at: r.new?.['ended_at'] ?? null }, opts), key: true, weight: 80 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, downVoid)
            if (ls.length) out.push({ title: tx(d, 'eq.downCorrected'), lines: ls, key: true, weight: 60 })
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

// ── MES-1(2026-10-06):设备与网关钥匙 ──────────────────────────────────────────
// 【钥匙那一块只说前缀】"Gateway key issued · 1a2b3c4d…" —— 前缀是 typed 的那一截(不拼进固定措辞,机器字检出器不扫它);
//   哈希在变更记录里被 never 规则遮住(Q20),这里一个字都不提它。撤销那一块带理由。
// 【停用】先问:停用那一次 UPDATE 不是一次"修改"(同一次里网关的钥匙一并撤销,各自一块)。
// 【编号】编号在标题里已经说了(这一页就是它),新登记那一块不再印 code。
function describeDevice(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        if (r.table === 'devices') {
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'dev.registered'), lines: valueLines(d, r, r.new, opts, new Set(['code'])), key: true, weight: 90 })
            } else if (isSet(r, 'retired_at')) {
                out.push({ title: tx(d, 'dev.retired'), lines: [], reason: typed(r.new?.['retire_reason']), key: true, weight: 85 })
            } else if (r.op === 'UPDATE') {
                const ls = changeLines(d, r, opts)
                if (ls.length) out.push({ title: tx(d, 'dev.changed'), lines: ls, key: true, weight: 50 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'gateway_keys') {
            const prefix = str(r, 'key_prefix')
            // 只给那 8 个字符:'ngk_' 前缀是一个机器标识的样子(机器字检出器会认它),而它对每一把钥匙都一样,不帮人认出哪一把
            const part = prefix ? typed(`${prefix}…`) : null
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'dev.keyIssued'), part, lines: [], key: true, weight: 80 })
            } else if (isSet(r, 'revoked_at')) {
                out.push({ title: tx(d, 'dev.keyRevoked'), part, lines: [], reason: typed(r.new?.['revoke_reason']), key: true, weight: 80 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'meter_readings') {
            // MES-5a-2:电表读数 —— 只追加。记一条(时刻、读数、是不是寄存器清零与理由、来源都在行里)· 更正是新的一行指着旧的
            //   (理由在理由那一格)· 撤回(记在了错的表上)没有值行,只有理由。
            if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
            const corrected = str(r, 'corrects_id', 'new') !== null
            const withdrawn = r.new?.['withdrawn'] === true
            const key: TrailTextKey = withdrawn ? 'dev.meterReadingWithdrawn' : corrected ? 'dev.meterReadingCorrected' : 'dev.meterReadingRecorded'
            out.push({ title: tx(d, key),
                       lines: withdrawn ? [] : valueLines(d, r, r.new, opts, new Set(['id', 'device_id', 'withdrawn', 'corrects_id', 'correction_reason'])),
                       reason: corrected ? typed(r.new?.['correction_reason']) : null, key: true, weight: 70 })
        } else if (r.table === 'instrument_calibrations') {
            // MES-2:校准记录 —— 记一次(日期、有效期、结论、证书号、机构都在行里)· 作废(带理由)。只追加,没有"改"。
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'dev.calibrationRecorded'), lines: valueLines(d, r, r.new, opts, new Set(['id', 'device_id'])), key: true, weight: 75 })
            } else if (isSet(r, 'voided_at')) {
                out.push({ title: tx(d, 'dev.calibrationVoided'), lines: [], reason: typed(r.new?.['void_reason']), key: true, weight: 75 })
            } else out.push(describeGeneric(d, r, opts))
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

// ── MES-5a-2(2026-10-08):一张电费单的分摊 —— 过账(表头:时间段、账单、kWh 的几份、金额 —— 金额由遮蔽规则管)·
//   分给一炉的那一份(标题后面挂那一炉的单号;依据、kWh、份额、金额是值行)。只追加,没有"改"。
//   在加工单页上,那一份从加工单这一边读起来也是这一句("Electricity share allocated · PROC-…")。
function describeEnergy(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        if (r.table === 'electricity_allocations') {
            out.push({ title: tx(d, 'ea.posted'), lines: valueLines(d, r, r.new, opts, new Set(['id', 'expense_id', 'journal_entry_id'])), key: true, weight: 90 })
        } else if (r.table === 'electricity_allocation_lines') {
            const run = str(r, 'run_id', 'new')
            const label = run ? r.refs?.['run_id']?.[run]?.label ?? null : null
            out.push({ title: tx(d, 'ea.runShare'), part: label ? { text: label } : null,
                       lines: valueLines(d, r, r.new, opts, new Set(['id', 'allocation_id', 'run_id', 'cost_entry_id'])), key: true, weight: 70 })
        } else if (r.table === 'electricity_allocation_reversals') {
            // MES-5b-2(Step 0 Q22 · Q32):撤回是一句(冲销日、冲销费用单与分录、已付的借回哪个银行、撤掉几行、放回几条估计是值行;金额由遮蔽规则管)
            //   —— 在那张单与它覆盖过的每一炉上同一句;理由在理由那一格。
            out.push({ title: tx(d, 'ea.reversed'), reason: typed(r.new?.['reason']),
                       lines: valueLines(d, r, r.new, opts, new Set(['id', 'allocation_id', 'reason'])), key: true, weight: 90 })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

// ── MES-2(2026-10-06):地磅单 —— 开单 · 一磅(第一磅开单、第二磅完成;更正带理由)· 分一份 · 照片 · 作废 ─────────────
// 【一磅只说它的角色与读数】草稿、收件箱那一层不进这里(草稿的读码是加工查看,不是地磅单的门);改过的值与理由在确认队列上。
// 【完成】是第二磅落下时 completed_at 被记下的那一次 UPDATE —— 它自己一块"Ticket completed",不说成"修改"。
function describeTicket(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        if (r.table === 'weighbridge_tickets') {
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'wb.opened'), lines: valueLines(d, r, r.new, opts, new Set(['code', 'completed_at'])), key: true, weight: 90 })
            } else if (isSet(r, 'voided_at')) {
                out.push({ title: tx(d, 'wb.voided'), lines: [], reason: typed(r.new?.['void_reason']), key: true, weight: 85 })
            } else if (isSet(r, 'completed_at')) {
                out.push({ title: tx(d, 'wb.completed'), lines: [], key: true, weight: 80 })
            } else if (r.op === 'UPDATE') {
                const ls = changeLines(d, r, opts)
                if (ls.length) out.push({ title: tx(d, 'wb.changed'), lines: ls, key: true, weight: 50 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'weighings') {
            if (r.op === 'INSERT') {
                const corrected = str(r, 'corrects_id', 'new') !== null
                out.push({ title: tx(d, corrected ? 'wb.weighingCorrected' : 'wb.weighingRecorded'),
                           // 谁、何时确认的就是这一条记录的人与时刻 —— 不在行里再说一遍
                           lines: valueLines(d, r, r.new, opts, new Set(['corrects_id', 'correction_reason', 'ticket_id', 'inbox_id', 'draft_id',
                               'confirmed_at', 'confirmed_by'])),
                           reason: corrected ? typed(r.new?.['correction_reason']) : null, key: true, weight: 70 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'weighbridge_ticket_shares') {
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'wb.shared'), lines: valueLines(d, r, r.new, opts, new Set(['ticket_id', 'receipt_quantity_reason'])),
                           reason: typed(r.new?.['receipt_quantity_reason']), key: true, weight: 65 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'weighbridge_ticket_photos') {
            // 撤下那一次 UPDATE 的 new 里只有撤下那三列 —— 文件名从上下文(ctx)读
            const part = typed(str(r, 'file_name') ?? undefined)
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'wb.photoAdded'), part, lines: [], key: true, weight: 40 })
            } else if (isSet(r, 'withdrawn_at')) {
                out.push({ title: tx(d, 'wb.photoWithdrawn'), part, lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 40 })
            } else out.push(describeGeneric(d, r, opts))
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

// ── MES-4a(2026-10-07,Step 0 Q9–Q17):一道工序的配置 ────────────────────────────────────────────────
// 字段:加上 · 改了 · 退役 / 恢复(退役不删)。机器:挂上 · 摘下。配方:加上 · 停用 / 恢复;一版:加上(写了不改)。
// 工序这一行本身:平衡容差给了 / 改了(V1)。标题后面挂人认得的那一段:字段名、机器的资产号、配方码、"配方码 v版本"。
function describeOpType(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        if (r.table === 'operation_type_fields') {
            const part = typed(str(r, 'name_en'))
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'opt.fieldAdded'), part, lines: valueLines(d, r, r.new, opts, new Set(['name_en'])), key: true, weight: 70 })
            } else if (r.op === 'UPDATE') {
                const act = changed(r, 'is_active') ? r.new?.['is_active'] : undefined
                const ls = changeLines(d, r, opts, new Set(act === undefined ? [] : ['is_active']))
                if (act !== undefined) out.push({ title: tx(d, act === true ? 'opt.fieldRestored' : 'opt.fieldRetired'), part, lines: ls, key: true, weight: 65 })
                else if (ls.length) out.push({ title: tx(d, 'opt.fieldChanged'), part, lines: ls, key: false, weight: 40 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'operation_type_equipment') {
            const a = str(r, 'fixed_asset_id')
            const part = a ? formatValue(d, 'operation_type_equipment', 'fixed_asset_id', a, imgOf(r), r.refs, r.op, opts) : null
            if (r.op === 'INSERT') out.push({ title: tx(d, 'opt.machineLinked'), part, lines: [], key: true, weight: 70 })
            else if (r.op === 'DELETE') out.push({ title: tx(d, 'opt.machineUnlinked'), part, lines: [], key: true, weight: 70 })
            else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'process_recipes') {
            const part = typed(str(r, 'code'))
            if (r.op === 'INSERT') {
                out.push({ title: tx(d, 'opt.recipeAdded'), part, lines: valueLines(d, r, r.new, opts, new Set(['code'])), key: true, weight: 70 })
            } else if (r.op === 'UPDATE') {
                const act = changed(r, 'is_active') ? r.new?.['is_active'] : undefined
                const ls = changeLines(d, r, opts, new Set(act === undefined ? [] : ['is_active']))
                if (act !== undefined) out.push({ title: tx(d, act === true ? 'opt.recipeRestored' : 'opt.recipeRetired'), part, lines: ls, key: true, weight: 65 })
                else if (ls.length) out.push({ title: tx(d, 'opt.recipeChanged'), part, lines: ls, key: false, weight: 40 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'process_recipe_versions') {
            if (r.op === 'INSERT') {
                const rc = refLabel(r, 'recipe_id')
                const v = num(r.new?.['version'] ?? null)
                const part = rc && v !== null ? { text: `${rc} v${v}` } : null
                out.push({ title: tx(d, 'opt.versionAdded'), part, lines: valueLines(d, r, r.new, opts, new Set(['recipe_id', 'version'])), key: true, weight: 70 })
            } else out.push(describeGeneric(d, r, opts))
        } else if (r.table === 'operation_types' && r.op === 'UPDATE' && changed(r, 'balance_tolerance_pct')) {
            out.push({ title: tx(d, 'opt.toleranceSet'), lines: changeLines(d, r, opts), key: true, weight: 60 })
        } else out.push(describeGeneric(d, r, opts))
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
            // U1-B(Q14):给一张发完的单加一行,状态由"已发 vs 已订"推导着翻回 partially_shipped —— 那是改单的【结果】,
            //   不是这一次的事件;同一次操作里有改单的事件史时,它排在改单之下(标题是 "Sales order amended · line added")。
            const derived = key === 'so.statusChanged' && [...types].some((t) => SO_AMEND.has(t))
            out.push({ title: tx(d, key), lines: ls, reason: to === 'cancelled' ? typed(r.new?.['cancel_reason']) : null, key: true, weight: derived ? 60 : 85 })
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
        // MES-3a(Q12):这张执照对一类 NEA 废物的库存上限 —— 给 · 改 · 拿掉(拿掉 = 退回"没给")
        if (r.table === 'licence_storage_limits') {
            const cat = dictName(d, r, 'category_code')
            if (r.op === 'INSERT') return { title: withPart(tx(d, 'lic.limitSet'), cat), lines: valueLines(d, r, r.new, opts, new Set(['category_code'])), key: true, weight: 60 }
            if (r.op === 'DELETE') return { title: withPart(tx(d, 'lic.limitCleared'), cat), lines: [], key: true, weight: 60 }
            return { title: withPart(tx(d, 'lic.limitChanged'), cat), lines: changeLines(d, r, opts), key: true, weight: 60 }
        }
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
    // MES-3b(Q4 · Q7):这个库位的标签 —— 发去打印了 / 补印(与理由)
    out.push(...describeLabelPrints(d, by('label_prints'), opts))
    return out
}

// ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):一次印标签 —— 挂在它印的那样东西(进料批 · 产出批 · 库位)下面。
//   只追加,所以只有 INSERT:第一次说 "Label issued for printing"(浏览器不报纸出没出来,所以不说 "printed"),
//   之后每一次说 "Label reprinted",理由放在理由那一格(人敲的字)。模板、纸、份数作值行;快照与二维码路径不进记录(它们是印出去的东西本身)。
function describeLabelPrints(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const skip = new Set(['object_kind', 'inbound_batch_id', 'output_batch_id', 'storage_location_id', 'is_reprint', 'reprint_reason',
        'qr_payload', 'printed_fields', 'printed_at', 'printed_by'])
    const out: Block2[] = []
    for (const r of rows) {
        if (r.op !== 'INSERT') continue
        const reprint = r.new?.['is_reprint'] === true
        out.push({ title: tx(d, reprint ? 'label.reprinted' : 'label.printed'), lines: valueLines(d, r, r.new, opts, skip),
                   reason: reprint ? typed(r.new?.['reprint_reason']) : null, key: true, weight: 42 })
    }
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
    return kind === 'formula_create' ? 'tr.sentNew' : kind === 'formula_change' ? 'tr.sentChange' : kind === 'formula_reactivate' ? 'tr.sentReactivate'
        : kind === 'contract_activate' ? 'tr.sentActivate' : 'tr.sentOther'    // AUDIT-TRAIL-1c-2:合同那一页上的那一种
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
    // MES-1(Q22):采集上限的修改史就是变更记录
    ingest_settings: 'set.ingest',
    // MES-5a-2(Q32):V25 的修改史就是变更记录
    electricity_settings: 'set.electricity',
    // MES-6a-1(Q14):V16 的修改史就是变更记录
    quality_settings: 'set.quality',
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
export const FIN_SUBJECTS = new Set(['journal_entry', 'invoice', 'credit_note', 'payment', 'payment_request', 'expense', 'payable',
    // AUDIT-TRAIL-1c-2
    'sale', 'freight', 'fixed_asset', 'bank_statement', 'gst_period', 'fx_rate', 'management_pack', 'contract',
    // AUDIT-TRAIL-1c-3
    'finance_lock', 'finance_gst', 'company_profile', 'year_close', 'journal_request', 'expense_claim', 'my_expense_claim', 'bank_transfer',
    'wht_remittance', 'cash_forecast', 'cash_forecast_line', 'bank_import_profile'])

/** 整页的冲销关系(与上面认冲销分录同一个做法:看整页,不只看这一条)—— 镜像 id → 原单 {id, code, href} */
export type FinCtx = {
    paymentMirror: Map<string, { code: string | null; href: string | null }>
    paymentOrigin: Map<string, { code: string | null }>
    expenseMirror: Map<string, { code: string | null; href: string | null }>
    expenseOrigin: Map<string, { code: string | null }>
    /** MES-6a-1(Q33–Q37):镜像费用单 id → 原单上存的冲销理由(reversal_reason)。这一刀之前冲的旧单没有它,理由仍从镜像单 notes 读 */
    expenseReason: Map<string, string>
    /** 冲销分录 id → 它冲的那一张原分录的单号(原分录今天的 reversed_by 指着它) */
    journalOrigin: Map<string, string | null>
}
export function finContext(rows: TrailRow[]): FinCtx {
    const c: FinCtx = { paymentMirror: new Map(), paymentOrigin: new Map(), expenseMirror: new Map(), expenseOrigin: new Map(), expenseReason: new Map(), journalOrigin: new Map() }
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
            if (table === 'expenses' && typeof img['reversal_reason'] === 'string' && !c.expenseReason.has(m)) c.expenseReason.set(m, img['reversal_reason'] as string)
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
    // ★ U1-A(Tim 的裁定:每一个被遮的值都读作 Restricted):imgOf 把受限标记丢掉,于是一个被遮的值在这里【整行消失】——
    //   读起来像"没填"。受限就说受限(vlinesR 的同一个判法,挪进所有人都走的这一支)。
    const raw = r.new?.[col] ?? r.old?.[col] ?? r.ctx?.[col]
    if (isRestricted(raw)) return [{ t: 'value', label: label ?? fieldMeta(d, r.table!, col)[0], value: { text: tx(d, 'restricted'), restricted: true } }]
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
    // ★ U1-A(Tim 的 UNBLOCK-1 Q1,2026-10-05):工资分录的金额对不持 data.view_pay 的读者是受限标记 —— imgOf 把受限值丢掉,
    //   下面那句 `?? 0` 会把它印成 "Credit 0.00 SGD"(一句谎话)。受限就说受限;借贷那一边照常说(方向不是工资)。
    const raw = r.new ?? r.old ?? {}
    if (isRestricted(raw['debit']) || isRestricted(raw['credit'])) {
        const side = isRestricted(raw['debit']) && isRestricted(raw['credit'])
            ? null
            : (num(img['debit'] ?? null) ?? 0) > 0 ? 'je.debit' as const : 'je.credit' as const
        const text = side ? tx(d, side, { amount: tx(d, 'restricted') }) : tx(d, 'restricted')
        return { t: 'value', label: acc, value: { text, restricted: true } }
    }
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
            // AUDIT-TRAIL-1c-3:年结那一块里,结转分录是年结那一句的一行("Closing journal: JE-…"),不再另起一句
            if (subject === 'year_close') continue
            const ls: Line[] = []
            if (isRoot) {
                ls.push(...vlines(d, r, ['entry_date', 'source_type'], opts))
                const memo = typed(r.new?.['memo'])
                if (memo) ls.push({ t: 'value', label: fieldMeta(d, 'journal_entries', 'memo')[0], value: memo })
                ls.push(...rows.filter((x) => x.table === 'journal_lines' && x.op === 'INSERT').map((x) => journalLineLine(d, x)))
                // AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(资产 · 期末:金额)
                for (const x of rows.filter((y) => y.table === 'fixed_asset_depreciation' && y.op === 'INSERT' && str(y, 'journal_entry_id') === id)) {
                    ls.push({ t: 'value', label: refLabel(x, 'asset_id') ?? cap(thing(d, 'fixed_assets')),
                              value: formatValue(d, 'fixed_asset_depreciation', 'amount_base', x.new?.['amount_base'], imgOf(x), x.refs, 'INSERT', opts) })
                }
            }
            // AUDIT-TRAIL-1c-3:在分录自己的页与清单块上(重估 · 折旧 · 工资 · 年结的批次),按来源说它是什么;别的页照旧 "Journal posted"
            const src = str(r, 'source_type')
            const srcKey: TrailTextKey = subject === 'journal_entry' && src && src in JE_SOURCE_TITLE ? JE_SOURCE_TITLE[src] : 'je.posted'
            out.push({ title: withPart(tx(d, srcKey), code), lines: ls, key: true, weight: isRoot ? 100 : 55, recordId: id })
        } else if (r.op === 'UPDATE' && changed(r, 'status') && str(r, 'status', 'new') === 'reversed') {
            const rev = str(r, 'reversed_by', 'new')
            // 冲销分录自己的页:它的建立那一句已经说了"Reverses JE-…"
            if (subject === 'journal_entry' && rev && rev === rootId) continue
            const revRow = rev ? jes.find((x) => idOf(x) === rev && x.op === 'INSERT') : undefined
            const ls: Line[] = []
            const v = docVal(d, r, 'journal_entries', 'reversed_by')
            if (v) ls.push({ t: 'value', label: tx(d, 'je.reversedByLine'), value: v })
            // AUDIT-TRAIL-1c-3(Q30):在缴纳那一块里,它的分录被冲销就是"WHT remittance reversed",冲销分录是下面一行
            if (subject === 'wht_remittance') {
                out.push({ title: tx(d, 'pr.done.wht_remittance_reversal'), lines: ls, reason: revRow ? reversalReason(str(revRow, 'memo')) : null,
                           key: true, weight: 96, recordId: id, whtReversal: true })
                continue
            }
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
        if (subject === 'sale') continue    // AUDIT-TRAIL-1c-2:在销售那一页上,开票那一行说成"开了哪一张发票"(describeLedger2)
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
    // AUDIT-TRAIL-1c-3:分录那一节说的"WHT remittance reversed"(Q30)不是"付了"那一句 —— 缴纳的建立不并进它
    const doneBlock = out.find((b) => !b.whtReversal && PR_KINDS.some((k) => b.title.startsWith(tx(d, PR_TEXT.done[k]))))
    for (const r of by('bank_transfers')) {
        const ls = r.op === 'INSERT' ? vlines(d, r, ['transfer_date', 'from_account', 'to_account', 'amount_out', 'amount_in', 'bank_reference'], opts)
            : isSet(r, 'reversed_at') ? vlines(d, r, ['reversal_entry_id'], opts) : changeLines(d, r, opts)
        if (doneBlock) { doneBlock.lines.push(...ls); continue }
        // AUDIT-TRAIL-1c-3:转账自己的一次改动是 "Bank transfer changed"(以前借了申请的 "Request changed")
        out.push({ title: tx(d, r.op === 'INSERT' ? 'pr.done.bank_transfer' : isSet(r, 'reversed_at') ? 'pr.done.bank_transfer_reversal' : 'btr.changed'), lines: ls, reason: typed(r.new?.['notes']),
                   key: r.op === 'INSERT' || isSet(r, 'reversed_at'), weight: 70 })
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
                       reason: typed(fc.expenseReason.get(id)) ?? reversalReason(str(r, 'notes')), key: true, weight: subject === 'expense' ? 95 : 65, recordId: id })
            continue
        }
        if (r.op === 'INSERT') {
            const root = subject === 'expense' && id === rootId
            const ls = root ? vlines(d, r, ['expense_date', 'supplier_id', 'payee_name', 'employee_id', 'account_code', 'amount_ccy', 'tax_ccy', 'amount_base',
                'payment_status', 'bank_account_code', 'wht_nature', 'wht_rate_pct', 'wht_amount_ccy', 'purchase_order_line_id'], opts) : vlines(d, r, ['amount_ccy'], opts)
            // AUDIT-TRAIL-1d-2:医疗报销付款建的费用单,notes 是 pay_medical_claim 写的 "Medical claim MC-… (EMP-…)" —— 系统写的,
            //   在报销单那一页上不冒充一个理由(报销单就是这一页)
            const sysNote = (subject === 'medical_claim' || subject === 'my_medical_claim') && /^Medical claim \S+ \(\S+\)$/.test(str(r, 'notes') ?? '')
            out.push({ title: withPart(tx(d, 'exp.recorded'), code), lines: ls, reason: sysNote ? null : typed(r.new?.['notes']), key: true, weight: root ? 100 : 65, recordId: id })
            continue
        }
        if (changed(r, 'reversed_by_expense') || (changed(r, 'status') && str(r, 'status', 'new') === 'reversed')) {
            const m = str(r, 'reversed_by_expense', 'new')
            if (m && exps.some((x) => x.op === 'INSERT' && idOf(x) === m)) continue
            const v = docVal(d, r, 'expenses', 'reversed_by_expense')
            // MES-6a-1(Q33–Q37):理由存在原单自己身上(reversal_reason)—— 报销单那一页只看得见原单这一行(镜像单不在它的成员里),理由照样说出来
            out.push({ title: withPart(tx(d, 'exp.reversed'), code), lines: v ? [{ t: 'value', label: tx(d, 'pay.reversingLine'), value: v }] : [],
                       reason: typed(r.new?.['reversal_reason']), key: true, weight: 90, recordId: id })
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
        if (subject === 'fixed_asset') continue    // AUDIT-TRAIL-1c-2:在资产那一页上从资产这一边说("Cost added · EXP-…")
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
        if (subject === 'freight') continue    // AUDIT-TRAIL-1c-2:在运费单那一页上,分摊是建单那一句的行(describeLedger2)
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: withPart(tx(d, 'batch.freight'), refLabel(r, 'freight_document_id')), lines: vlines(d, r, ['amount_base'], opts), key: true, weight: 50 })
    }

    // 别的表(这几页的登记表之外不该出现;出现了照通用的说,不丢)
    // ── ⑧ AUDIT-TRAIL-1c-2:其余的单据与合同 ─────────────────────────────────────────────────────
    out.push(...describeLedger2(d, rows, opts))
    // ── ⑨ AUDIT-TRAIL-1c-3:期末、设置与清单页上的记录 ───────────────────────────────────────────────
    out.push(...describeLedger3(d, rows, opts))
    // Q30:缴纳的冲销经一张申请付出时,申请那一句("WHT remittance reversed · PREQ-…")与分录那一句说的是同一件事 ——
    //   分录那一句的"Reversed by"并进申请那一句(它的"Posted as"是同一张分录,不再说一遍),申请那一句带着审批留痕
    const jrev = out.find((b) => b.whtReversal)
    const rrev = jrev && out.find((b) => b !== jrev && b.title.startsWith(tx(d, 'pr.done.wht_remittance_reversal')))
    if (jrev && rrev) {
        const postedAs = fieldMeta(d, 'payment_requests', 'result_journal_entry_id')[0]
        rrev.lines = [...rrev.lines.filter((l) => !(l.t === 'value' && l.label === postedAs)), ...jrev.lines]
        if (!rrev.reason && jrev.reason) rrev.reason = jrev.reason
        rrev.weight = Math.max(rrev.weight, jrev.weight)
        out.splice(out.indexOf(jrev), 1)
    }
    const known = new Set(['journal_entries', 'journal_lines', 'journal_requests', 'invoice_requests', 'payment_requests', 'approval_log', 'invoices',
        'invoice_lines', 'invoice_issues', 'credit_notes', 'credit_note_lines', 'cn_issues', 'payments', 'payment_allocations', 'bank_transfers',
        'wht_remittances', 'expenses', 'expense_claims', 'fixed_asset_cost_entries', 'prepayment_applications', 'finance_attachments',
        'inbound_batches', 'price_history', 'freight_allocations', ...LEDGER2_TABLES, ...LEDGER3_TABLES])
    for (const r of rows) if (r.table && !known.has(r.table)) out.push(describeGeneric(d, r, opts))
    return out
}
/** AUDIT-TRAIL-1c-3:分录自己的页与清单块上,按来源说出一张批次分录是什么(字面量写全 —— check-trail-wording 按字面认) */
const JE_SOURCE_TITLE: Record<string, TrailTextKey> = {
    revaluation: 'je.posted.revaluation', depreciation: 'je.posted.depreciation', payroll: 'je.posted.payroll', year_close: 'je.posted.year_close',
}
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-2:其余的单据与合同 —— 销售 · 运费单 · 资产(财务那一页)· 对账单 · GST 期间 · 汇率 · 管理包 · 合同
//   (Tim 2026-10-03,AT-1c Step 0 §a 与 Q6 · Q7 · Q9 · Q10 · Q14 · Q21 · Q22 · Q23 · Q24 · Q25)
// ════════════════════════════════════════════════════════════════════════════
// 【同一个家族】这八页上的每一行都经 describeFinance 说(它们与 1c-1 那七页共用分录、核销、附件、审批的说法);
//   这里只管【这一刀才画上页面】的那些表。
// 【一件事两行】(1b-3 的规矩)资产卡与汇率各有一张修改史,与那一行自己的变更记录在同一笔里写:记录开始之后变更记录那一行说
//   (它有全部的列),修改史那一行不再说;记录开始之前只有修改史(与那一行的建行那一刻),由它说。
// 【机器写的那一截】撤销对账往备注里追加 "UNRECONCILED <时刻>: <理由>"(Q24)—— 认出来,说成 "Reconciliation undone",
//   理由是人写的那一句;那一截时刻不上屏。GST 的申报格只说英文(label_zh 是机器写的中文,Q8 · Q23)。
export const LEDGER2_TABLES = ['sales_records', 'sales_record_movements', 'sales_attribution_log', 'freight_documents', 'fixed_assets',
    'fixed_asset_history', 'fixed_asset_depreciation', 'fixed_asset_depreciation_anchors', 'asset_disposal_requests', 'equipment_maintenance',
    'equipment_downtime', 'equipment_service_intervals', 'shift_handover_equipment_refs', 'bank_statements', 'bank_statement_lines',
    'bank_line_matches', 'bank_reconciliations', 'bank_reconciliation_variance_items', 'gst_periods', 'gst_return_boxes', 'gst_filing_requests',
    'fx_rates', 'fx_rate_history', 'management_packs', 'contracts', 'contract_grade_specs', 'contract_insurance_obligations',
    'contract_volume_commitments', 'contract_pricing_terms', 'contract_settlement_terms', 'contract_refining_charges', 'contract_penalty_elements',
    'terms_requests', 'contract_document_terms']
const CONTRACT_TERM_TABLES = ['contract_grade_specs', 'contract_insurance_obligations', 'contract_volume_commitments', 'contract_pricing_terms',
    'contract_settlement_terms', 'contract_refining_charges', 'contract_penalty_elements']
/** 撤销对账追加的那一截:"\nUNRECONCILED 2026-10-03 16:00:00.123+08: <理由>" → 理由;认不出就是 null */
export function unreconcileReason(notes: string | null): string | null {
    if (!notes) return null
    const m = notes.match(/(?:^|\n)UNRECONCILED \d{4}-\d{2}-\d{2}[ T][\d:.]+(?:[+-]\d{2}(?::?\d{2})?|Z)?: ([^\n]*)$/)
    return m ? m[1].trim() || null : null
}
/** 资产卡修改史里一对 old_x / new_x 说的是资产卡的哪几列 —— 主键、建行的时刻与人、编号不说(编号在页头)*/
const FA_HISTORY_SKIP = new Set(['id', 'created_at', 'created_by', 'code'])
function faHistoryLines(d: TrailDict, h: TrailRow, opts: BuildOptions, created: boolean): Line[] {
    const n = h.new ?? {}
    const out: Line[] = []
    const cols = created
        ? Object.keys(n).filter((k) => k.startsWith('new_')).map((k) => k.slice(4))
        : (Array.isArray(n['changed_columns']) ? (n['changed_columns'] as Json[]).filter((c): c is string => typeof c === 'string') : [])
    for (const c of cols) {
        if (FA_HISTORY_SKIP.has(c)) continue
        const label = fieldMeta(d, 'fixed_assets', c)[0]
        if (created) {
            if (isEmpty(n['new_' + c] ?? null)) continue
            out.push({ t: 'value', label, value: formatValue(d, 'fixed_asset_history', 'new_' + c, n['new_' + c], n, h.refs, 'INSERT', opts) })
        } else {
            out.push({ t: 'change', label, old: formatValue(d, 'fixed_asset_history', 'old_' + c, n['old_' + c], n, h.refs, 'UPDATE', opts),
                       new: formatValue(d, 'fixed_asset_history', 'new_' + c, n['new_' + c], n, h.refs, 'UPDATE', opts) })
        }
    }
    return out
}
/** 一张申请(资产处置 · GST 申报)的一生:送去批 · 批准(审批关着时生下来就批了,Q32)· 驳回 · 撤回 · 别的改动 */
function requestBlocks(d: TrailDict, rows: TrailRow[], opts: BuildOptions, table: string,
                       keys: { sent: TrailTextKey; approved: TrailTextKey; rejected: TrailTextKey; withdrawn: TrailTextKey; changed: TrailTextKey },
                       insertCols: string[], approvedWithLog: (id: string | undefined) => boolean): Block2[] {
    const out: Block2[] = []
    const mine = rows.filter((r) => r.table === table)
    const inserted = new Map<string, TrailRow>()
    for (const r of mine) if (r.op === 'INSERT' && idOf(r)) inserted.set(idOf(r)!, { ...r, new: { ...(r.new ?? {}) } })
    for (const r of mine) {
        const ins = r.op === 'UPDATE' && idOf(r) ? inserted.get(idOf(r)!) : undefined
        if (ins) { Object.assign(ins.new!, r.new ?? {}); ins.refs = mergeRefs(ins.refs, r.refs) }
    }
    for (const r0 of mine) {
        if (r0.op === 'UPDATE' && idOf(r0) && inserted.has(idOf(r0)!)) continue
        const r = r0.op === 'INSERT' && idOf(r0) ? inserted.get(idOf(r0)!) ?? r0 : r0
        const id = idOf(r)
        const { code, part } = labelPart(r)
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        if (r.op === 'INSERT') {
            const ls = vlines(d, r, insertCols, opts)
            const isAuto = approvedWithLog(id) || str(r0, 'status', 'new') === 'approved'
            if (isAuto) ls.unshift({ t: 'note', text: tx(d, 'po.autoApproved') })
            const end = str(r, 'status', 'new')
            const k = isAuto || end === 'approved' ? keys.approved : end === 'rejected' ? keys.rejected : keys.sent
            out.push({ title: withPart(tx(d, k), code), part, lines: ls, reason: typed(r.new?.['reason'] ?? r.new?.['note']),
                       key: true, weight: 85, recordId: id, absorbsApproval: true })
        } else if (to === 'withdrawn' || isSet(r, 'withdrawn_at')) {
            out.push({ title: withPart(tx(d, keys.withdrawn), code), part, lines: [], reason: typed(r.new?.['withdraw_reason']), key: true, weight: 85, recordId: id, absorbsApproval: true })
        } else if (to === 'approved' || to === 'rejected') {
            out.push({ title: withPart(tx(d, to === 'approved' ? keys.approved : keys.rejected), code), part, lines: [],
                       reason: typed(r.new?.['decision_notes']), key: true, weight: 90, recordId: id, absorbsApproval: true })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, new Set(['decided_at', 'decided_by', 'executed_at', 'snapshot', 'estimate', 'result', 'boxes', 'label']))
            if (ls.length) out.push({ title: withPart(tx(d, keys.changed), code), part, lines: ls, key: false, weight: 35, recordId: id })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}

function describeLedger2(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const subject = opts.subject ?? ''
    const rootId = opts.recordId ?? null
    const auto = (id: string | undefined) => !!id && by('approval_log').some((a) => str(a, 'subject_id') === id && str(a, 'decision', 'new') === 'auto_approved')
    const skipStamps = new Set(['updated_at', 'updated_by'])

    // ── ① 销售(Q14)──────────────────────────────────────────────────────────────────
    const sales = by('sales_records')
    const saleInserted = sales.some((r) => r.op === 'INSERT')
    const attrib = by('sales_attribution_log')
    for (const r of sales) {
        if (r.op === 'INSERT') {
            const root = subject === 'sale' && idOf(r) === rootId
            const ls = vlines(d, r, root ? ['output_batch_id', 'customer_id', 'sale_date', 'quantity', 'unit_price', 'currency', 'fx_rate', 'amount_base',
                'sales_order_line_id', 'price_source'] : ['sale_date', 'quantity', 'amount_base'], opts)
            out.push({ title: tx(d, 'sale.recorded'), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: root ? 100 : 60 })
        } else if (r.op === 'UPDATE' && changed(r, 'customer_id') && isEmpty(r.old?.['customer_id'] ?? null)) {
            const log = attrib.find((a) => a.op === 'INSERT')
            out.push({ title: tx(d, 'sale.attributed'), lines: vline(d, r, 'customer_id', opts), reason: log ? typed(log.new?.['note']) : null, key: true, weight: 90 })
        } else if (r.op === 'UPDATE' && isSet(r, 'cogs_entry_id')) {
            const v = docVal(d, r, 'sales_records', 'cogs_entry_id')
            out.push({ title: tx(d, 'sale.cogsPosted'), lines: v ? [{ t: 'value', label: fieldMeta(d, 'sales_records', 'cogs_entry_id')[0], value: v }] : [], key: true, weight: 70 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'sale.changed'), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const r of attrib) {
        // 归属客户那一笔里,销售那一行已经说了(理由取自这一行的 note)
        if (r.op === 'INSERT' && sales.some((x) => x.op === 'UPDATE' && changed(x, 'customer_id'))) continue
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'sale.attributed'), lines: vlines(d, r, ['customer_id', 'amount_base'], opts), reason: typed(r.new?.['note']), key: true, weight: 90 })
    }
    for (const r of by('sales_record_movements')) {
        if (r.op === 'INSERT' && saleInserted) continue        // 出库是记销售那一笔的副作用
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'batch.saleStock'), lines: [], key: false, weight: 40 })
    }
    if (subject === 'sale') for (const r of by('invoice_lines')) {
        const code = refLabel(r, 'invoice_id')
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'batch.invoiced'), code), lines: vlines(d, r, ['quantity', 'amount_ccy'], opts), key: true, weight: 75 })
        else if (r.op === 'UPDATE' && changed(r, 'invoice_voided') && r.new?.['invoice_voided'] === true) out.push({ title: withPart(tx(d, 'inv.voided'), code), lines: [], key: true, weight: 75 })
        else if (r.op === 'UPDATE') { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'inv.lineChanged'), lines: ls, key: false, weight: 30 }) }
        else out.push(describeGeneric(d, r, opts))
    }

    // ── ② 运费单 ────────────────────────────────────────────────────────────────────
    const frts = by('freight_documents')
    const frtAllocs = by('freight_allocations')
    const allocLine = (r: TrailRow): Line => ({ t: 'value', label: refLabel(r, 'inbound_batch_id') ?? cap(thing(d, 'freight_allocations')),
        value: formatValue(d, 'freight_allocations', 'amount_base', imgOf(r)['amount_base'], imgOf(r), r.refs, r.op, opts) })
    for (const r of frts) {
        if (r.op === 'INSERT') {
            const ls = vlines(d, r, ['doc_date', 'supplier_id', 'direction', 'amount_ccy', 'currency', 'fx_rate', 'amount_base', 'allocation_basis',
                'payment_status', 'bank_account_code', 'container_id'], opts)
            ls.push(...frtAllocs.filter((a) => a.op === 'INSERT').map(allocLine))
            out.push({ title: withPart(tx(d, 'frt.recorded'), subject === 'freight' ? null : str(r, 'code')), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 100 })
        } else if ((changed(r, 'status') && str(r, 'status', 'new') === 'reversed') || isSet(r, 'reversed_at')) {
            // 冲销分录是下面那一块(分录那一家说"Journal … reversed / Reversed by");这里只说这张单冲销了、为什么
            out.push({ title: tx(d, 'frt.reversed'), lines: [], reason: typed(r.new?.['reversal_reason']), key: true, weight: 95 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, skipStamps)
            if (ls.length) out.push({ title: tx(d, 'frt.changed'), lines: ls, key: changed(r, 'payment_status'), weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    if (subject === 'freight') for (const r of frtAllocs) {
        if (r.op === 'INSERT' && frts.some((x) => x.op === 'INSERT')) continue
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'batch.freight'), refLabel(r, 'inbound_batch_id')), lines: vlines(d, r, ['amount_base'], opts), key: true, weight: 50 })
        else if (r.op === 'UPDATE') { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'frt.allocationChanged'), lines: ls, key: false, weight: 30 }) }
        else out.push(describeGeneric(d, r, opts))
    }

    // ── ③ 资产(财务那一页,Q10)────────────────────────────────────────────────────────
    const fas = by('fixed_assets')
    const faLogged = fas.some((r) => !r.prelog)
    const faInserted = fas.some((r) => r.op === 'INSERT')
    for (const r of fas) {
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'eq.cardCreated'), lines: vlines(d, r, ['description', 'category', 'acquisition_date', 'cost_ccy', 'currency', 'fx_rate',
                'cost_base', 'useful_life_months', 'residual_base', 'depreciation_account_code', 'planned_in_service_date', 'expense_id'], opts),
                       reason: typed(r.new?.['notes']), key: true, weight: 100 })
        } else if (r.op === 'UPDATE') {
            if (changed(r, 'status') && str(r, 'status', 'new') === 'disposed') {
                out.push({ title: tx(d, 'fa.disposed'), lines: changeLines(d, r, opts, new Set(['status'])), key: true, weight: 95 })
            } else if (isSet(r, 'in_service_date')) {
                out.push({ title: tx(d, 'fa.inService'), lines: changeLines(d, r, opts), key: true, weight: 90 })
            } else {
                const ls = changeLines(d, r, opts)
                if (ls.length) out.push({ title: tx(d, 'eq.cardEdited'), lines: ls, key: false, weight: 30 })
            }
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const h of by('fixed_asset_history')) {
        // 一件事两行:同一笔里资产卡自己那一行(变更记录)在,就由它说
        if (faLogged && !h.prelog) continue
        if (h.op !== 'INSERT') { out.push(describeGeneric(d, h, opts)); continue }
        const ct = str(h, 'change_type', 'new')
        if (ct === 'created') {
            if (faInserted) continue
            out.push({ title: tx(d, 'eq.cardCreated'), lines: faHistoryLines(d, h, opts, true), key: true, weight: 100 })
            continue
        }
        const n = h.new ?? {}
        const cols = Array.isArray(n['changed_columns']) ? n['changed_columns'] as Json[] : []
        const ls = faHistoryLines(d, h, opts, false)
        if (cols.includes('status') && n['new_status'] === 'disposed') out.push({ title: tx(d, 'fa.disposed'), lines: ls, key: true, weight: 95 })
        else if (cols.includes('in_service_date') && !isEmpty(n['new_in_service_date'] ?? null)) out.push({ title: tx(d, 'fa.inService'), lines: ls, key: true, weight: 90 })
        else if (ls.length) out.push({ title: tx(d, 'eq.cardEdited'), lines: ls, key: false, weight: 30 })
    }
    if (subject === 'fixed_asset') for (const r of by('fixed_asset_cost_entries')) {
        if (r.op === 'INSERT') out.push({ title: withPart(tx(d, 'fa.costAdded'), refLabel(r, 'expense_id')), lines: vlines(d, r, ['amount_ccy', 'amount_base'], opts), key: true, weight: 70 })
        else if (r.op === 'UPDATE') { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'fa.costChanged'), lines: ls, key: false, weight: 30 }) }
        else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('fixed_asset_depreciation')) {
        // AUDIT-TRAIL-1c-3:在分录那一页(与折旧批次那一块)上,每一张资产的那一行是过账那一句的一行(describeFinance)
        if (subject === 'journal_entry' && r.op === 'INSERT' && rows.some((x) => x.table === 'journal_entries' && x.op === 'INSERT' && idOf(x) === str(r, 'journal_entry_id'))) continue
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'fa.depreciated'), lines: vlines(d, r, ['period_end', 'amount_base', 'journal_entry_id'], opts), key: true, weight: 70 })
    }
    for (const r of by('fixed_asset_depreciation_anchors')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        out.push({ title: tx(d, 'fa.rebased'), lines: vlines(d, r, ['effective_from', 'pre_anchor_target_base', 'remaining_months', 'expense_id', 'maintenance_id'], opts),
                   reason: typed(r.new?.['reason']), key: true, weight: 70 })
    }
    out.push(...requestBlocks(d, rows, opts, 'asset_disposal_requests',
        { sent: 'fa.disposalSent', approved: 'fa.disposalApproved', rejected: 'fa.disposalRejected', withdrawn: 'fa.disposalWithdrawn', changed: 'fa.disposalChanged' },
        ['disposal_date', 'proceeds_base', 'bank_account'], auto))
    // 保养维修、停机、保养间隔、交接班提到的停机:与加工那一页同一套说法(家在 equipment)
    const eq = rows.filter((r) => ['equipment_maintenance', 'equipment_downtime', 'equipment_service_intervals', 'shift_handover_equipment_refs'].includes(r.table!))
    if (eq.length) out.push(...describeEquipment(d, eq, opts, 'equipment'))

    // ── ④ 对账单(Q6 · Q9 · Q24)───────────────────────────────────────────────────────
    const stmts = by('bank_statements'), sLines = by('bank_statement_lines'), matches = by('bank_line_matches')
    const recons = by('bank_reconciliations'), items = by('bank_reconciliation_variance_items')
    const reconLines = (): Line[] => {
        const ls: Line[] = []
        for (const r of recons.filter((x) => x.op === 'INSERT')) ls.push(...vlines(d, r, ['as_of', 'bank_closing_balance', 'book_balance', 'difference', 'matched_lines', 'ignored_lines'], opts))
        for (const v of items.filter((x) => x.op === 'INSERT')) {
            const img = imgOf(v)
            const kind = typeof img['item_kind'] === 'string' ? enumLabel(d, 'bank_reconciliation_variance_items', 'item_kind', img['item_kind'] as string) : cap(thing(d, 'bank_reconciliation_variance_items'))
            const amt = formatValue(d, 'bank_reconciliation_variance_items', 'amount', img['amount'], img, v.refs, v.op, opts)
            const note = typeof img['note'] === 'string' && img['note'] ? img['note'] as string : null
            ls.push({ t: 'value', label: kind, value: note ? { text: `${amt.text} · ${note}`, typed: true } : amt })
        }
        return ls
    }
    let reconSaid = false
    for (const r of stmts) {
        if (r.op === 'INSERT') {
            const ls = vlines(d, r, ['bank_account_code', 'currency', 'period_start', 'period_end', 'opening_balance', 'closing_balance', 'file_name'], opts)
            const n = sLines.filter((x) => x.op === 'INSERT').length
            if (n) ls.push({ t: 'value', label: tx(d, 'bst.lines'), value: { text: String(n) } })
            out.push({ title: tx(d, 'bst.imported'), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 100 })
            continue
        }
        if (r.op !== 'UPDATE') { out.push(describeGeneric(d, r, opts)); continue }
        if (isSet(r, 'deleted_at')) { out.push({ title: tx(d, 'bst.deleted'), lines: [], key: true, weight: 95 }); continue }
        const toStatus = changed(r, 'status') ? str(r, 'status', 'new') : null
        if (toStatus === 'reconciled' || isSet(r, 'reconciled_at')) {
            reconSaid = true
            out.push({ title: tx(d, 'bst.reconciled'), lines: reconLines(), key: true, weight: 95 })
            continue
        }
        if (toStatus === 'open' && str(r, 'status', 'old') === 'reconciled') {
            // Q24:撤销对账往备注后面追加了一截机器写的 "UNRECONCILED <时刻>: <理由>" —— 不当成一次备注的改动说;理由是人写的那一句
            const sup = recons.find((x) => isSet(x, 'superseded_at'))
            const why = unreconcileReason(str(r, 'notes', 'new')) ?? (sup ? str(sup, 'superseded_reason', 'new') : null)
            reconSaid = true
            out.push({ title: tx(d, 'bst.unreconciled'), lines: [], reason: typed(why), key: true, weight: 95 })
            continue
        }
        const notesMachine = changed(r, 'notes') && unreconcileReason(str(r, 'notes', 'new')) !== null
        const ls = changeLines(d, r, opts, new Set([...skipStamps, ...(notesMachine ? ['notes'] : [])]))
        if (ls.length) out.push({ title: tx(d, 'bst.changed'), lines: ls, key: false, weight: 30 })
    }
    for (const r of recons) {
        if (reconSaid) continue
        if (r.op === 'INSERT') out.push({ title: tx(d, 'bst.reconciled'), lines: reconLines(), key: true, weight: 90 })
        else if (isSet(r, 'superseded_at')) out.push({ title: tx(d, 'bst.unreconciled'), lines: [], reason: typed(r.new?.['superseded_reason']), key: true, weight: 90 })
        else if (r.op === 'UPDATE') { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'bst.reconChanged'), lines: ls, key: false, weight: 30 }) }
        else out.push(describeGeneric(d, r, opts))
    }
    if (!reconSaid && !recons.some((x) => x.op === 'INSERT')) for (const v of items) {
        out.push({ title: tx(d, 'bst.reconChanged'), lines: v.op === 'UPDATE' ? changeLines(d, v, opts) : valueLines(d, v, v.op === 'DELETE' ? v.old : v.new, opts, new Set(['reconciliation_id'])), key: false, weight: 30 })
    }
    const lineNo = (r: TrailRow): string | null => { const n = num(imgOf(r)['line_no'] ?? null); return n === null ? null : tx(d, 'po.lineHeading', { n }) }
    const matchLine = (m: TrailRow): Line => ({ t: 'value', label: refLabel(m, 'journal_line_id') ?? cap(fieldMeta(d, 'bank_line_matches', 'journal_line_id')[0]),
        value: formatValue(d, 'bank_line_matches', 'matched_amount', imgOf(m)['matched_amount'], imgOf(m), m.refs, m.op, opts) })
    const matchesSaid = new Set<TrailRow>()
    for (const r of sLines) {
        if (r.op === 'INSERT' && stmts.some((x) => x.op === 'INSERT')) continue    // 导入那一句已经数过了
        const part = lineNo(r)
        const from = str(r, 'match_status', 'old'), to = changed(r, 'match_status') ? str(r, 'match_status', 'new') : null
        const mine = matches.filter((m) => str(m, 'statement_line_id') === idOf(r))
        if (to === 'matched') {
            mine.filter((m) => m.op === 'INSERT').forEach((m) => matchesSaid.add(m))
            out.push({ title: withPart(tx(d, 'bst.lineMatched'), part), lines: mine.filter((m) => m.op === 'INSERT').map(matchLine), key: true, weight: 60 })
        } else if (to === 'ignored') {
            out.push({ title: withPart(tx(d, 'bst.lineIgnored'), part), lines: [], reason: typed(r.new?.['ignore_reason']), key: true, weight: 60 })
        } else if (to === 'unmatched' && from === 'ignored') {
            out.push({ title: withPart(tx(d, 'bst.lineUnignored'), part), lines: [], key: true, weight: 60 })
        } else if (to === 'unmatched') {
            mine.filter((m) => m.op === 'DELETE').forEach((m) => matchesSaid.add(m))
            out.push({ title: withPart(tx(d, 'bst.lineUnmatched'), part), lines: mine.filter((m) => m.op === 'DELETE').map(matchLine), key: true, weight: 60 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, new Set(['match_status']))
            if (ls.length) out.push({ title: withPart(tx(d, 'bst.lineChanged'), part), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const m of matches) {
        if (matchesSaid.has(m)) continue
        const part = refLabel(m, 'statement_line_id')
        if (m.op === 'INSERT') out.push({ title: withPart(tx(d, 'bst.lineMatched'), part), lines: [matchLine(m)], key: true, weight: 60 })
        else if (m.op === 'DELETE') out.push({ title: withPart(tx(d, 'bst.lineUnmatched'), part), lines: [matchLine(m)], key: true, weight: 60 })
        else out.push(describeGeneric(d, m, opts))
    }

    // ── ⑤ GST 期间(Q22 · Q23)──────────────────────────────────────────────────────────
    for (const r of by('gst_periods')) {
        if (r.op === 'INSERT') {
            const corr = str(r, 'corrects_period_id')
            const code = corr ? refLabel(r, 'corrects_period_id') : null
            const title = corr ? (code ? tx(d, 'gstp.correctionOpened', { code }) : tx(d, 'gstp.correctionOpenedPlain')) : tx(d, 'gstp.opened')
            out.push({ title, lines: vlines(d, r, ['period_start', 'period_end'], opts), reason: typed(r.new?.['notes']), key: true, weight: 100 })
            continue
        }
        if (r.op !== 'UPDATE') { out.push(describeGeneric(d, r, opts)); continue }
        if ((changed(r, 'status') && str(r, 'status', 'new') === 'filed') || isSet(r, 'filed_at')) {
            out.push({ title: tx(d, 'gstp.filed'), lines: vlines(d, r, ['filed_on', 'filed_reference'], opts), key: true, weight: 95 })
            continue
        }
        // 批准那一下把期间翻成 approved —— 那是申报申请被批准的副作用(那一句在申请那一块里)
        const ls = changeLines(d, r, opts, new Set(by('gst_filing_requests').some((x) => changed(x, 'status')) || by('gst_return_boxes').length ? ['status'] : []))
        if (ls.length) out.push({ title: tx(d, 'gstp.changed'), lines: ls, key: changed(r, 'status'), weight: 40 })
    }
    out.push(...requestBlocks(d, rows, opts, 'gst_filing_requests',
        { sent: 'gstp.sent', approved: 'gstp.approved', rejected: 'gstp.rejected', withdrawn: 'gstp.withdrawn', changed: 'gstp.requestChanged' }, [], auto))
    const boxes = by('gst_return_boxes').filter((r) => r.op === 'INSERT')
    if (boxes.length) {
        // Q23:同一笔里抄下来的每一格并成一块("GST return locked · 9 boxes"),每一格一行,只说英文
        const sorted = [...boxes].sort((a, b) => (num(String(imgOf(a)['box'] ?? '').replace(/^box/, '')) ?? 0) - (num(String(imgOf(b)['box'] ?? '').replace(/^box/, '')) ?? 0))
        out.push({ title: tx(d, 'gstp.locked', { n: boxes.length }), key: true, weight: 80, lines: sorted.map((r) => {
            const img = imgOf(r)
            const n = String(img['box'] ?? '').replace(/^box/, '')
            const en = typeof img['label_en'] === 'string' && img['label_en'] ? ` · ${img['label_en']}` : ''
            return { t: 'value' as const, label: `${tx(d, 'gstp.box', { n })}${en}`, value: formatValue(d, 'gst_return_boxes', 'value_base', img['value_base'], img, r.refs, r.op, opts) }
        }) })
    }
    for (const r of by('gst_return_boxes')) if (r.op !== 'INSERT') out.push(describeGeneric(d, r, opts))

    // ── ⑥ 汇率(一件事两行;Q7)────────────────────────────────────────────────────────────
    const rates = by('fx_rates'), hist = by('fx_rate_history')
    const histAction = (h: TrailRow) => str(h, 'action', 'new')
    // AUDIT-TRAIL-1c-3(Q16):一次批量录入(/finance/fx 的清单块把同一次操作碰到的几条汇率并成一条)—— 一句,每一条汇率一行
    const ratesIn = rates.filter((r) => r.op === 'INSERT')
    if (ratesIn.length > 1) {
        out.push({ title: tx(d, 'fxr.recordedMany', { n: ratesIn.length }), key: true, weight: 100, lines: ratesIn.map((r) => {
            const img = imgOf(r)
            // 每一条的名字与 trail_ref_label 给汇率起的名字同一种说法("USD · TT selling rate · 01/10/2026")
            const label = [typeof img['currency'] === 'string' ? img['currency'] : null,
                typeof img['rate_type'] === 'string' ? FX_SIDE_NAME[img['rate_type'] as string] ?? formatValue(d, 'fx_rates', 'rate_type', img['rate_type'], img, r.refs, 'INSERT', opts).text : null,
                formatValue(d, 'fx_rates', 'rate_date', img['rate_date'], img, r.refs, 'INSERT', opts).text].filter(Boolean).join(' · ')
            return { t: 'value' as const, label, value: formatValue(d, 'fx_rates', 'rate_sgd_per_unit', img['rate_sgd_per_unit'], img, r.refs, 'INSERT', opts) }
        }) })
    }
    for (const r of rates) {
        const h = hist.find((x) => x.op === 'INSERT' && str(x, 'fx_rate_id') === idOf(r))
        if (r.op === 'INSERT' && ratesIn.length > 1) continue
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'fxr.recorded'), lines: vlines(d, r, ['currency', 'rate_type', 'rate_sgd_per_unit', 'rate_date', 'source'], opts),
                       reason: typed(r.new?.['notes']), key: true, weight: 100 })
        } else if (r.op === 'UPDATE' && isSet(r, 'deleted_at')) {
            out.push({ title: tx(d, 'fxr.withdrawn'), lines: [], reason: h ? typed(h.new?.['reason']) : null, key: true, weight: 95 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, skipStamps)
            const corrected = h && histAction(h) === 'corrected'
            if (ls.length || corrected) out.push({ title: tx(d, corrected ? 'fxr.corrected' : 'fxr.changed'), lines: ls, reason: h ? typed(h.new?.['reason']) : null, key: !!corrected, weight: corrected ? 90 : 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const h of hist) {
        if (h.op !== 'INSERT') { out.push(describeGeneric(d, h, opts)); continue }
        if (rates.some((r) => idOf(r) === str(h, 'fx_rate_id'))) continue    // 那一行自己的变更记录说了
        const a = histAction(h)
        if (a === 'withdrawn') out.push({ title: tx(d, 'fxr.withdrawn'), lines: [], reason: typed(h.new?.['reason']), key: true, weight: 95 })
        else if (a === 'corrected') out.push({ title: tx(d, 'fxr.corrected'), lines: [{ t: 'change', label: fieldMeta(d, 'fx_rates', 'rate_sgd_per_unit')[0],
            old: formatValue(d, 'fx_rate_history', 'prev_rate', h.new?.['prev_rate'], imgOf(h), h.refs, 'INSERT', opts),
            new: formatValue(d, 'fx_rate_history', 'rate_sgd_per_unit', h.new?.['rate_sgd_per_unit'], imgOf(h), h.refs, 'INSERT', opts) }], reason: typed(h.new?.['reason']), key: true, weight: 90 })
        else out.push({ title: tx(d, 'fxr.recorded'), lines: vlines(d, h, ['currency', 'rate_type', 'rate_sgd_per_unit', 'rate_date', 'source'], opts), reason: typed(h.new?.['notes']), key: true, weight: 100 })
    }

    // ── ⑦ 管理包(Q25)──────────────────────────────────────────────────────────────────
    for (const r of by('management_packs')) {
        if (r.op === 'INSERT') {
            out.push({ title: withPart(tx(d, 'mpk.produced'), subject === 'management_pack' && idOf(r) === rootId ? null : str(r, 'code')),
                       lines: vlines(d, r, ['period_month', 'period_start', 'period_end', 'locked_before_at_production', 'base_currency'], opts),
                       reason: typed(r.new?.['notes']), key: true, weight: subject === 'management_pack' && idOf(r) !== rootId ? 60 : 100 })
        } else if (r.op === 'UPDATE' && isSet(r, 'superseded_at')) {
            const v = docVal(d, r, 'management_packs', 'superseded_by')
            out.push({ title: tx(d, 'mpk.superseded'), lines: v ? [{ t: 'value', label: tx(d, 'mpk.replacedBy'), value: v }] : [],
                       reason: typed(r.new?.['superseded_reason']), key: true, weight: 95 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'mpk.changed'), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }

    // ── ⑧ 合同(Q21)──────────────────────────────────────────────────────────────────
    for (const r of by('contracts')) {
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'con.created'), lines: vlines(d, r, ['customer_id', 'supplier_id', 'side', 'kind', 'title', 'status', 'effective_from', 'effective_to',
                'signed_on', 'currency', 'incoterm', 'payment_terms_days', 'document_ref'], opts), reason: typed(r.new?.['notes']), key: true, weight: 100 })
            continue
        }
        if (r.op !== 'UPDATE') { out.push(describeGeneric(d, r, opts)); continue }
        if (isSet(r, 'deleted_at')) { out.push({ title: tx(d, 'con.deleted'), lines: [], key: true, weight: 95 }); continue }
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        const ls = changeLines(d, r, opts, new Set([...skipStamps, 'status']))
        if (to) out.push({ title: tx(d, to === 'active' ? 'con.activated' : to === 'suspended' ? 'con.suspended' : 'con.statusChanged'),
                           lines: to === 'active' || to === 'suspended' ? ls : changeLines(d, r, opts, skipStamps), key: true, weight: 96 })
        else if (ls.length) out.push({ title: tx(d, 'con.edited'), lines: ls, key: false, weight: 30 })
    }
    for (const t of CONTRACT_TERM_TABLES) for (const r of by(t)) {
        const thingName = thing(d, t)
        const metalCol = ['metal', 'substance'].find((c) => !isEmpty(imgOf(r)[c] ?? null))
        const part = metalCol ? { text: dictName(d, r, metalCol) } : null
        const skip = new Set(['contract_id', ...skipStamps, ...(metalCol ? [metalCol] : [])])
        if (r.op === 'INSERT') out.push({ title: tx(d, 'con.termAdded', { thing: thingName }), part, lines: valueLines(d, r, r.new, opts, skip), key: false, weight: 50 })
        else if (r.op === 'DELETE') out.push({ title: tx(d, 'con.termRemoved', { thing: thingName }), part, lines: valueLines(d, r, r.old, opts, skip), key: false, weight: 50 })
        else { const ls = changeLines(d, r, opts, skip); if (ls.length) out.push({ title: tx(d, 'con.termChanged', { thing: thingName }), part, lines: ls, key: false, weight: 40 }) }
    }
    const trs = by('terms_requests')
    if (trs.length) out.push(...describeFormula(d, trs, opts))
    for (const r of by('contract_document_terms')) {
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const code = refLabel(r, 'purchase_order_id') ?? refLabel(r, 'sales_order_id')
        out.push({ title: code ? tx(d, 'con.linked', { code }) : tx(d, 'con.linkedPlain'), lines: [], key: true, weight: 60 })
    }
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
// AUDIT-TRAIL-1c-3:期末、设置与清单页上的记录 —— 锁期面板 · GST 面板 · 公司资料 · 年结 · 现金预测与常设行 · 银行导入模板
//   (Tim 2026-10-03,AT-1c Step 0 §a 与 Q3 · Q4 · Q16 · Q25 · Q29)
// ════════════════════════════════════════════════════════════════════════════
// 【一行,两块面板】finance_settings 那一行由锁期与 GST 两块面板分着管(M6:读法那一层已经只留下这一块的列)——
//   这里按【变的是哪一列】说,不按主语说;同一份造句器在汇总页之外的任何一页上都只会看见它那一块的列。
// 【月结 / 反结】关账在同一笔里写一行 period_closes、把锁往后挪 —— 一句 "Month closed up to …",挪锁是它下面一行;
//   反结给那一行盖戳、把锁往回挪 —— "Month reopened from …"(那个月的第一天)。单独挪锁(设置页那一格)是 "Period lock moved"。
// 【一次操作一条】冻结一张新的预测、作废旧的一张(Q16):清单块把两条记录读回来的行并成一次 buildEntries —— 新那一张的冻结是标题,
//   旧那一张"被取代"是它下面一块。
export const LEDGER3_TABLES = ['finance_settings', 'period_closes', 'year_closes', 'company_profile', 'cash_forecasts', 'cash_forecast_lines',
    'bank_import_profiles']
const GST_SETTING_COLS = ['gst_registered', 'gst_registration_no']
/** 一条汇率的名字里那一段(与 trail_ref_label 的 fx_rates 那一支同一组词) */
const FX_SIDE_NAME: Record<string, string> = { tt_buy: 'TT buying rate', tt_sell: 'TT selling rate', mid: 'Mid rate' }
/** "2026-08-31" → "2026-08-01"(反结的那个月从哪一天起) */
function monthStart(v: string | null): string | null {
    return v && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 8) + '01' : null
}
function describeLedger3(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const subject = opts.subject ?? ''
    const rootId = opts.recordId ?? null
    const skipStamps = new Set(['updated_at', 'updated_by'])
    const dateText = (r: TrailRow, table: string, col: string, raw: Json | undefined) => formatValue(d, table, col, raw, imgOf(r), r.refs, r.op, opts).text

    // ── ① 锁期(Q25 · Q29 · M7)────────────────────────────────────────────────────────────
    const settings = by('finance_settings')
    const lockRow = settings.find((r) => r.op === 'UPDATE' && changed(r, 'locked_before'))
    const lockLines: Line[] = lockRow ? [{ t: 'change', label: fieldMeta(d, 'finance_settings', 'locked_before')[0],
        old: formatValue(d, 'finance_settings', 'locked_before', lockRow.old?.['locked_before'], imgOf(lockRow), lockRow.refs, 'UPDATE', opts),
        new: formatValue(d, 'finance_settings', 'locked_before', lockRow.new?.['locked_before'], imgOf(lockRow), lockRow.refs, 'UPDATE', opts) }] : []
    let lockSaid = false
    for (const r of by('period_closes')) {
        const end = str(r, 'period_end')
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'plock.monthClosed', { date: dateText(r, 'period_closes', 'period_end', end) }),
                       lines: [...lockLines, ...vlines(d, r, ['entries_count', 'total_debits', 'total_credits'], opts)],
                       reason: typed(r.new?.['notes']), key: true, weight: 100 })
            lockSaid = true
        } else if (r.op === 'UPDATE' && isSet(r, 'reopened_at')) {
            out.push({ title: tx(d, 'plock.monthReopened', { date: dateText(r, 'period_closes', 'period_end', monthStart(end)) }),
                       lines: [...lockLines], reason: typed(r.new?.['reopen_reason']), key: true, weight: 100 })
            lockSaid = true
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'plock.closeChanged'), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    // ── ② 同一行设置:锁(单独挪)· GST 注册 —— M6 已经只留下这一块的列 ──────────────────────────────────
    for (const r of settings) {
        if (r.op !== 'UPDATE') { out.push(describeGeneric(d, r, opts)); continue }
        if (changed(r, 'locked_before') && !lockSaid) {
            const was = r.old?.['locked_before'] ?? null, now = r.new?.['locked_before'] ?? null
            out.push({ title: tx(d, isEmpty(was) ? 'plock.set' : isEmpty(now) ? 'plock.removed' : 'plock.moved'), lines: [...lockLines], key: true, weight: 90 })
        }
        if (GST_SETTING_COLS.some((c) => changed(r, c))) {
            const reg = changed(r, 'gst_registered') ? r.new?.['gst_registered'] : undefined
            const key: TrailTextKey = reg === true ? 'gstset.registered' : reg === false ? 'gstset.deregistered' : 'gstset.changed'
            out.push({ title: tx(d, key), lines: changeLines(d, r, opts, new Set(['locked_before', ...skipStamps])), key: true, weight: 90 })
        }
        // 这一行别的列(没有面板管的那六列、审批方针那四列)只在汇总页上出现 —— 那里不走这个家族(Q4 · Q2);
        //   真走到这里(一个将来的主语没设 root_columns)就照实说出来,不丢
        const rest = (r.cols ?? []).filter((c) => c !== 'locked_before' && !GST_SETTING_COLS.includes(c) && !skipStamps.has(c))
        if (rest.length) out.push({ ...describeGeneric(d, { ...r, cols: rest }, opts), weight: 20 })
    }

    // ── ③ 公司资料(一块面板编辑整行;银行那五列对不持 data.view_banking 的人是 Restricted —— 遮蔽那一步给的)─────────
    for (const r of by('company_profile')) {
        if (r.op === 'INSERT') out.push({ title: tx(d, 'coprof.created'), lines: valueLines(d, r, r.new, opts, skipStamps), key: true, weight: 100 })
        else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, skipStamps)
            if (ls.length) out.push({ title: tx(d, 'coprof.changed'), lines: ls, key: false, weight: 60 })
        } else out.push(describeGeneric(d, r, opts))
    }

    // ── ④ 年结:结转分录是年结那一句的一行;反结的冲销分录同样 ──────────────────────────────────────
    for (const r of by('year_closes')) {
        const end = dateText(r, 'year_closes', 'year_end', str(r, 'year_end'))
        if (r.op === 'INSERT') {
            const ls = vlines(d, r, ['net_result'], opts)
            const j = docVal(d, r, 'year_closes', 'closing_journal_id')
            if (j) ls.push({ t: 'value', label: fieldMeta(d, 'year_closes', 'closing_journal_id')[0], value: j })
            out.push({ title: tx(d, 'yclose.closed', { date: end }), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 100 })
        } else if (r.op === 'UPDATE' && isSet(r, 'reopened_at')) {
            const j = docVal(d, r, 'year_closes', 'reversal_journal_id')
            out.push({ title: tx(d, 'yclose.reopened', { date: end }), lines: j ? [{ t: 'value', label: fieldMeta(d, 'year_closes', 'reversal_journal_id')[0], value: j }] : [],
                       reason: typed(r.new?.['reopen_reason']), key: true, weight: 100 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'yclose.changed'), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }

    // ── ⑤ 现金预测(Q16)· 常设行 ────────────────────────────────────────────────────────────
    for (const r of by('cash_forecasts')) {
        const code = str(r, 'code')
        const own = subject === 'cash_forecast' && idOf(r) === rootId
        if (r.op === 'INSERT') {
            out.push({ title: withPart(tx(d, 'fcst.frozen'), code), lines: vlines(d, r, ['week_start', 'horizon_weeks', 'base_currency'], opts),
                       key: true, weight: own ? 100 : 80 })
        } else if (r.op === 'UPDATE' && isSet(r, 'superseded_at')) {
            const v = docVal(d, r, 'cash_forecasts', 'superseded_by')
            out.push({ title: withPart(tx(d, 'fcst.superseded'), code), lines: v ? [{ t: 'value', label: tx(d, 'fcst.replacedBy'), value: v }] : [],
                       reason: typed(r.new?.['superseded_reason']), key: true, weight: own ? 95 : 70 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: withPart(tx(d, 'fcst.changed'), code), lines: ls, key: false, weight: 30 })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const r of by('cash_forecast_lines')) {
        const part = typed(str(r, 'label'))
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'fcl.added'), part, lines: vlines(d, r, ['direction', 'amount_ccy', 'cadence', 'start_date', 'end_date'], opts),
                       reason: typed(r.new?.['notes']), key: true, weight: 100 })
        } else if (r.op === 'UPDATE') {
            const off = changed(r, 'is_active') ? r.new?.['is_active'] : undefined
            const ls = changeLines(d, r, opts, new Set([...skipStamps, ...(off === undefined ? [] : ['is_active'])]))
            const key: TrailTextKey = off === false ? 'fcl.switchedOff' : off === true ? 'fcl.switchedOn' : 'fcl.changed'
            if (ls.length || off !== undefined) out.push({ title: tx(d, key), part, lines: ls, key: off !== undefined, weight: off !== undefined ? 80 : 40 })
        } else if (r.op === 'DELETE') {
            out.push({ title: tx(d, 'fcl.removed'), part, lines: [], key: true, weight: 80 })
        } else out.push(describeGeneric(d, r, opts))
    }

    // ── ⑥ 银行导入模板(删掉的也读 —— "删掉了"正是要说的事)──────────────────────────────────────────
    for (const r of by('bank_import_profiles')) {
        const part = typed(str(r, 'name'))
        if (r.op === 'INSERT') out.push({ title: tx(d, 'bip.created'), part, lines: vlines(d, r, ['bank_account_code', 'mapping'], opts), key: true, weight: 100 })
        // 删掉的那一下同时改了别的列(同一次操作里先改名再删)—— 别的列照样说(1b-3 的规矩:删除不吞掉同一笔里的改动)
        else if (r.op === 'UPDATE' && isSet(r, 'deleted_at')) out.push({ title: tx(d, 'bip.deleted'), part, lines: changeLines(d, r, opts, new Set(['deleted_at', ...skipStamps])), key: true, weight: 90 })
        else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, skipStamps)
            if (ls.length) out.push({ title: tx(d, 'bip.changed'), part, lines: ls, key: false, weight: 40 })
        } else if (r.op === 'DELETE') out.push({ title: tx(d, 'bip.deleted'), part, lines: [], key: true, weight: 90 })
        else out.push(describeGeneric(d, r, opts))
    }
    return out
}


// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1d-1:机制、设置与员工 —— 账号 · 授权 · 审批方针 · 六本字典 · 导入批次 · 员工 · 部门 · 培训记录
//   (Tim 2026-10-04,AT-1d Step 0 §a 与 Q2 · Q3 · Q9 · Q10 · Q12 · Q21 · Q22 · Q23 · Q27 · Q28 · Q29 · Q30 · Q31)
// ════════════════════════════════════════════════════════════════════════════
// 【账号(access 家族)】一个登录账号的事:建立 / 停用 / 恢复(change_log 里 table_name = 'auth.users' 的 ACCOUNT_* 行)·
//   授给它的角色(user_roles:授予是一行 INSERT,收回是给那一行盖 revoked_* 的戳 —— 从来不删)· 它作为附加账号挂在谁身上
//   (employee_accounts 与它的挂接史:同一笔、同一刻,只说一次)· 它是谁的主账号(employees.user_id —— 读法那一层已经只留下这一列,M10)。
//   同一张授权表在三页上从三边说:账号页 "Role granted: CFO";角色页 "Role granted to Sandra";员工页(账号的镜像)同账号页。
//   ★ 停用 / 恢复先写事件、auth 那一头失败再写一行 *_FAILED(两次调用,两笔事务)—— buildEntries 先把这一对并成一条,
//     这里只说 "Account could not be disabled"(Q9:那一对的意思是"没有停用",不是"停用了,然后失败了")。
// 【员工(hr 家族)】员工那一行 · 任职履历(每一行就是一件事,按 change_type 说)· 调薪申请(与它的审批并成一句)· 培训 · 部门。
//   匿名化(Q30):员工那一行的姓名、证件……被清空、履历的旧薪新薪被清空 —— 说一句 "Personal data anonymised",
//   那些被清空的值【一个都不说】(把它们说成"改成了空"是一句错话,也会把匿名化之前的名字在 old 那一侧再印一遍)。
// 【机器写进人话那一列的字】(Q10):任职履历的 notes 有三种是系统写的 —— 评审批准写的"Probation confirmed by performance review
//   <uuid>"、调薪执行写的"Salary change approved with request <label>"、员工表单自己拼的"status: a → b; department: X → Y"。
//   前两种认出来、说成英文的一行;第三种整句不说(它说的那几样,履历那一行自己的几列已经说了)。
const ACCESS_TABLES = new Set(['auth.users', 'user_roles', 'employee_accounts', 'employee_account_history'])
const HR1_TABLES = new Set(['employees', 'employment_history', 'salary_change_requests', 'training_records', 'departments'])
const DICT_TABLES = new Set(['substances', 'battery_chemistries', 'material_kinds', 'inbound_safety_states', 'laboratories', 'inbound_source_reasons',
    'nea_waste_categories', 'dangerous_goods_codes', 'label_templates',
    // MES-4a(Q5 · Q15):班次(时刻是 time 列,说成 HH:MM)· 异常事件的种类
    'shifts', 'processing_event_types',
    // MES-4b(Q3 · Q21):电芯结构 · 交叉污染流(警戒线 V11 是一个百分数)
    'cell_constructions', 'contamination_streams'])
const HR_SKIP = new Set(['updated_at', 'updated_by', 'created_at', 'created_by'])
/** 一个被引用值的名字(refs 解析出来的;人 → 名字或 Restricted) */
function refText(d: TrailDict, r: TrailRow, col: string): Val | null {
    const raw = str(r, col)
    return raw ? refVal(d, r.table!, col, raw, r.refs) : null
}
/** 员工表单写进 notes 的那一句("status: probation → active; department: X → Y")—— 一律不说 */
const APP_CHANGE_NOTE = /^(?:(?:status|department|position|employment type): [^;]* → [^;]*)(?:; (?:status|department|position|employment type): [^;]* → [^;]*)*$/
/** 任职履历 notes 里系统写的那两种 → 一行英文;人写的照原样;app 拼的那一种 → null */
function historyNote(d: TrailDict, notes: string | null): Line | null {
    if (!notes || !notes.trim()) return null
    if (/^Probation confirmed by performance review [0-9a-fA-F-]{36}$/.test(notes.trim())) return { t: 'note', text: tx(d, 'emp.noteReview') }
    // AUDIT-TRAIL-1d-3:同一支 approve_review 的另一句(评审里定的新月薪)—— 此前没有认,于是一个 uuid 当成备注印在员工页上
    if (/^Salary change approved with performance review [0-9a-fA-F-]{36}$/.test(notes.trim())) return { t: 'note', text: tx(d, 'emp.noteReviewSalary') }
    const m = notes.trim().match(/^Salary change approved with request (.+)$/)
    if (m) return { t: 'value', label: tx(d, 'emp.noteSalaryRequest'), value: { text: m[1], typed: true } }
    if (APP_CHANGE_NOTE.test(notes.trim())) return null
    return { t: 'value', label: fieldMeta(d, 'employment_history', 'notes')[0], value: truncate(notes, true) }
}
const HISTORY_TITLE: Record<string, TrailTextKey> = {
    hired: 'emp.hired', confirmed: 'emp.confirmed', promotion: 'emp.promotion', transfer: 'emp.transfer', type_change: 'emp.typeChange',
    status_change: 'emp.statusChange', separated: 'emp.separated', category_change: 'emp.categoryChange',
}
function describeAccess(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const onRole = opts.subject === 'role'
    const onAccount = opts.subject === 'account'
    // ── 账号事件(停用失败那一对已被 buildEntries 并进同一条:只说失败那一句)──
    const events = rows.filter((r) => r.table === 'auth.users')
    const failed = new Set(events.filter((r) => r.op?.endsWith('_FAILED')).map((r) => r.op!.replace(/_FAILED$/, '')))
    for (const r of events) {
        if (r.op && failed.has(r.op)) continue
        if (r.op === 'INSERT' && r.prelog) {
            const email = str(r, 'email')
            out.push({ title: tx(d, 'account.ACCOUNT_CREATE'), lines: email ? [{ t: 'value', label: fieldMeta(d, 'auth.users', 'email')[0], value: { text: email, typed: true } }] : [],
                       key: true, weight: 100 })
            continue
        }
        out.push({ ...describeGeneric(d, r, opts), weight: 100 })
    }
    // ── 授权(一行一块:授予 / 收回)──
    for (const r of rows.filter((x) => x.table === 'user_roles')) {
        const role = refText(d, r, 'role_id')?.text ?? cap(thing(d, 'roles'))
        const who = refText(d, r, 'user_id')
        const revoked = (r.op === 'UPDATE' && isSet(r, 'revoked_at')) || (r.prelog && r.op === 'UPDATE' && r.cols?.includes('revoked_at'))
        if (r.op === 'INSERT') {
            out.push({ title: onRole && who ? tx(d, 'acct.grantedTo', { who: who.text }) : tx(d, 'acct.roleGranted', { role }), lines: [], key: true, weight: 90 })
        } else if (revoked) {
            out.push({ title: onRole && who ? tx(d, 'acct.removedFrom', { who: who.text }) : tx(d, 'acct.roleRemoved', { role }), lines: [],
                       reason: typed(r.new?.['revoke_reason']), key: true, weight: 90 })
        } else if (r.op === 'DELETE') {
            out.push({ title: tx(d, 'acct.roleRemoved', { role }), lines: [], key: true, weight: 90 })
        } else {
            const ls = changeLines(d, r, opts)
            if (ls.length) out.push({ title: tx(d, 'generic.edited', { thing: thing(d, 'user_roles') }), lines: ls, key: false, weight: 30 })
        }
    }
    // ── 附加账号:挂接表与它的挂接史是同一件事的两行(同一笔)—— 有挂接表那一行就只说它 ──
    const links = rows.filter((r) => r.table === 'employee_accounts')
    for (const r of links) {
        const emp = refText(d, r, 'employee_id')
        const lines: Line[] = onAccount && emp ? [{ t: 'value', label: fieldMeta(d, 'employee_accounts', 'employee_id')[0], value: emp }] : []
        if (r.op === 'INSERT') out.push({ title: tx(d, 'acct.extraLinked'), lines, key: true, weight: 85 })
        else if (r.op === 'DELETE') out.push({ title: tx(d, 'acct.extraUnlinked'), lines, key: true, weight: 85 })
        else { const ls = changeLines(d, r, opts); if (ls.length) out.push({ title: tx(d, 'acct.extraLinked'), lines: ls, key: false, weight: 30 }) }
    }
    if (!links.length) {
        for (const r of rows.filter((x) => x.table === 'employee_account_history')) {
            const unlinked = str(r, 'action') === 'unlinked'
            out.push({ title: tx(d, unlinked ? 'acct.extraUnlinked' : 'acct.extraLinked'), lines: [], key: true, weight: 85 })
        }
    }
    // ── 主账号:员工那一行的 user_id(M10:读法只交来这一列)──
    for (const r of rows.filter((x) => x.table === 'employees')) {
        // 员工编号(不是名字 —— 名字要过 ActorName 那一道,而这一行是员工那一行自己,不经 trail_actor);一个 id 形状的值宁可不说
        const code = docCode(str(r, 'code'))
        const now = r.op === 'DELETE' ? null : (r.new?.['user_id'] ?? null)
        const linked = typeof now === 'string'
        out.push({ title: code ? tx(d, linked ? 'acct.primaryLinked' : 'acct.primaryUnlinked', { code })
                                 : tx(d, linked ? 'acct.primaryLinkedAny' : 'acct.primaryUnlinkedAny'), lines: [], key: true, weight: 85 })
    }
    return out
}
/** 几列的值,【受限的照样说 Restricted】—— vlines 走 imgOf,受限的值在那里被丢掉,于是一笔看不见的月薪会整行消失
 *  ("Salary set" 下面什么都没有,读起来像没有填数)。人事这几块的薪资列要说出"有一个数,你看不见" */
function vlinesR(d: TrailDict, r: TrailRow, cols: string[], opts: BuildOptions): Line[] {
    return cols.flatMap((c) => {
        const raw = r.new?.[c] ?? r.old?.[c] ?? r.ctx?.[c]
        if (isRestricted(raw)) return [{ t: 'value', label: fieldMeta(d, r.table!, c)[0], value: { text: tx(d, 'restricted'), restricted: true } } as Line]
        return vline(d, r, c, opts)
    })
}
function describeHr(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const anonymised = by('employees').some((r) => (r.op === 'UPDATE' && isSet(r, 'anonymised_at')) || (r.prelog && r.cols?.includes('anonymised_at')))
    // ── 员工那一行 ──
    for (const r of by('employees')) {
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'emp.added'), lines: valueLines(d, r, r.new, opts, new Set([...HR_SKIP, 'user_id', 'monthly_salary_set'])), key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        if (anonymised) {
            if (isSet(r, 'anonymised_at') || r.cols?.includes('anonymised_at')) out.push({ title: tx(d, 'emp.anonymised'), lines: [], key: true, weight: 100 })
            continue
        }
        if ((changed(r, 'deleted_at') && r.new?.['deleted_at']) || (r.prelog && r.cols?.includes('deleted_at'))) {
            out.push({ title: tx(d, 'emp.deleted'), lines: changeLines(d, r, opts, new Set(['deleted_at', ...HR_SKIP])), key: true, weight: 100 })
            continue
        }
        if (changed(r, 'user_id')) {
            out.push({ title: tx(d, r.new?.['user_id'] ? 'emp.loginLinked' : 'emp.loginUnlinked'), lines: [], key: true, weight: 90 })
        }
        const ls = changeLines(d, r, opts, new Set([...HR_SKIP, 'user_id', 'monthly_salary_set']))
        if (ls.length) out.push({ title: tx(d, 'emp.edited'), lines: ls, key: false, weight: 60 })
    }
    // ── 任职履历:每一行就是一件事 ──
    for (const r of by('employment_history')) {
        if (r.op !== 'INSERT') {
            if (anonymised) continue
            const ls = changeLines(d, r, opts, new Set(HR_SKIP))
            if (ls.length) out.push({ title: tx(d, 'emp.historyChanged'), lines: ls, key: false, weight: 30 })
            continue
        }
        const ct = str(r, 'change_type') ?? ''
        const salary = ct === 'salary_change'
        const title = salary
            ? tx(d, isEmpty(r.new?.['old_monthly_salary']) && !isRestricted(r.new?.['old_monthly_salary']) ? 'emp.salarySet' : 'emp.salaryChanged')
            : HISTORY_TITLE[ct] ? tx(d, HISTORY_TITLE[ct]) : tx(d, 'emp.historyRecorded')
        const cols = salary ? ['effective_date', 'old_monthly_salary', 'new_monthly_salary']
            : ['effective_date', 'job_title', 'department_id', 'employment_type', 'employment_status', 'work_category']
        const ls = vlinesR(d, r, cols, opts)
        const note = historyNote(d, str(r, 'notes'))
        if (note) ls.push(note)
        out.push({ title, lines: ls, key: true, weight: 95 })
    }
    // ── 调薪申请(审批留痕并进这一句)──
    for (const r of by('salary_change_requests')) {
        const id = idOf(r)
        if (r.op === 'INSERT') {
            const ls = vlinesR(d, r, ['effective_date', 'old_monthly_salary', 'new_monthly_salary'], opts)
            if (str(r, 'status', 'new') === 'approved') ls.push({ t: 'note', text: tx(d, 'po.autoApproved') })
            out.push({ title: tx(d, 'scr.requested'), lines: ls, reason: typed(r.new?.['reason']), key: true, weight: 90, recordId: id, absorbsApproval: false })
            continue
        }
        if (r.op === 'UPDATE' && (changed(r, 'status') || (r.prelog && r.cols?.includes('withdrawn_at')))) {
            const st = str(r, 'status', 'new') ?? (r.prelog ? 'withdrawn' : '')
            const key: TrailTextKey = st === 'approved' ? 'scr.approved' : st === 'rejected' ? 'scr.rejected' : st === 'withdrawn' ? 'scr.withdrawn' : 'scr.changed'
            out.push({ title: tx(d, key), lines: [], reason: typed(r.new?.['decision_notes'] ?? r.new?.['withdraw_reason']), key: true, weight: 90,
                       recordId: id, absorbsApproval: st === 'approved' || st === 'rejected' })
            continue
        }
        const ls = changeLines(d, r, opts, new Set([...HR_SKIP, 'decided_via', 'snapshot']))
        if (ls.length) out.push({ title: tx(d, 'scr.changed'), lines: ls, key: false, weight: 30, recordId: id })
    }
    // ── 培训记录 ──
    for (const r of by('training_records')) {
        const part = typed(str(r, 'training_name'))
        if (r.op === 'INSERT') out.push({ title: tx(d, 'trn.added'), part, lines: valueLines(d, r, r.new, opts, new Set([...HR_SKIP, 'training_name'])), key: true, weight: 80 })
        else if ((r.op === 'UPDATE' && isSet(r, 'deleted_at')) || (r.prelog && r.cols?.includes('deleted_at'))) out.push({ title: tx(d, 'trn.deleted'), part, lines: changeLines(d, r, opts, new Set(['deleted_at', ...HR_SKIP])), key: true, weight: 80 })
        else if (r.op === 'UPDATE') { const ls = changeLines(d, r, opts, HR_SKIP); if (ls.length) out.push({ title: tx(d, 'trn.changed'), part, lines: ls, key: false, weight: 40 }) }
        else out.push(describeGeneric(d, r, opts))
    }
    // ── 部门 ──
    for (const r of by('departments')) {
        const part = typed(str(r, 'name_en'))
        if (r.op === 'INSERT') out.push({ title: tx(d, 'dept.created'), part, lines: valueLines(d, r, r.new, opts, new Set([...HR_SKIP, 'name_en'])), key: true, weight: 80 })
        else if ((r.op === 'UPDATE' && isSet(r, 'deleted_at')) || (r.prelog && r.cols?.includes('deleted_at'))) out.push({ title: tx(d, 'dept.deleted'), part, lines: [], key: true, weight: 80 })
        else if (r.op === 'UPDATE') {
            const act = changed(r, 'is_active') ? r.new?.['is_active'] : undefined
            const ls = changeLines(d, r, opts, new Set([...HR_SKIP, ...(act === undefined ? [] : ['is_active'])]))
            if (act !== undefined) out.push({ title: tx(d, act === true ? 'dept.reactivated' : 'dept.deactivated'), part, lines: ls, key: true, weight: 70 })
            else if (ls.length) out.push({ title: tx(d, 'dept.changed'), part, lines: ls, key: false, weight: 40 })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}
const POLICY_COLS = ['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']
/** 审批方针(Q25):那一行设置的四列(M6 已经只留下它们)与它的修改史(M7)。记录开始之后,同一次保存在两张表上各一行 ——
 *  设置那一行说(它有每一列),修改史那一行不再说;之前只有修改史,它说(old_ / new_ 成对)。 */
function describePolicy(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const settings = rows.filter((r) => r.table === 'finance_settings' && r.op === 'UPDATE')
    const titleOf = (was: Json | undefined, now: Json | undefined, moved: boolean): TrailTextKey =>
        moved && now === true ? 'pol.switchedOn' : moved && now === false ? 'pol.switchedOff' : 'pol.changed'
    for (const r of settings) {
        const ls = changeLines(d, r, opts, new Set(['updated_at', 'updated_by']))
        if (!ls.length) continue
        out.push({ title: tx(d, titleOf(r.old?.['approvals_enabled'], r.new?.['approvals_enabled'], changed(r, 'approvals_enabled'))), lines: ls, key: true, weight: 100 })
    }
    if (!settings.length) {
        for (const h of rows.filter((r) => r.table === 'finance_settings_history')) {
            const ls: Line[] = []
            for (const c of POLICY_COLS) {
                const was = h.new?.['old_' + c], now = h.new?.['new_' + c]
                if (JSON.stringify(was ?? null) === JSON.stringify(now ?? null)) continue
                ls.push({ t: 'change', label: fieldMeta(d, 'finance_settings', c)[0],
                          old: formatValue(d, 'finance_settings_history', 'old_' + c, was, imgOf(h), h.refs, 'INSERT', opts),
                          new: formatValue(d, 'finance_settings_history', 'new_' + c, now, imgOf(h), h.refs, 'INSERT', opts) })
            }
            const moved = JSON.stringify(h.new?.['old_approvals_enabled'] ?? null) !== JSON.stringify(h.new?.['new_approvals_enabled'] ?? null)
            out.push({ title: tx(d, titleOf(h.new?.['old_approvals_enabled'], h.new?.['new_approvals_enabled'], moved)), lines: ls, key: true, weight: 100 })
        }
    }
    for (const r of rows.filter((x) => x.table === 'finance_settings' && x.op !== 'UPDATE')) out.push(describeGeneric(d, r, opts))
    return out
}
/** 六本字典(M11):一个值加上 / 改了 / 停用 / 恢复 —— 字典不删(没有删除策略) */
function describeDict(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    for (const r of rows) {
        const t = thing(d, r.table)
        const part = typed(str(r, 'name_en'))
        if (r.op === 'INSERT') out.push({ title: tx(d, 'dictv.added', { thing: t }), part, lines: valueLines(d, r, r.new, opts, new Set(['name_en'])), key: true, weight: 80 })
        else if (r.op === 'UPDATE') {
            const act = changed(r, 'is_active') ? r.new?.['is_active'] : undefined
            const ls = changeLines(d, r, opts, new Set(act === undefined ? [] : ['is_active']))
            if (act !== undefined) out.push({ title: tx(d, act === true ? 'dictv.reactivated' : 'dictv.deactivated', { thing: t }), part, lines: ls, key: true, weight: 70 })
            else if (ls.length) out.push({ title: tx(d, 'dictv.changed', { thing: t }), part, lines: ls, key: false, weight: 40 })
        } else if (r.op === 'DELETE') {
            // AUDIT-TRAIL-1d-2:公共假期是【硬删】的 —— 那一行最后的样子(日期、名字)就是这件事的内容
            out.push({ title: tx(d, 'generic.deleted', { thing: t }), part, lines: valueLines(d, r, r.old, opts, new Set(['name_en'])), key: true, weight: 80 })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}
/** 导入批次(F97):"N supplier records imported from a file"—— 文件名是人起的名字 */
function describeImport(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    return rows.map((r) => {
        if (r.op !== 'INSERT') return describeGeneric(d, r, opts)
        const n = num(r.new?.['row_count'] ?? null) ?? 0
        const target = str(r, 'target_table')
        const what = target ? (d.tables[target]?.[0] ?? humanize(target).toLowerCase()) : 'record'
        return { title: tx(d, n === 1 ? 'imp.imported.one' : 'imp.imported.many', { n, thing: what }), part: typed(str(r, 'file_name')),
                 lines: vlines(d, r, ['code_first', 'code_last'], opts), key: true, weight: 90 }
    })
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1d-2:请假与考勤 —— 请假 · 假期发放 · 医疗报销 · 加班 · 考勤(假别与公共假期走字典那一家:M11 集合)
//   (Tim 2026-10-04,AT-1d Step 0 §a 与 Q10 · Q12 · Q14 · Q15 · Q20 · Q27 · Q35 · Q37)
// ════════════════════════════════════════════════════════════════════════════
// 【一个决定,几行】批准一张请假在同一笔里写:请假那一行(状态 + 决定的戳)· 审批留痕 · 每一笔扣减(leave_consumption 'draw')。
//   界面只说一句 "Leave approved",扣了几天是它下面一行;取消同形("Leave cancelled",还回去几天是一行)。
//   记录开始之前,决定那一对戳与审批留痕、扣减【同一刻】写下,于是归成同一条 —— 照样只说一次。
// 【按状态说】(Q12)取消【改写】决定那一对戳(cancel_leave_request),所以那一对戳在记录开始之前的意思由【今天的状态】说:
//   approved / rejected 是那一次决定;cancelled 是那一次取消(线上两次本人取消只剩它)。之前那一段里,那一行的 decision_notes
//   是今天的值 —— 取消没给理由时它仍是批准人的话 —— 所以取消那一句把它照字段名说("Decision notes: …"),不冒充取消的理由。
// 【加班】送审 / 批准 / 退回各写一行审批留痕,与批次那一行同一笔 —— 并成一句;退回照页面的话说 "Overtime sent back"(Q35)。
//   审批关着时决定那一格被追加一截系统写的中文(decide_overtime_batch)—— 剥掉,只留那个人的话(Q10)。
//   送审与批准都会把每一行的 day_kind 重盖一遍(同一笔、整批)—— 那是副作用,不说;冲销 / 丢弃把每一行作废,同上。
// 【考勤】完成那一下:补齐缺的行 + 两次整批改动(冻结、加班三档)+ 那一个月的状态 —— 一句 "Attendance period completed",
//   人数是一行;每一行的派生值不逐行说。记录开始之前只剩【最近】那一次完成与重开(重开清掉完成、覆盖上一次重开),照直说。
// 【审批并进哪一块】只有【决定 / 取消 / 状态】那几块带 recordId —— 申请、提交、开批那一块不带:同一次操作里既提交又决定时
//   (线上回滚的证明正是这样),审批留痕并进决定那一句,而不是挂在申请下面再说一遍。
// 【医疗报销】付款建的费用单是另一张单据:报销单这一边说 "Expense raised to pay the claim" 并链到它;费用页上(Q37)
//   报销单那几行从报销单这一边说。撤回【没有记人】—— 之前那一段说 "Not recorded",不拿 updated_by 猜。
const TIME_TABLES = new Set(['leave_requests', 'leave_consumption', 'leave_grants', 'medical_claims', 'overtime_batches', 'overtime_lines',
    'attendance_periods', 'attendance_lines'])
const TIME_APPROVALS = new Set(['leave_request', 'medical_claim', 'overtime_batch'])
/** 审批关着时 decide_overtime_batch 在那个人的话后面追加的一截中文(concat_ws(' · ', 人的话, '审批流未启用…'))—— 剥掉(Q10) */
export function stripOvertimeMachineNote(note: string | null): string | null {
    if (!note) return null
    const s = note.replace(/(?:^|\s*·\s*)审批流未启用[\s\S]*$/, '').trim()
    return s || null
}
function daysText(d: TrailDict, n: number | null): string {
    return n === null ? '' : n === 1 ? tx(d, 'lv.days.one') : tx(d, 'lv.days.many', { n: NUM4.format(n) })
}
function sumDays(rows: TrailRow[], entry: 'draw' | 'release'): number | null {
    const rs = rows.filter((r) => r.table === 'leave_consumption' && r.op === 'INSERT' && str(r, 'entry_type') === entry)
    return rs.length ? rs.reduce((n, r) => n + (num(r.new?.['days'] ?? null) ?? 0), 0) : null
}
function describeTime(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const sub = opts.subject ?? ''
    const by = (t: string) => rows.filter((r) => r.table === t)
    const skip = new Set(['updated_at', 'updated_by', 'created_at', 'created_by'])
    // 一张单据在它自己那一页(与 /me 本人那一行)上不再报单号;在别处(费用页、汇总页)报
    const codePart = (r: TrailRow, own: string[]) => (own.includes(sub) ? null : docCode(str(r, 'code') ?? str(r, 'label')))

    // ── 请假 ──
    const taken = sumDays(rows, 'draw'), returned = sumDays(rows, 'release')
    for (const r of by('leave_requests')) {
        const id = idOf(r)
        const code = codePart(r, ['leave_request', 'my_leave_request'])
        if (r.op === 'INSERT') {
            const type = refText(d, r, 'leave_type_code')?.text ?? cap(fieldMeta(d, 'leave_requests', 'leave_type_code')[0]).toLowerCase()
            const ls = vlines(d, r, ['start_date', 'end_date'], opts)
            for (const c of ['start_half_day', 'end_half_day']) if (r.new?.[c] === true) ls.push(...vline(d, r, c, opts))
            ls.push(...vlines(d, r, ['certificate_ref'], opts))
            if (r.new?.['is_exception'] === true) {
                ls.push({ t: 'note', text: tx(d, 'lv.exception') })
                ls.push(...vlines(d, r, ['exception_reason'], opts))
            }
            // U1-A(UNBLOCK-1 Q8):请假事由对不持 data.view_health 的读者是受限标记 —— typed() 会把它当成"没写",于是那一行理由消失;
            //   受限就说受限
            out.push({ title: withPart(tx(d, 'lv.requested', { days: daysText(d, num(r.new?.['days'] ?? null)), type }), code), lines: ls,
                       reason: isRestricted(r.new?.['reason']) ? { text: tx(d, 'restricted'), restricted: true } : typed(r.new?.['reason']),
                       key: true, weight: 100 })
            continue
        }
        const decided = changed(r, 'status') || (r.prelog && (r.cols ?? []).includes('decided_at'))
        const st = decided ? str(r, 'status', 'new') : null
        if (st === 'approved' || st === 'rejected') {
            const ls: Line[] = st === 'approved' && taken !== null ? [{ t: 'value', label: tx(d, 'lv.daysTaken'), value: { text: daysText(d, taken) } }] : []
            out.push({ title: withPart(tx(d, st === 'approved' ? 'lv.approved' : 'lv.rejected'), code), lines: ls,
                       reason: typed(r.new?.['decision_notes']), key: true, weight: 100, recordId: id, absorbsApproval: true })
            continue
        }
        if (st === 'cancelled') {
            const ls: Line[] = returned !== null ? [{ t: 'value', label: tx(d, 'lv.daysReturned'), value: { text: daysText(d, returned) } }] : []
            // 之前那一段:decision_notes 是今天的值(可能是批准人的话)—— 照字段名说,不冒充取消的理由;之后:只在这一次改了它时才是理由
            if (r.prelog) ls.push(...vlines(d, r, ['decision_notes'], opts))
            out.push({ title: withPart(tx(d, 'lv.cancelled'), code), lines: ls,
                       reason: !r.prelog && changed(r, 'decision_notes') ? typed(r.new?.['decision_notes']) : null, key: true, weight: 100, recordId: id, absorbsApproval: true })
            continue
        }
        const ls = changeLines(d, r, opts, skip)
        if (ls.length) out.push({ title: withPart(tx(d, 'lv.changed'), code), lines: ls, key: false, weight: 40, recordId: id })
    }
    // 扣减 / 归还:在决定 / 取消那一句里说了;单独出现(不该发生)才各自成句
    // (记录开始之前一张后来被取消的请假:那一次批准只剩审批留痕 —— 扣减那几行与它同一刻,由审批那一句说)
    const lvApproval = by('approval_log').some((a) => str(a, 'subject_type') === 'leave_request' && a.op === 'INSERT')
    const lvDecided = lvApproval || out.some((b) => b.recordId && by('leave_requests').some((r) => idOf(r) === b.recordId && r.op !== 'INSERT'))
    for (const r of by('leave_consumption')) {
        if (r.op === 'INSERT' && lvDecided) continue
        if (r.op !== 'INSERT') { out.push(describeGeneric(d, r, opts)); continue }
        const draw = str(r, 'entry_type') === 'draw'
        out.push({ title: tx(d, draw ? 'lv.daysTaken' : 'lv.daysReturned'), lines: vlines(d, r, ['days', 'leave_grant_id', 'accrual_year', 'notes'], opts), key: false, weight: 30 })
    }

    // ── 假期发放(一次结转是一条:N 个人一句)──
    const grants = by('leave_grants')
    const carried = grants.filter((r) => r.op === 'INSERT' && str(r, 'grant_type') === 'carry_forward')
    if (carried.length > 1) {
        out.push({ title: tx(d, 'lgr.carriedMany', { n: carried.length }), key: true, weight: 90,
                   lines: carried.map((r) => ({ t: 'value', label: refText(d, r, 'employee_id')?.text ?? cap(fieldMeta(d, 'leave_grants', 'employee_id')[0]),
                                                value: { text: daysText(d, num(r.new?.['days'] ?? null)) } }) as Line) })
    }
    for (const r of grants) {
        if (carried.length > 1 && carried.includes(r)) continue
        if (r.op === 'INSERT') {
            const one = str(r, 'grant_type') === 'carry_forward'
            out.push({ title: tx(d, one ? 'lgr.carried' : 'lgr.granted', { days: daysText(d, num(r.new?.['days'] ?? null)) }),
                       lines: vlines(d, r, ['employee_id', 'leave_type_code', 'leave_year', 'grant_type', 'expires_on'], opts), reason: typed(r.new?.['notes']), key: true, weight: 90 })
        } else if (r.op === 'DELETE' || isSet(r, 'deleted_at')) {
            out.push({ title: tx(d, 'lgr.removed'), lines: r.op === 'DELETE' ? vlines(d, r, ['employee_id', 'days'], opts) : [], key: true, weight: 90 })
        } else {
            const ls = changeLines(d, r, opts, skip)
            if (ls.length) out.push({ title: tx(d, 'lgr.changed'), lines: ls, key: false, weight: 40 })
        }
    }

    // ── 医疗报销 ──
    for (const r of by('medical_claims')) {
        const id = idOf(r)
        const code = codePart(r, ['medical_claim', 'my_medical_claim'])
        if (r.op === 'INSERT') {
            const amt = formatValue(d, 'medical_claims', 'amount_sgd', r.new?.['amount_sgd'], imgOf(r), r.refs, 'INSERT', opts)
            out.push({ title: withPart(tx(d, 'mc.submitted', { amount: amt.text }), code), lines: vlines(d, r, ['employee_id', 'claim_date', 'description', 'receipt_ref'], opts),
                       key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        const st = changed(r, 'status') ? str(r, 'status', 'new') : null
        if (st === 'approved' || st === 'rejected') {
            // U1-B:批准 / 驳回的理由是健康的字(data.view_health,或本人)—— 受限就说受限
            out.push({ title: withPart(tx(d, st === 'approved' ? 'mc.approved' : 'mc.rejected'), code), lines: [], reason: typedOrRestricted(d, r.new?.['decision_notes']),
                       key: true, weight: 100, recordId: id, absorbsApproval: true })
            continue
        }
        if (st === 'withdrawn' || isSet(r, 'withdrawn_at')) {
            out.push({ title: withPart(tx(d, 'mc.withdrawn'), code), lines: [], key: true, weight: 100, recordId: id })
            continue
        }
        if (changed(r, 'expense_id') && str(r, 'expense_id', 'new')) {
            const v = docVal(d, r, 'medical_claims', 'expense_id')
            out.push({ title: withPart(tx(d, 'mc.expenseRaised'), code), lines: v ? [{ t: 'value', label: fieldMeta(d, 'medical_claims', 'expense_id')[0], value: v }] : [],
                       key: true, weight: 95, recordId: id })
            continue
        }
        const ls = changeLines(d, r, opts, skip)
        if (ls.length) out.push({ title: withPart(tx(d, 'mc.changed'), code), lines: ls, key: false, weight: 40, recordId: id })
    }

    // ── 加班 ──
    const batchMoved = by('overtime_batches').some((r) => changed(r, 'status') || (r.prelog && r.op === 'UPDATE'))
    for (const r of by('overtime_batches')) {
        const id = idOf(r)
        const code = codePart(r, ['overtime_batch'])
        if (r.op === 'INSERT') {
            out.push({ title: withPart(tx(d, 'ot.started'), code), lines: vlines(d, r, ['period_month'], opts), key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        const moved = changed(r, 'status') || (r.prelog && ((r.cols ?? []).includes('reversed_at') || (r.cols ?? []).includes('discarded_at')))
        const st = moved ? str(r, 'status', 'new') : null
        if (st) {
            const from = str(r, 'status', 'old')
            let title: string
            let reason: Val | null = null
            let lines: Line[] = []
            switch (st) {
                case 'submitted': {
                    const hrs = by('overtime_lines').filter((l) => !imgOf(l)['voided_at']).reduce((n, l) => n + (num(imgOf(l)['hours'] ?? null) ?? 0), 0)
                    title = hrs > 0 ? tx(d, 'ot.submittedHours', { hours: NUM4.format(hrs) }) : tx(d, 'ot.submitted'); break
                }
                case 'draft': title = tx(d, from === 'submitted' ? 'ot.withdrawn' : 'ot.changed'); break
                case 'approved': title = tx(d, 'ot.approved'); reason = typed(stripOvertimeMachineNote(str(r, 'decision_notes', 'new'))); break
                case 'rejected': title = tx(d, 'ot.sentBack'); reason = typed(stripOvertimeMachineNote(str(r, 'decision_notes', 'new'))); break
                case 'reversed': title = tx(d, 'ot.reversed'); reason = typed(r.new?.['reverse_reason']); break
                case 'discarded': title = tx(d, 'ot.discarded'); break
                default: title = tx(d, 'ot.changed'); lines = changeLines(d, r, opts, skip)
            }
            out.push({ title: withPart(title, code), lines, reason, key: true, weight: 100, recordId: id, absorbsApproval: st === 'submitted' || st === 'approved' || st === 'rejected' })
            continue
        }
        const ls = changeLines(d, r, opts, skip)
        if (ls.length) out.push({ title: withPart(tx(d, 'ot.changed'), code), lines: ls, key: false, weight: 40, recordId: id })
    }
    for (const r of by('overtime_lines')) {
        // 送审 / 批准重盖 day_kind、冲销 / 丢弃作废每一行(包括之前那一段的作废戳)—— 那是批次那一步的副作用
        if (r.op === 'UPDATE' && (batchMoved || r.prelog) && (r.cols ?? []).every((c) => c === 'day_kind' || c === 'voided_at')) continue
        const emp = refText(d, r, 'employee_id')
        const ls = r.op === 'UPDATE' ? changeLines(d, r, opts, skip) : vlines(d, r, ['work_date', 'day_kind', 'hours', 'note'], opts)
        if (r.op === 'UPDATE' && !ls.length) continue
        out.push({ title: tx(d, r.op === 'INSERT' ? 'ot.lineAdded' : r.op === 'DELETE' ? 'ot.lineRemoved' : 'ot.lineChanged'), part: emp && !emp.restricted ? emp : null,
                   lines: emp?.restricted ? [{ t: 'value', label: fieldMeta(d, 'overtime_lines', 'employee_id')[0], value: emp }, ...ls] : ls, key: r.op !== 'UPDATE', weight: 60 })
    }
    // 审批留痕:送审 / 批准 / 退回(批次那一句里已经说了的,由 foldApprovals 吸收;只有它自己时 —— 记录开始之前 —— 照页面的话说)
    for (const a of by('approval_log')) {
        if (a.op !== 'INSERT') { out.push(describeGeneric(d, a, opts)); continue }
        const stype = str(a, 'subject_type') ?? ''
        const decision = str(a, 'decision', 'new') ?? ''
        const own = (stype === 'leave_request' && (sub === 'leave_request' || sub === 'my_leave_request'))
            || (stype === 'medical_claim' && (sub === 'medical_claim' || sub === 'my_medical_claim')) || (stype === 'overtime_batch' && sub === 'overtime_batch')
        const code = own ? null : docCode(str(a, 'subject_code'))
        const key: TrailTextKey | null = stype === 'leave_request' ? (decision === 'approved' || decision === 'auto_approved' ? 'lv.approved' : decision === 'rejected' ? 'lv.rejected' : null)
            : stype === 'medical_claim' ? (decision === 'approved' || decision === 'auto_approved' ? 'mc.approved' : decision === 'rejected' ? 'mc.rejected' : null)
            : (decision === 'submitted' ? 'ot.submitted' : decision === 'approved' || decision === 'auto_approved' ? 'ot.approved' : decision === 'rejected' ? 'ot.sentBack' : null)
        const note = stype === 'overtime_batch' ? stripOvertimeMachineNote(str(a, 'note', 'new')) : str(a, 'note', 'new')
        if (!key) { out.push(...describeApproval(d, [a])); continue }
        const lvLines: Line[] = key === 'lv.approved' && taken !== null && !by('leave_requests').some((r) => r.op !== 'INSERT')
            ? [{ t: 'value', label: tx(d, 'lv.daysTaken'), value: { text: daysText(d, taken) } }] : []
        out.push({ title: withPart(tx(d, key), code), lines: [...lvLines, ...(decision === 'auto_approved' ? [{ t: 'note', text: tx(d, 'po.autoApproved') } as Line] : [])],
                   reason: decision === 'auto_approved' ? null : typed(note), key: true, weight: 90, approvalFor: str(a, 'subject_id') ?? undefined })
    }

    // ── 考勤 ──
    const periods = by('attendance_periods')
    const lines = by('attendance_lines')
    const opened = periods.some((r) => r.op === 'INSERT')
    const completed = periods.some((r) => (changed(r, 'status') && str(r, 'status', 'new') === 'complete') || (r.prelog && (r.cols ?? []).includes('completed_at')))
    for (const r of periods) {
        const code = codePart(r, ['attendance_period'])
        const prelogNote: Line[] = r.prelog ? [{ t: 'note', text: tx(d, 'attp.latestOnly') }] : []
        if (r.op === 'INSERT') {
            const n = lines.filter((l) => l.op === 'INSERT').length
            out.push({ title: withPart(tx(d, 'attp.opened'), code), key: true, weight: 100,
                       lines: [...vlines(d, r, ['period_month'], opts), ...(n ? [{ t: 'value', label: tx(d, 'attp.people'), value: { text: NUM4.format(n) } } as Line] : [])] })
        } else if ((changed(r, 'status') && str(r, 'status', 'new') === 'complete') || (r.prelog && (r.cols ?? []).includes('completed_at'))) {
            const n = new Set(lines.map((l) => JSON.stringify(l.key))).size
            out.push({ title: withPart(tx(d, 'attp.completed'), code), key: true, weight: 100,
                       lines: [...(n ? [{ t: 'value', label: tx(d, 'attp.people'), value: { text: NUM4.format(n) } } as Line] : []), ...prelogNote] })
        } else if (isSet(r, 'reopened_at') || (changed(r, 'status') && str(r, 'status', 'new') === 'open') || (r.prelog && (r.cols ?? []).includes('reopened_at'))) {
            out.push({ title: withPart(tx(d, 'attp.reopened'), code), lines: prelogNote, reason: typed(r.new?.['reopen_reason']), key: true, weight: 100 })
        } else if (r.op === 'DELETE') out.push(describeGeneric(d, r, opts))
        else { const ls = changeLines(d, r, opts, skip); if (ls.length) out.push({ title: withPart(tx(d, 'attp.changed'), code), lines: ls, key: false, weight: 40 }) }
    }
    const recorded: TrailRow[] = [], joined: TrailRow[] = [], frozen: TrailRow[] = []
    for (const r of lines) {
        if (r.op === 'INSERT') { if (!opened && !completed) joined.push(r); continue }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        // 完成那一下整批冻住的那几列(派生值)—— 不逐行说
        if (completed && !(r.cols ?? []).some((c) => c === 'note' || c === 'recorded_at')) continue
        if (r.prelog && (r.cols ?? []).includes('frozen_at')) { frozen.push(r); continue }
        if (isSet(r, 'recorded_at') || changed(r, 'note') || (r.prelog && (r.cols ?? []).includes('recorded_at'))) recorded.push(r)
        else { const ls = changeLines(d, r, opts, skip); if (ls.length) out.push({ title: tx(d, 'attp.recorded'), lines: ls, key: false, weight: 40 }) }
    }
    for (const r of recorded) {
        const emp = refText(d, r, 'employee_id')
        out.push({ title: tx(d, 'attp.recorded'), part: emp && !emp.restricted ? emp : null, key: true, weight: 70,
                   lines: [...(emp?.restricted ? [{ t: 'value', label: fieldMeta(d, 'attendance_lines', 'employee_id')[0], value: emp } as Line] : []),
                           ...vlines(d, r, ['note'], opts)] })
    }
    if (joined.length) {
        out.push({ title: tx(d, 'attp.joinersAdded'), key: true, weight: 80,
                   lines: joined.map((r) => ({ t: 'value', label: fieldMeta(d, 'attendance_lines', 'employee_id')[0], value: refText(d, r, 'employee_id') ?? { text: tx(d, 'empty'), empty: true } }) as Line) })
    }
    if (frozen.length && !completed) {
        out.push({ title: tx(d, 'attp.frozen'), key: true, weight: 70, lines: [{ t: 'value', label: tx(d, 'attp.people'), value: { text: NUM4.format(frozen.length) } }] })
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1d-3:工资与评审 —— 工资期 · 评审(HR 那一页与审核人那一页)· 评审轮次 · KPI 条目(评分刻度走字典那一家:M11 集合)
//   (Tim 2026-10-04,AT-1d Step 0 §a 与 Q5 · Q6 · Q7 · Q10 · Q11 · Q12 · Q27)
// ════════════════════════════════════════════════════════════════════════════
// 【工资行按员工配对】(Q11)upsert_payroll_period 每次保存都把这一期的工资行【全删、重插】(新的 id)。于是同一次操作里,
//   同一个员工的一删一插是【同一行】:没变的一对什么都不说;变了的一对是一行 "Line · <name> · Gross pay: a → b"(每变一列一行)。
//   只删不插 = 这个人不在了("Line removed · <name>");只插不删 = 新来的("Line added · <name>")。
//   ★ 读者看不见金额(不持 data.view_pay —— 遮蔽规则把那五列说成 Restricted)时,一对"变没变"本身就是工资数据:
//     那一次保存只说一行 "Pay lines · N people: Restricted"(Q4:看得见它在,看不见内容),不逐人猜。
// 【机器写进人话那一格的字】(Q10)① 撤销过账在工资期的 notes 末尾追加一行 "[YYYY-MM-DD HH:MI unposted] 理由" —— 那是
//   "Payroll unposted" 这件事本身,理由是那一行的后半截;从来不说成 "Notes changed",那一截时间戳也不上屏。
//   ② 批 / 驳工资申请时,审批留痕的说明后面追加一行中英两段的 "本期含审批人自己的工资行 · this period includes the approver's
//   own pay line: EMP-…" —— 剥掉,换成一行英文说明。③ 申请的 label("PAY-2026-0001 · post #1")里那一截原样的种类不上屏:
//   标题已经说了它是过账还是撤销。④ 审批关着时自动批的那一句中文说明 —— "Approved automatically"(与采购单同一句)。
// 【分录说它是哪一笔】过账 · 发薪 · CPF · 代扣款 · 撤销的冲销 —— 按【结构】认(工资期那几列指着谁、工资行的 paid_journal_entry_id、
//   申请的 result_journal_entry_id、整页的冲销关系),不读 memo。与那一步同一笔的分录并进那一句;只有分录自己时(记录开始之前)
//   照它的身份说同一句。认不出的照 1c-3 的说法 "Payroll journal posted"。
// 【评审的结论按评审自己的几列说】(Q7)批准在同一笔里还改了员工那一行与任职履历(转正、调薪)——它们没有指回评审的键,不挂进来;
//   "Review approved" 下面一行一行说出评审自己记着的结论:评级 · 试用期结论 · 新月薪(遮蔽照今天:不持 view_pay 的人是 Restricted)·
//   生效日。记录开始之前只剩审批留痕那一行 —— 结论从整页那一份评审今天的样子读(审批之后这几列冻住,guard_performance_review_write)。
// 【轮次】(Q6)开轮在同一笔里给每个人铺一份评审 —— 那几份评审不挂在轮次上(没有成员),轮次那一块只说 "Review cycle opened";
//   每一份评审自己的那一段以 "Annual review opened (cycle <名字>)" 开头。
// 【页面的话】(Q35)"Open self-assessment" / "Reopen self-assessment" / "Finalised" —— 评审页上那几个按钮与标记的说法。
const PAY_TABLES = new Set(['payroll_periods', 'payroll_lines', 'payroll_requests'])
const REVIEW_TABLES = new Set(['performance_reviews', 'review_goals', 'review_cycles'])
const PAY_MONEY = ['gross_pay', 'employer_cpf', 'employee_cpf', 'other_deductions', 'net_pay']
/** 整页的工资与评审上下文(与认冲销分录同一个做法:看整页,不只看这一条) */
export type HrCtx = {
    /** 分录 id → 它是工资期的哪一笔 */
    journalRole: Map<string, 'post' | 'salary' | 'cpf' | 'deductions' | 'reversal'>
    /** 发薪分录 id → 它付了几行 */
    salaryLines: Map<string, number>
    /** 工资申请 id → post / reversal */
    requestKind: Map<string, string>
    /** 评审 id → 它今天的样子(遮蔽之后;受限的值保留成 Restricted)与那一份的引用(评级的名字、人)*/
    reviewImg: Map<string, { ctx: Img; refs: Refs | null }>
}
export function hrContext(rows: TrailRow[], reversals: Set<string>): HrCtx {
    const c: HrCtx = { journalRole: new Map(), salaryLines: new Map(), requestKind: new Map(), reviewImg: new Map() }
    const paid = new Map<string, Set<string>>()
    for (const r of rows) {
        if (r.hidden) continue
        if (r.table === 'payroll_periods') {
            for (const [col, role] of [['journal_entry_id', 'post'], ['cpf_journal_entry_id', 'cpf'], ['deductions_journal_entry_id', 'deductions']] as const) {
                for (const v of [r.ctx?.[col], r.old?.[col], r.new?.[col]]) if (typeof v === 'string') c.journalRole.set(v, role)
            }
        } else if (r.table === 'payroll_lines') {
            for (const v of [r.ctx?.['paid_journal_entry_id'], r.new?.['paid_journal_entry_id']]) {
                if (typeof v !== 'string') continue
                c.journalRole.set(v, 'salary')
                paid.set(v, (paid.get(v) ?? new Set()).add(JSON.stringify(r.key)))
            }
        } else if (r.table === 'payroll_requests') {
            const id = idOf(r), kind = str(r, 'kind')
            if (id && kind) c.requestKind.set(id, kind)
            const j = imgOf(r)['result_journal_entry_id']
            if (typeof j === 'string' && kind) c.journalRole.set(j, kind === 'reversal' ? 'reversal' : 'post')
        } else if (r.table === 'performance_reviews') {
            const id = idOf(r)
            if (id && r.ctx && !c.reviewImg.has(id)) c.reviewImg.set(id, { ctx: r.ctx, refs: r.refs })
        }
    }
    for (const id of reversals) c.journalRole.set(id, 'reversal')
    for (const [j, s] of paid) c.salaryLines.set(j, s.size)
    return c
}
/** decide_payroll_request 在审批留痕的说明后面追加的那一行(中英两段)→ 人写的话 + 那一行点名的员工编号(Q10) */
export function splitPayrollDecisionNote(note: string | null): { text: string | null; ownLine: string | null } {
    if (!note) return { text: null, ownLine: null }
    const m = note.match(/(?:^|\n)本期含审批人自己的工资行 · this period includes the approver's own pay line: (\S+)\s*$/)
    if (!m) return { text: note.trim() || null, ownLine: null }
    const text = note.slice(0, m.index).trim()
    return { text: text || null, ownLine: m[1] }
}
/** unpost_payroll_period_internal 追加在工资期 notes 末尾的 "[YYYY-MM-DD HH:MI unposted] 理由" → 人写的备注 + 最后那一次的理由(Q10) */
export function splitPayrollUnpostNote(notes: string | null): { notes: string | null; reason: string | null; unposts: number } {
    if (!notes) return { notes: null, reason: null, unposts: 0 }
    const re = /(?:^|\n)\[\d{4}-\d{2}-\d{2} \d{2}:\d{2} unposted\] ([^\n]*)/g
    const reasons = [...notes.matchAll(re)].map((m) => m[1].trim())
    const rest = notes.replace(re, '').trim()
    return { notes: rest || null, reason: reasons.length ? reasons[reasons.length - 1] || null : null, unposts: reasons.length }
}
/** 申请的 label "PAY-2026-0001 · post #1" → 期间编号(那一截原样的种类不上屏)与种类 */
function payrollLabel(label: string | null): { code: string | null; kind: string | null } {
    if (!label) return { code: null, kind: null }
    const m = label.match(/^(.+?) · (post|reversal) #\d+$/)
    const code = m ? m[1] : label.split(' · ')[0]
    return { code: DOC_CODE.test(code) ? code : null, kind: m ? m[2] : null }
}
const PAYROLL_REQUEST_TEXT = {
    post: { sent: 'prl.sentPost', approved: 'prl.approvedPost', rejected: 'prl.rejectedPost', withdrawn: 'prl.withdrawnPost' },
    reversal: { sent: 'prl.sentUnpost', approved: 'prl.approvedUnpost', rejected: 'prl.rejectedUnpost', withdrawn: 'prl.withdrawnUnpost' },
} as const
function prlKey(kind: string | null, what: 'sent' | 'approved' | 'rejected' | 'withdrawn'): TrailTextKey {
    return PAYROLL_REQUEST_TEXT[kind === 'reversal' ? 'reversal' : 'post'][what]
}
function describePay(d: TrailDict, rows: TrailRow[], opts: BuildOptions, hc: HrCtx): Block2[] {
    const out: Block2[] = []
    const onPage = opts.subject === 'payroll_period'
    const by = (t: string) => rows.filter((r) => r.table === t)
    const skip = new Set(['updated_at', 'updated_by', 'created_at', 'created_by'])
    const people = (n: number) => tx(d, n === 1 ? 'prl.people.one' : 'prl.people.many', { n })
    const periods = by('payroll_periods'), lines = by('payroll_lines'), jes = by('journal_entries')
    const statusTo = (r: TrailRow) => (changed(r, 'status') ? str(r, 'status', 'new') : null)
    const created = periods.find((r) => r.op === 'INSERT')
    const postRow = periods.find((r) => statusTo(r) === 'posted')
    const unpostRow = periods.find((r) => statusTo(r) === 'draft' && str(r, 'status', 'old') === 'posted')
    const cpfRow = periods.find((r) => r.op === 'UPDATE' && isSet(r, 'cpf_paid_at'))
    const dedRow = periods.find((r) => r.op === 'UPDATE' && isSet(r, 'deductions_paid_at'))
    // 这一期的编号:在它自己那一页上不再报;在别处(汇总页、分录页)报
    const codeOf = (r: TrailRow | undefined) => (onPage || !r ? null : docCode(str(r, 'code')))
    const jeLine = (key: TrailTextKey, v: Val | null): Line[] => (v ? [{ t: 'value', label: tx(d, key), value: v }] : [])
    // 分录号只在读者看得见那一张分录时才说(工资期页自己的规矩:没有财务权限的人在页头读到的是 Restricted)——
    //   同一笔里那一张分录不在可见的行里 = 它被藏了
    const restrictedVal: Val = { text: tx(d, 'restricted'), restricted: true }
    const seen = (v: Val | null, jid: Json | undefined): Val | null => (v && typeof jid === 'string' && !jes.some((j) => idOf(j) === jid) ? restrictedVal : v)
    const jeSelf = (r: TrailRow): Val | null => { const c = str(r, 'code'); return c ? { text: c } : null }
    const jeOf = (role: string) => jes.find((j) => j.op === 'INSERT' && hc.journalRole.get(idOf(j) ?? '') === role)

    // ── 工资行:一次操作里按员工配对(Q11)──
    const del = new Map<string, TrailRow>(), ins = new Map<string, TrailRow>()
    const lineUpdates: TrailRow[] = []
    for (const r of lines) {
        const emp = str(r, 'employee_id')
        if (r.op === 'DELETE' && emp) del.set(emp, r)
        else if (r.op === 'INSERT' && emp) ins.set(emp, r)
        else if (r.op === 'UPDATE') lineUpdates.push(r)
    }
    const lineLines: Line[] = []
    let hiddenPairs = 0
    const nameOf = (r: TrailRow) => refText(d, r, 'employee_id')?.text ?? cap(thing(d, 'payroll_lines'))
    const money = (r: TrailRow, img: Img | null, c: string) => formatValue(d, 'payroll_lines', c, img?.[c], imgOf(r), r.refs, r.op, opts)
    for (const [emp, after] of ins) {
        const before = del.get(emp)
        if (!before) continue
        const restricted = PAY_MONEY.some((c) => isRestricted(before.old?.[c]) || isRestricted(after.new?.[c]))
        const cols = restricted ? ['notes'] : [...PAY_MONEY, 'notes']
        for (const c of cols) {
            if (JSON.stringify(before.old?.[c] ?? null) === JSON.stringify(after.new?.[c] ?? null)) continue
            lineLines.push({ t: 'change', label: `${tx(d, 'prl.lineHeading', { name: nameOf(after) })} · ${fieldMeta(d, 'payroll_lines', c)[0]}`,
                old: money(before, before.old, c), new: money(after, after.new, c) })
        }
        if (restricted) hiddenPairs++
    }
    if (hiddenPairs) lineLines.push({ t: 'value', label: tx(d, 'prl.linesRestricted', { people: people(hiddenPairs) }), value: { text: tx(d, 'restricted'), restricted: true } })
    if (!created) {
        for (const [emp, r] of ins) if (!del.has(emp)) lineLines.push({ t: 'value', label: tx(d, 'prl.lineAdded', { name: nameOf(r) }), value: money(r, r.new, 'gross_pay') })
        for (const [emp, r] of del) if (!ins.has(emp)) lineLines.push({ t: 'value', label: tx(d, 'prl.lineRemoved', { name: nameOf(r) }), value: money(r, r.old, 'gross_pay') })
    }

    // ── 工资期 ──
    for (const r of periods) {
        if (r === created) {
            const n = ins.size
            const totals = periods.filter((x) => x !== r && x.op === 'UPDATE')
            const last = (c: string): Json | undefined => { let v = r.new?.[c]; for (const x of totals) if ((x.cols ?? []).includes(c)) v = x.new?.[c]; return v }
            const img = { ...(r.new ?? {}) }
            for (const c of ['gross_total', 'net_pay_total']) img[c] = last(c) ?? null
            const ls: Line[] = []
            for (const c of ['period_month', 'payment_date', 'currency', 'gross_total', 'net_pay_total', 'source_note']) {
                const v = img[c]
                if (isEmpty(v ?? null) && !isRestricted(v)) continue
                ls.push({ t: 'value', label: fieldMeta(d, 'payroll_periods', c)[0], value: formatValue(d, 'payroll_periods', c, v, img, r.refs, 'INSERT', opts) })
            }
            const notes = typed(splitPayrollUnpostNote(str(r, 'notes', 'new')).notes)
            if (notes) ls.push({ t: 'value', label: fieldMeta(d, 'payroll_periods', 'notes')[0], value: notes })
            out.push({ title: withPart(n ? `${tx(d, 'prl.recorded')} · ${people(n)}` : tx(d, 'prl.recorded'), codeOf(r)), lines: ls, key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE' || (r.op === 'UPDATE' && isSet(r, 'deleted_at'))) { out.push(describeGeneric(d, r, opts)); continue }
        // 建立的那一笔里,upsert 先以 0 插入、再把合计写上 —— 那是建立本身(合计已经取最后写下的值说了),不是一次改动
        if (created && r.op === 'UPDATE' && !statusTo(r)) continue
        if (r === postRow) {
            out.push({ title: withPart(tx(d, 'prl.posted'), codeOf(r)), key: true, weight: 100,
                lines: jeLine('prl.journal', seen(docVal(d, r, 'payroll_periods', 'journal_entry_id'), r.new?.['journal_entry_id'])) })
            continue
        }
        if (r === unpostRow) {
            const orig = jes.find((j) => j.op === 'UPDATE' && changed(j, 'reversed_by'))
            const rev = (orig ? docVal(d, orig, 'journal_entries', 'reversed_by') : (() => { const j = jeOf('reversal'); return j ? jeSelf(j) : null })()) ?? restrictedVal
            const reason = splitPayrollUnpostNote(str(r, 'notes', 'new')).reason
            out.push({ title: withPart(tx(d, 'prl.unposted'), codeOf(r)), lines: jeLine('prl.reversalJournal', rev), reason: typed(reason), key: true, weight: 100 })
            continue
        }
        if (r === cpfRow || r === dedRow) {
            const cpf = r === cpfRow
            out.push({ title: withPart(tx(d, cpf ? 'prl.cpfPaid' : 'prl.deductionsPaid'), codeOf(r)), key: true, weight: 100,
                lines: [...vline(d, r, cpf ? 'cpf_paid_at' : 'deductions_paid_at', opts),
                        ...jeLine('prl.journal', seen(docVal(d, r, 'payroll_periods', cpf ? 'cpf_journal_entry_id' : 'deductions_journal_entry_id'),
                                                      r.new?.[cpf ? 'cpf_journal_entry_id' : 'deductions_journal_entry_id']))] })
            continue
        }
        // 一次保存(重导):抬头那几列 + 合计 + 配对之后的工资行;notes 只比人写的那一段(撤销追加的那几行不是这一次的改动)
        const was = splitPayrollUnpostNote(str(r, 'notes', 'old')).notes, now = splitPayrollUnpostNote(str(r, 'notes', 'new')).notes
        const ls = changeLines(d, r, opts, new Set([...skip, 'notes', 'status', 'journal_entry_id']))
        if (changed(r, 'notes') && was !== now) {
            ls.push({ t: 'change', label: fieldMeta(d, 'payroll_periods', 'notes')[0],
                old: was ? truncate(was, true) : { text: tx(d, 'empty'), empty: true }, new: now ? truncate(now, true) : { text: tx(d, 'empty'), empty: true } })
        }
        if (ls.length || lineLines.length) out.push({ title: withPart(tx(d, 'prl.changed'), codeOf(r)), lines: [...ls, ...lineLines], key: false, weight: 60 })
    }
    // 工资行单独出现(记录开始之前:最近一次保存的那一刻;或一次只动了行的操作)
    if (!periods.some((r) => r !== created && r.op === 'UPDATE' && !isSet(r, 'cpf_paid_at') && !isSet(r, 'deductions_paid_at')) && !created) {
        const prelogIns = [...ins.values()].filter((r) => r.prelog)
        if (prelogIns.length && !del.size) out.push({ title: `${tx(d, 'prl.linesSaved')} · ${people(prelogIns.length)}`, lines: [], key: true, weight: 50 })
        else if (lineLines.length) out.push({ title: tx(d, 'prl.changed'), lines: lineLines, key: false, weight: 50 })
    }
    for (const r of lineUpdates) {
        // 发薪那一笔给每一行盖 paid_at —— 那是"Salaries paid"那一句(分录的建立说它)
        if ((r.cols ?? []).every((c) => c === 'paid_at' || c === 'paid_journal_entry_id')) continue
        const ls = changeLines(d, r, opts, skip)
        if (ls.length) out.push({ title: tx(d, 'prl.changed'), lines: [{ t: 'heading', text: tx(d, 'prl.lineHeading', { name: nameOf(r) }) }, ...ls], key: false, weight: 40 })
    }

    // ── 这一期的分录(过账 · 发薪 · CPF · 代扣款 · 撤销的冲销):与那一步同一笔的并进那一句;单独出现时照它的身份说同一句 ──
    for (const j of jes) {
        const id = idOf(j) ?? ''
        const role = hc.journalRole.get(id)
        if (j.op === 'UPDATE' && changed(j, 'status') && str(j, 'status', 'new') === 'reversed') {
            if (unpostRow) continue
            out.push({ title: tx(d, 'prl.unposted'), lines: jeLine('prl.reversalJournal', docVal(d, j, 'journal_entries', 'reversed_by')), key: true, weight: 90 })
            continue
        }
        if (j.op !== 'INSERT') { out.push({ ...describeGeneric(d, j, opts), title: withPart(tx(d, 'journal.edited'), str(j, 'code')), weight: 25 }); continue }
        if (role === 'post') { if (!postRow) out.push({ title: tx(d, 'prl.posted'), lines: jeLine('prl.journal', jeSelf(j)), key: true, weight: 90 }); continue }
        if (role === 'reversal') { if (!unpostRow && !jes.some((x) => x.op === 'UPDATE' && str(x, 'reversed_by', 'new') === id)) out.push({ title: tx(d, 'prl.unposted'), lines: jeLine('prl.reversalJournal', jeSelf(j)), key: true, weight: 90 }); continue }
        if (role === 'cpf') { if (!cpfRow) out.push({ title: tx(d, 'prl.cpfPaid'), lines: jeLine('prl.journal', jeSelf(j)), key: true, weight: 90 }); continue }
        if (role === 'deductions') { if (!dedRow) out.push({ title: tx(d, 'prl.deductionsPaid'), lines: jeLine('prl.journal', jeSelf(j)), key: true, weight: 90 }); continue }
        if (role === 'salary') {
            const n = hc.salaryLines.get(id) ?? lineUpdates.filter((r) => str(r, 'paid_journal_entry_id', 'new') === id).length
            out.push({ title: n ? `${tx(d, 'prl.salariesPaid')} · ${people(n)}` : tx(d, 'prl.salariesPaid'), lines: jeLine('prl.journal', jeSelf(j)), key: true, weight: 90 })
            continue
        }
        out.push({ title: withPart(tx(d, 'je.posted.payroll'), str(j, 'code')), lines: [], key: true, weight: 55 })
    }

    // ── 过账 / 撤销的申请(审批留痕并进它批的那一张;执行与过账 / 撤销同一笔 —— 那一句说它)──
    for (const r of by('payroll_requests')) {
        const id = idOf(r)
        const kind = str(r, 'kind') ?? (id ? hc.requestKind.get(id) ?? null : null)
        const code = onPage ? null : payrollLabel(str(r, 'label')).code
        const to = statusTo(r)
        if (r.op === 'INSERT') {
            const auto = str(r, 'status', 'new') === 'approved' || by('approval_log').some((a) => str(a, 'subject_id') === id && str(a, 'decision', 'new') === 'auto_approved')
            const ls: Line[] = [...(auto ? [{ t: 'note', text: tx(d, 'po.autoApproved') } as Line] : []), ...vlines(d, r, ['gross_total'], opts)]
            out.push({ title: withPart(tx(d, prlKey(kind, auto ? 'approved' : 'sent')), code), lines: ls, reason: typed(r.new?.['notes']), key: true, weight: 85,
                       recordId: id, absorbsApproval: true })
        } else if (to === 'withdrawn' || (r.prelog && (r.cols ?? []).includes('withdrawn_at'))) {
            out.push({ title: withPart(tx(d, prlKey(kind, 'withdrawn')), code), lines: [], key: true, weight: 85, recordId: id, absorbsApproval: true })
        } else if (to === 'approved' || to === 'rejected') {
            out.push({ title: withPart(tx(d, prlKey(kind, to)), code), lines: [], reason: typed(r.new?.['decision_notes']), key: true, weight: 90, recordId: id, absorbsApproval: true })
        } else if (to === 'executed') {
            // 执行与过账 / 撤销同一笔 —— 工资期那一句说它;万一它单独出现,照它的种类说那一步
            if (!postRow && !unpostRow) out.push({ title: withPart(tx(d, kind === 'reversal' ? 'prl.unposted' : 'prl.posted'), code), lines: [], key: true, weight: 90 })
        } else if (r.op === 'UPDATE') {
            const ls = changeLines(d, r, opts, new Set(['decided_at', 'decided_by', 'executed_at', 'executed_by', 'result_journal_entry_id', 'label', 'snapshot']))
            if (ls.length) out.push({ title: withPart(tx(d, 'prl.requestChanged'), code), lines: ls, key: false, weight: 35, recordId: id })
        } else out.push(describeGeneric(d, r, opts))
    }
    for (const a of by('approval_log')) {
        if (a.op !== 'INSERT') { out.push(describeGeneric(d, a, opts)); continue }
        const sid = str(a, 'subject_id')
        const { code, kind: lk } = payrollLabel(str(a, 'subject_code'))
        const kind = (sid ? hc.requestKind.get(sid) : null) ?? lk
        const decision = str(a, 'decision', 'new') ?? ''
        const what = decision === 'submitted' ? 'sent' : decision === 'approved' || decision === 'auto_approved' ? 'approved' : decision === 'rejected' ? 'rejected' : null
        if (!what) { out.push(...describeApproval(d, [a])); continue }
        const { text, ownLine } = decision === 'auto_approved' ? { text: null, ownLine: null } : splitPayrollDecisionNote(str(a, 'note', 'new'))
        const ls: Line[] = [...(decision === 'auto_approved' ? [{ t: 'note', text: tx(d, 'po.autoApproved') } as Line] : []),
                            ...(ownLine ? [{ t: 'note', text: tx(d, 'prl.ownLine', { code: ownLine }) } as Line] : [])]
        out.push({ title: withPart(tx(d, prlKey(kind, what)), onPage ? null : code), lines: ls, reason: typed(text), key: true, weight: 85, approvalFor: sid ?? undefined })
    }
    // 审批并进申请那一句时,那一句只带走理由与它自己的标题;"本期含审批人自己的工资行"那一行要跟过去
    for (const a of out.filter((b) => b.approvalFor)) {
        const target = out.find((b) => b !== a && b.recordId === a.approvalFor)
        if (target) for (const l of a.lines) if (l.t === 'note' && !target.lines.some((x) => x.t === 'note' && x.text === l.text)) target.lines.push(l)
    }
    return out
}

function reviewTitle(d: TrailDict, r: TrailRow): string {
    if (str(r, 'review_type') === 'probation') return tx(d, 'rv.openedProbation')
    const cyc = refText(d, r, 'cycle_id')
    return cyc ? tx(d, 'rv.openedAnnual', { cycle: cyc.text }) : tx(d, 'rv.openedAnnualNoCycle')
}
/** 评审的结论,按评审自己的几列说(Q7)—— 受限的照样说 Restricted(vlinesR) */
function reviewOutcome(d: TrailDict, r: TrailRow, opts: BuildOptions): Line[] {
    const img = imgOf(r)
    const raw = (c: string) => r.new?.[c] ?? r.old?.[c] ?? r.ctx?.[c]
    const cols = ['rating_code', ...(img['review_type'] === 'probation' ? ['probation_outcome'] : [])]
    if (!isEmpty(raw('new_monthly_salary') ?? null) || isRestricted(raw('new_monthly_salary'))) cols.push('new_monthly_salary', 'salary_effective_date')
    return vlinesR(d, r, cols, opts)
}
const REVIEW_CONCLUSION = ['rating_code', 'summary_text']
const REVIEW_HR = ['probation_outcome', 'new_monthly_salary', 'salary_effective_date']
function goalHeading(d: TrailDict, r: TrailRow): Line {
    const n = num(imgOf(r)['sequence'] ?? null)
    return { t: 'heading', text: n !== null ? tx(d, 'rv.goalHeading', { n }) : cap(thing(d, 'review_goals')), part: typed(str(r, 'objective_text')) }
}
function describeReview(d: TrailDict, rows: TrailRow[], opts: BuildOptions, hc: HrCtx): Block2[] {
    const out: Block2[] = []
    const by = (t: string) => rows.filter((r) => r.table === t)
    const skip = new Set(['updated_at', 'updated_by', 'created_at', 'created_by'])
    const reviews = by('performance_reviews'), goals = by('review_goals')
    // 自评那一笔(本人保存 / 定稿)整批写每一个目标的结果 —— 那几行是它下面的行,不各自成句
    const selfOp = reviews.some((r) => r.op === 'UPDATE' && (changed(r, 'self_assessment_text') || changed(r, 'self_assessment_submitted_at')) && !changed(r, 'status'))
    const goalLines: Line[] = []
    for (const r of reviews) {
        const id = idOf(r)
        if (r.op === 'INSERT') {
            out.push({ title: reviewTitle(d, r), lines: vlinesR(d, r, ['employee_id', 'period_start', 'period_end', 'reviewer_employee_id'], opts), key: true, weight: 100 })
            continue
        }
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        const prelogVoid = r.prelog && (r.cols ?? []).includes('voided_at')
        if (to === 'void' || prelogVoid) {
            out.push({ title: tx(d, 'rv.voided'), lines: [], reason: typed(r.new?.['void_reason']), key: true, weight: 100, recordId: id })
            continue
        }
        if (to === 'self_review') {
            const reopened = !isEmpty(r.old?.['self_assessment_submitted_at'] ?? null)
            out.push({ title: tx(d, reopened ? 'rv.selfReopened' : 'rv.openedForSelf'), lines: [], key: true, weight: 95, recordId: id })
            continue
        }
        if (to === 'submitted') {
            out.push({ title: tx(d, 'rv.submitted'), lines: vlinesR(d, r, ['rating_code', ...(imgOf(r)['review_type'] === 'probation' ? ['probation_outcome'] : [])], opts),
                       key: true, weight: 95, recordId: id, absorbsApproval: true })
            continue
        }
        if (to === 'approved') {
            out.push({ title: tx(d, 'rv.approved'), lines: reviewOutcome(d, r, opts), key: true, weight: 100, recordId: id, absorbsApproval: true })
            continue
        }
        if (to === 'acknowledged') {
            out.push({ title: tx(d, 'rv.acknowledged'), lines: [], key: true, weight: 95, recordId: id, absorbsApproval: true })
            continue
        }
        if (changed(r, 'self_assessment_submitted_at') && !isEmpty(r.new?.['self_assessment_submitted_at'] ?? null)) {
            out.push({ title: tx(d, 'rv.selfFinalised'), lines: vlines(d, r, ['self_assessment_text'], opts), key: true, weight: 90, recordId: id })
            continue
        }
        if (changed(r, 'self_assessment_text')) {
            out.push({ title: tx(d, 'rv.selfSaved'), lines: changeLines(d, r, opts, new Set([...skip, 'self_assessment_submitted_at'])), key: false, weight: 70, recordId: id })
            continue
        }
        const cols = r.cols ?? []
        const key: TrailTextKey = cols.includes('reviewer_employee_id') ? 'rv.reviewerChanged'
            : cols.some((c) => REVIEW_CONCLUSION.includes(c)) ? 'rv.conclusionChanged'
            : cols.some((c) => REVIEW_HR.includes(c)) ? 'rv.hrDecisionChanged' : 'rv.changed'
        const ls = changeLines(d, r, opts, skip)
        if (ls.length) out.push({ title: tx(d, key), lines: ls, key: key !== 'rv.changed', weight: 70, recordId: id })
    }
    for (const r of goals) {
        const part = typed(str(r, 'objective_text'))
        if (r.op === 'INSERT') {
            out.push({ title: tx(d, 'rv.goalAdded'), part, lines: vlines(d, r, ['target_value', 'unit'], opts), key: false, weight: 60 })
        } else if (r.op === 'DELETE') {
            out.push({ title: tx(d, 'rv.goalRemoved'), part, lines: vlines(d, r, ['target_value', 'actual_value', 'unit', 'employee_result_text', 'reviewer_assessment_text'], opts), key: false, weight: 60 })
        } else {
            const ls = changeLines(d, r, opts, skip)
            if (!ls.length) continue
            if (selfOp) goalLines.push(goalHeading(d, r), ...ls)
            else out.push({ title: tx(d, 'rv.goalChanged'), part, lines: ls, key: false, weight: 60 })
        }
    }
    if (goalLines.length) {
        const self = out.find((b) => b.title === tx(d, 'rv.selfFinalised') || b.title === tx(d, 'rv.selfSaved'))
        if (self) self.lines.push(...goalLines)
        else out.push({ title: tx(d, 'rv.goalChanged'), lines: goalLines, key: false, weight: 60 })
    }
    // 审批留痕:送审 · 批准 · 本人确认(与评审那一行同一笔时并进那一句;单独出现时 —— 记录开始之前 —— 照同一句说,
    //   批准那一句的结论从整页那一份评审今天的样子读,Q7)
    for (const a of by('approval_log')) {
        if (a.op !== 'INSERT') { out.push(describeGeneric(d, a, opts)); continue }
        const decision = str(a, 'decision', 'new') ?? ''
        const sid = str(a, 'subject_id') ?? undefined
        const key: TrailTextKey | null = decision === 'submitted' ? 'rv.submitted' : decision === 'approved' || decision === 'auto_approved' ? 'rv.approved'
            : decision === 'acknowledged' ? 'rv.acknowledged' : null
        if (!key) { out.push(...describeApproval(d, [a])); continue }
        const own = opts.subject === 'performance_review' || opts.subject === 'my_review'
        const rv = sid ? hc.reviewImg.get(sid) : undefined
        const ls = key === 'rv.approved' && rv && !reviews.some((r) => idOf(r) === sid)
            ? reviewOutcome(d, { ...a, table: 'performance_reviews', op: 'UPDATE', cols: [], old: null, new: null, ctx: rv.ctx, refs: rv.refs }, opts) : []
        out.push({ title: withPart(tx(d, key), own ? null : docCode(str(a, 'subject_code'))), lines: ls, reason: typed(a.new?.['note']), key: true, weight: 90, approvalFor: sid })
    }
    // ── 评审轮次(Q6)──
    for (const r of by('review_cycles')) {
        const part = typed(str(r, 'name'))
        const to = changed(r, 'status') ? str(r, 'status', 'new') : null
        if (r.op === 'INSERT') out.push({ title: tx(d, 'rcy.created'), part, lines: vlines(d, r, ['period_start', 'period_end', 'due_date', 'notes'], opts), key: true, weight: 100 })
        else if (to === 'open') out.push({ title: tx(d, 'rcy.opened'), part, lines: [], key: true, weight: 100 })
        else if (to === 'closed') out.push({ title: tx(d, 'rcy.closed'), part, lines: [], key: true, weight: 100 })
        else if (r.op === 'UPDATE' && !isSet(r, 'deleted_at')) {
            const ls = changeLines(d, r, opts, skip)
            if (ls.length) out.push({ title: tx(d, 'rcy.changed'), part, lines: ls, key: false, weight: 40 })
        } else out.push(describeGeneric(d, r, opts))
    }
    return out
}
/** KPI 条目:一次生成(assign_position_kpis 一个人一次,N 条一笔)· 打分 / 改分(score_kpi_entry)· 别的改动 */
function describeKpi(d: TrailDict, rows: TrailRow[], opts: BuildOptions): Block2[] {
    const out: Block2[] = []
    const skip = new Set(['updated_at', 'updated_by', 'created_at', 'created_by'])
    const partOf = (r: TrailRow) => typed([str(r, 'kpi_ref'), str(r, 'title')].filter(Boolean).join(' · '))
    const made = rows.filter((r) => r.op === 'INSERT')
    if (made.length) {
        const ls: Line[] = []
        const emps = [...new Set(made.map((r) => str(r, 'employee_id')).filter((x): x is string => !!x))]
        for (const e of emps) {
            const first = made.find((r) => str(r, 'employee_id') === e)!
            ls.push({ t: 'value', label: fieldMeta(d, 'kpi_entries', 'employee_id')[0], value: refText(d, first, 'employee_id') ?? { text: tx(d, 'empty'), empty: true } })
        }
        for (const r of made) {
            const w = formatValue(d, 'kpi_entries', 'weight_pct', imgOf(r)['weight_pct'], imgOf(r), r.refs, 'INSERT', opts)
            ls.push({ t: 'value', label: str(r, 'kpi_ref') ?? cap(thing(d, 'kpi_entries')), value: typed(`${str(r, 'title') ?? ''} (${w.text}%)`) ?? { text: tx(d, 'empty'), empty: true } })
        }
        out.push({ title: made.length === 1 ? tx(d, 'kpe.generatedOne') : tx(d, 'kpe.generated', { n: made.length }), lines: ls, key: true, weight: 100 })
    }
    for (const r of rows) {
        if (r.op === 'INSERT') continue
        if (r.op === 'DELETE') { out.push(describeGeneric(d, r, opts)); continue }
        const now = num(r.new?.['score'] ?? null)
        if (now !== null && (changed(r, 'score') || (r.prelog && (r.cols ?? []).includes('scored_at')))) {
            // 打分(score_kpi_entry 一次写下分、种类、依据、反馈、封顶);再打一次是"改分":先前那个分说出来
            const was = r.prelog ? null : num(r.old?.['score'] ?? null)
            const title = was !== null ? tx(d, 'kpe.rescored', { from: was, to: now }) : tx(d, 'kpe.scored', { score: now })
            const ls = r.prelog ? vlines(d, r, ['score_kind'], opts)
                : vlines(d, r, ['score_kind', 'computed_basis', 'evidence_note', 'feedback_note', 'override_cap', 'override_reason'], opts)
            out.push({ title, part: partOf(r), lines: ls, key: true, weight: 90 })
            continue
        }
        const ls = changeLines(d, r, opts, new Set([...skip, 'scored_at', 'scored_by']))
        if (ls.length) out.push({ title: tx(d, 'kpe.changed'), part: partOf(r), lines: ls, key: false, weight: 40 })
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
    // AUDIT-TRAIL-1c-2:一列在同一笔里改出去又改回来(对账 → 撤销对账),净值没动 —— 不说 "Open → Open"、"(empty) → (empty)"。
    // 一行合并之后一列都不剩,它就什么都没改,整行不说。只动【合并过】的行:单独一次 UPDATE 照原样交给各自的描述器。
    const merged = new Set([...seen.values()].filter((m) => rows.filter((r) => r.op === 'UPDATE' && r.table === m.table && JSON.stringify(r.key) === JSON.stringify(m.key)).length > 1))
    for (const m of merged) m.cols = m.cols!.filter((c) => JSON.stringify(m.old?.[c] ?? null) !== JSON.stringify(m.new?.[c] ?? null))
    return out.filter((r) => !(merged.has(r) && !r.cols!.length))
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

export function buildEntries(d: TrailDict, rows0: TrailRow[], opts: BuildOptions = {}): Entry[] {
    // AUDIT-TRAIL-1d-1(Q9):停用 / 恢复先写事件、auth 那一头失败再写一行 *_FAILED —— 两次调用、两条记录。那一对的意思是
    //   "没有停用 / 没有恢复",所以把事件那一行并进失败那一条(同一个账号、在它之前最近的那一次同名事件),只说一句。
    const rows = rows0.map((r) => ({ ...r }))
    for (const f of rows) {
        if (f.table !== 'auth.users' || !f.op?.endsWith('_FAILED') || f.hidden) continue
        const base = f.op.replace(/_FAILED$/, '')
        const k = JSON.stringify(f.key)
        const prior = rows.filter((x) => x.table === 'auth.users' && x.op === base && JSON.stringify(x.key) === k && x.at <= f.at && x.group !== f.group)
            .sort((a, b) => (a.at < b.at ? 1 : -1))[0]
        if (prior) { prior.group = f.group; prior.order = f.order }
    }
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
    // AUDIT-TRAIL-1d-3:工资期的分录是哪一笔、发薪付了几行、评审今天的结论 —— 看整页
    const hc = hrContext(rows, reversals)
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
            // AUDIT-TRAIL-1c-3:每一行都被合并掉了(同一次操作里改出去又改回来 —— 挪锁往前、再挪回来),而一行都没有被藏 ——
            //   那一次操作净值什么都没改,不说;只有真的有行看不见时才是 Restricted(以前两种都印 Restricted,那是一句错话)
            if (!rs.some((r) => r.hidden)) continue
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
                case 'access': bs = describeAccess(d, list, opts); break
                case 'hr': bs = describeHr(d, list, opts); break
                case 'policy': bs = describePolicy(d, list, opts); break
                case 'dict': bs = describeDict(d, list, opts); break
                case 'import': bs = describeImport(d, list, opts); break
                case 'time': bs = describeTime(d, list, opts); break
                case 'pay': bs = describePay(d, list, opts, hc); break
                case 'review': bs = describeReview(d, list, opts, hc); break
                case 'kpi': bs = describeKpi(d, list, opts); break
                case 'device': bs = describeDevice(d, list, opts); break
                case 'energy': bs = describeEnergy(d, list, opts); break
                case 'ticket': bs = describeTicket(d, list, opts); break
                case 'optype': bs = describeOpType(d, list, opts); break
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
export type ListRecord = { subject: string; id: string; label: string; href?: string | null }
/** 几条记录读回来的行(已按 mergeKey 去重)→ 一次操作一条:同一个 op_key 的行交给同一次 buildEntries,
 *  Record 一栏列出这次操作碰到的每一条记录(按清单上的先后)。没有 op_key 的行(旧读法)按"记录 · 条"各自成条。 */
export function mergeByOperation(d: TrailDict, items: { row: TrailRow; rec: ListRecord }[]): (Entry & { recordText: string; recordHref: string | null })[] {
    const ops = new Map<string, { rows: TrailRow[]; recs: ListRecord[] }>()
    for (const { row, rec } of items) {
        const k = row.opKey ?? `${rec.subject}:${rec.id}:${row.group}`
        const g = ops.get(k) ?? { rows: [], recs: [] }
        g.rows.push({ ...row, group: k, order: 0 })
        if (!g.recs.some((x) => x.subject === rec.subject && x.id === rec.id)) g.recs.push(rec)
        ops.set(k, g)
    }
    const out: (Entry & { recordText: string; recordHref: string | null })[] = []
    for (const [k, g] of ops) {
        const [first] = g.recs
        for (const e of buildEntries(d, g.rows, { subject: first.subject, recordId: first.id })) {
            // AUDIT-TRAIL-1c-3:只碰到一条、而它有自己的页 → Record 一栏是一个链接
            out.push({ ...e, key: k, recordText: g.recs.map((x) => x.label).join(' · '), recordHref: g.recs.length === 1 ? g.recs[0].href ?? null : null })
        }
    }
    return out
}
