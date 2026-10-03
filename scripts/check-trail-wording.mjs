#!/usr/bin/env node
// scripts/check-trail-wording.mjs
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :lib/trail/render.ts 在【我自己造的样本行】上造出来的句子;外加 lib/trail/text.ts、
//                   lib/trail/catalogue.generated.ts、db/functions 里的两张登记表与 db/tables 的 CHECK 约束。
//   我声称管的是   :审计记录与 /settings/change-history 上一个机器字都印不出来,措辞目录完整。
//   两者不同之处   :我读的是【样本】,不是线上的真行 —— 真数据里一种我没造过的形状(一个 JSON 列里恰好认得的键、
//                   一张表将来新加的列在目录生成之前)我看不见;扫真页面的是冒烟的 trail 判据(scripts/smoke-routes.mjs)。
//                   目录完整那一臂只管登记了主语的表;别的表的枚举值落到 humanize,不是机器字,但措辞未经人过目。
// ==========================================================================
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a(Tim 的 Q7 · Q41)· 审计记录的措辞:目录完整,且一个机器字都印不出来
// ════════════════════════════════════════════════════════════════════════════
// 在 npm run build 里跑,不碰库(只读仓库文件,~1s)。五臂,各自报、各自红:
//   ① 尺:lib/trail/machineTokens.ts 的自证 —— 已知的坏样本每一个都认得出,已知的好话一个都不误报。
//      尺瞎了就不许往下判(AGENTS.md「覆盖率本身必须是一条断言」)。
//   ② 登记表一致:SQL 那一侧(trail_subjects / trail_subject_members)与界面那一侧(render.ts 的三组表、
//      AuditTrail.tsx 的根表、dict.ts 的分界时刻 vs change_log_began_at)逐项相等 —— 一边加了表、另一边没跟上就红。
//   ③ 措辞目录的完整性(Q7):代码里用到的每一个键都在 lib/trail/text.ts 里,目录里的每一个键都有人用;
//      三个主语的每一张表、每一列都有英文标签(不是列名本身),每一个枚举取值都有英文说法(不许落到 humanize)。
//   ④ 机器字扫描(Q41):对【每一张被记录的表】的每一列、每一个 CHECK 取值、每一种"谁"、受限 / 空 / 已删除的每一种
//      引用、以及三个主语的每一个关键事件,造样本行,过 buildEntries,把造出来的每一句交给检出器。
//      一处命中 = 红,并点名那一句与它来自哪一张表的哪一种样本。
//   ⑤ 覆盖:扫过的表数必须等于目录里的表数(238),扫过的句子必须过一个下限 —— 一次悄悄少扫了的运行不许报"干净"。
//   ⑥ 商务样例(AUDIT-TRAIL-1b-2):1b-2 每一个主语的字段编辑 · 子行改动 · 关键事件,造出来的英文逐字等于交回报告里列的那一句。
//   ⑦ 主数据样例(AUDIT-TRAIL-1b-3):1b-3 的物料 · 库位 · 金属价格 · 公式与条款申请 · 任务 · 三个阈值面板,同一个办法;
//      外加任务修改史与公式修改史每一个 change_type 的机器字扫描(它们是隐藏列,④ 的样本走不到那些分支)。
//   ⑧ 账上的单据(AUDIT-TRAIL-1c-1)· ⑨ 其余的单据与合同(AUDIT-TRAIL-1c-2):同一个办法,外加按【那一页】的说法(subject)
//      对每一个主语的每一张表造样本的机器字扫描(④ 的通用扫描不带 subject,走不到 describeFinance / describeLedger2)。
//
// 故障注入(TRAIL_WORDING_FAULT=<臂>,每一臂必须在【它那一臂】红):
//   blind-detector · registry-drift · missing-key · dead-key · label-gap · enum-gap · raw-date · raw-ref · raw-json · raw-null · raw-role ·
//   wording-drift(AUDIT-TRAIL-1b-2:⑥ 商务样例 —— 改一句措辞,逐字比对必须红)·
//   wording-drift-1b3(AUDIT-TRAIL-1b-3:⑦ 主数据样例 —— 同上)· wording-drift-1c1(⑧)· wording-drift-1c2(AUDIT-TRAIL-1c-2:⑨)
// 退出码:0 干净 · 1 有发现 · 3 尺瞎了或覆盖不足(本脚本【不知道】答案)
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const FAULT = process.env.TRAIL_WORDING_FAULT ?? ''
const imp = (p) => import(join(ROOT, p))
const T = await imp('lib/trail/text.ts')
const C = await imp('lib/trail/catalogue.generated.ts')
const R = await imp('lib/trail/render.ts')
const D = await imp('lib/dates.ts')
const M = await imp('lib/trail/machineTokens.ts')
const MV = await imp('messages/trail-machine-values.ts')
const read = (p) => readFileSync(join(ROOT, p), 'utf8')

const problems = { ruler: [], registry: [], catalogue: [], tokens: [], coverage: [] }
const detect = FAULT === 'blind-detector' ? () => [] : M.machineTokens

// ── ① 尺 ────────────────────────────────────────────────────────────────────
problems.ruler.push(...M.selfProof(detect))

// ── ② 登记表一致 ────────────────────────────────────────────────────────────
// AUDIT-TRAIL-1b-1:主语一行是 ('主语', ARRAY['码', …], '根表', '根键', 'table'|'page', 列 | NULL);
//   成员一行是 ('主语', ord, '表', '父表', '外键', '{…}'::jsonb, 'down'|'up', shown, home)。按行的形状整行认,
//   不按"第几个引号串"认 —— 一个主语认两个码时,按位置取根表会取到第二个码(1b-1 第一次跑就是这么错的)。
const subjectSrc = read('db/functions/trail_subjects.sql').replace(/--[^\n]*/g, '')
const subjects = [...subjectSrc.matchAll(/\('([a-z_]+)',\s*ARRAY\[([^\]]*)\],\s*'([a-z_]+)',\s*'([a-z_]+)',\s*'([a-z]+)'/g)]
    .map((m) => ({ subject: m[1], views: [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]), root: m[3], rule: m[5] }))
const memberSrc = read('db/functions/trail_subject_members.sql').replace(/--[^\n]*/g, '')
const members = [...memberSrc.matchAll(/\('([a-z_]+)',\s*(\d+),\s*'([a-z_]+)',\s*'([a-z_]+)',\s*'([a-z_]+)',\s*'[^']*'::jsonb,\s*'(up|down)',\s*(true|false),\s*(true|false)\)/g)]
    .map((m) => ({ subject: m[1], ord: m[2], table: m[3], parent: m[4], hop: m[6], shown: m[7] === 'true' }))
const renderSrc = read('lib/trail/render.ts')
const subjectBlock = renderSrc.match(/export const SUBJECT_TABLES[^=]*= \{([\s\S]*?)\n\}/)?.[1] ?? ''
const uiSets = Object.fromEntries([...subjectBlock.matchAll(/([a-z_]+): \[([^\]]*)\]/g)]
    .map((m) => [m[1], new Set([...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]))]))
if (subjects.length < 10 || members.length < 100 || Object.keys(uiSets).length !== subjects.length) {
    problems.registry.push(`解析登记表读出 ${subjects.length} 个主语 / ${members.length} 行成员 / render.ts 的 SUBJECT_TABLES ${Object.keys(uiSets).length} 个 —— 解析器瞎了`)
}
// 垫脚石(shown = false)不进审计记录,所以不进界面那一侧的表集
const tablesOf = (s) => new Set([subjects.find((x) => x.subject === s)?.root, ...members.filter((m) => m.subject === s && m.shown).map((m) => m.table)])
if (FAULT === 'registry-drift') uiSets.purchase_order.delete('po_issues')
for (const s of subjects) {
    const a = [...tablesOf(s.subject)].sort().join(','), b = [...(uiSets[s.subject] ?? [])].sort().join(',')
    if (a !== b) problems.registry.push(`主语 ${s.subject}:SQL 登记的表 [${a}] ≠ render.ts 认的表 [${b}]`)
}
const rootsSrc = read('app/components/trail/AuditTrail.tsx')
for (const s of subjects) {
    if (!new RegExp(`${s.subject}: '${s.root}'`).test(rootsSrc)) problems.registry.push(`AuditTrail.tsx 的 TRAIL_SUBJECT_ROOTS 里 ${s.subject} 不是 ${s.root}`)
}
const beganSql = read('db/functions/change_log_began_at.sql').match(/SELECT '([^']+)'::timestamptz/)?.[1]
const beganTs = read('lib/trail/dict.ts').match(/TRAIL_LOG_BEGAN_AT = '([^']+)'/)?.[1]
if (!beganSql || beganSql !== beganTs) problems.registry.push(`分界时刻不一致:SQL「${beganSql}」vs dict.ts「${beganTs}」`)

// ── ③ 措辞目录的完整性 ──────────────────────────────────────────────────────
const text = { ...T.TRAIL_TEXT }
if (FAULT === 'missing-key') delete text['po.cancelled']
if (FAULT === 'dead-key') text['po.neverUsed'] = 'Never used'
const USERS = ['lib/trail/render.ts', 'app/components/trail/AuditTrail.tsx', 'app/components/trail/AuditTrailList.tsx',
    'app/settings/change-history/page.tsx', 'app/components/trail/EndedBanner.tsx', 'app/components/trail/RecentTrail.tsx',
    'app/components/trail/ListTrail.tsx']
const used = new Set()
let dynamicAccount = false
for (const f of USERS) {
    const src = read(f)
    for (const m of src.matchAll(/'([a-zA-Z]+(?:\.[a-zA-Z_]+)*)'/g)) if (m[1] in T.TRAIL_TEXT || m[1].includes('.')) used.add(m[1])
    for (const m of src.matchAll(/TRAIL_TEXT\.([a-zA-Z]+)\b/g)) used.add(m[1])
    if (/`account\.\$\{/.test(src)) dynamicAccount = true
}
for (const k of used) if (k in T.TRAIL_TEXT && !(k in text)) problems.catalogue.push(`代码用到了措辞键「${k}」,目录里没有`)
for (const k of Object.keys(text)) {
    if (used.has(k) || (dynamicAccount && k.startsWith('account.'))) continue
    problems.catalogue.push(`措辞键「${k}」没有任何代码用到 —— 删掉它,或者接上`)
}
for (const [k, v] of Object.entries(text)) {
    const hits = detect(v.replace(/\{\w+\}/g, 'X'))
    if (hits.length) problems.catalogue.push(`措辞键「${k}」本身含机器字:${hits.map((h) => h.token).join(', ')}`)
}
const fields = JSON.parse(JSON.stringify(C.TRAIL_FIELDS))
const enums = JSON.parse(JSON.stringify(C.TRAIL_ENUMS))
if (FAULT === 'label-gap') delete fields.purchase_order_lines.quantity
if (FAULT === 'enum-gap') delete enums['purchase_orders#status'].cancelled
// 一张表的镜像通常是 db/tables/<表>.sql;少数几张与它的主表同住一个文件(freight_allocations 在 freight_documents.sql 里)
function mirrorFileOf(t) {
    const f = `db/tables/${t}.sql`
    if (existsSync(join(ROOT, f))) return f
    for (const g of readdirSync(join(ROOT, 'db/tables'))) {
        if (new RegExp(`CREATE TABLE (?:public\\.)?${t}\\s*\\(`).test(read(`db/tables/${g}`))) return `db/tables/${g}`
    }
    return null
}
function mirrorColumns(t) {
    const f = mirrorFileOf(t)
    if (!f) return null
    const src = read(f).replace(/--[^\n]*/g, '')
    const m = src.match(new RegExp(`CREATE TABLE (?:public\\.)?${t}\\s*\\(([\\s\\S]*?)\\n\\);`))
    const cols = []
    if (m) for (const line of m[1].split('\n')) {
        const c = line.match(/^\s+"?([a-z_][a-z0-9_]*)"?\s+[a-z]/)
        if (c && !/^(constraint|primary|unique|check|foreign|exclude)$/i.test(c[1])) cols.push(c[1])
    }
    for (const a of src.matchAll(new RegExp(`ALTER TABLE (?:ONLY )?(?:public\\.)?${t}\\s+ADD COLUMN (?:IF NOT EXISTS )?"?([a-z_][a-z0-9_]*)`, 'g'))) cols.push(a[1])
    return [...new Set(cols)]
}
function checkValues(t, col) {
    const f = join(ROOT, `db/tables/${t}.sql`)
    if (!existsSync(f)) return null
    const src = readFileSync(f, 'utf8').replace(/--[^\n]*/g, '')
    const m = src.match(new RegExp(`CHECK\\s*\\(\\s*\\(?"?${col}"?\\)?\\s*IN\\s*\\(([^)]*)\\)`, 's')) ||
        src.match(new RegExp(`"?${col}"?\\s*=\\s*ANY\\s*\\(\\s*\\(?ARRAY\\[([^\\]]*)\\]`, 's'))
    return m ? [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]) : null
}
const HIDDEN = new Set(['technical', 'audit_std', 'own_key', 'text_code', 'uuid_nofk'])
const HISTORY_BASE = { purchase_order_history: 'purchase_orders', processing_cost_entry_history: 'processing_cost_entries' }
const subjectTables = [...new Set(subjects.flatMap((s) => [...tablesOf(s.subject)]))]
let subjectCols = 0
for (const t of subjectTables) {
    const cols = mirrorColumns(t)
    if (!cols || cols.length < 2) { problems.catalogue.push(`读不出 ${t} 的列(db/tables/${t}.sql)—— 解析器瞎了`); continue }
    for (const c of cols) {
        subjectCols++
        const meta = fields[t]?.[c]
        if (!meta) { problems.catalogue.push(`${t}.${c}:英文目录里没有这一列(跑 node scripts/gen-trail-catalogue.mjs --write,或在生成器里补)`); continue }
        const [label, kind] = meta
        if (!HIDDEN.has(kind) && (label === c || detect(label).length)) problems.catalogue.push(`${t}.${c}:标签「${label}」是机器字`)
        if (kind === 'enum' || kind === 'enum_like') {
            const vals = checkValues(t, c) ?? checkValues(HISTORY_BASE[t] ?? '', c.replace(/^(old|new)_/, '')) ?? []
            for (const v of vals) {
                const bare = c.replace(/^(old|new)_/, '')
                const hit = MV.TRAIL_MACHINE_VALUES[`${t}#${c}`]?.[v] ?? enums[`${t}#${c}`]?.[v] ?? enums[`${HISTORY_BASE[t]}#${bare}`]?.[v] ?? enums[`purchase_order_lines#${bare}`]?.[v]
                if (!hit) problems.catalogue.push(`${t}.${c} 的取值「${v}」没有英文说法(会落到 humanize)`)
            }
        }
    }
}
if (subjectCols < 150) problems.coverage.push(`三个主语的表只数出 ${subjectCols} 列(应当 ≥ 150)—— 列解析瞎了`)

// ── ④ 机器字扫描 ────────────────────────────────────────────────────────────
const dict = {
    text, fields, tables: C.TRAIL_TABLES, enums, machine: MV.TRAIL_MACHINE_VALUES, baseCurrency: 'SGD',
    formatDate: FAULT === 'raw-date' ? (v) => v : (v) => D.formatDate(v, 'en'),
    formatStamp: (v) => D.formatTrailStamp(v),
}
if (FAULT === 'raw-json') dict.text = { ...dict.text, 'value.detailsChanged': '{"a": 1}' }
if (FAULT === 'raw-null') dict.text = { ...dict.text, empty: 'null' }
if (FAULT === 'raw-role') dict.text = { ...dict.text, 'who.system': 'service_role' }
// 造样本按【原始目录】的种类造(外键列 → 一个 id),造句按 dict 的 —— 注入只改后者,于是"外键被当成一段文字印出来"真的会发生
const SAMPLE_KINDS = JSON.parse(JSON.stringify(fields))
if (FAULT === 'raw-ref') {
    dict.fields = JSON.parse(JSON.stringify(fields))
    for (const t of Object.keys(dict.fields)) for (const c of Object.keys(dict.fields[t]))
        if (dict.fields[t][c][1].startsWith('fk_')) dict.fields[t][c] = [dict.fields[t][c][0], 'text']
}

const ACTORS = [{ state: 'person', name: 'Sandra' }, { state: 'system' }, { state: 'removed' }, { state: 'unlinked' },
    { state: 'anonymised' }, { state: 'unknown' }, null]
const REFS = [(l) => ({ label: l }), (l) => ({ label: l, gone: true }), () => ({ label: null, gone: true }), () => null,
    (l) => ({ label: l, unit: 'kg' })]
let uuidN = 0
const uuid = () => `00000000-0000-4000-8000-${String(++uuidN).padStart(12, '0')}`
function sample(t, c, kind, variant) {
    switch (kind) {
        case 'fk_document': case 'fk_other': case 'fk_person': case 'dict': case 'actor': case 'uuid_nofk': case 'technical': case 'audit_std':
            return uuid()
        case 'currency': return 'SGD'
        case 'enum': case 'enum_like': {
            const vals = checkValues(t, c) ?? Object.keys(enums[`${t}#${c}`] ?? {})
            return vals.length ? vals[variant % vals.length] : 'some_value'
        }
        case 'boolean': return variant % 2 === 0
        case 'date': return `2026-09-${String(1 + (variant % 28)).padStart(2, '0')}`
        case 'timestamp_audit': case 'time': return '2026-09-01T06:33:00+00:00'
        case 'money': case 'number': return 1234.5 + variant
        case 'jsonb': return variant % 2 ? { percentage: 50, label: 'Deposit', trigger_event: 'on_order', fixed_amount_ccy: 10 } : { a: [1, 2] }
        case 'array': return ['First', 'Second']
        default: return variant % 3 === 0 ? 'Payment schedule 50% Advanced, 40% upon delivery' : variant % 3 === 1 ? 'Short note' : 'x'.repeat(150)
    }
}
function refsFor(t, img, variant) {
    const out = {}
    for (const [c, v] of Object.entries(img)) {
        const kind = SAMPLE_KINDS[t]?.[c]?.[1]
        if (typeof v !== 'string' || !['fk_document', 'fk_other', 'fk_person', 'dict', 'actor', 'currency'].includes(kind ?? '')) continue
        const r = kind === 'actor' ? { person: ACTORS[variant % ACTORS.length] } : REFS[variant % REFS.length]('Sample record')
        if (r !== null) out[c] = { [v]: r }
    }
    return out
}
const RESTRICTED = { $restricted: true }
let scanned = 0
const tablesSwept = new Set()
function sweep(label, rows, subject = null) {
    let entries
    try {
        entries = R.buildEntries(dict, rows, { currency: 'SGD', subject })
    } catch (e) {
        problems.tokens.push(`${label}:造句器抛错 ${e.message}`)
        return
    }
    for (const e of entries) {
        const strings = [e.title, e.titlePart?.text, e.titlePart?.full, e.who.text, e.atText, e.reason?.text, e.reason?.full]
        for (const l of e.lines) {
            if (l.t === 'heading') strings.push(l.text, l.part?.text, l.part?.full)
            else if (l.t === 'note') strings.push(l.text)
            else if (l.t === 'value') strings.push(l.label, l.value.text, l.value.full)
            else strings.push(l.label, l.old.text, l.old.full, l.new.text, l.new.full)
        }
        for (const s of strings) {
            if (s === undefined || s === null) continue
            scanned++
            const hits = detect(String(s))
            if (hits.length) problems.tokens.push(`${label}:「${String(s).slice(0, 120)}」含 ${hits.map((h) => `${h.kind}「${h.token}」`).join('、')}`)
        }
    }
}
let group = 0
const row = (t, op, over = {}) => ({ group: 'G' + (++group), order: group, prelog: false, at: '2026-09-29T02:00:00+00:00', table: t,
    key: { id: uuid() }, op, actor: ACTORS[group % ACTORS.length], cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false,
    restricted: false, ...over })

for (const t of Object.keys(SAMPLE_KINDS)) {
    tablesSwept.add(t)
    const cols = Object.entries(SAMPLE_KINDS[t])
    for (let variant = 0; variant < 4; variant++) {
        const img = {}, old = {}, neu = {}
        for (const [c, [, kind]] of cols) {
            img[c] = sample(t, c, kind, variant)
            old[c] = variant === 2 ? RESTRICTED : variant === 3 ? null : sample(t, c, kind, variant + 1)
            neu[c] = variant === 1 ? RESTRICTED : sample(t, c, kind, variant + 2)
        }
        const refs = { ...refsFor(t, img, variant), ...refsFor(t, old, variant + 1), ...refsFor(t, neu, variant + 2) }
        sweep(`${t} · INSERT · 样本 ${variant}`, [row(t, 'INSERT', { new: img, refs, prelog: variant === 3 })])
        sweep(`${t} · UPDATE · 样本 ${variant}`, [row(t, 'UPDATE', { cols: cols.map(([c]) => c), old, new: neu, refs, ctx: img })])
        sweep(`${t} · DELETE · 样本 ${variant}`, [row(t, 'DELETE', { old: img, refs })])
    }
    // 每一个枚举取值都说一遍
    for (const [c, [, kind]] of cols) {
        if (kind !== 'enum' && kind !== 'enum_like') continue
        const vals = checkValues(t, c) ?? Object.keys(enums[`${t}#${c}`] ?? {})
        for (let i = 0; i < vals.length; i++) {
            sweep(`${t}.${c} = ${vals[i]}`, [row(t, 'UPDATE', { cols: [c], old: { [c]: vals[(i + 1) % vals.length] }, new: { [c]: vals[i] } })])
        }
    }
}
// AUDIT-TRAIL-1b-1:每一个主语的每一张表,再按【它那一页】的说法造一遍(批次页从批次这一边说加工投入、
//   往上一跳够到的单据要点名 —— 这些分支只在带着主语时才走得到)
for (const s of subjects) {
    for (const t of tablesOf(s.subject)) {
        const cols = Object.entries(SAMPLE_KINDS[t] ?? {})
        for (let variant = 0; variant < 3; variant++) {
            const img = {}, old = {}, neu = {}
            for (const [c, [, kind]] of cols) {
                img[c] = sample(t, c, kind, variant)
                old[c] = variant === 2 ? RESTRICTED : sample(t, c, kind, variant + 1)
                neu[c] = variant === 1 ? RESTRICTED : sample(t, c, kind, variant + 2)
            }
            const refs = { ...refsFor(t, img, variant), ...refsFor(t, old, variant + 1), ...refsFor(t, neu, variant + 2) }
            sweep(`${s.subject} · ${t} · INSERT · 样本 ${variant}`, [row(t, 'INSERT', { new: img, refs, ctx: img, prelog: variant === 2 })], s.subject)
            sweep(`${s.subject} · ${t} · UPDATE · 样本 ${variant}`, [row(t, 'UPDATE', { cols: cols.map(([c]) => c), old, new: neu, refs, ctx: img })], s.subject)
            sweep(`${s.subject} · ${t} · DELETE · 样本 ${variant}`, [row(t, 'DELETE', { old: img, refs })], s.subject)
        }
    }
}
tablesSwept.add('auth.users')
// 关键事件:每一个主语的每一种事件,外加受限 / 看不见 / 账号事件 / 整表清空
const po = (op, over) => row('purchase_orders', op, over)
const at = () => ({ group: 'K' + (++group), order: group })
for (const dec of checkValues('approval_log', 'decision') ?? []) {
    const g = at()
    sweep(`approval_log decision ${dec}`, [row('approval_log', 'INSERT', { ...g, new: { decision: dec, level: 1, note: 'Looks right', amount_ccy: 10, currency: 'SGD' } })])
}
for (const [from, to] of [['confirmed', 'cancelled'], ['receiving', 'closed'], ['closed', 'receiving'], ['confirmed', 'receiving'], ['draft', 'confirmed']]) {
    sweep(`PO ${from} → ${to}`, [po('UPDATE', { cols: ['status', 'cancel_reason'], old: { status: from, cancel_reason: null }, new: { status: to, cancel_reason: 'Wrong supplier' } })])
}
{
    const g = at(); const line = uuid()
    sweep('PO raised with lines, auto approval and a contract', [
        po('INSERT', { ...g, new: { estimated_total_ccy: 0, currency: 'SGD', approval_status: 'approved' } }),
        po('UPDATE', { ...g, cols: ['estimated_total_ccy'], old: { estimated_total_ccy: 0 }, new: { estimated_total_ccy: 305550 } }),
        row('purchase_order_lines', 'INSERT', { ...g, key: { id: line }, new: { line_no: 1, quantity: 1, unit: 'unit' } }),
        row('approval_log', 'INSERT', { ...g, new: { decision: 'auto_approved', note: '审批流未启用 —— 系统直接盖章' } }),
        row('contract_document_terms', 'INSERT', { ...g, new: { contract_code: 'CON-2026-0001' } }),
        row('contract_document_terms', 'INSERT', { ...g, hidden: true, table: null, op: null, actor: null }),
    ])
}
for (const ct of checkValues('purchase_order_history', 'change_type') ?? []) {
    sweep(`PO history ${ct} (记录开始之前)`, [row('purchase_order_history', 'INSERT', { prelog: true, new: {
        change_type: ct, line_no: 1, payment_term_seq: 2, old_incoterm: 'CIF', new_incoterm: 'FOB', old_quantity: 1, new_quantity: 2,
        old_unit: 'kg', new_unit: 'kg', old_payment_term: { percentage: 50 }, new_payment_term: { percentage: 40, label: 'Deposit' },
        old_estimated_unit_price: RESTRICTED, new_estimated_unit_price: RESTRICTED, amend_reason: 'Supplier asked' } })])
}
for (const ct of checkValues('processing_cost_entry_history', 'change_type') ?? []) {
    sweep(`cost history ${ct}`, [row('processing_cost_entry_history', 'INSERT', { new: { entry_id: uuid(), change_type: ct,
        old_amount_base: 100, new_amount_base: RESTRICTED, old_cost_type: 'labour', new_cost_type: 'electricity', new_is_estimate: true } })])
}
{
    const g = at(); const out = uuid(), batch = uuid()
    sweep('run completed', [
        row('processing_runs', 'INSERT', { ...g, new: { process_date: '2026-08-10', loss_qty: 40, notes: 'Night shift', operation_type_code: 'x' } }),
        row('processing_inputs', 'INSERT', { ...g, new: { inbound_batch_id: batch, quantity_consumed: 300 }, refs: { inbound_batch_id: { [batch]: { label: 'IN-2026-0001 · Foil', unit: 'kg' } } } }),
        row('processing_outputs', 'INSERT', { ...g, new: { output_batch_id: out, quantity_produced: 200 }, refs: { output_batch_id: { [out]: { label: null, gone: true } } } }),
    ])
    const g2 = at()
    sweep('run allocated', [
        row('processing_runs', 'UPDATE', { ...g2, cols: ['allocated_at', 'capitalized_cost_base', 'capitalization_entry_id', 'allocation_basis'],
            old: {}, new: { allocated_at: '2026-08-10T09:38:00Z', capitalized_cost_base: RESTRICTED, capitalization_entry_id: uuid(), allocation_basis: 'metal_value' } }),
        row('processing_outputs', 'UPDATE', { ...g2, cols: ['allocated_cost_base', 'unit_cost_base'], old: {}, new: { output_batch_id: out, allocated_cost_base: 809.14, unit_cost_base: 4.0457 } }),
        row('batch_processing_cost_allocations', 'INSERT', { ...g2, new: { inbound_batch_id: batch, amount_base: 944 } }),
    ])
    sweep('run rolled back', [row('processing_runs', 'UPDATE', { cols: ['status', 'deleted_at', 'delete_reason'], old: { status: 'committed' }, new: { status: 'reversed', deleted_at: '2026-08-31T03:54:34Z', delete_reason: 'Wrong batch' } })])
}
{
    const g = at(); const role = uuid()
    sweep('role created with permissions', [
        row('roles', 'INSERT', { ...g, key: { id: role }, new: { name_en: 'Buyer', code: 'buyer', is_active: true } }),
        row('role_permissions', 'INSERT', { ...g, key: { role_id: role, permission_code: 'module.purchasing.view' }, new: { permission_code: 'module.purchasing.view' },
            refs: { permission_code: { 'module.purchasing.view': { label: 'Purchasing (view)' } } } }),
        row('role_permissions', 'INSERT', { ...g, key: { role_id: role, permission_code: 'data.view_pay' }, new: { permission_code: 'data.view_pay' }, refs: {} }),
    ])
    const g2 = at()
    sweep('role permissions changed', [
        row('role_permissions', 'DELETE', { ...g2, key: { role_id: role, permission_code: 'data.view_pay' }, old: { permission_code: 'data.view_pay' },
            refs: { permission_code: { 'data.view_pay': { label: null, gone: true } } } }),
        row('role_permissions', 'INSERT', { ...g2, prelog: true, key: { role_id: role, permission_code: 'x.y' }, new: {} }),
    ])
    sweep('role deactivated', [row('roles', 'UPDATE', { cols: ['is_active'], old: { is_active: true }, new: { is_active: false } })])
}
// AUDIT-TRAIL-1b-2:商务那一半的关键事件 —— 订单 / 报价事件史的【每一种】取值(带着写它的函数真的会拼出来的 detail)、
//   供应商的【每一步】状态、信用、拆箱、单据清单的每一种状态。事件史的 change_type 在目录里是隐藏列,样本扫描造的是一个 id,
//   走不到这些分支 —— 所以在这里一种一种造。取值集合从真源读(CHECK · supplier_status_moves),读出 0 个 = 覆盖不足。
{
    const soTypes = checkValues('sales_order_history', 'change_type') ?? []
    const qtTypes = checkValues('quote_history', 'change_type') ?? []
    const moves = [...read('db/functions/supplier_status_moves.sql').matchAll(/\('([a-z_]+)',\s*'([a-z_]+)',\s*'[a-z_.]+'\)/g)].map((m) => [m[1], m[2]])
    if (soTypes.length < 15 || qtTypes.length < 4 || moves.length < 15) {
        problems.coverage.push(`商务关键事件的取值只读出 订单事件 ${soTypes.length} / 报价事件 ${qtTypes.length} / 供应商状态步 ${moves.length} —— 解析器瞎了`)
    }
    const SO_DETAIL = { created: 'SO-2026-0001', converted_from_quote: 'QT-2026-0001', cancelled: 'Customer changed their mind', issued: 'v2',
        reserved: 'line 1 · OUT-2026-0118 12 kg', released: 'line 1 · 12 · walk complete', invoiced: 'INV-2026-0006',
        invoice_voided: 'INV-2026-0006 · wrong price', shipped: 'SHP-2026-0001 · 12/12', credit_noted: 'CN-2026-0001 · SGD 50 · damaged' }
    for (const ct of soTypes) for (const subject of [null, 'sales_order', 'output_batch']) {
        const g = at(); const so = uuid()
        sweep(`sales_order_history ${ct} (${subject ?? '汇总页'})`, [row('sales_order_history', 'INSERT', { ...g, prelog: ct === 'created', new: {
            sales_order_id: so, change_type: ct, detail: SO_DETAIL[ct] ?? null, line_no: 1, old_quantity: 12, new_quantity: 10,
            old_unit_price: 5, new_unit_price: RESTRICTED, amend_reason: 'Customer asked' }, refs: { sales_order_id: { [so]: { label: 'SO-2026-0001' } } } })], subject)
    }
    for (const ct of qtTypes) {
        const g = at()
        sweep(`quote_history ${ct}`, [row('quote_history', 'INSERT', { ...g, new: { change_type: ct,
            detail: ct === 'issued' ? 'v1' : ct === 'converted' ? 'SO-2026-0004' : ct === 'declined' ? 'Too expensive' : 'QT-2026-0001' } })], 'quote')
    }
    for (const [from, to] of moves) {
        const g = at(); const sup = uuid()
        sweep(`supplier ${from} → ${to}`, [
            row('suppliers', 'UPDATE', { ...g, key: { id: sup }, cols: ['status'], old: { status: from }, new: { status: to } }),
            row('supplier_status_history', 'INSERT', { ...g, new: { supplier_id: sup, from_status: from, to_status: to, note: 'Checked the licence' } }),
            row('approval_log', 'INSERT', { ...g, new: { subject_type: 'supplier', subject_id: sup, subject_code: 'SUP-2026-0001', decision: 'approved' } }),
        ], 'supplier')
    }
    for (const [o, n] of [[[null, false], [5000, false]], [[5000, false], [5000, true]], [[5000, true], [5000, false]], [[5000, false], [8000, true]]]) {
        sweep(`credit ${JSON.stringify(o)} → ${JSON.stringify(n)}`, [row('customer_credit_history', 'INSERT', { new: {
            old_credit_limit_base: o[0], new_credit_limit_base: n[0], old_credit_hold: o[1], new_credit_hold: n[1] } })], 'customer')
    }
    sweep('container detached', [row('container_milestones', 'INSERT', { new: { milestone: 'other', event_date: '2026-09-01', note: 'detached SHP-2026-0003: wrong box' } })], 'container')
    for (const st of checkValues('container_documents', 'status') ?? []) {
        sweep(`container document → ${st}`, [row('container_documents', 'UPDATE', { cols: ['status', 'na_reason'], old: { status: 'pending' },
            new: { status: st, na_reason: 'Not needed on this lane', document_type: 'Import Permit' } })], 'container')
    }
    for (const sub of ['shipment', 'sales_order', 'quote', 'customer', 'supplier', 'forwarder', 'container', 'lane', 'port', 'company_licence', 'commission_agreement']) {
        sweep(`${sub} 整条看不见`, [row(subjects.find((x) => x.subject === sub)?.root ?? null, null, { hidden: true, table: null, actor: null })], sub)
    }
}
for (const op of ['ACCOUNT_CREATE', 'ACCOUNT_DELETE', 'ACCOUNT_DISABLE', 'ACCOUNT_DISABLE_FAILED', 'ACCOUNT_ENABLE', 'ACCOUNT_ENABLE_FAILED']) {
    sweep(`account ${op}`, [row('auth.users', op, { new: { email: 'someone@example.test' } })])
}
sweep('truncate', [row('role_permissions', 'TRUNCATE', {})])
sweep('whole entry hidden', [row('purchase_order_lines', null, { hidden: true, table: null, actor: null })])
sweep('private task', [row('tasks', 'UPDATE', { restricted: true, cols: ['title'], old: { title: RESTRICTED }, new: { title: RESTRICTED } })])

// ── ⑥ 商务样例(AUDIT-TRAIL-1b-2):每一个新主语的【字段编辑 · 子行改动 · 关键事件】→ 逐字的英文 ─────────────
//   ④ 只问"有没有机器字";这一臂问"说的是不是那一句"—— 标题、标题后面人敲的那一段、每一行、理由,逐字比。
//   交回报告列给 Tim 过目的正是这些句子;改了一句而不改这里,这一臂就红(注入:TRAIL_WORDING_FAULT=wording-drift)。
problems.gold = []
if (FAULT === 'wording-drift') dict.text = { ...dict.text, 'so.shipped': 'Shipped out' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const ref = (label, extra = {}) => ({ label, ...extra })
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const G = (label, subject, rows, want) => {
        let e
        try { [e] = R.buildEntries(dict, rows.map((r) => ({ group: 'GOLD', order: 1, prelog: false, at: '2026-09-29T02:00:00+00:00', key: { id: uuid() },
            actor: { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r })),
            { currency: 'SGD', subject }) } catch (err) { problems.gold.push(`${label}:造句器抛错 ${err.message}`); return }
        const got = { title: e?.title, part: e?.titlePart?.text ?? null, lines: (e?.lines ?? []).map(lineText), reason: e?.reason?.text ?? null }
        if (got.title !== want.title) problems.gold.push(`${label}:标题「${got.title}」≠「${want.title}」`)
        if ((want.part ?? null) !== got.part) problems.gold.push(`${label}:标题后那一段「${got.part}」≠「${want.part ?? null}」`)
        if (want.lines && JSON.stringify(got.lines) !== JSON.stringify(want.lines)) problems.gold.push(`${label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(want.lines)}`)
        if ((want.reason ?? null) !== got.reason) problems.gold.push(`${label}:理由「${got.reason}」≠「${want.reason ?? null}」`)
    }
    const mat = { material_id: { [id('mat')]: ref('NMC Cathode Foil', { unit: 'kg' }) } }
    // 报价
    G('quote · field edit', 'quote', [{ table: 'quotes', op: 'UPDATE', cols: ['notes'], old: { notes: 'Old note' }, new: { notes: 'Deliver in two lots' } }],
      { title: 'Quote details changed', lines: ['Notes: Old note → Deliver in two lots'] })
    G('quote · line change', 'quote', [{ table: 'quote_lines', op: 'UPDATE', cols: ['quantity'], old: { quantity: 10 }, new: { quantity: 12 },
        ctx: { line_no: 1, material_id: id('mat') }, refs: mat }],
      { title: 'Line changed · Line 1 · NMC Cathode Foil', lines: ['Quantity: 10 kg → 12 kg'] })
    G('quote · issued (history + issue in one operation)', 'quote', [
        { table: 'quotes', op: 'UPDATE', cols: ['status'], old: { status: 'draft' }, new: { status: 'issued' } },
        { table: 'qt_issues', op: 'INSERT', new: { version: 2 } },
        { table: 'quote_history', op: 'INSERT', new: { change_type: 'issued', detail: 'v2' } }],
      { title: 'Quote issued to the customer (version 2)', lines: [] })
    // 一次操作里既建又改(线上那一次回滚的证明就是这个形状):改过的那一行、后面的那几步一样都不能丢
    G('quote · created and a line changed in one operation', 'quote', [
        { table: 'quotes', op: 'INSERT', new: { customer_id: id('cus'), quote_date: '2026-09-29', valid_until: '2026-10-29', currency: 'SGD', fx_rate: 1, status: 'draft' },
          refs: { customer_id: { [id('cus')]: ref('Test Customer') } } },
        { table: 'quote_history', op: 'INSERT', new: { change_type: 'created', detail: 'QT-2026-0009' } },
        { table: 'quote_lines', op: 'INSERT', key: { id: id('ql') }, new: { line_no: 1, material_id: id('mat'), quantity: 10, unit_price: 28 }, refs: mat },
        { table: 'quote_lines', op: 'UPDATE', key: { id: id('ql') }, cols: ['quantity'], old: { quantity: 10 }, new: { quantity: 12 },
          ctx: { line_no: 1, material_id: id('mat') }, refs: mat }],
      { title: 'Quote created · 1 line · 280.00 SGD', lines: ['Customer: Test Customer', 'Quotation date: 29/09/2026', 'Valid until: 29/10/2026',
        'Currency: SGD', 'FX rate: 1', 'Line 1 · NMC Cathode Foil: 10 kg @ 28.00 SGD', '[Line changed · Line 1 · NMC Cathode Foil]', 'Quantity: 10 kg → 12 kg'] })
    G('supplier · submitted and approved in one operation', 'supplier', [
        { table: 'suppliers', op: 'UPDATE', key: { id: id('sup2') }, cols: ['status', 'notes'], old: { status: 'draft', notes: null }, new: { status: 'approved', notes: 'Checked' } },
        { table: 'supplier_status_history', op: 'INSERT', new: { supplier_id: id('sup2'), from_status: 'draft', to_status: 'pending_review', note: 'Ready for review' } },
        { table: 'supplier_status_history', op: 'INSERT', new: { supplier_id: id('sup2'), from_status: 'pending_review', to_status: 'approved', note: 'Licence checked' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'supplier', subject_id: id('sup2'), subject_code: 'SUP-2026-0002', decision: 'submitted' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'supplier', subject_id: id('sup2'), subject_code: 'SUP-2026-0002', decision: 'approved' } }],
      { title: 'Supplier submitted for review', lines: ['Note: Ready for review', '[Supplier approved]', 'Note: Licence checked', '[Supplier details changed]', 'Notes: (empty) → Checked'] })
    G('quote · converted', 'quote', [{ table: 'quote_history', op: 'INSERT', new: { change_type: 'converted', detail: 'SO-2026-0004' } }],
      { title: 'Quote converted to sales order SO-2026-0004', lines: [] })
    // 销售订单
    G('sales order · created (order + history + line)', 'sales_order', [
        { table: 'sales_orders', op: 'INSERT', new: { customer_id: id('cus'), order_date: '2026-09-29', currency: 'SGD', fx_rate: 1, status: 'draft' },
          refs: { customer_id: { [id('cus')]: ref('Test Customer') } } },
        { table: 'sales_order_history', op: 'INSERT', new: { change_type: 'created', detail: 'SO-2026-0009' } },
        { table: 'sales_order_lines', op: 'INSERT', new: { line_no: 1, material_id: id('mat'), quantity: 10, unit_price: 5 }, refs: mat }],
      { title: 'Sales order created · 1 line · 50.00 SGD',
        lines: ['Customer: Test Customer', 'Order date: 29/09/2026', 'Currency: SGD', 'FX rate: 1', 'Line 1 · NMC Cathode Foil: 10 kg @ 5.00 SGD'] })
    G('sales order · field edit (amend notes)', 'sales_order', [
        { table: 'sales_orders', op: 'UPDATE', cols: ['notes'], old: { notes: null }, new: { notes: 'Deliver in one lot' } },
        { table: 'sales_order_history', op: 'INSERT', new: { change_type: 'header_update', old_notes: null, new_notes: 'Deliver in one lot', amend_reason: 'Customer asked' } }],
      { title: 'Sales order amended · notes and terms changed', lines: ['Notes: (empty) → Deliver in one lot'], reason: 'Customer asked' })
    G('sales order · line change (amend)', 'sales_order', [
        { table: 'sales_order_history', op: 'INSERT', new: { change_type: 'line_update', line_no: 1, old_quantity: 10, new_quantity: 8, amend_reason: 'Customer asked' } }],
      { title: 'Sales order amended · line changed · Line 1', lines: ['Quantity: 10 → 8'], reason: 'Customer asked' })
    G('sales order · shipped', 'sales_order', [{ table: 'sales_order_history', op: 'INSERT', new: { change_type: 'shipped', detail: 'SHP-2026-0001 · 12/12' } }],
      { title: 'Goods shipped · SHP-2026-0001', lines: ['Details: 12/12'] })
    G('sales order · invoice voided', 'sales_order', [{ table: 'sales_order_history', op: 'INSERT', new: { change_type: 'invoice_voided', detail: 'INV-2026-0006 · wrong price' } }],
      { title: 'Invoice voided · INV-2026-0006', lines: [], reason: 'wrong price' })
    G('sales order · issued', 'sales_order', [
        { table: 'so_issues', op: 'INSERT', new: { version: 1 } }, { table: 'sales_order_history', op: 'INSERT', new: { change_type: 'issued', detail: 'v1' } }],
      { title: 'Sales order issued to the customer (version 1)', lines: [] })
    // 发货单
    G('shipment · packed into a container', 'shipment', [{ table: 'shipments', op: 'UPDATE', cols: ['container_id'], old: { container_id: null },
        new: { container_id: id('ctr') }, refs: { container_id: { [id('ctr')]: ref('CTR-2026-0001') } } }],
      { title: 'Loaded into container · CTR-2026-0001', lines: [] })
    G('shipment · line added', 'shipment', [{ table: 'shipment_lines', op: 'INSERT', new: { output_batch_id: id('ob'), qty: 12 },
        refs: { output_batch_id: { [id('ob')]: ref('OUT-2026-0118 · NMC Cathode Foil', { unit: 'kg' }) } } }],
      { title: 'Shipment line added', lines: ['OUT-2026-0118 · NMC Cathode Foil: 12 kg'] })
    G('shipment · delivery note issued', 'shipment', [{ table: 'shipment_issues', op: 'INSERT', new: { version: 3 } }],
      { title: 'Delivery note issued (version 3)', lines: [] })
    // 客户
    G('customer · field edit', 'customer', [{ table: 'customers', op: 'UPDATE', cols: ['legal_name'], old: { legal_name: 'Acme' }, new: { legal_name: 'Acme Pte Ltd' } }],
      { title: 'Customer details changed', lines: ['Legal name: Acme → Acme Pte Ltd'] })
    G('customer · contact added', 'customer', [{ table: 'counterparty_contacts', op: 'INSERT', new: { name: 'Ada Tan', email: 'ada@example.test', is_primary: true } }],
      { title: 'Contact added', part: 'Ada Tan', lines: ['Email: ada@example.test', 'Primary contact: Yes'] })
    G('customer · credit hold placed', 'customer', [
        { table: 'customers', op: 'UPDATE', cols: ['credit_hold'], old: { credit_hold: false }, new: { credit_hold: true } },
        { table: 'customer_credit_history', op: 'INSERT', new: { old_credit_limit_base: 5000, new_credit_limit_base: 5000, old_credit_hold: false, new_credit_hold: true } }],
      { title: 'Credit hold placed — shipments frozen', lines: ['Credit hold: No → Yes'] })
    // 佣金协议
    G('commission · field edit', 'commission_agreement', [{ table: 'commission_agreements', op: 'UPDATE', cols: ['remarks'], old: { remarks: null }, new: { remarks: '2% on invoice' } }],
      { title: 'Commission agreement changed', lines: ['Clause / remarks: (empty) → 2% on invoice'] })
    G('commission · deleted', 'commission_agreement', [{ table: 'commission_agreements', op: 'UPDATE', cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-09-29T02:00:00Z' } }],
      { title: 'Commission agreement deleted', lines: [] })
    // 供应商
    G('supplier · field edit', 'supplier', [{ table: 'suppliers', op: 'UPDATE', cols: ['payment_terms'], old: { payment_terms: 'NET30' }, new: { payment_terms: 'NET60' } }],
      { title: 'Supplier details changed', lines: ['Payment terms: NET30 → NET60'] })
    G('supplier · certificate added', 'supplier', [{ table: 'supplier_compliance', op: 'INSERT', new: { cert_type_code: 'ART18', cert_no: 'CERT-1', valid_until: '2027-03-02' },
        refs: { cert_type_code: { ART18: ref('Article 18') } } }],
      { title: 'Compliance certificate added · Article 18', part: 'CERT-1', lines: ['Valid until: 02/03/2027'] })
    G('supplier · approved (status + history + approval)', 'supplier', [
        { table: 'suppliers', op: 'UPDATE', key: { id: id('sup') }, cols: ['status', 'approved_at'], old: { status: 'pending_review' }, new: { status: 'approved' } },
        { table: 'supplier_status_history', op: 'INSERT', new: { supplier_id: id('sup'), from_status: 'pending_review', to_status: 'approved', note: 'Licence checked' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'supplier', subject_id: id('sup'), subject_code: 'SUP-2026-0001', decision: 'approved' } }],
      { title: 'Supplier approved', lines: [], reason: 'Licence checked' })
    // 货代
    G('forwarder · details changed', 'forwarder', [{ table: 'forwarder_details', op: 'UPDATE', cols: ['main_routes'], old: { main_routes: 'SG → CN' }, new: { main_routes: 'SG → CN, SG → KR' } }],
      { title: 'Logistics details changed', lines: ['Main routes: SG → CN → SG → CN, SG → KR'] })
    G('forwarder · rate quote added', 'forwarder', [{ table: 'forwarder_rate_quotes', op: 'INSERT', new: { lane_id: id('lane'), amount_ccy: 1200, currency: 'USD', free_days: 5 },
        refs: { lane_id: { [id('lane')]: ref('SGSIN Singapore → CNSHA Shanghai') } } }],
      { title: 'Rate quote added · SGSIN Singapore → CNSHA Shanghai', lines: ['Amount: 1,200.00 USD', 'Currency: USD', 'Free days: 5'] })
    // 集装箱
    G('container · field edit', 'container', [{ table: 'containers', op: 'UPDATE', cols: ['vessel'], old: { vessel: null }, new: { vessel: 'MV Fixture' } }],
      { title: 'Container details changed', lines: ['Vessel: (empty) → MV Fixture'] })
    G('container · document received', 'container', [{ table: 'container_documents', op: 'UPDATE', cols: ['status'], old: { status: 'pending' },
        new: { status: 'received' }, ctx: { document_type: 'Import permit' } }],
      { title: 'Document received', part: 'Import permit', lines: [] })
    G('container · milestone', 'container', [{ table: 'container_milestones', op: 'INSERT', new: { milestone: 'departed', event_date: '2026-09-29' } }],
      { title: 'Milestone recorded · Departed', lines: ['Date it happened: 29/09/2026'] })
    G('container · shipment detached', 'container', [{ table: 'container_milestones', op: 'INSERT', new: { milestone: 'other', event_date: '2026-09-29', note: 'detached SHP-2026-0003: wrong box' } }],
      { title: 'Shipment SHP-2026-0003 taken out of this container', lines: [], reason: 'wrong box' })
    // 航段 · 港口 · 执照
    const ports = { origin_port_id: { [id('p1')]: ref('SGSIN Singapore') }, destination_port_id: { [id('p2')]: ref('CNSHA Shanghai') } }
    G('lane · created', 'lane', [{ table: 'lanes', op: 'INSERT', new: { origin_port_id: id('p1'), destination_port_id: id('p2') }, refs: ports }],
      { title: 'Lane created · SGSIN Singapore → CNSHA Shanghai', lines: [] })
    G('lane · requirement added', 'lane', [{ table: 'lane_document_requirements', op: 'INSERT', new: { document_type: 'Import permit', regime: 'Basel' } }],
      { title: 'Required document added', part: 'Import permit', lines: ['Regime: Basel'] })
    G('lane · checklist reviewed', 'lane', [{ table: 'lanes', op: 'UPDATE', cols: ['checklist_reviewed_at'], old: { checklist_reviewed_at: null },
        new: { checklist_reviewed_at: '2026-09-29T02:00:00Z' }, ctx: { origin_port_id: id('p1'), destination_port_id: id('p2') }, refs: ports }],
      { title: 'Document checklist reviewed · SGSIN Singapore → CNSHA Shanghai', lines: [] })
    G('port · renamed', 'port', [{ table: 'ports', op: 'UPDATE', cols: ['name'], old: { name: 'Singapore' }, new: { name: 'Singapore (Pasir Panjang)' }, ctx: { code: 'SGSIN' } }],
      { title: 'Port changed · SGSIN Singapore (Pasir Panjang)', lines: ['Port name: Singapore → Singapore (Pasir Panjang)'] })
    G('licence · standing changed', 'company_licence', [{ table: 'company_compliance', op: 'UPDATE', cols: ['status'], old: { status: 'active' }, new: { status: 'suspended' },
        ctx: { cert_type_code: 'GWDF', cert_no: 'WDL-21-2-5380' }, refs: { cert_type_code: { GWDF: ref('GWDF Licence') } } }],
      { title: 'Licence standing changed · GWDF Licence', part: 'WDL-21-2-5380', lines: ['Standing: Active → Suspended'] })
    if (FAULT === 'wording-drift' && !problems.gold.length) problems.gold.push('(注入 wording-drift 没有咬人 —— 这一臂瞎了)')
}

// ── ⑦ 主数据样例(AUDIT-TRAIL-1b-3):物料 · 库位 · 金属价格 · 公式与条款申请 · 任务 · 三个阈值面板 ──────────────
//   与 ⑥ 同一个办法:每一个新主语的【字段编辑 · 子行改动 · 关键事件】造出来的英文,逐字等于交回报告里列的那一句。
//   另加两条 ④ 走不到的扫描:任务修改史与公式修改史的 change_type 在目录里是隐藏列(样本里是一个 id),
//   所以它们的【每一个取值】在这里一种一种造(取值从 CHECK 读,读出 0 个 = 覆盖不足)。
//   注入:TRAIL_WORDING_FAULT=wording-drift-1b3(改一句措辞,这一臂必须红)。
problems.gold3 = []
if (FAULT === 'wording-drift-1b3') dict.text = { ...dict.text, 'loc.classesChanged': 'Allowed classes edited' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const G = (label, subject, rows, want) => {
        let e
        try { [e] = R.buildEntries(dict, rows.map((r) => ({ group: 'GOLD3', order: 1, prelog: false, at: '2026-09-29T02:00:00+00:00', key: { id: uuid() },
            actor: { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r })),
            { currency: 'SGD', subject }) } catch (err) { problems.gold3.push(`${label}:造句器抛错 ${err.message}`); return }
        const got = { title: e?.title, part: e?.titlePart?.text ?? null, lines: (e?.lines ?? []).map(lineText), reason: e?.reason?.text ?? null }
        if (got.title !== want.title) problems.gold3.push(`${label}:标题「${got.title}」≠「${want.title}」`)
        if ((want.part ?? null) !== got.part) problems.gold3.push(`${label}:标题后那一段「${got.part}」≠「${want.part ?? null}」`)
        if (want.lines && JSON.stringify(got.lines) !== JSON.stringify(want.lines)) problems.gold3.push(`${label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(want.lines)}`)
        if ((want.reason ?? null) !== got.reason) problems.gold3.push(`${label}:理由「${got.reason}」≠「${want.reason ?? null}」`)
    }
    const metal = (code, label) => ({ metal: { [code]: { label } } })
    const cls = (code, label) => ({ classification_code: { [code]: { label } } })
    // 物料
    G('material · field edit', 'material', [{ table: 'materials', op: 'UPDATE', cols: ['spec'], old: { spec: null }, new: { spec: 'Shredded, <5 mm' } }],
      { title: 'Material details changed', lines: ['Spec / Description: (empty) → Shredded, <5 mm'] })
    G('material · assay requirement (delete-all + insert, netted)', 'material', [
        { table: 'material_required_metals', op: 'DELETE', key: { material_id: id('m'), metal: 'ni' }, old: { metal: 'ni' }, refs: metal('ni', 'Nickel') },
        { table: 'material_required_metals', op: 'DELETE', key: { material_id: id('m'), metal: 'co' }, old: { metal: 'co' }, refs: metal('co', 'Cobalt') },
        { table: 'material_required_metals', op: 'INSERT', key: { material_id: id('m'), metal: 'ni' }, new: { metal: 'ni' }, refs: metal('ni', 'Nickel') },
        { table: 'material_required_metals', op: 'INSERT', key: { material_id: id('m'), metal: 'li' }, new: { metal: 'li' }, refs: metal('li', 'Lithium') }],
      { title: 'Assay requirement changed', lines: ['Added: Lithium', 'Removed: Cobalt'] })
    G('material · created (unit stored in Chinese → English, Q8)', 'material', [
        { table: 'materials', op: 'INSERT', new: { name: 'NMC black mass', unit: '吨', status: 'draft', may_be_processed: true, code: 'MAT-2026-0009' } },
        { table: 'material_required_metals', op: 'INSERT', key: { material_id: id('m'), metal: 'ni' }, new: { metal: 'ni' }, refs: metal('ni', 'Nickel') }],
      { title: 'Material created', lines: ['Name: NMC black mass', 'Unit: t', 'May be fed to a processing run: Yes', 'Status: Draft', 'Assay required for: Nickel'] })
    G('material · deleted', 'material', [{ table: 'materials', op: 'UPDATE', cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-09-29T02:00:00Z' } }],
      { title: 'Material deleted', lines: [] })
    G('material · attachment added', 'material', [{ table: 'material_attachments', op: 'INSERT', new: { file_name: 'coa-2026.pdf', doc_category: 'coa', material_id: id('m') } }],
      { title: 'Attachment added', part: 'coa-2026.pdf', lines: ['Category: COA'] })
    // 库位(Q13:一次保存只写变了的 —— 改名 + 加一个分类是【一条】记录)
    G('location · field edit', 'storage_location', [{ table: 'storage_locations', op: 'UPDATE', cols: ['zone'], old: { zone: 'A' }, new: { zone: 'B' } }],
      { title: 'Storage location details changed', lines: ['Zone: A → B'] })
    G('location · class change', 'storage_location', [
        { table: 'storage_location_allowed_classes', op: 'INSERT', new: { classification_code: 'HW2', location_id: id('l') }, refs: cls('HW2', 'Hazardous waste (lead)') },
        { table: 'storage_location_allowed_classes', op: 'DELETE', old: { classification_code: 'HW1', location_id: id('l') }, refs: cls('HW1', 'Hazardous waste (lithium)') }],
      { title: 'Allowed material classes changed · 1 added, 1 removed', lines: ['Added: Hazardous waste (lead)', 'Removed: Hazardous waste (lithium)'] })
    G('location · rename and a class in one save', 'storage_location', [
        { table: 'storage_locations', op: 'UPDATE', cols: ['name'], old: { name: 'Bay A1' }, new: { name: 'Bay A1 (north)' } },
        { table: 'storage_location_allowed_classes', op: 'INSERT', new: { classification_code: 'HW2', location_id: id('l') }, refs: cls('HW2', 'Hazardous waste (lead)') }],
      { title: 'Allowed material classes changed · 1 added', lines: ['Added: Hazardous waste (lead)', '[Storage location details changed]', 'Name: Bay A1 → Bay A1 (north)'] })
    G('location · taken out of use', 'storage_location', [{ table: 'storage_locations', op: 'UPDATE', cols: ['is_active'], old: { is_active: true }, new: { is_active: false } }],
      { title: 'Storage location taken out of use', lines: [] })
    G('location · created with a class', 'storage_location', [
        { table: 'storage_locations', op: 'INSERT', new: { code: 'WH-A1', name: 'Bay A1', zone: 'A', is_active: true } },
        { table: 'storage_location_allowed_classes', op: 'INSERT', new: { classification_code: 'HW1', location_id: id('l') }, refs: cls('HW1', 'Hazardous waste (lithium)') }],
      { title: 'Storage location created', part: 'WH-A1', lines: ['Name: Bay A1', 'Zone: A', 'Allowed material classes: Hazardous waste (lithium)'] })
    // 一次操作 = 一笔事务(线上那一次回滚的证明就是这个形状):建库位时勾了一个分类、随后那一次保存把它换掉并改了名 ——
    //   换分类那一步必须说出来(先插后删不是"整组替换");删掉的那一次把同一次操作里别的改动也带着
    G('location · created, then renamed and a class swapped in the same operation', 'storage_location', [
        { table: 'storage_locations', op: 'INSERT', key: { id: id('l2') }, new: { code: 'WH-B2', name: 'Bay B2', zone: 'B', is_active: true } },
        { table: 'storage_location_allowed_classes', op: 'INSERT', key: { id: id('c1') }, new: { classification_code: 'HW1', location_id: id('l2') }, refs: cls('HW1', 'Hazardous waste (lithium)') },
        { table: 'storage_locations', op: 'UPDATE', key: { id: id('l2') }, cols: ['name'], old: { name: 'Bay B2' }, new: { name: 'Bay B2 (east)' } },
        { table: 'storage_location_allowed_classes', op: 'DELETE', key: { id: id('c1') }, old: { classification_code: 'HW1', location_id: id('l2') }, refs: cls('HW1', 'Hazardous waste (lithium)') },
        { table: 'storage_location_allowed_classes', op: 'INSERT', key: { id: id('c2') }, new: { classification_code: 'HW2', location_id: id('l2') }, refs: cls('HW2', 'Hazardous waste (lead)') }],
      { title: 'Storage location created', part: 'WH-B2', lines: ['Name: Bay B2', 'Zone: B', 'Allowed material classes: Hazardous waste (lithium)',
        '[Allowed material classes changed · 1 added, 1 removed]', 'Added: Hazardous waste (lead)', 'Removed: Hazardous waste (lithium)',
        '[Storage location details changed]', 'Name: Bay B2 → Bay B2 (east)'] })
    G('material · edited and deleted in the same operation (one merged edit)', 'material', [
        { table: 'materials', op: 'UPDATE', key: { id: id('m2') }, cols: ['spec'], old: { spec: null }, new: { spec: 'Shredded' } },
        { table: 'materials', op: 'UPDATE', key: { id: id('m2') }, cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-09-29T02:00:00Z' } }],
      { title: 'Material deleted', lines: ['Spec / Description: (empty) → Shredded'] })
    // 金属价格
    G('metal price · recorded', 'metal_price', [{ table: 'metal_prices', op: 'INSERT', new: { metal: 'ni', price_date: '2026-09-29', price_usd_per_tonne: 16250,
        source: 'broker_quote', quote_delayed: false, anomaly_check: { verdict: 'inside' } }, refs: metal('ni', 'Nickel') }],
      { title: 'Metal price recorded', lines: ['Metal: Nickel', 'Price date: 29/09/2026', 'Price (USD/t): 16,250.00', 'Source: Broker / counterparty quotation', 'Delayed figure: No'] })
    G('metal price · field edit', 'metal_price', [{ table: 'metal_prices', op: 'UPDATE', cols: ['price_usd_per_tonne', 'source'],
        old: { price_usd_per_tonne: 16250, source: 'unknown' }, new: { price_usd_per_tonne: 16300, source: 'published_index' } }],
      { title: 'Metal price changed', lines: ['Price (USD/t): 16,250.00 → 16,300.00', 'Source: Source not recorded → Published index'] })
    G('metal price · deleted', 'metal_price', [{ table: 'metal_prices', op: 'UPDATE', cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-09-29T02:00:00Z' } }],
      { title: 'Metal price deleted', lines: [] })
    // 定价公式与条款申请
    G('formula · terms sent to the CFO', 'pricing_formula', [{ table: 'terms_requests', op: 'INSERT', key: { id: id('tr') },
        new: { kind: 'formula_change', label: 'TR-2026-0004', reason: 'Supplier agreed a higher nickel payable', status: 'submitted' } }],
      { title: 'Change to the pricing formula sent to the CFO', part: 'TR-2026-0004', lines: [], reason: 'Supplier agreed a higher nickel payable' })
    G('formula · CFO approved (request + approval + formula + payable in one operation)', 'pricing_formula', [
        { table: 'terms_requests', op: 'UPDATE', key: { id: id('tr') }, cols: ['status', 'decision_notes'], old: { status: 'submitted' },
          new: { status: 'approved', decision_notes: 'OK from 1 Oct' }, ctx: { label: 'TR-2026-0004', kind: 'formula_change' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'terms_request', subject_id: id('tr'), subject_code: 'TR-2026-0004', decision: 'approved', note: 'OK from 1 Oct' } },
        { table: 'pricing_formulas', op: 'UPDATE', cols: ['treatment_charge_usd_per_tonne'], old: { treatment_charge_usd_per_tonne: 300 }, new: { treatment_charge_usd_per_tonne: 280 } },
        { table: 'pricing_formula_history', op: 'INSERT', new: { change_type: 'update', old_treatment_charge_usd_per_tonne: 300, new_treatment_charge_usd_per_tonne: 280 } },
        { table: 'pricing_formula_metals', op: 'UPDATE', key: { formula_id: id('f'), metal: 'ni' }, cols: ['payable_pct'], old: { payable_pct: 75 }, new: { payable_pct: 78 },
          ctx: { metal: 'ni' }, refs: metal('ni', 'Nickel') }],
      { title: 'CFO approved the terms', part: 'TR-2026-0004', lines: ['[Payable % set · Nickel]', 'Payable %: 75 → 78', '[Pricing formula changed]',
        'Treatment charge (USD per tonne): 300.00 → 280.00'], reason: 'OK from 1 Oct' })
    G('formula · field edit before the log (history only)', 'pricing_formula', [{ table: 'pricing_formula_history', op: 'INSERT', prelog: true,
        new: { change_type: 'update', old_average_days: 5, new_average_days: 10 } }],
      { title: 'Pricing formula changed', lines: ['Averaging days: 5 → 10'] })
    // 任务(团队任务的一件事两份 —— change_log 与修改史 —— 只说一次;私人任务只有 change_log)
    G('task · field edit (team: row + history in one operation)', 'task', [
        { table: 'tasks', op: 'UPDATE', cols: ['title'], old: { title: 'Ship samples' }, new: { title: 'Ship the samples' } },
        { table: 'task_history', op: 'INSERT', new: { change_type: 'header_update', old_title: 'Ship samples', new_title: 'Ship the samples' } }],
      { title: 'Task edited', lines: ['Title: Ship samples → Ship the samples'] })
    G('task · step ticked (team: row + history)', 'task', [
        { table: 'task_nodes', op: 'UPDATE', key: { id: id('n1') }, cols: ['done', 'done_at'], old: { done: false, done_at: null }, new: { done: true, done_at: '2026-09-29T02:00:00Z' }, ctx: { title: 'Pack boxes' } },
        { table: 'task_history', op: 'INSERT', new: { change_type: 'node_done', node_id: id('n1'), old_node_done: false, new_node_done: true } }],
      { title: 'Step ticked', part: 'Pack boxes', lines: [] })
    G('task · personal task edited (no history)', 'task', [{ table: 'tasks', op: 'UPDATE', cols: ['status', 'priority'], old: { status: 'todo', priority: 'medium' },
        new: { status: 'in_progress', priority: 'high' } }],
      { title: 'Task edited', lines: ['Status: To Do → In Progress', 'Priority: Medium → High'] })
    G('task · participant added (row + history)', 'task', [
        { table: 'task_participants', op: 'INSERT', new: { employee_id: id('e2') }, refs: { employee_id: { [id('e2')]: { label: 'Choo Er' } } } },
        { table: 'task_history', op: 'INSERT', new: { change_type: 'participant_added', employee_id: id('e2') }, refs: { employee_id: { [id('e2')]: { label: 'Choo Er' } } } }],
      { title: 'Participant added · Choo Er', lines: [] })
    // 记录开始之前:步骤的建行戳与修改史的 node_added 是同一笔、同一刻(fixture 240 N)—— 只说一次
    G('task · before the log, a step added (stamp + history in one operation)', 'task', [
        { table: 'task_nodes', op: 'INSERT', prelog: true, key: { id: id('n9') }, new: { title: 'Old step', target_date: '2026-09-01' } },
        { table: 'task_history', op: 'INSERT', prelog: true, new: { change_type: 'node_added', node_id: id('n9'), new_node_title: 'Old step', new_node_target_date: '2026-09-01' } }],
      { title: 'Step added', part: 'Old step', lines: ['Target date: 01/09/2026'] })
    G('task · made a team task', 'task', [
        { table: 'tasks', op: 'UPDATE', cols: ['task_type'], old: { task_type: 'personal' }, new: { task_type: 'team' } },
        { table: 'task_history', op: 'INSERT', new: { change_type: 'promoted_from_personal', employee_id: id('e') } }],
      { title: 'Made a team task', lines: [] })
    // 三个阈值面板(M6:读法只交回面板那几列;造句器不加也不减)
    G('variance thresholds', 'processing_settings', [{ table: 'processing_settings', op: 'UPDATE', cols: ['wo_input_overrun_pct'], old: { wo_input_overrun_pct: 10 }, new: { wo_input_overrun_pct: 12 } }],
      { title: 'Variance thresholds changed', lines: ['Input overrun (%): 10 → 12'] })
    G('price anomaly warning', 'pricing_settings', [{ table: 'pricing_settings', op: 'UPDATE', cols: ['metal_price_change_warn_pct'], old: { metal_price_change_warn_pct: 15 }, new: { metal_price_change_warn_pct: 20 } }],
      { title: 'Price anomaly warning changed', lines: ['Warn above (%): 15 → 20'] })
    G('discrepancy thresholds', 'receiving_settings', [{ table: 'receiving_settings', op: 'UPDATE', cols: ['grn_short_pct', 'grn_assay_tolerance_pct'],
        old: { grn_short_pct: 5, grn_assay_tolerance_pct: 10 }, new: { grn_short_pct: 4, grn_assay_tolerance_pct: 12 } }],
      { title: 'Discrepancy thresholds changed', lines: ['Short delivery (%): 5 → 4', 'Assay tolerance (%): 10 → 12'] })
    // 修改史的每一个取值(④ 走不到)
    const taskTypes = checkValues('task_history', 'change_type') ?? []
    const pfTypes = checkValues('pricing_formula_history', 'change_type') ?? []
    if (taskTypes.length < 14 || pfTypes.length < 6) problems.coverage.push(`主数据修改史的取值只读出 任务 ${taskTypes.length} / 公式 ${pfTypes.length} —— 解析器瞎了`)
    for (const ct of taskTypes) for (const prelog of [true, false]) {
        sweep(`task_history ${ct}${prelog ? '(记录开始之前)' : ''}`, [row('task_history', 'INSERT', { prelog, new: { change_type: ct, node_id: uuid(), employee_id: id('e2'),
            old_title: 'A', new_title: 'B', old_status: 'todo', new_status: 'done', old_priority: 'low', new_priority: 'high', old_node_title: 'Pack', new_node_title: 'Pack boxes',
            old_node_target_date: '2026-09-01', new_node_target_date: '2026-09-03', old_node_done: false, new_node_done: true, old_sort_order: 1, new_sort_order: 2 },
            refs: { employee_id: { [id('e2')]: { label: 'Choo Er' } } } })], 'task')
    }
    for (const ct of pfTypes) {
        sweep(`pricing_formula_history ${ct}`, [row('pricing_formula_history', 'INSERT', { prelog: true, new: { change_type: ct, metal: 'ni', old_payable_pct: 75, new_payable_pct: RESTRICTED,
            old_name: 'A', new_name: 'B', old_direction: 'purchase', new_direction: 'both', old_price_basis: 'spot', new_price_basis: 'average', old_is_active: true, new_is_active: false },
            refs: metal('ni', 'Nickel') })], 'pricing_formula')
    }
    for (const st of checkValues('terms_requests', 'status') ?? []) {
        sweep(`terms request → ${st}`, [row('terms_requests', 'UPDATE', { cols: ['status', 'withdrawn_at'], old: { status: 'submitted' }, new: { status: st, withdrawn_at: st === 'withdrawn' ? '2026-09-29T02:00:00Z' : null },
            ctx: { label: 'TR-2026-0001', kind: 'formula_change' } })], 'pricing_formula')
    }
    for (const sub of ['material', 'storage_location', 'metal_price', 'pricing_formula', 'task', 'processing_settings', 'pricing_settings', 'receiving_settings']) {
        sweep(`${sub} 整条看不见`, [row(subjects.find((x) => x.subject === sub)?.root ?? null, null, { hidden: true, table: null, actor: null })], sub)
    }
    if (FAULT === 'wording-drift-1b3' && !problems.gold3.length) problems.gold3.push('(注入 wording-drift-1b3 没有咬人 —— 这一臂瞎了)')
}

// ── ⑧ 账上的单据(AUDIT-TRAIL-1c-1)──────────────────────────────────────────
// 七个主语(分录 · 发票 · 贷项通知 · 收付款 · 付款申请 · 费用 · 应付)各一次字段编辑(有的话)· 子行改动 · 关键事件,逐字;
//   加上:冲销读作一句(Q31)、冲销分录是【一行】带链接(Q33)、审批关着时"Approved automatically"(Q32)、
//   付款申请要结清的单据按单号说(Q13)、引用里的员工名照 ActorName 的规矩受限(Q12)、清单页一次操作只说一次(Q16)、
//   冲销分录的"来源"换成原分录的来源(Q15)、1b-3 的第 28 号(删掉的步骤说出它的计划日期与勾没勾,Q34 补的金句)。
//   注入 wording-drift-1c1 → 这一臂必须红。
problems.gold8 = []
if (FAULT === 'wording-drift-1c1') dict.text = { ...dict.text, 'je.reversed': 'Journal undone' }
{
    const SL = await imp('app/finance/sourceLinkReversal.ts')
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const mk = (rows, group = 'GOLD8') => rows.map((r) => ({ group, order: 1, prelog: false, at: '2026-10-03T02:00:00+00:00', key: { id: uuid() },
        actor: { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
    const G = (label, opts, rows, want) => {
        let e
        try { [e] = R.buildEntries(dict, mk(rows), { currency: 'SGD', ...opts }) } catch (err) { problems.gold8.push(`${label}:造句器抛错 ${err.message}`); return null }
        const got = { title: e?.title, part: e?.titlePart?.text ?? null, lines: (e?.lines ?? []).map(lineText), reason: e?.reason?.text ?? null }
        if (got.title !== want.title) problems.gold8.push(`${label}:标题「${got.title}」≠「${want.title}」`)
        if ((want.part ?? null) !== got.part) problems.gold8.push(`${label}:标题后那一段「${got.part}」≠「${want.part ?? null}」`)
        if (want.lines && JSON.stringify(got.lines) !== JSON.stringify(want.lines)) problems.gold8.push(`${label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(want.lines)}`)
        if ((want.reason ?? null) !== got.reason) problems.gold8.push(`${label}:理由「${got.reason}」≠「${want.reason ?? null}」`)
        return e
    }
    const acct = (code, label) => ({ account_id: { [code]: { label } } })
    const ref = (col, v, label, href) => ({ [col]: { [v]: href ? { label, href } : { label } } })

    // ── 分录 ──
    const je = id('je'), rev = id('rev')
    G('journal · posted (field values + its lines)', { subject: 'journal_entry', recordId: je }, [
        { table: 'journal_entries', op: 'INSERT', key: { id: je }, new: { code: 'JE-2026-0090', entry_date: '2026-10-03', source_type: 'manual', memo: 'Accrual for September', status: 'posted' } },
        { table: 'journal_lines', op: 'INSERT', new: { entry_id: je, account_id: 'a1', debit: 100, credit: 0, currency: 'SGD', amount_ccy: 100 }, refs: acct('a1', 'Office rent') },
        { table: 'journal_lines', op: 'INSERT', new: { entry_id: je, account_id: 'a2', debit: 0, credit: 100, currency: 'USD', amount_ccy: 75 }, refs: acct('a2', 'Cash at Bank – USD') }],
      { title: 'Journal posted · JE-2026-0090', lines: ['Entry date: 03/10/2026', 'Source: Manual', 'Memo: Accrual for September',
        'Office rent: Debit 100.00 SGD', 'Cash at Bank – USD: Credit 100.00 SGD (75.00 USD)'] })
    const eRev = G('journal · reversed — one linked line, its lines not repeated (Q33)', { subject: 'journal_entry', recordId: je }, [
        { table: 'journal_entries', op: 'UPDATE', key: { id: je }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null },
          new: { status: 'reversed', reversed_by: rev }, ctx: { code: 'JE-2026-0090', reversed_by: rev }, refs: ref('reversed_by', rev, 'JE-2026-0091', `/finance/journal/${rev}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: rev }, new: { code: 'JE-2026-0091', memo: 'REVERSAL: JE-2026-0090 — booked to the wrong account', status: 'posted' } }],
      { title: 'Journal reversed', lines: ['Reversed by: JE-2026-0091'], reason: 'booked to the wrong account' })
    if (eRev && eRev.lines[0]?.value?.href !== `/finance/journal/${rev}`) problems.gold8.push(`journal · reversed:那一行不是链接(Q33)—— href ${eRev.lines[0]?.value?.href}`)
    G('journal · the reversal on its own page', { subject: 'journal_entry', recordId: rev }, [
        { table: 'journal_entries', op: 'UPDATE', key: { id: je }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null },
          new: { status: 'reversed', reversed_by: rev }, ctx: { code: 'JE-2026-0090', reversed_by: rev } },
        { table: 'journal_entries', op: 'INSERT', key: { id: rev }, new: { code: 'JE-2026-0091', memo: 'REVERSAL: JE-2026-0090 — booked to the wrong account', status: 'posted' } },
        { table: 'journal_lines', op: 'INSERT', new: { entry_id: rev, account_id: 'a1', debit: 0, credit: 100, currency: 'SGD', amount_ccy: 100 }, refs: acct('a1', 'Office rent') }],
      { title: 'Reversal journal posted · JE-2026-0091', lines: ['Reverses: JE-2026-0090', 'Office rent: Credit 100.00 SGD'], reason: 'booked to the wrong account' })
    G('journal · on another document (posting)', { subject: 'invoice', recordId: id('inv') }, [
        { table: 'journal_entries', op: 'INSERT', new: { code: 'JE-2026-0092', status: 'posted' } }],
      { title: 'Journal posted · JE-2026-0092', lines: [] })
    G('journal · manual journal raised with approvals off (Q32)', { subject: 'journal_entry', recordId: id('je3') }, [
        { table: 'journal_entries', op: 'INSERT', key: { id: id('je3') }, new: { code: 'JE-2026-0093', entry_date: '2026-10-03', source_type: 'manual', status: 'posted' } },
        { table: 'journal_requests', op: 'INSERT', key: { id: id('jr') }, new: { kind: 'entry', label: 'manual journal #4', status: 'approved', entry_date: '2026-10-03', amount_base: 50 } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'journal_request', subject_id: id('jr'), decision: 'auto_approved', note: '审批关着时提交' } }],
      { title: 'Journal posted · JE-2026-0093', lines: ['Entry date: 03/10/2026', 'Source: Manual', '[Manual journal approved · manual journal #4]',
        '(Approved automatically (approvals were switched off))', 'Entry date: 03/10/2026', 'Amount (sum of debits): 50.00 SGD'] })
    G('journal · reversal sent for approval (approvals on)', { subject: 'journal_entry', recordId: je }, [
        { table: 'journal_requests', op: 'INSERT', key: { id: id('jr2') }, new: { kind: 'reversal', label: 'JE-2026-0090 · reversal #1', status: 'submitted', memo: 'booked to the wrong account', target_entry_id: je } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'journal_request', subject_id: id('jr2'), decision: 'submitted', level: 2 } }],
      { title: 'Reversal sent for approval', part: 'JE-2026-0090 · reversal #1', lines: [], reason: 'booked to the wrong account' })
    G('journal · reversal request rejected', { subject: 'journal_entry', recordId: je }, [
        { table: 'journal_requests', op: 'UPDATE', key: { id: id('jr2') }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'submitted' }, new: { status: 'rejected', decision_notes: 'The account is right' }, ctx: { kind: 'reversal', label: 'JE-2026-0090 · reversal #1' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'journal_request', subject_id: id('jr2'), decision: 'rejected', level: 2, note: 'The account is right' } }],
      { title: 'Reversal rejected', part: 'JE-2026-0090 · reversal #1', lines: [], reason: 'The account is right' })

    // ── 发票 · 贷项通知 ──
    const inv = id('inv')
    G('invoice · issued with its lines (child lines)', { subject: 'invoice', recordId: inv }, [
        { table: 'invoices', op: 'INSERT', key: { id: inv }, new: { code: 'INV-2026-0010', customer_id: 'c1', kind: 'order', issue_date: '2026-10-03', due_date: '2026-11-02', currency: 'SGD', status: 'issued' },
          refs: ref('customer_id', 'c1', 'Acme Recycling') },
        { table: 'invoice_lines', op: 'INSERT', new: { invoice_id: inv, line_no: 1, description: 'Black mass', quantity: 10, unit_price: 25, unit: 'kg' } }],
      { title: 'Invoice issued · INV-2026-0010', lines: ['Customer: Acme Recycling', 'Invoice type: From a sales order', 'Issue date: 03/10/2026',
        'Due date: 02/11/2026', 'Currency: SGD', 'Line 1 · Black mass: 10 kg @ 25.00 SGD'] })
    G('invoice · void sent for approval', { subject: 'invoice', recordId: inv }, [
        { table: 'invoice_requests', op: 'INSERT', key: { id: id('ir') }, new: { kind: 'void', label: 'INV-2026-0010 · void', status: 'submitted', reason: 'Wrong customer', doc_date: '2026-10-03', amount_base: 250 } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'invoice_request', subject_id: id('ir'), decision: 'submitted', level: 2 } }],
      { title: 'Void sent for approval', part: 'INV-2026-0010 · void', lines: ['Document date: 03/10/2026', 'Amount (base currency): 250.00 SGD'], reason: 'Wrong customer' })
    G('invoice · voided on approval (key event; the lines’ void flag is not said again)', { subject: 'invoice', recordId: inv }, [
        { table: 'invoices', op: 'UPDATE', key: { id: inv }, cols: ['status', 'voided_at', 'voided_by', 'void_reason'], old: { status: 'issued' },
          new: { status: 'void', voided_at: '2026-10-03T02:00:00Z', void_reason: 'Wrong customer' }, ctx: { code: 'INV-2026-0010' } },
        { table: 'invoice_lines', op: 'UPDATE', cols: ['invoice_voided'], old: { invoice_voided: false }, new: { invoice_voided: true } },
        { table: 'invoice_requests', op: 'UPDATE', key: { id: id('ir') }, cols: ['status'], old: { status: 'submitted' }, new: { status: 'approved' }, ctx: { kind: 'void', label: 'INV-2026-0010 · void' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'invoice_request', subject_id: id('ir'), decision: 'approved', level: 2 } }],
      { title: 'Invoice voided', lines: ['[Void approved · INV-2026-0010 · void]'], reason: 'Wrong customer' })
    G('invoice · voided before the log (the stamp is the only record, Q9)', { subject: 'invoice', recordId: inv }, [
        { table: 'invoices', op: 'UPDATE', prelog: true, key: { id: inv }, cols: ['voided_at', 'voided_by', 'status', 'void_reason'],
          new: { voided_at: '2026-08-01T02:00:00Z', status: 'void', void_reason: 'Duplicate' } }],
      { title: 'Invoice voided', lines: [], reason: 'Duplicate' })
    G('invoice · PDF issued', { subject: 'invoice', recordId: inv }, [{ table: 'invoice_issues', op: 'INSERT', new: { invoice_id: inv, version: 2, sha256: 'abc' } }],
      { title: 'Invoice PDF issued · version 2', lines: [] })
    const cn = id('cn')
    G('credit note · issued with its lines', { subject: 'credit_note', recordId: cn }, [
        { table: 'credit_notes', op: 'INSERT', key: { id: cn }, new: { code: 'CN-2026-0002', invoice_id: inv, note_date: '2026-10-03', currency: 'SGD', reason: 'Price adjustment' },
          refs: ref('invoice_id', inv, 'INV-2026-0010') },
        { table: 'credit_note_lines', op: 'INSERT', new: { credit_note_id: cn, invoice_line_id: 'il1', kind: 'revenue_reduction', amount: 20 }, refs: ref('invoice_line_id', 'il1', 'INV-2026-0010 line 1') }],
      { title: 'Credit note issued · CN-2026-0002', lines: ['Against invoice: INV-2026-0010', 'Credit note date: 03/10/2026', 'Currency: SGD',
        'INV-2026-0010 line 1: 20.00 SGD · Price / quality adjustment'], reason: 'Price adjustment' })

    // ── 收付款(Q31)──
    const pay = id('pay'), mir = id('mir')
    G('payment · recorded with an allocation (child line)', { subject: 'payment', recordId: pay }, [
        { table: 'payments', op: 'INSERT', key: { id: pay }, new: { code: 'PMT-2026-0010', direction: 'out', payment_date: '2026-10-03', counterparty_type: 'supplier',
          supplier_id: 's1', amount_ccy: 500, currency: 'SGD', amount_base: 500, fx_rate: 1, bank_account_code: '1000', status: 'posted' }, refs: ref('supplier_id', 's1', 'Bosch Rexroth') },
        { table: 'payment_allocations', op: 'INSERT', new: { payment_id: pay, expense_id: 'x1', allocated_base: 500 }, refs: ref('expense_id', 'x1', 'EXP-2026-0004') }],
      { title: 'Payment recorded · PMT-2026-0010', lines: ['Payment date: 03/10/2026', 'Counterparty type: Supplier', 'Supplier: Bosch Rexroth',
        'Amount: 500.00 SGD', 'Amount (base currency): 500.00 SGD', 'FX rate: 1', 'Bank account: Cash at Bank – SGD', 'EXP-2026-0004: 500.00 SGD'] })
    const reverseRows = [
        { table: 'payments', op: 'UPDATE', key: { id: pay }, cols: ['status', 'reversed_by_payment'], old: { status: 'posted' }, new: { status: 'reversed', reversed_by_payment: mir },
          ctx: { code: 'PMT-2026-0010', direction: 'out', reversed_by_payment: mir }, refs: ref('reversed_by_payment', mir, 'PMT-2026-0011', `/finance/payments/${mir}`) },
        { table: 'payments', op: 'INSERT', key: { id: mir }, new: { code: 'PMT-2026-0011', direction: 'out', notes: 'REVERSAL: PMT-2026-0010 — paid twice', status: 'posted' } }]
    const ePay = G('payment · reversed, on the original (Q31)', { subject: 'payment', recordId: pay }, reverseRows,
      { title: 'Payment reversed · PMT-2026-0010', lines: ['Reversing entry: PMT-2026-0011'], reason: 'paid twice' })
    if (ePay && ePay.lines[0]?.value?.href !== `/finance/payments/${mir}`) problems.gold8.push('payment · reversed:镜像单那一行不是链接')
    G('payment · reversed, on the mirror (Q31: same sentence)', { subject: 'payment', recordId: mir }, reverseRows,
      { title: 'Payment reversed · PMT-2026-0010', lines: ['Reversing entry: PMT-2026-0011'], reason: 'paid twice' })
    G('payment · reversed before the log (only the mirror’s creation, Q31)', { subject: 'payment', recordId: pay }, [
        { table: 'payments', op: 'UPDATE', key: { id: pay }, prelog: true, cols: [], ctx: { code: 'PMT-2026-0010', direction: 'out', reversed_by_payment: mir },
          refs: ref('reversed_by_payment', mir, 'PMT-2026-0011', `/finance/payments/${mir}`), new: {} },
        { table: 'payments', op: 'INSERT', prelog: true, key: { id: mir }, new: { code: 'PMT-2026-0011', direction: 'out', notes: 'REVERSAL: PMT-2026-0010 — paid twice' } }],
      { title: 'Payment reversed · PMT-2026-0010', lines: ['Reversing entry: PMT-2026-0011'], reason: 'paid twice' })
    G('payment · allocation seen from the invoice', { subject: 'invoice', recordId: inv }, [
        { table: 'payment_allocations', op: 'INSERT', new: { payment_id: pay, invoice_id: inv, allocated_base: 250 }, refs: ref('payment_id', pay, 'RCPT-2026-0004') }],
      { title: 'Payment allocated · RCPT-2026-0004', lines: ['Allocated: 250.00 SGD'] })

    // ── 付款申请(Q13 · Q32)──
    const pr = id('pr')
    G('payment request · sent, the documents it settles named (Q13)', { subject: 'payment_request', recordId: pr }, [
        { table: 'payment_requests', op: 'INSERT', key: { id: pr }, new: { code: 'PREQ-2026-0007', kind: 'payment_out', status: 'submitted', counterparty_type: 'supplier', supplier_id: 's1',
          amount_ccy: 500, currency: 'SGD', planned_date: '2026-10-10', allocations: [{ expense_id: 'x1', amount_doc: 300 }, { purchase_order_id: 'po1', amount_doc: 200 }], notes: 'Pay before the 10th' },
          refs: { ...ref('supplier_id', 's1', 'Bosch Rexroth'), allocations: { x1: { label: 'EXP-2026-0004' }, po1: { label: 'PO-2026-0011' } } } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'payment_request', subject_id: pr, decision: 'submitted', level: 2 } }],
      { title: 'Payment sent for approval · PREQ-2026-0007', lines: ['Supplier: Bosch Rexroth', 'Amount: 500.00 SGD', 'Currency: SGD', 'Planned payment date: 10/10/2026',
        'EXP-2026-0004: 300.00 (document currency)', 'PO-2026-0011: 200.00 (document currency)'], reason: 'Pay before the 10th' })
    G('payment request · approvals off: approved automatically (Q32)', { subject: 'payment_request', recordId: pr }, [
        { table: 'payment_requests', op: 'INSERT', key: { id: pr }, new: { code: 'PREQ-2026-0008', kind: 'bank_transfer', status: 'approved', amount_ccy: 1000, currency: 'SGD' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'payment_request', subject_id: pr, decision: 'auto_approved', note: '审批关着' } }],
      { title: 'Bank transfer approved · PREQ-2026-0008', lines: ['(Approved automatically (approvals were switched off))', 'Amount: 1,000.00 SGD', 'Currency: SGD'] })
    G('payment request · paid (the payment it made is a link)', { subject: 'payment_request', recordId: pr }, [
        { table: 'payment_requests', op: 'UPDATE', key: { id: pr }, cols: ['status', 'paid_at', 'paid_by', 'result_payment_id'], old: { status: 'approved' },
          new: { status: 'paid', result_payment_id: pay }, ctx: { code: 'PREQ-2026-0007', kind: 'payment_out' }, refs: ref('result_payment_id', pay, 'PMT-2026-0010', `/finance/payments/${pay}`) }],
      { title: 'Paid · PREQ-2026-0007', lines: ['Payment made: PMT-2026-0010'] })
    G('payment request · WHT remittance reversal sent (Q30)', { subject: 'payment_request', recordId: pr }, [
        { table: 'payment_requests', op: 'INSERT', key: { id: pr }, new: { code: 'PREQ-2026-0009', kind: 'wht_remittance_reversal', status: 'submitted', amount_ccy: 40, currency: 'SGD' } }],
      { title: 'WHT remittance reversal sent for approval · PREQ-2026-0009', lines: ['Amount: 40.00 SGD', 'Currency: SGD'] })
    G('payment request · withdrawn', { subject: 'payment_request', recordId: pr }, [
        { table: 'payment_requests', op: 'UPDATE', key: { id: pr }, cols: ['status', 'withdrawn_at', 'withdrawn_by'], old: { status: 'submitted' }, new: { status: 'withdrawn' },
          ctx: { code: 'PREQ-2026-0007', kind: 'payment_out' } }],
      { title: 'Request withdrawn · PREQ-2026-0007', lines: [] })

    // ── 费用(Q12:引用里的员工名照 ActorName 的规矩)──
    const ex = id('ex'), exm = id('exm')
    G('expense · recorded; an employee the reader may not see reads Restricted (Q12)', { subject: 'expense', recordId: ex }, [
        { table: 'expenses', op: 'INSERT', key: { id: ex }, new: { code: 'EXP-2026-0012', expense_date: '2026-10-03', employee_id: 'e1', account_code: '6100', amount_ccy: 80, currency: 'SGD',
          amount_base: 80, payment_status: 'unpaid', status: 'posted', notes: 'Taxi to the port' },
          refs: { employee_id: { e1: { person: { state: 'restricted' } } }, account_code: { 6100: { label: 'Travel' } } } }],
      { title: 'Expense recorded · EXP-2026-0012', lines: ['Expense date: 03/10/2026', 'Employee: Restricted', 'Account: Travel', 'Amount: 80.00 SGD',
        'Amount (base currency): 80.00 SGD', 'Payment status: Unpaid'], reason: 'Taxi to the port' })
    G('expense · attachment (child line)', { subject: 'expense', recordId: ex }, [
        { table: 'finance_attachments', op: 'INSERT', new: { expense_id: ex, file_name: 'taxi-receipt.jpg', doc_type: 'receipt' } }],
      { title: 'Attachment added', part: 'taxi-receipt.jpg', lines: ['Document type: Receipt'] })
    G('expense · reversed (Q31)', { subject: 'expense', recordId: ex }, [
        { table: 'expenses', op: 'UPDATE', key: { id: ex }, cols: ['status', 'reversed_by_expense'], old: { status: 'posted' }, new: { status: 'reversed', reversed_by_expense: exm },
          ctx: { code: 'EXP-2026-0012', reversed_by_expense: exm }, refs: ref('reversed_by_expense', exm, 'EXP-2026-0013', `/finance/expenses/${exm}`) },
        { table: 'expenses', op: 'INSERT', key: { id: exm }, new: { code: 'EXP-2026-0013', notes: 'REVERSAL: EXP-2026-0012' } }],
      { title: 'Expense reversed · EXP-2026-0012', lines: ['Reversing entry: EXP-2026-0013'] })

    // ── 应付(Q5)──
    const b = id('b')
    G('payable · goods received (pre-log, payable columns only)', { subject: 'payable', recordId: b }, [
        { table: 'inbound_batches', op: 'INSERT', prelog: true, key: { id: b }, new: { quantity: 405, unit: 'kg', supplier_id: 's1', unit_price: 2.5, arrival_date: '2026-09-01' },
          refs: ref('supplier_id', 's1', 'Bosch Rexroth') }],
      { title: 'Goods received · 405 kg', lines: ['Supplier: Bosch Rexroth', 'Unit price: 2.50 SGD', 'Arrival date: 01/09/2026'] })
    G('payable · price changed (field edit, said once)', { subject: 'payable', recordId: b }, [
        { table: 'inbound_batches', op: 'UPDATE', key: { id: b }, cols: ['unit_price', 'pricing_status'], old: { unit_price: 2.5, pricing_status: 'provisional' }, new: { unit_price: 2.75, pricing_status: 'final' } },
        { table: 'price_history', op: 'INSERT', new: { inbound_batch_id: b, old_unit_price: 2.5, new_unit_price: 2.75, currency: 'SGD', notes: 'Final assay' } }],
      { title: 'Price changed', lines: ['Unit price: 2.50 SGD → 2.75 SGD'], reason: 'Final assay' })
    G('payable · written off (key event)', { subject: 'payable', recordId: b }, [
        { table: 'inbound_batches', op: 'UPDATE', key: { id: b }, cols: ['deleted_at', 'deleted_by', 'delete_reason'], old: { deleted_at: null },
          new: { deleted_at: '2026-10-03T02:00:00Z', delete_reason: 'Contaminated load' } }],
      { title: 'Batch written off', lines: [], reason: 'Contaminated load' })
    G('payable · payment allocated (child line)', { subject: 'payable', recordId: b }, [
        { table: 'payment_allocations', op: 'INSERT', new: { payment_id: pay, inbound_batch_id: b, allocated_base: 1012.5 }, refs: ref('payment_id', pay, 'PMT-2026-0010') }],
      { title: 'Payment allocated · PMT-2026-0010', lines: ['Allocated: 1,012.50 SGD'] })

    // ── 线上回滚证明抓到的两处(本刀修的):人批的不读成"自动";进料单价与改价史的新旧单价是【本位币】──
    G('journal · raised and approved by a person in one operation is not "automatic"', { subject: 'journal_entry', recordId: id('je4') }, [
        { table: 'journal_requests', op: 'INSERT', key: { id: id('jr4') }, new: { kind: 'entry', label: 'manual journal #9', status: 'submitted', entry_date: '2026-10-03', amount_base: 0 } },
        { table: 'journal_requests', op: 'UPDATE', key: { id: id('jr4') }, cols: ['amount_base'], old: { amount_base: 0 }, new: { amount_base: 12 } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'journal_request', subject_id: id('jr4'), decision: 'submitted', level: 2 } },
        { table: 'journal_requests', op: 'UPDATE', key: { id: id('jr4') }, cols: ['status', 'decided_at', 'decided_by'], old: { status: 'submitted' }, new: { status: 'approved' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'journal_request', subject_id: id('jr4'), decision: 'approved', level: 2 } }],
      { title: 'Manual journal approved', part: 'manual journal #9', lines: ['Entry date: 03/10/2026', 'Amount (sum of debits): 12.00 SGD'] })
    G('payable · a price set in USD: the batch price and the old / new prices are base currency', { subject: 'payable', recordId: b, currency: 'USD' }, [
        { table: 'price_history', op: 'INSERT', new: { inbound_batch_id: b, old_unit_price: null, new_unit_price: 3.4, currency: 'USD', original_price: 2.5, fx_rate: 1.36 } },
        { table: 'inbound_batches', op: 'UPDATE', key: { id: b }, cols: ['unit_price'], old: { unit_price: null }, new: { unit_price: 3.4 } }],
      { title: 'Price changed', lines: ['Unit price: (empty) → 3.40 SGD'] })
    // ── Q16:清单页一次操作只说一次(冲销那一笔:原单与镜像两条记录,同一个 op_key)──
    {
        const rows = mk(reverseRows).map((r) => ({ ...r, opKey: 'L42' }))
        const merged = R.mergeByOperation(dict, [{ row: rows[0], rec: { subject: 'payment', id: pay, label: 'PMT-2026-0010' } },
                                                 { row: rows[1], rec: { subject: 'payment', id: mir, label: 'PMT-2026-0011' } }])
        if (merged.length !== 1) problems.gold8.push(`Q16 一次操作两条记录:合成了 ${merged.length} 条(应当 1 条)`)
        else {
            if (merged[0].title !== 'Payment reversed · PMT-2026-0010') problems.gold8.push(`Q16:标题「${merged[0].title}」`)
            if (merged[0].recordText !== 'PMT-2026-0010 · PMT-2026-0011') problems.gold8.push(`Q16:Record 一栏「${merged[0].recordText}」`)
        }
        // 同一行被两条记录读到(航段在港口的记录里也有):mergeKey 相同 → 只留一份
        if (R.mergeKey(rows[0], 7) !== R.mergeKey({ ...rows[0] }, 7) || R.mergeKey(rows[0], 7) === R.mergeKey(rows[1], 8)) problems.gold8.push('Q16:mergeKey 认不出同一行 / 把两行认成一行')
    }
    // ── Q15:冲销分录的来源换成原分录的来源 ──
    {
        const eff = SL.effectiveSources([{ source_type: 'purchase', source_id: 'J-orig' }, { source_type: 'purchase', source_id: 'B-1' }, { source_type: 'manual', source_id: null }],
            [{ id: 'J-orig', source_type: 'purchase', source_id: 'B-1' }])
        const a = eff.get('purchase:J-orig'), c = eff.get('purchase:B-1')
        if (a?.source_id !== 'B-1') problems.gold8.push(`Q15:冲销分录的来源没有换成原分录的(得到 ${JSON.stringify(a)})`)
        if (c?.source_id !== 'B-1') problems.gold8.push('Q15:一张普通分录的来源被改了')
        if (eff.size !== 3) problems.gold8.push(`Q15:${eff.size} 条来源进、出来的条数不对`)
    }
    // ── Q34:1b-3 的第 28 号 —— 删掉的步骤说出它的计划日期与勾没勾(以前只有机器字扫描,没有金句)──
    G('task · step deleted (logged) — target date and tick state (1b-3 defect 28)', { subject: 'task' }, [
        { table: 'task_nodes', op: 'DELETE', old: { title: 'Lunch', target_date: '2026-10-05', done: false, task_id: id('t') } }],
      { title: 'Step deleted', part: 'Lunch', lines: ['Target date: 05/10/2026', 'Done: No'] })
    G('task · step deleted before the log — from the history row', { subject: 'task' }, [
        { table: 'task_history', op: 'INSERT', prelog: true, new: { change_type: 'node_removed', node_id: id('n'), old_node_title: 'Lunch', old_node_target_date: '2026-10-05', old_node_done: false } }],
      { title: 'Step deleted', part: 'Lunch', lines: ['Previous step target date: 05/10/2026', 'Step was ticked: No'] })

    // 机器字扫描:七个新主语各自的表,按【这一页】的说法(subject)造样本跑一遍 —— ④ 的通用扫描不带 subject,走不到 describeFinance
    let fin = 0
    for (const sub of ['journal_entry', 'invoice', 'credit_note', 'payment', 'payment_request', 'expense', 'payable']) {
        for (const t of R.SUBJECT_TABLES[sub] ?? []) {
            const cols = Object.entries(SAMPLE_KINDS[t] ?? {})
            for (let variant = 0; variant < 4; variant++) {
                const img = {}, old = {}, neu = {}
                for (const [c, [, kind]] of cols) {
                    img[c] = sample(t, c, kind, variant)
                    old[c] = variant === 2 ? RESTRICTED : variant === 3 ? null : sample(t, c, kind, variant + 1)
                    neu[c] = variant === 1 ? RESTRICTED : sample(t, c, kind, variant + 2)
                }
                const refs = { ...refsFor(t, img, variant), ...refsFor(t, old, variant + 1), ...refsFor(t, neu, variant + 2) }
                for (const [op, o] of [['INSERT', { new: img, prelog: variant === 3 }], ['UPDATE', { cols: cols.map(([c]) => c), old, new: neu, ctx: img }], ['DELETE', { old: img }]]) {
                    sweep(`${sub} · ${t} · ${op} · 样本 ${variant}`, [row(t, op, { ...o, refs })], sub)
                    fin++
                }
            }
        }
        for (const k of ['payment_out', 'payment_reversal', 'bank_transfer', 'bank_transfer_reversal', 'wht_remittance', 'wht_remittance_reversal']) {
            for (const st of ['submitted', 'approved', 'rejected', 'withdrawn', 'paid']) {
                sweep(`${sub} · payment request ${k} → ${st}`, [row('payment_requests', 'UPDATE', { cols: ['status'], old: { status: 'submitted' }, new: { status: st }, ctx: { kind: k, code: 'PREQ-2026-0001' } })], sub)
                fin++
            }
        }
        sweep(`${sub} 整条看不见`, [row(R.SUBJECT_TABLES[sub][0], null, { hidden: true, table: null, actor: null })], sub)
    }
    // 应当造的句数由登记表算出来(每张表 4 个样本 × 3 种操作 · 每个主语 30 次申请状态 · 一句整条看不见)—— 一个数对不上就是造样本那一段瞎了
    const finWant = ['journal_entry', 'invoice', 'credit_note', 'payment', 'payment_request', 'expense', 'payable']
        .reduce((n, sub) => n + (R.SUBJECT_TABLES[sub] ?? []).length * 12 + 30, 0)
    if (fin !== finWant || fin < 700) problems.coverage.push(`账上那七页的机器字扫描造了 ${fin} 句,登记表要求 ${finWant} 句 —— 造样本那一段瞎了`)
    if (FAULT === 'wording-drift-1c1' && !problems.gold8.length) problems.gold8.push('(注入 wording-drift-1c1 没有咬人 —— 这一臂瞎了)')
}

// ── ⑨ 其余的单据与合同(AUDIT-TRAIL-1c-2)─────────────────────────────────────────────────────
// 八个主语(销售 · 运费单 · 资产 · 对账单 · GST 期间 · 汇率 · 管理包 · 合同)各一次字段编辑 · 子行改动 · 关键事件,逐字;
//   加上:更正件说它为哪一期开(Q22)、申报那一刻的每一格并进申报那一条且只说英文(Q23)、撤销对账备注里那一截机器字说成
//   "Reconciliation undone"(Q24)、一件事两行(资产卡与汇率的修改史)、合同的生效申请与 CFO 的决定并成一句;
//   以及 1c-1 留下的缺口:付款申请 · 贷项通知 · 收付款 · 发票的【字段编辑】各一句金句(此前只有机器字扫描兜着)。
//   每一句都先由造句器造出来、逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/AUDIT-TRAIL-1c-2.md §8 逐条列出。
//   注入 wording-drift-1c2 → 这一臂必须红。
problems.gold9 = []
if (FAULT === 'wording-drift-1c2') dict.text = { ...dict.text, 'bst.unreconciled': 'Reconciliation reversed' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const ref = (col, v, label, href) => ({ [col]: { [v]: href ? { label, href } : { label } } })
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const cases = () => {
    const C = []
    const add = (label, opts, rows) => C.push({ label, opts, rows })
    // ── sale ──
    const sale = id('sale'), ob = id('ob'), cus = id('cus'), inv = id('inv'), mv = id('mv'), je = id('cogs')
    add('sale · recorded (key event; the stock issue is the same operation)', { subject: 'sale', recordId: sale }, [
        { table: 'sales_records', op: 'INSERT', key: { id: sale }, new: { output_batch_id: ob, customer_id: cus, sale_date: '2026-10-01', quantity: 200, unit_price: 4.5, currency: 'SGD', fx_rate: 1, amount_base: 900, price_source: 'manual', notes: 'Spot sale' },
          refs: { ...ref('output_batch_id', ob, 'OUT-2026-0186 · NMC Cathode Foil'), ...ref('customer_id', cus, 'Acme Recycling'), output_batch_id: { [ob]: { label: 'OUT-2026-0186 · NMC Cathode Foil', unit: 'kg' } } } },
        { table: 'sales_record_movements', op: 'INSERT', new: { sales_record_id: sale, movement_id: mv } }])
    add('sale · invoiced (child line: the invoice line that bills it)', { subject: 'sale', recordId: sale }, [
        { table: 'invoice_lines', op: 'INSERT', new: { invoice_id: inv, sales_record_id: sale, quantity: 200, amount_ccy: 900, line_no: 1 }, refs: ref('invoice_id', inv, 'INV-2026-0010') }])
    add('sale · customer attributed (field edit, with the attribution note)', { subject: 'sale', recordId: sale }, [
        { table: 'sales_records', op: 'UPDATE', key: { id: sale }, cols: ['customer_id'], old: { customer_id: null }, new: { customer_id: cus }, refs: ref('customer_id', cus, 'Acme Recycling') },
        { table: 'sales_attribution_log', op: 'INSERT', new: { sales_record_id: sale, customer_id: cus, amount_base: 900, note: 'Was a walk-in sale' }, refs: ref('customer_id', cus, 'Acme Recycling') }])
    add('sale · cost of sales posted', { subject: 'sale', recordId: sale }, [
        { table: 'sales_records', op: 'UPDATE', key: { id: sale }, cols: ['cogs_entry_id'], old: { cogs_entry_id: null }, new: { cogs_entry_id: je }, refs: ref('cogs_entry_id', je, 'JE-2026-0101', `/finance/journal/${je}`) }])
    // ── freight ──
    const frt = id('frt'), fwd = id('fwd'), ib1 = id('ib1'), ib2 = id('ib2'), fje = id('fje'), rje = id('rje')
    add('freight · recorded with its apportionment (key event + child lines)', { subject: 'freight', recordId: frt }, [
        { table: 'freight_documents', op: 'INSERT', key: { id: frt }, new: { code: 'FRT-2026-0005', doc_date: '2026-10-01', supplier_id: fwd, direction: 'inbound', amount_ccy: 300, currency: 'SGD', fx_rate: 1, amount_base: 300, allocation_basis: 'weight', payment_status: 'unpaid', notes: 'Port to yard' }, refs: ref('supplier_id', fwd, 'Swift Forwarding') },
        { table: 'freight_allocations', op: 'INSERT', new: { freight_document_id: frt, inbound_batch_id: ib1, amount_base: 200 }, refs: ref('inbound_batch_id', ib1, 'IN-2026-0020 · Black mass') },
        { table: 'freight_allocations', op: 'INSERT', new: { freight_document_id: frt, inbound_batch_id: ib2, amount_base: 100 }, refs: ref('inbound_batch_id', ib2, 'IN-2026-0021 · Black mass') }])
    add('freight · payment status (field edit)', { subject: 'freight', recordId: frt }, [
        { table: 'freight_documents', op: 'UPDATE', key: { id: frt }, cols: ['payment_status', 'updated_at'], old: { payment_status: 'unpaid', updated_at: '2026-10-01T01:00:00Z' }, new: { payment_status: 'paid', updated_at: '2026-10-02T01:00:00Z' }, ctx: { code: 'FRT-2026-0005' } }])
    add('freight · reversed (key event; the reversal journal is the journal block)', { subject: 'freight', recordId: frt }, [
        { table: 'freight_documents', op: 'UPDATE', key: { id: frt }, cols: ['status', 'reversed_at', 'reversed_by', 'reversal_reason', 'reversal_entry_id'], old: { status: 'posted' },
          new: { status: 'reversed', reversed_at: '2026-10-03T02:00:00Z', reversal_reason: 'Billed twice', reversal_entry_id: rje }, ctx: { code: 'FRT-2026-0005' } },
        { table: 'journal_entries', op: 'UPDATE', key: { id: fje }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null }, new: { status: 'reversed', reversed_by: rje },
          ctx: { code: 'JE-2026-0110', reversed_by: rje }, refs: ref('reversed_by', rje, 'JE-2026-0111', `/finance/journal/${rje}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: rje }, new: { code: 'JE-2026-0111', memo: 'REVERSAL: JE-2026-0110 — Billed twice', status: 'posted' } }])
    // ── fixed asset ──
    const fa = id('fa'), exp = id('exp'), dep = id('dep'), adr = id('adr'), dje = id('dje')
    add('fixed asset · card created (key event)', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'fixed_assets', op: 'INSERT', key: { id: fa }, new: { code: 'FA-2026-0003', description: 'Shredder', category: 'equipment', acquisition_date: '2026-09-01', cost_ccy: 0, currency: 'SGD', cost_base: 0, useful_life_months: 60, residual_base: 0, status: 'active' } }])
    add('fixed asset · useful life changed (field edit)', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'fixed_assets', op: 'UPDATE', key: { id: fa }, cols: ['useful_life_months'], old: { useful_life_months: 60 }, new: { useful_life_months: 84 } }])
    add('fixed asset · cost added from an expense (child line)', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'fixed_asset_cost_entries', op: 'INSERT', new: { asset_id: fa, expense_id: exp, amount_ccy: 12000, currency: 'SGD', amount_base: 12000 }, refs: ref('expense_id', exp, 'EXP-2026-0040') },
        { table: 'fixed_assets', op: 'UPDATE', key: { id: fa }, cols: ['cost_base', 'cost_ccy'], old: { cost_base: 0, cost_ccy: 0 }, new: { cost_base: 12000, cost_ccy: 12000 }, ctx: { currency: 'SGD' } }])
    add('fixed asset · put into service (key event)', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'fixed_assets', op: 'UPDATE', key: { id: fa }, cols: ['in_service_date'], old: { in_service_date: null }, new: { in_service_date: '2026-10-01' } }])
    add('fixed asset · depreciation posted', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'fixed_asset_depreciation', op: 'INSERT', key: { id: dep }, new: { asset_id: fa, period_end: '2026-10-31', amount_base: 200, journal_entry_id: dje }, refs: ref('journal_entry_id', dje, 'JE-2026-0120', `/finance/journal/${dje}`) }])
    add('fixed asset · disposal approved and carried out (request + approval + the card, one operation)', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'asset_disposal_requests', op: 'UPDATE', key: { id: adr }, cols: ['status', 'decided_at', 'decided_by', 'executed_at'], old: { status: 'submitted' }, new: { status: 'approved' }, ctx: { label: 'FA-2026-0003 · disposal #1' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'asset_disposal_request', subject_id: adr, decision: 'approved', level: 1 } },
        { table: 'fixed_assets', op: 'UPDATE', key: { id: fa }, cols: ['status', 'disposal_date', 'disposal_proceeds_base'], old: { status: 'active', disposal_date: null, disposal_proceeds_base: null }, new: { status: 'disposed', disposal_date: '2026-10-03', disposal_proceeds_base: 500 } }])
    add('fixed asset · a change before the log (from the history row)', { subject: 'fixed_asset', recordId: fa }, [
        { table: 'fixed_asset_history', op: 'INSERT', prelog: true, new: { fixed_asset_id: fa, change_type: 'updated', changed_columns: ['useful_life_months', 'notes'], old_useful_life_months: 60, new_useful_life_months: 48, old_notes: null, new_notes: 'Heavy use' } }])
    // ── bank statement ──
    const bs = id('bs'), bl1 = id('bl1'), bl2 = id('bl2'), bl3 = id('bl3'), jl = id('jl'), rec = id('rec')
    add('bank statement · imported (key event; its lines counted)', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_statements', op: 'INSERT', key: { id: bs }, new: { code: 'BS-2026-0003', bank_account_code: '1000', currency: 'SGD', period_start: '2026-09-01', period_end: '2026-09-30', opening_balance: 1000, closing_balance: 1500, file_name: 'dbs-sep.csv', status: 'open' } },
        { table: 'bank_statement_lines', op: 'INSERT', key: { id: bl1 }, new: { statement_id: bs, line_no: 1, amount: 300 } },
        { table: 'bank_statement_lines', op: 'INSERT', key: { id: bl2 }, new: { statement_id: bs, line_no: 2, amount: 200 } },
        { table: 'bank_statement_lines', op: 'INSERT', key: { id: bl3 }, new: { statement_id: bs, line_no: 3, amount: 0.5 } }])
    add('bank statement · a line matched (child line)', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_statement_lines', op: 'UPDATE', key: { id: bl1 }, cols: ['match_status'], old: { match_status: 'unmatched' }, new: { match_status: 'matched' }, ctx: { line_no: 1, statement_id: bs } },
        { table: 'bank_line_matches', op: 'INSERT', new: { statement_line_id: bl1, journal_line_id: jl, matched_amount: 300 }, refs: ref('journal_line_id', jl, 'JE-2026-0090 · Cash at Bank – SGD') }])
    add('bank statement · a line ignored', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_statement_lines', op: 'UPDATE', key: { id: bl3 }, cols: ['match_status', 'ignore_reason'], old: { match_status: 'unmatched', ignore_reason: null }, new: { match_status: 'ignored', ignore_reason: 'Bank rounding' }, ctx: { line_no: 3, statement_id: bs } }])
    add('bank statement · reconciled (key event, with the explained difference)', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_statements', op: 'UPDATE', key: { id: bs }, cols: ['status', 'reconciled_at', 'reconciled_by'], old: { status: 'open' }, new: { status: 'reconciled', reconciled_at: '2026-10-03T03:00:00Z' }, ctx: { currency: 'SGD' } },
        { table: 'bank_reconciliations', op: 'INSERT', key: { id: rec }, new: { statement_id: bs, as_of: '2026-09-30', currency: 'SGD', bank_closing_balance: 1500, book_balance: 1499.5, difference: 0.5, matched_lines: 2, ignored_lines: 1 } },
        { table: 'bank_reconciliation_variance_items', op: 'INSERT', new: { reconciliation_id: rec, item_no: 1, item_kind: 'bank_charge', amount: 0.5, note: 'September fee' } }])
    // 同一笔里对账又撤销:status / reconciled_at 改出去又改回来 —— 合并之后不许说 "Open → Open"、"(empty) → (empty)"
    // (第一版的 mergeUpdates 会;回滚的线上证明 B 里看到的。注入:把 render.ts 里那一句过滤拿掉,这一句必须红)
    const bsx = id('bsx'), recx = id('recx')
    add('bank statement · reconciled and undone in one operation (a column that comes back is not a change)', { subject: 'bank_statement', recordId: bsx }, [
        { table: 'bank_statements', op: 'UPDATE', key: { id: bsx }, cols: ['status', 'reconciled_at', 'reconciled_by'], old: { status: 'open', reconciled_at: null, reconciled_by: null }, new: { status: 'reconciled', reconciled_at: '2026-10-03T03:00:00Z', reconciled_by: id('who') }, ctx: { currency: 'SGD' } },
        { table: 'bank_reconciliations', op: 'INSERT', key: { id: recx }, new: { statement_id: bsx, as_of: '2026-09-30', currency: 'SGD', bank_closing_balance: 1500, book_balance: 1500, difference: 0, matched_lines: 3, ignored_lines: 0 } },
        { table: 'bank_reconciliations', op: 'UPDATE', key: { id: recx }, cols: ['superseded_at', 'superseded_reason'], old: { superseded_at: null, superseded_reason: null }, new: { superseded_at: '2026-10-03T03:00:00Z', superseded_reason: 'Wrong period' } },
        { table: 'bank_statements', op: 'UPDATE', key: { id: bsx }, cols: ['status', 'reconciled_at', 'reconciled_by', 'notes'], old: { status: 'reconciled', reconciled_at: '2026-10-03T03:00:00Z', reconciled_by: id('who'), notes: null },
          new: { status: 'open', reconciled_at: null, reconciled_by: null, notes: 'UNRECONCILED 2026-10-03 11:00:00+08: Wrong period' } }])
    add('bank statement · reconciliation undone (Q24: the machine suffix in the notes is not a notes edit)', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_reconciliations', op: 'UPDATE', key: { id: rec }, cols: ['superseded_at', 'superseded_reason'], old: { superseded_at: null }, new: { superseded_at: '2026-10-04T01:00:00Z', superseded_reason: 'Wrong period' } },
        { table: 'bank_statements', op: 'UPDATE', key: { id: bs }, cols: ['status', 'reconciled_at', 'reconciled_by', 'notes'], old: { status: 'reconciled', notes: 'Imported from DBS' },
          new: { status: 'open', reconciled_at: null, notes: 'Imported from DBS\nUNRECONCILED 2026-10-04 09:00:00.123456+08: Wrong period' } }])
    add('bank statement · notes edited (field edit)', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_statements', op: 'UPDATE', key: { id: bs }, cols: ['notes'], old: { notes: null }, new: { notes: 'Re-imported' } }])
    add('bank statement · deleted before the log (date only)', { subject: 'bank_statement', recordId: bs }, [
        { table: 'bank_statements', op: 'UPDATE', key: { id: bs }, prelog: true, cols: ['deleted_at'], new: { deleted_at: '2026-07-30T02:00:00Z' }, actor: { state: 'unknown' } }])
    // ── GST period ──
    const gp = id('gp'), orig = id('orig'), gfr = id('gfr')
    add('GST period · correction opened (Q22: says which period it corrects)', { subject: 'gst_period', recordId: gp }, [
        { table: 'gst_periods', op: 'INSERT', key: { id: gp }, new: { code: 'GST-2026-Q3-C1', period_start: '2026-07-01', period_end: '2026-09-30', status: 'open', corrects_period_id: orig, notes: 'Late supplier invoice' },
          refs: ref('corrects_period_id', orig, 'GST-2026-Q3') }])
    add('GST period · return sent for approval (child: the filing request)', { subject: 'gst_period', recordId: gp }, [
        { table: 'gst_filing_requests', op: 'INSERT', key: { id: gfr }, new: { status: 'submitted', label: 'GST-2026-Q3 · filing #1', period_id: gp, note: 'Ready to file', boxes: [{ box: 'box1' }] } }])
    const boxRow = (n, en, v) => ({ table: 'gst_return_boxes', op: 'INSERT', new: { period_id: gp, box: 'box' + n, label_en: en, label_zh: '中文标签', value_base: v } })
    add('GST period · return approved, the boxes locked (Q23: one entry, English only)', { subject: 'gst_period', recordId: gp }, [
        { table: 'gst_filing_requests', op: 'UPDATE', key: { id: gfr }, cols: ['status', 'decided_at', 'decided_by', 'executed_at'], old: { status: 'submitted' }, new: { status: 'approved' }, ctx: { label: 'GST-2026-Q3 · filing #1' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'gst_filing_request', subject_id: gfr, decision: 'approved', level: 1 } },
        { table: 'gst_periods', op: 'UPDATE', key: { id: gp }, cols: ['status'], old: { status: 'open' }, new: { status: 'approved' } },
        boxRow(6, 'Output tax due', 70), boxRow(1, 'Total value of standard-rated supplies', 1000), boxRow(13, 'Revenue for the accounting period', 1000)])
    add('GST period · filing recorded (key event)', { subject: 'gst_period', recordId: gp }, [
        { table: 'gst_periods', op: 'UPDATE', key: { id: gp }, cols: ['status', 'filed_at', 'filed_by', 'filed_on', 'filed_reference'], old: { status: 'approved' }, new: { status: 'filed', filed_at: '2026-10-05T02:00:00Z', filed_on: '2026-10-05', filed_reference: 'IRAS-ACK-778' } }])
    add('GST period · notes edited (field edit)', { subject: 'gst_period', recordId: gp }, [
        { table: 'gst_periods', op: 'UPDATE', key: { id: gp }, cols: ['notes'], old: { notes: null }, new: { notes: 'Checked by auditor' } }])
    // ── FX rate ──
    const fx = id('fx')
    add('FX rate · recorded (one event, two rows: the rate and its history)', { subject: 'fx_rate', recordId: fx }, [
        { table: 'fx_rates', op: 'INSERT', key: { id: fx }, new: { currency: 'USD', rate_type: 'tt_sell', rate_sgd_per_unit: 1.3521, rate_date: '2026-10-01', source: 'DBS' } },
        { table: 'fx_rate_history', op: 'INSERT', new: { fx_rate_id: fx, action: 'created', currency: 'USD', rate_type: 'tt_sell', rate_sgd_per_unit: 1.3521, rate_date: '2026-10-01', source: 'DBS' } }])
    add('FX rate · corrected (field edit, the reason from the history row)', { subject: 'fx_rate', recordId: fx }, [
        { table: 'fx_rates', op: 'UPDATE', key: { id: fx }, cols: ['rate_sgd_per_unit', 'updated_at', 'updated_by'], old: { rate_sgd_per_unit: 1.3521 }, new: { rate_sgd_per_unit: 1.3512 } },
        { table: 'fx_rate_history', op: 'INSERT', new: { fx_rate_id: fx, action: 'corrected', prev_rate: 1.3521, rate_sgd_per_unit: 1.3512, reason: 'Typed the buy rate' } }])
    add('FX rate · withdrawn (key event)', { subject: 'fx_rate', recordId: fx }, [
        { table: 'fx_rates', op: 'UPDATE', key: { id: fx }, cols: ['deleted_at', 'updated_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-03T04:00:00Z' } },
        { table: 'fx_rate_history', op: 'INSERT', new: { fx_rate_id: fx, action: 'withdrawn', reason: 'Bank holiday — no rate published' } }])
    add('FX rate · corrected before the log (the history row speaks)', { subject: 'fx_rate', recordId: fx }, [
        { table: 'fx_rate_history', op: 'INSERT', prelog: true, new: { fx_rate_id: fx, action: 'corrected', prev_rate: 1.36, rate_sgd_per_unit: 1.35, reason: 'Wrong day' } }])
    // ── management pack ──
    const pk = id('pk'), pk2 = id('pk2')
    add('management pack · produced (key event)', { subject: 'management_pack', recordId: pk }, [
        { table: 'management_packs', op: 'INSERT', key: { id: pk }, new: { code: 'PACK-2026-0001', period_month: '2026-09-01', period_start: '2026-09-01', period_end: '2026-09-30', locked_before_at_production: '2026-09-30', base_currency: 'SGD', payload: { a: 1 } } }])
    add('management pack · replaced (the newer pack is a link)', { subject: 'management_pack', recordId: pk }, [
        { table: 'management_packs', op: 'UPDATE', key: { id: pk }, cols: ['superseded_at', 'superseded_by', 'superseded_reason'], old: { superseded_at: null },
          new: { superseded_at: '2026-10-04T01:00:00Z', superseded_by: pk2, superseded_reason: 'Late accrual posted' }, refs: ref('superseded_by', pk2, 'PACK-2026-0002', `/finance/packs/${pk2}`) }])
    add('management pack · notes edited (field edit)', { subject: 'management_pack', recordId: pk }, [
        { table: 'management_packs', op: 'UPDATE', key: { id: pk }, cols: ['notes'], old: { notes: null }, new: { notes: 'Sent to the board' } }])
    // ── contract ──
    const con = id('con'), sup = id('sup'), tr = id('tr'), po = id('po')
    add('contract · created (key event)', { subject: 'contract', recordId: con }, [
        { table: 'contracts', op: 'INSERT', key: { id: con }, new: { code: 'CON-2026-0004', supplier_id: sup, side: 'buy', kind: 'supply', title: '2027 black mass supply', status: 'draft', effective_from: '2027-01-01', currency: 'USD', incoterm: 'CIF' }, refs: ref('supplier_id', sup, 'Green Cells Ltd') }])
    add('contract · title changed (field edit)', { subject: 'contract', recordId: con }, [
        { table: 'contracts', op: 'UPDATE', key: { id: con }, cols: ['title', 'updated_at', 'updated_by'], old: { title: '2027 black mass supply' }, new: { title: '2027 black mass supply (revised)' } }])
    add('contract · an index pricing term added (child line)', { subject: 'contract', recordId: con }, [
        { table: 'contract_pricing_terms', op: 'INSERT', new: { contract_id: con, metal: 'ni', base_event: 'arrival', qp_months: 1, index_code: 'LME', payable_pct: 75 }, refs: { ...ref('metal', 'ni', 'Nickel'), ...ref('index_code', 'LME', 'London Metal Exchange') } }])
    add('contract · activated (the CFO approved the activation request; one operation)', { subject: 'contract', recordId: con }, [
        { table: 'terms_requests', op: 'UPDATE', key: { id: tr }, cols: ['status', 'decided_at', 'decided_by', 'executed_at'], old: { status: 'submitted' }, new: { status: 'approved' }, ctx: { kind: 'contract_activate', label: 'CON-2026-0004 · activate #1' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'terms_request', subject_id: tr, decision: 'approved', level: 2 } },
        { table: 'contracts', op: 'UPDATE', key: { id: con }, cols: ['status'], old: { status: 'draft' }, new: { status: 'active' } }])
    add('contract · activation sent to the CFO', { subject: 'contract', recordId: con }, [
        { table: 'terms_requests', op: 'INSERT', key: { id: tr }, new: { kind: 'contract_activate', status: 'submitted', label: 'CON-2026-0004 · activate #1', contract_id: con, reason: 'Signed on 28/09' } }])
    add('contract · linked to a purchase order', { subject: 'contract', recordId: con }, [
        { table: 'contract_document_terms', op: 'INSERT', new: { contract_id: con, purchase_order_id: po, contract_title: '2027 black mass supply' }, refs: ref('purchase_order_id', po, 'PO-2026-0015') }])
    // ── 1c-1 gap: field edits on payment requests and credit notes (+ payments, invoices) ──
    const pr = id('pr'), cn = id('cn'), pay = id('pay'), inv2 = id('inv2')
    add('payment request · planned date changed (field edit)', { subject: 'payment_request', recordId: pr }, [
        { table: 'payment_requests', op: 'UPDATE', key: { id: pr }, cols: ['planned_date'], old: { planned_date: '2026-10-01' }, new: { planned_date: '2026-10-05' }, ctx: { code: 'PREQ-2026-0005', kind: 'payment_out', status: 'submitted' } }])
    add('credit note · reason changed (field edit)', { subject: 'credit_note', recordId: cn }, [
        { table: 'credit_notes', op: 'UPDATE', key: { id: cn }, cols: ['reason'], old: { reason: 'Price' }, new: { reason: 'Price adjustment agreed on 01/10' }, ctx: { code: 'CN-2026-0003' } }])
    add('payment · notes changed (field edit)', { subject: 'payment', recordId: pay }, [
        { table: 'payments', op: 'UPDATE', key: { id: pay }, cols: ['notes'], old: { notes: null }, new: { notes: 'Bank slip attached' }, ctx: { code: 'PMT-2026-0012', direction: 'out' } }])
    add('invoice · notes changed (field edit)', { subject: 'invoice', recordId: inv2 }, [
        { table: 'invoices', op: 'UPDATE', key: { id: inv2 }, cols: ['notes'], old: { notes: null }, new: { notes: 'Customer PO 4471' }, ctx: { code: 'INV-2026-0012' } }])
    return C
}
    const WANT = {
        "sale · recorded (key event; the stock issue is the same operation)": {
                "title": "Sale recorded",
                "part": null,
                "lines": [
                        "Output batch: OUT-2026-0186 · NMC Cathode Foil",
                        "Customer: Acme Recycling",
                        "Sale date: 01/10/2026",
                        "Quantity: 200 kg",
                        "Unit price: 4.50 SGD",
                        "Currency: SGD",
                        "FX rate: 1",
                        "Amount (base currency): 900.00 SGD",
                        "Price source: Entered by hand"
                ],
                "reason": "Spot sale"
        },
        "sale · invoiced (child line: the invoice line that bills it)": {
                "title": "Invoiced · INV-2026-0010",
                "part": null,
                "lines": [
                        "Quantity: 200",
                        "Amount: 900.00 SGD"
                ],
                "reason": null
        },
        "sale · customer attributed (field edit, with the attribution note)": {
                "title": "Customer attributed to the sale",
                "part": null,
                "lines": [
                        "Customer: Acme Recycling"
                ],
                "reason": "Was a walk-in sale"
        },
        "sale · cost of sales posted": {
                "title": "Cost of sales posted",
                "part": null,
                "lines": [
                        "Cost-of-sales journal: JE-2026-0101"
                ],
                "reason": null
        },
        "freight · recorded with its apportionment (key event + child lines)": {
                "title": "Freight document recorded",
                "part": null,
                "lines": [
                        "Date: 01/10/2026",
                        "Forwarder: Swift Forwarding",
                        "Direction: Inbound — freight on material we bought",
                        "Amount: 300.00 SGD",
                        "Currency: SGD",
                        "FX rate: 1",
                        "Amount (base currency): 300.00 SGD",
                        "Apportionment: By weight",
                        "Payment: Unpaid (payable)",
                        "IN-2026-0020 · Black mass: 200.00 SGD",
                        "IN-2026-0021 · Black mass: 100.00 SGD"
                ],
                "reason": "Port to yard"
        },
        "freight · payment status (field edit)": {
                "title": "Freight document changed",
                "part": null,
                "lines": [
                        "Payment: Unpaid (payable) → Paid"
                ],
                "reason": null
        },
        "freight · reversed (key event; the reversal journal is the journal block)": {
                "title": "Freight document reversed",
                "part": null,
                "lines": [
                        "[Journal JE-2026-0110 reversed]",
                        "Reversed by: JE-2026-0111"
                ],
                "reason": "Billed twice"
        },
        "fixed asset · card created (key event)": {
                "title": "Asset card created",
                "part": null,
                "lines": [
                        "Description: Shredder",
                        "Category: Equipment",
                        "Acquisition date: 01/09/2026",
                        "Cost (transaction currency): 0.00 SGD",
                        "Currency: SGD",
                        "Cost (base currency): 0.00 SGD",
                        "Useful life (months): 60",
                        "Residual value (base currency): 0.00 SGD"
                ],
                "reason": null
        },
        "fixed asset · useful life changed (field edit)": {
                "title": "Asset card edited",
                "part": null,
                "lines": [
                        "Useful life (months): 60 → 84"
                ],
                "reason": null
        },
        "fixed asset · cost added from an expense (child line)": {
                "title": "Cost added · EXP-2026-0040",
                "part": null,
                "lines": [
                        "Amount: 12,000.00 SGD",
                        "Amount (base currency): 12,000.00 SGD",
                        "[Asset card edited]",
                        "Cost (base currency): 0.00 SGD → 12,000.00 SGD",
                        "Cost (transaction currency): 0.00 SGD → 12,000.00 SGD"
                ],
                "reason": null
        },
        "fixed asset · put into service (key event)": {
                "title": "Put into service",
                "part": null,
                "lines": [
                        "In service from: (empty) → 01/10/2026"
                ],
                "reason": null
        },
        "fixed asset · depreciation posted": {
                "title": "Depreciation posted",
                "part": null,
                "lines": [
                        "Period end: 31/10/2026",
                        "Amount (base currency): 200.00 SGD",
                        "Journal: JE-2026-0120"
                ],
                "reason": null
        },
        "fixed asset · disposal approved and carried out (request + approval + the card, one operation)": {
                "title": "Asset disposed",
                "part": null,
                "lines": [
                        "Disposal date: (empty) → 03/10/2026",
                        "Disposal proceeds (base currency): (empty) → 500.00 SGD",
                        "[Disposal approved · FA-2026-0003 · disposal #1]"
                ],
                "reason": null
        },
        "fixed asset · a change before the log (from the history row)": {
                "title": "Asset card edited",
                "part": null,
                "lines": [
                        "Useful life (months): 60 → 48",
                        "Notes: (empty) → Heavy use"
                ],
                "reason": null
        },
        "bank statement · imported (key event; its lines counted)": {
                "title": "Bank statement imported",
                "part": null,
                "lines": [
                        "Account: Cash at Bank – SGD",
                        "Currency: SGD",
                        "Period start: 01/09/2026",
                        "Period end: 30/09/2026",
                        "Opening balance: 1,000.00 SGD",
                        "Closing balance: 1,500.00 SGD",
                        "Source file: dbs-sep.csv",
                        "Lines: 3"
                ],
                "reason": null
        },
        "bank statement · a line matched (child line)": {
                "title": "Statement line matched · Line 1",
                "part": null,
                "lines": [
                        "JE-2026-0090 · Cash at Bank – SGD: 300.00 SGD"
                ],
                "reason": null
        },
        "bank statement · a line ignored": {
                "title": "Statement line ignored · Line 3",
                "part": null,
                "lines": [],
                "reason": "Bank rounding"
        },
        "bank statement · reconciled (key event, with the explained difference)": {
                "title": "Bank statement reconciled",
                "part": null,
                "lines": [
                        "As at: 30/09/2026",
                        "Bank closing balance: 1,500.00 SGD",
                        "Book balance: 1,499.50 SGD",
                        "Difference: 0.50 SGD",
                        "Matched lines: 2",
                        "Ignored lines: 1",
                        "Bank charge not yet booked: 0.50 SGD · September fee"
                ],
                "reason": null
        },
        "bank statement · reconciliation undone (Q24: the machine suffix in the notes is not a notes edit)": {
                "title": "Reconciliation undone",
                "part": null,
                "lines": [],
                "reason": "Wrong period"
        },
        "bank statement · notes edited (field edit)": {
                "title": "Bank statement changed",
                "part": null,
                "lines": [
                        "Notes: (empty) → Re-imported"
                ],
                "reason": null
        },
        "bank statement · deleted before the log (date only)": {
                "title": "Bank statement deleted",
                "part": null,
                "lines": [],
                "reason": null
        },
        "GST period · correction opened (Q22: says which period it corrects)": {
                "title": "Correction opened for GST-2026-Q3",
                "part": null,
                "lines": [
                        "Period start: 01/07/2026",
                        "Period end: 30/09/2026"
                ],
                "reason": "Late supplier invoice"
        },
        "GST period · return sent for approval (child: the filing request)": {
                "title": "GST return sent for approval",
                "part": "GST-2026-Q3 · filing #1",
                "lines": [],
                "reason": "Ready to file"
        },
        "GST period · return approved, the boxes locked (Q23: one entry, English only)": {
                "title": "GST return approved",
                "part": "GST-2026-Q3 · filing #1",
                "lines": [
                        "[GST return locked · 3 boxes]",
                        "Box 1 · Total value of standard-rated supplies: 1,000.00 SGD",
                        "Box 6 · Output tax due: 70.00 SGD",
                        "Box 13 · Revenue for the accounting period: 1,000.00 SGD"
                ],
                "reason": null
        },
        "GST period · filing recorded (key event)": {
                "title": "GST return filed",
                "part": null,
                "lines": [
                        "Filed on: 05/10/2026",
                        "IRAS acknowledgement: IRAS-ACK-778"
                ],
                "reason": null
        },
        "GST period · notes edited (field edit)": {
                "title": "GST period changed",
                "part": null,
                "lines": [
                        "Notes: (empty) → Checked by auditor"
                ],
                "reason": null
        },
        "FX rate · recorded (one event, two rows: the rate and its history)": {
                "title": "Exchange rate recorded",
                "part": null,
                "lines": [
                        "Currency: USD",
                        "Side: TT sell (bank sells the foreign currency)",
                        "Rate (base currency per unit): 1.3521",
                        "Rate date: 01/10/2026",
                        "Source: DBS"
                ],
                "reason": null
        },
        "FX rate · corrected (field edit, the reason from the history row)": {
                "title": "Exchange rate corrected",
                "part": null,
                "lines": [
                        "Rate (base currency per unit): 1.3521 → 1.3512"
                ],
                "reason": "Typed the buy rate"
        },
        "FX rate · withdrawn (key event)": {
                "title": "Exchange rate withdrawn",
                "part": null,
                "lines": [],
                "reason": "Bank holiday — no rate published"
        },
        "FX rate · corrected before the log (the history row speaks)": {
                "title": "Exchange rate corrected",
                "part": null,
                "lines": [
                        "Rate (base currency per unit): 1.36 → 1.35"
                ],
                "reason": "Wrong day"
        },
        "management pack · produced (key event)": {
                "title": "Management pack produced",
                "part": null,
                "lines": [
                        "Month: 01/09/2026",
                        "Period start: 01/09/2026",
                        "Period end: 30/09/2026",
                        "Locked before (at production): 30/09/2026",
                        "Base currency: SGD"
                ],
                "reason": null
        },
        "management pack · replaced (the newer pack is a link)": {
                "title": "Management pack replaced",
                "part": null,
                "lines": [
                        "Replaced by: PACK-2026-0002"
                ],
                "reason": "Late accrual posted"
        },
        "management pack · notes edited (field edit)": {
                "title": "Management pack changed",
                "part": null,
                "lines": [
                        "Notes: (empty) → Sent to the board"
                ],
                "reason": null
        },
        "contract · created (key event)": {
                "title": "Contract created",
                "part": null,
                "lines": [
                        "Supplier: Green Cells Ltd",
                        "Side: Buy",
                        "Kind: Supply",
                        "Title: 2027 black mass supply",
                        "Status: Draft",
                        "In force from: 01/01/2027",
                        "Currency: USD",
                        "Incoterm: CIF"
                ],
                "reason": null
        },
        "contract · title changed (field edit)": {
                "title": "Contract changed",
                "part": null,
                "lines": [
                        "Title: 2027 black mass supply → 2027 black mass supply (revised)"
                ],
                "reason": null
        },
        "contract · an index pricing term added (child line)": {
                "title": "Index pricing term added",
                "part": "Nickel",
                "lines": [
                        "Base month from: Arrival",
                        "Quotational period (M+n): 1",
                        "Index: London Metal Exchange",
                        "Payable %: 75"
                ],
                "reason": null
        },
        "contract · activated (the CFO approved the activation request; one operation)": {
                "title": "Contract activated",
                "part": null,
                "lines": [
                        "[CFO approved the terms · CON-2026-0004 · activate #1]"
                ],
                "reason": null
        },
        "contract · activation sent to the CFO": {
                "title": "Contract activation sent to the CFO",
                "part": "CON-2026-0004 · activate #1",
                "lines": [],
                "reason": "Signed on 28/09"
        },
        "contract · linked to a purchase order": {
                "title": "Linked to PO-2026-0015",
                "part": null,
                "lines": [],
                "reason": null
        },
        "payment request · planned date changed (field edit)": {
                "title": "Request changed · PREQ-2026-0005",
                "part": null,
                "lines": [
                        "Planned payment date: 01/10/2026 → 05/10/2026"
                ],
                "reason": null
        },
        "credit note · reason changed (field edit)": {
                "title": "Credit note changed",
                "part": null,
                "lines": [
                        "Reason: Price → Price adjustment agreed on 01/10"
                ],
                "reason": null
        },
        "payment · notes changed (field edit)": {
                "title": "Payment changed · PMT-2026-0012",
                "part": null,
                "lines": [
                        "Notes: (empty) → Bank slip attached"
                ],
                "reason": null
        },
        "invoice · notes changed (field edit)": {
                "title": "Invoice changed",
                "part": null,
                "lines": [
                        "Notes: (empty) → Customer PO 4471"
                ],
                "reason": null
        },
        "bank statement · reconciled and undone in one operation (a column that comes back is not a change)": {
                "title": "Bank statement reconciled",
                "part": null,
                "lines": [
                        "As at: 30/09/2026",
                        "Bank closing balance: 1,500.00 SGD",
                        "Book balance: 1,500.00 SGD",
                        "Difference: 0.00 SGD",
                        "Matched lines: 3",
                        "Ignored lines: 0",
                        "[Reconciliation undone]"
                ],
                "reason": "Wrong period"
        }
    }
    const C9 = cases()
    if (C9.length !== Object.keys(WANT).length || C9.length < 40) problems.gold9.push(`⑨ 造了 ${C9.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    const got9 = {}
    for (const c of C9) {
        const rows = c.rows.map((r) => ({ group: 'GOLD9', order: 1, prelog: false, at: '2026-10-03T02:00:00+00:00', key: { id: uuid() },
            actor: { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: 'SGD', ...c.opts }) } catch (err) { problems.gold9.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        if (es.length !== 1) { problems.gold9.push(`${c.label}:一次操作应当是一条,造出了 ${es.length} 条`); continue }
        const e = es[0]
        got9[c.label] = e
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null }
        const w = WANT[c.label]
        if (!w) { problems.gold9.push(`${c.label}:金句表里没有这一句`); continue }
        if (got.title !== w.title) problems.gold9.push(`${c.label}:标题「${got.title}」≠「${w.title}」`)
        if (got.part !== w.part) problems.gold9.push(`${c.label}:标题后那一段「${got.part}」≠「${w.part}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold9.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
        if (got.reason !== w.reason) problems.gold9.push(`${c.label}:理由「${got.reason}」≠「${w.reason}」`)
    }
    // 链接:成本分录、取代它的那一份包是点得过去的单据(路径来自 trail_ref_label 的 href,界面不拼路由)
    const hrefOf = (label, i = 0) => { const l = got9[label]?.lines?.[i]; return l && l.t === 'value' ? l.value.href : undefined }
    if (!hrefOf('sale · cost of sales posted')?.startsWith('/finance/journal/')) problems.gold9.push('sale · cost of sales posted:成本分录那一行不是链接')
    if (!hrefOf('management pack · replaced (the newer pack is a link)')?.startsWith('/finance/packs/')) problems.gold9.push('management pack · replaced:取代它的那一份不是链接')
    // Q23:申报那一条里一个中文字都没有(label_zh 是机器写的中文)
    const gst = got9['GST period · return approved, the boxes locked (Q23: one entry, English only)']
    if (gst && /[\u3400-\u9fff]/.test(JSON.stringify(gst))) problems.gold9.push('GST · Q23:申报那一条里出现了中文(label_zh 上了屏)')

    // 机器字扫描:八个新主语各自的表,按【这一页】的说法(subject)造样本跑一遍 —— ④ 的通用扫描不带 subject,走不到 describeLedger2
    const SUBS9 = ['sale', 'freight', 'fixed_asset', 'bank_statement', 'gst_period', 'fx_rate', 'management_pack', 'contract']
    let fin9 = 0
    for (const sub of SUBS9) {
        for (const t of R.SUBJECT_TABLES[sub] ?? []) {
            const cols = Object.entries(SAMPLE_KINDS[t] ?? {})
            for (let variant = 0; variant < 4; variant++) {
                const img = {}, old = {}, neu = {}
                for (const [c, [, kind]] of cols) {
                    img[c] = sample(t, c, kind, variant)
                    old[c] = variant === 2 ? RESTRICTED : variant === 3 ? null : sample(t, c, kind, variant + 1)
                    neu[c] = variant === 1 ? RESTRICTED : sample(t, c, kind, variant + 2)
                }
                const refs = { ...refsFor(t, img, variant), ...refsFor(t, old, variant + 1), ...refsFor(t, neu, variant + 2) }
                for (const [op, o] of [['INSERT', { new: img, prelog: variant === 3 }], ['UPDATE', { cols: cols.map(([c]) => c), old, new: neu, ctx: img }], ['DELETE', { old: img }]]) {
                    sweep(`${sub} · ${t} · ${op} · 样本 ${variant}`, [row(t, op, { ...o, refs })], sub)
                    fin9++
                }
            }
        }
        // 申请的每一种状态(资产处置 · GST 申报 · 合同生效)与撤销对账的备注后缀,按这一页说一遍
        for (const st of ['submitted', 'approved', 'rejected', 'withdrawn']) {
            sweep(`${sub} · disposal → ${st}`, [row('asset_disposal_requests', 'UPDATE', { cols: ['status'], old: { status: 'submitted' }, new: { status: st }, ctx: { label: 'FA-2026-0001 · disposal #1' } })], sub)
            sweep(`${sub} · GST filing → ${st}`, [row('gst_filing_requests', 'UPDATE', { cols: ['status'], old: { status: 'submitted' }, new: { status: st }, ctx: { label: 'GST-2026-Q3 · filing #1' } })], sub)
            sweep(`${sub} · contract activation → ${st}`, [row('terms_requests', 'UPDATE', { cols: ['status'], old: { status: 'submitted' }, new: { status: st }, ctx: { kind: 'contract_activate', label: 'CON-2026-0001 · activate #1' } })], sub)
            fin9 += 3
        }
        sweep(`${sub} · unreconcile suffix`, [row('bank_statements', 'UPDATE', { cols: ['status', 'notes'], old: { status: 'reconciled', notes: null }, new: { status: 'open', notes: 'UNRECONCILED 2026-10-04 09:00:00.1+08: why' } })], sub)
        sweep(`${sub} 整条看不见`, [row(R.SUBJECT_TABLES[sub][0], null, { hidden: true, table: null, actor: null })], sub)
        fin9 += 2
    }
    // 应当造的句数由登记表算出来(每张表 4 个样本 × 3 种操作 · 每个主语 12 次申请状态 + 1 句备注后缀 + 1 句整条看不见)
    const fin9Want = SUBS9.reduce((n, sub) => n + (R.SUBJECT_TABLES[sub] ?? []).length * 12 + 14, 0)
    if (fin9 !== fin9Want || fin9 < 500) problems.coverage.push(`其余单据那八页的机器字扫描造了 ${fin9} 句,登记表要求 ${fin9Want} 句 —— 造样本那一段瞎了`)
    if (FAULT === 'wording-drift-1c2' && !problems.gold9.length) problems.gold9.push('(注入 wording-drift-1c2 没有咬人 —— 这一臂瞎了)')
}

// ── ⑤ 覆盖 ──────────────────────────────────────────────────────────────────
const expectTables = Object.keys(C.TRAIL_FIELDS).length + 1
if (tablesSwept.size !== expectTables) problems.coverage.push(`扫过 ${tablesSwept.size} 张表,目录里有 ${expectTables} 张`)
if (scanned < 20000) problems.coverage.push(`只扫了 ${scanned} 句(下限 20,000)—— 造样本那一段悄悄少造了`)

// ── 报告 ────────────────────────────────────────────────────────────────────
const NAMES = { ruler: '① 尺', registry: '② 登记表一致', catalogue: '③ 措辞目录完整', tokens: '④ 机器字', coverage: '⑤ 覆盖', gold: '⑥ 商务样例', gold3: '⑦ 主数据样例', gold8: '⑧ 账上的单据', gold9: '⑨ 其余的单据与合同' }
let exit = 0
for (const [k, list] of Object.entries(problems)) {
    if (!list.length) { console.log(`✓ check-trail-wording ${NAMES[k]}`); continue }
    console.error(`✗ check-trail-wording ${NAMES[k]}:${list.length} 处`)
    for (const p of list.slice(0, 25)) console.error('   ' + p)
    if (list.length > 25) console.error(`   …另有 ${list.length - 25} 处`)
    exit = Math.max(exit, k === 'ruler' || k === 'coverage' ? 3 : 1)
}
console.log(`   (${subjects.length} 个主语 ${subjectTables.length} 张表 · ${subjectCols} 列;扫过 ${tablesSwept.size} 张表、${scanned} 句;措辞键 ${Object.keys(text).length} 个)`)
if (FAULT) console.log(`   ★ 故障注入:${FAULT}`)
process.exit(exit)
