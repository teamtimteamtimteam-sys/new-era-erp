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
//   ⑪ 账号、设置与员工(AUDIT-TRAIL-1d-1):十二个主语与角色页上的授权,同一个办法(停用失败并成一句 · 授权两边说 ·
//      员工页上账号事件 Restricted · 入职一条 · 履历里系统写的说明 · 匿名化 · 审批方针只说它那四列)外加按那一页的机器字扫描。
//   ⑫ 请假与考勤(AUDIT-TRAIL-1d-2):九个主语与费用页上的医疗报销(Q37),同一个办法(请假的决定与审批、扣减并成一句 · 之前那一对戳
//      按状态说 · "Overtime sent back" 且审批人那一格里系统追加的中文被剥掉 · 一次结转一条 · 硬删的假期 · 考勤完成一句、之前只剩最近一次)
//      外加按那一页的机器字扫描(每一种审批决定、每一种加班状态)。
//   ⑬ 工资与评审(AUDIT-TRAIL-1d-3):六个主语与员工页上评审定的调薪,同一个办法(工资行按员工配对 · 撤销那一行备注是理由 ·
//      审批说明后面那一截中英两段剥掉 · label 里原样的种类不上屏 · 分录按结构认 · 年度评审以它的轮次开头 · 批准按评审自己的几列说结论 ·
//      审核人那一份里审批是 Restricted · KPI 一次生成是一条)外加按那一页的机器字扫描(两种审批的每一种决定、申请与评审的每一种状态)。
//   ⑭ U1-B 的工作流与泄漏:停机的作废与更正 · 采购单关闭 / 重开的理由 · 深度放电判断 · 工资分录冲销申请的金额 Restricted ·
//      医疗报销的批准理由 Restricted(报销单页与费用页)。
//   ⑩ 期末、设置与清单页(AUDIT-TRAIL-1c-3):同一个办法 —— 十二个主语的金句(两块面板各看各的列 · 月结 / 反结 · 年结 ·
//      Q16 的合并 · Q30 · M8 的报销人)外加按【那一页】的机器字扫描(describeLedger3)。
//
// 故障注入(TRAIL_WORDING_FAULT=<臂>,每一臂必须在【它那一臂】红):
//   blind-detector · registry-drift · missing-key · dead-key · label-gap · enum-gap · raw-date · raw-ref · raw-json · raw-null · raw-role ·
//   wording-drift(AUDIT-TRAIL-1b-2:⑥ 商务样例 —— 改一句措辞,逐字比对必须红)·
//   wording-drift-1b3(AUDIT-TRAIL-1b-3:⑦ 主数据样例 —— 同上)· wording-drift-1c1(⑧)· wording-drift-1c2(AUDIT-TRAIL-1c-2:⑨)·
//   wording-drift-1c3(AUDIT-TRAIL-1c-3:⑩)· wording-drift-1d1(AUDIT-TRAIL-1d-1:⑪)· wording-drift-1d2(AUDIT-TRAIL-1d-2:⑫)·
//   wording-drift-1d3(AUDIT-TRAIL-1d-3:⑬)· wording-drift-u1b(U1-B:⑭)· wording-drift-mes1(MES-1:⑮)· wording-drift-mes2(MES-2:⑯)
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
const CM = await imp('lib/currencyMap.ts')
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
// AUDIT-TRAIL-1c-3:M8 的主语没有页面码 —— ARRAY[]::text[](空数组要写类型);M7 的成员没有外键 —— NULL 与 'all'。
//   两种写法都要认:漏认一个主语,下面"55 ≠ 56"那一句会当场红(实测:第一次跑就是这么红的)。
// AUDIT-TRAIL-1d-1:M9 的根表带 schema('auth.users'),M11 的规则是 'collection',M12 的规则是 'gate:<名字>' —— 三种都认
const subjects = [...subjectSrc.matchAll(/\('([a-z_]+)',\s*ARRAY\[([^\]]*)\](?:::text\[\])?,\s*'([a-z_.]+)',\s*'([a-z_]+)',\s*'([a-z:]+)'/g)]
    .map((m) => ({ subject: m[1], views: [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]), root: m[3], rule: m[5] }))
const memberSrc = read('db/functions/trail_subject_members.sql').replace(/--[^\n]*/g, '')
const members = [...memberSrc.matchAll(/\('([a-z_]+)',\s*(\d+),\s*'([a-z_.]+)',\s*'([a-z_.]+)',\s*(?:'([a-z_]+)'|NULL),\s*'[^']*'::jsonb,\s*'(up|down|all)',\s*(true|false),\s*(true|false)\)/g)]
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
// AUDIT-TRAIL-1d-1(M9):只在变更记录里出现的表(auth.users)没有 db/tables 镜像 —— 它的"列"就是登记表里那一份安全投影
const logOnlySrc = read('db/functions/trail_log_only_tables.sql').replace(/--[^\n]*/g, '')
const LOG_ONLY = Object.fromEntries([...logOnlySrc.matchAll(/\('([a-z_.]+)',\s*'[a-z_]+',\s*'[a-z_]+',\s*ARRAY\[([^\]]*)\]/g)]
    .map((m) => [m[1], [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1])]))
if (!LOG_ONLY['auth.users']?.length) problems.registry.push('trail_log_only_tables.sql 里读不出 auth.users 的安全投影 —— 解析器瞎了')
for (const t of subjectTables) {
    const cols = LOG_ONLY[t] ?? mirrorColumns(t)
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
    bankCurrency: CM.currencyOfBank,
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
    // U1-A(Tim 的 UNBLOCK-1 Q1,2026-10-05):一张工资分录,读的人不持 data.view_pay —— 每一行的金额是受限标记(debit 与 credit 两列都被遮)。
    //   每一行说 Restricted;此前 journalLineLine 把它印成 "Credit 0.00 SGD"(imgOf 丢掉受限值,再 ?? 0)。
    const pj = id('pj')
    G('journal · a payroll journal read without data.view_pay (U1-A Q1: Restricted, never 0.00)', { subject: 'journal_entry', recordId: pj }, [
        { table: 'journal_entries', op: 'INSERT', key: { id: pj }, new: { code: 'JE-2026-0095', entry_date: '2026-10-28', source_type: 'payroll', memo: 'Salary payment PAY-2026-0010', status: 'posted' } },
        { table: 'journal_lines', op: 'INSERT', new: { entry_id: pj, account_id: 'a3', debit: RESTRICTED, credit: RESTRICTED, currency: 'SGD', amount_ccy: RESTRICTED, line_memo: 'Salary run PAY-2026-0010' }, refs: acct('a3', 'Accrued salaries') },
        { table: 'journal_lines', op: 'INSERT', new: { entry_id: pj, account_id: 'a4', debit: RESTRICTED, credit: RESTRICTED, currency: 'SGD', amount_ccy: RESTRICTED, line_memo: 'EMP-2026-0007 Lim Wei Ming' }, refs: acct('a4', 'Cash at Bank – SGD') }],
      { title: 'Payroll journal posted · JE-2026-0095',
        lines: ['Entry date: 28/10/2026', 'Source: Payroll', 'Memo: Salary payment PAY-2026-0010', 'Accrued salaries: Restricted', 'Cash at Bank – SGD: Restricted'] })
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

// ── ⑩ 期末、设置与清单页上的记录(AUDIT-TRAIL-1c-3)───────────────────────────────────────────────────
// 十二个主语(锁期 · GST · 公司资料 · 年结 · 人工分录申请 · 报销单与报销人自己 · 转账 · 代扣税缴纳 · 现金预测与常设行 · 导入映射)
//   各一次字段编辑与关键事件,逐字;加上:两块面板各看各的列(M6 —— 读法那一层挡;这里证造句器按【变的那一列】说)、锁期那一段
//   说出月结与反结(M7)、年结那一块、清单块把一次操作碰到的几条记录并成一条(Q16:批量汇率 · 冻结预测并作废旧的一张)、缴纳的冲销
//   说成 "WHT remittance reversed"(Q30)、报销人自己读到的审批留痕是 Restricted(M8 · Q4)、分录页上按来源说出批次分录是什么
//   (重估 · 折旧连带每一张资产的那一行)。每一句都先由造句器造出来、逐句人工核过,再钉在这里 —— 交回报告
//   docs/handbacks/AUDIT-TRAIL-1c-3.md §8 逐条列出。注入 wording-drift-1c3 → 这一臂必须红。
problems.gold10 = []
if (FAULT === 'wording-drift-1c3') dict.text = { ...dict.text, 'plock.monthClosed': 'Period closed up to {date}' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const ref = (col, v, label, href) => ({ [col]: { [v]: href ? { label, href } : { label } } })
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows) => C.push({ label, opts, rows })
    const fs = { id: true }
    // ── 锁期(finance_lock):M6 已经只留下 locked_before;M7 把 period_closes 整张带进来 ──
    add('lock · moved on the settings page (key event)', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: '2026-08-01' }, new: { locked_before: '2026-09-01' } }])
    add('lock · set where there was none', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: null }, new: { locked_before: '2026-08-01' } }])
    add('lock · removed', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: '2026-08-01' }, new: { locked_before: null } }])
    const pc = id('pc')
    add('lock · month closed (the close row and the lock move are one operation)', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'period_closes', op: 'INSERT', key: { id: pc }, new: { period_end: '2026-08-31', entries_count: 82, total_debits: 125000, total_credits: 125000, notes: 'August books checked' } },
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: '2026-08-01' }, new: { locked_before: '2026-09-01' } }])
    add('lock · month reopened (from the first day of that month)', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'period_closes', op: 'UPDATE', key: { id: pc }, cols: ['reopened_at', 'reopened_by', 'reopen_reason'], old: { reopened_at: null, reopened_by: null, reopen_reason: null },
          new: { reopened_at: '2026-09-03T02:00:00Z', reopen_reason: 'Late supplier invoice' }, ctx: { period_end: '2026-08-31' } },
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: '2026-09-01' }, new: { locked_before: '2026-08-01' } }])
    add('lock · a month closed before the log (from the close row alone)', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'period_closes', op: 'INSERT', prelog: true, key: { id: id('pc0') }, new: { period_end: '2026-07-31', entries_count: 40, total_debits: 9000, total_credits: 9000, notes: null } }])
    // ── GST(finance_gst):M6 只留下注册开关与注册号 ──
    add('GST · registration switched on (key event)', { subject: 'finance_gst', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['gst_registered', 'gst_registration_no'], old: { gst_registered: false, gst_registration_no: null },
          new: { gst_registered: true, gst_registration_no: 'M90312345A' } }])
    add('GST · registration number corrected (field edit)', { subject: 'finance_gst', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['gst_registration_no'], old: { gst_registration_no: 'M90312345A' }, new: { gst_registration_no: 'M90312345B' } }])
    add('GST · registration switched off', { subject: 'finance_gst', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['gst_registered'], old: { gst_registered: true }, new: { gst_registered: false } }])
    // ── 公司资料 ──
    add('company profile · address changed (field edit)', { subject: 'company_profile', recordId: 'true' }, [
        { table: 'company_profile', op: 'UPDATE', key: fs, cols: ['address_lines', 'postal_code'], old: { address_lines: '1 Tuas Ave', postal_code: '639001' }, new: { address_lines: '8 Tuas South Link', postal_code: '637645' } }])
    add('company profile · bank account changed, read without data.view_banking (Restricted)', { subject: 'company_profile', recordId: 'true' }, [
        { table: 'company_profile', op: 'UPDATE', key: fs, cols: ['bank_account_no'], old: { bank_account_no: RESTRICTED }, new: { bank_account_no: RESTRICTED } }])
    // ── 年结 ──
    const yc = id('yc'), cje = id('cje'), rje = id('rje')
    add('year close · closed (key event; the closing journal is a line)', { subject: 'year_close', recordId: yc }, [
        { table: 'year_closes', op: 'INSERT', key: { id: yc }, new: { year_end: '2026-12-31', closing_journal_id: cje, net_result: 48250.5, notes: 'FY2026' },
          refs: ref('closing_journal_id', cje, 'JE-2026-0200', `/finance/journal/${cje}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: cje }, new: { code: 'JE-2026-0200', source_type: 'year_close', status: 'posted' } }])
    add('year close · reopened (the reversal journal is a line)', { subject: 'year_close', recordId: yc }, [
        { table: 'year_closes', op: 'UPDATE', key: { id: yc }, cols: ['reopened_at', 'reopened_by', 'reopen_reason', 'reversal_journal_id'],
          old: { reopened_at: null, reversal_journal_id: null }, new: { reopened_at: '2027-01-10T02:00:00Z', reopen_reason: 'Audit adjustment', reversal_journal_id: rje },
          ctx: { year_end: '2026-12-31' }, refs: ref('reversal_journal_id', rje, 'JE-2027-0004', `/finance/journal/${rje}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: rje }, new: { code: 'JE-2027-0004', source_type: 'year_close', status: 'posted' } }])
    // ── 人工分录申请(Q17)──
    const jr = id('jr'), jje = id('jje')
    add('journal request · new manual journal sent for approval (key event)', { subject: 'journal_request', recordId: jr }, [
        { table: 'journal_requests', op: 'INSERT', key: { id: jr }, new: { kind: 'entry', status: 'submitted', label: 'manual journal #3', entry_date: '2026-10-02', amount_base: 1200, memo: 'Accrue October rent', credits_bank: false } }])
    add('journal request · approved and posted (the approval folds in; the posted journal is a block)', { subject: 'journal_request', recordId: jr }, [
        { table: 'journal_requests', op: 'UPDATE', key: { id: jr }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes', 'result_journal_entry_id'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'OK', result_journal_entry_id: jje }, ctx: { kind: 'entry', label: 'manual journal #3' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'journal_request', subject_id: jr, decision: 'approved', level: 2 } },
        { table: 'journal_entries', op: 'INSERT', key: { id: jje }, new: { code: 'JE-2026-0150', source_type: 'manual', status: 'posted' } }])
    add('journal request · withdrawn', { subject: 'journal_request', recordId: jr }, [
        { table: 'journal_requests', op: 'UPDATE', key: { id: jr }, cols: ['status', 'withdrawn_at', 'withdrawn_by', 'withdraw_reason'], old: { status: 'submitted' },
          new: { status: 'withdrawn', withdraw_reason: 'Wrong month' }, ctx: { kind: 'entry', label: 'manual journal #3' } }])
    // ── 报销单(Q20)与报销人自己(M8)──
    const cl = id('cl'), cexp = id('cexp'), emp = id('emp')
    add('expense claim · submitted (key event)', { subject: 'expense_claim', recordId: cl }, [
        { table: 'expense_claims', op: 'INSERT', key: { id: cl }, new: { code: 'CLM-2026-0005', employee_id: emp, spend_date: '2026-10-01', amount_ccy: 86.4, currency: 'SGD', description: 'Taxi to the port', status: 'submitted' },
          refs: ref('employee_id', emp, 'Chooer') }])
    add('expense claim · approved, its expense recorded in the same operation', { subject: 'expense_claim', recordId: cl }, [
        { table: 'expense_claims', op: 'UPDATE', key: { id: cl }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes', 'expense_id', 'account_code', 'tax_code', 'posting_date'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Receipt attached', expense_id: cexp }, ctx: { code: 'CLM-2026-0005' } },
        { table: 'approval_log', op: 'INSERT', new: { subject_type: 'expense_claim', subject_id: cl, decision: 'approved', level: 1 } },
        { table: 'expenses', op: 'INSERT', key: { id: cexp }, new: { code: 'EXP-2026-0030', amount_ccy: 86.4, currency: 'SGD' } }])
    add('expense claim · the claimant on /me: the decision row is Restricted (M8 · Q4)', { subject: 'my_expense_claim', recordId: cl }, [
        { table: 'expense_claims', op: 'UPDATE', key: { id: cl }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes', 'expense_id'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Receipt attached', expense_id: cexp }, ctx: { code: 'CLM-2026-0005' } },
        { table: null, op: null, hidden: true, actor: null },
        { table: null, op: null, hidden: true, actor: null }])
    add('expense claim · description corrected (field edit)', { subject: 'expense_claim', recordId: cl }, [
        { table: 'expense_claims', op: 'UPDATE', key: { id: cl }, cols: ['description'], old: { description: 'Taxi' }, new: { description: 'Taxi to the port' }, ctx: { code: 'CLM-2026-0005' } }])
    // ── 行内转账 ──
    const bt = id('bt'), btj = id('btj'), btr = id('btr')
    add('bank transfer · made (key event)', { subject: 'bank_transfer', recordId: bt }, [
        { table: 'bank_transfers', op: 'INSERT', key: { id: bt }, new: { transfer_date: '2026-10-02', from_account: '1000', to_account: '1010', amount_out: 1350, amount_in: 1000, bank_reference: 'DBS 7781', journal_entry_id: btj } },
        { table: 'journal_entries', op: 'INSERT', key: { id: btj }, new: { code: 'JE-2026-0151', source_type: 'transfer', status: 'posted' } }])
    add('bank transfer · reversed', { subject: 'bank_transfer', recordId: bt }, [
        { table: 'bank_transfers', op: 'UPDATE', key: { id: bt }, cols: ['reversed_at', 'reversed_by', 'reversal_entry_id'], old: { reversed_at: null }, new: { reversed_at: '2026-10-03T02:00:00Z', reversal_entry_id: btr },
          refs: ref('reversal_entry_id', btr, 'JE-2026-0152', `/finance/journal/${btr}`) }])
    add('bank transfer · bank reference corrected (field edit)', { subject: 'bank_transfer', recordId: bt }, [
        { table: 'bank_transfers', op: 'UPDATE', key: { id: bt }, cols: ['bank_reference'], old: { bank_reference: 'DBS 7781' }, new: { bank_reference: 'DBS 7787' } }])
    // ── 代扣税缴纳(Q30)──
    const wr = id('wr'), wj = id('wj'), wrj = id('wrj'), wpr = id('wpr')
    add('WHT remittance · remitted (key event)', { subject: 'wht_remittance', recordId: wr }, [
        { table: 'wht_remittances', op: 'INSERT', key: { id: wr }, new: { code: 'WHT-2026-0002', period_month: '2026-09-01', amount_base: 340, remitted_on: '2026-10-02', filed_reference: 'IRAS 55120', journal_entry_id: wj } },
        { table: 'journal_entries', op: 'INSERT', key: { id: wj }, new: { code: 'JE-2026-0160', source_type: 'wht_remittance', status: 'posted' } }])
    add('WHT remittance · reversed through its request (Q30: one sentence, the reversal journal a line)', { subject: 'wht_remittance', recordId: wr }, [
        { table: 'payment_requests', op: 'UPDATE', key: { id: wpr }, cols: ['status', 'paid_at', 'paid_by', 'result_journal_entry_id'], old: { status: 'approved' },
          new: { status: 'paid', result_journal_entry_id: wrj }, ctx: { kind: 'wht_remittance_reversal', code: 'PREQ-2026-0009' }, refs: ref('result_journal_entry_id', wrj, 'JE-2026-0161', `/finance/journal/${wrj}`) },
        { table: 'journal_entries', op: 'UPDATE', key: { id: wj }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null }, new: { status: 'reversed', reversed_by: wrj },
          ctx: { code: 'JE-2026-0160', reversed_by: wrj }, refs: ref('reversed_by', wrj, 'JE-2026-0161', `/finance/journal/${wrj}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: wrj }, new: { code: 'JE-2026-0161', memo: 'REVERSAL: JE-2026-0160 — Filed against the wrong month', status: 'posted' } }])
    add('WHT remittance · reversed with no request (before PAY-REQ-1)', { subject: 'wht_remittance', recordId: wr }, [
        { table: 'journal_entries', op: 'UPDATE', key: { id: wj }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null }, new: { status: 'reversed', reversed_by: wrj },
          ctx: { code: 'JE-2026-0160', reversed_by: wrj }, refs: ref('reversed_by', wrj, 'JE-2026-0161', `/finance/journal/${wrj}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: wrj }, new: { code: 'JE-2026-0161', memo: 'REVERSAL: JE-2026-0160 — Filed against the wrong month', status: 'posted' } }])
    // ── 现金预测(Q16:冻结一张新的、作废旧的一张是一次操作)与常设行 ──
    const f1 = id('f1'), f2 = id('f2'), fl = id('fl')
    add('cash forecast · frozen, replacing the earlier one (Q16: one operation, two records)', { subject: 'cash_forecast', recordId: f2 }, [
        { table: 'cash_forecasts', op: 'INSERT', key: { id: f2 }, new: { code: 'FCST-2026-0002', week_start: '2026-10-05', horizon_weeks: 13, base_currency: 'SGD' } },
        { table: 'cash_forecasts', op: 'UPDATE', key: { id: f1 }, cols: ['superseded_at', 'superseded_by', 'superseded_reason'], old: { superseded_at: null, superseded_by: null },
          new: { superseded_at: '2026-10-05T02:00:00Z', superseded_by: f2, superseded_reason: 'Customer paid early' }, ctx: { code: 'FCST-2026-0001' }, refs: ref('superseded_by', f2, 'FCST-2026-0002') }])
    add('recurring line · added (key event)', { subject: 'cash_forecast_line', recordId: fl }, [
        { table: 'cash_forecast_lines', op: 'INSERT', key: { id: fl }, new: { label: 'Office rent', direction: 'out', amount_ccy: 4200, currency: 'SGD', cadence: 'monthly', start_date: '2026-10-01', end_date: null, is_active: true } }])
    add('recurring line · amount changed (field edit)', { subject: 'cash_forecast_line', recordId: fl }, [
        { table: 'cash_forecast_lines', op: 'UPDATE', key: { id: fl }, cols: ['amount_ccy', 'updated_at', 'updated_by'], old: { amount_ccy: 4200 }, new: { amount_ccy: 4400 }, ctx: { label: 'Office rent', currency: 'SGD' } }])
    add('recurring line · switched off', { subject: 'cash_forecast_line', recordId: fl }, [
        { table: 'cash_forecast_lines', op: 'UPDATE', key: { id: fl }, cols: ['is_active'], old: { is_active: true }, new: { is_active: false }, ctx: { label: 'Office rent' } }])
    // ── 导入映射 ──
    const bp = id('bp')
    add('import mapping · saved (key event)', { subject: 'bank_import_profile', recordId: bp }, [
        { table: 'bank_import_profiles', op: 'INSERT', key: { id: bp }, new: { name: 'DBS business CSV', bank_account_code: '1000', mapping: { date: 0, amount: 3 } } }])
    add('import mapping · renamed (field edit)', { subject: 'bank_import_profile', recordId: bp }, [
        { table: 'bank_import_profiles', op: 'UPDATE', key: { id: bp }, cols: ['name', 'updated_at', 'updated_by'], old: { name: 'DBS CSV' }, new: { name: 'DBS business CSV' }, ctx: { name: 'DBS business CSV' } }])
    add('import mapping · deleted', { subject: 'bank_import_profile', recordId: bp }, [
        { table: 'bank_import_profiles', op: 'UPDATE', key: { id: bp }, cols: ['deleted_at', 'updated_at', 'updated_by'], old: { deleted_at: null }, new: { deleted_at: '2026-10-04T02:00:00Z' }, ctx: { name: 'DBS business CSV' } }])
    // ── 批量汇率(Q16:fx_rate 清单块把一次批量录入的几条并成一条)──
    add('FX · a bulk save of three rates (Q16: one entry)', { subject: 'fx_rate', recordId: id('fx1') }, [
        { table: 'fx_rates', op: 'INSERT', key: { id: id('fx1') }, new: { currency: 'USD', rate_type: 'tt_sell', rate_sgd_per_unit: 1.3521, rate_date: '2026-10-02', source: 'DBS' } },
        { table: 'fx_rates', op: 'INSERT', key: { id: id('fx2') }, new: { currency: 'USD', rate_type: 'tt_buy', rate_sgd_per_unit: 1.3388, rate_date: '2026-10-02', source: 'DBS' } },
        { table: 'fx_rates', op: 'INSERT', key: { id: id('fx3') }, new: { currency: 'USD', rate_type: 'mid', rate_sgd_per_unit: 1.3455, rate_date: '2026-10-02', source: 'DBS' } }])
    // ── 分录页与它的清单块:按来源说出批次分录是什么 ──
    const dj = id('dj'), a1 = id('a1'), a2 = id('a2'), rv = id('rv')
    add('journal · a depreciation run on its own page (each asset a line)', { subject: 'journal_entry', recordId: dj }, [
        { table: 'journal_entries', op: 'INSERT', key: { id: dj }, new: { code: 'JE-2026-0170', entry_date: '2026-10-31', source_type: 'depreciation', status: 'posted' } },
        { table: 'fixed_asset_depreciation', op: 'INSERT', new: { asset_id: a1, period_end: '2026-10-31', amount_base: 200, journal_entry_id: dj }, refs: ref('asset_id', a1, 'FA-2026-0001') },
        { table: 'fixed_asset_depreciation', op: 'INSERT', new: { asset_id: a2, period_end: '2026-10-31', amount_base: 75.5, journal_entry_id: dj }, refs: ref('asset_id', a2, 'FA-2026-0002') }])
    add('journal · an FX revaluation run on its own page', { subject: 'journal_entry', recordId: rv }, [
        { table: 'journal_entries', op: 'INSERT', key: { id: rv }, new: { code: 'JE-2026-0171', entry_date: '2026-10-31', source_type: 'revaluation', memo: 'Month-end revaluation', status: 'posted' } }])
    // ── 一次操作里的几件事(线上的回滚证明一笔事务做完全程才看见的三处;Tim 的规矩:没有改动就不说,删除不吞掉同一笔的改动)──
    add('lock · moved forward and back in one operation (nets to nothing: no entry, never "Restricted")', { subject: 'finance_lock', recordId: 'true' }, [
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: '2026-08-01' }, new: { locked_before: '2026-09-01' } },
        { table: 'finance_settings', op: 'UPDATE', key: fs, cols: ['locked_before'], old: { locked_before: '2026-09-01' }, new: { locked_before: '2026-08-01' } }])
    add('WHT remittance · remitted and reversed in one operation (the creation keeps its own sentence)', { subject: 'wht_remittance', recordId: wr }, [
        { table: 'wht_remittances', op: 'INSERT', key: { id: wr }, new: { code: 'WHT-2026-0002', period_month: '2026-09-01', amount_base: 340, remitted_on: '2026-10-02', journal_entry_id: wj } },
        { table: 'journal_entries', op: 'INSERT', key: { id: wj }, new: { code: 'JE-2026-0160', source_type: 'wht_remittance', status: 'posted' } },
        { table: 'journal_entries', op: 'UPDATE', key: { id: wj }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null }, new: { status: 'reversed', reversed_by: wrj },
          ctx: { code: 'JE-2026-0160', reversed_by: wrj }, refs: ref('reversed_by', wrj, 'JE-2026-0161', `/finance/journal/${wrj}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: wrj }, new: { code: 'JE-2026-0161', memo: 'REVERSAL: JE-2026-0160 — Filed against the wrong month', status: 'posted' } }])
    add('import mapping · renamed and deleted in one operation (the deletion keeps the rename)', { subject: 'bank_import_profile', recordId: bp }, [
        { table: 'bank_import_profiles', op: 'UPDATE', key: { id: bp }, cols: ['name'], old: { name: 'DBS CSV' }, new: { name: 'DBS business CSV' }, ctx: { name: 'DBS business CSV' } },
        { table: 'bank_import_profiles', op: 'UPDATE', key: { id: bp }, cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-04T02:00:00Z' }, ctx: { name: 'DBS business CSV' } }])
    const WANT = {
        "lock · moved forward and back in one operation (nets to nothing: no entry, never \"Restricted\")": { none: true },
        "WHT remittance · remitted and reversed in one operation (the creation keeps its own sentence)": {
        "title": "WHT remittance reversed",
        "part": null,
        "lines": [
                "Reversed by: JE-2026-0161",
                "[WHT remitted · WHT-2026-0002]",
                "Withholding month: 01/09/2026",
                "Amount: 340.00 SGD",
                "Paid on: 02/10/2026",
                "[Journal posted · JE-2026-0160]"
        ],
        "reason": "Filed against the wrong month"
        },
        "import mapping · renamed and deleted in one operation (the deletion keeps the rename)": {
        "title": "Import mapping deleted",
        "part": "DBS business CSV",
        "lines": [
                "Mapping name: DBS CSV → DBS business CSV"
        ],
        "reason": null
        },
        "lock · moved on the settings page (key event)": {
                "title": "Period lock moved",
                "part": null,
                "lines": [
                        "Period locked before: 01/08/2026 → 01/09/2026"
                ],
                "reason": null
        },
        "lock · set where there was none": {
                "title": "Period lock set",
                "part": null,
                "lines": [
                        "Period locked before: (empty) → 01/08/2026"
                ],
                "reason": null
        },
        "lock · removed": {
                "title": "Period lock removed",
                "part": null,
                "lines": [
                        "Period locked before: 01/08/2026 → (empty)"
                ],
                "reason": null
        },
        "lock · month closed (the close row and the lock move are one operation)": {
                "title": "Month closed up to 31/08/2026",
                "part": null,
                "lines": [
                        "Period locked before: 01/08/2026 → 01/09/2026",
                        "Entries: 82",
                        "Total debits: 125,000.00 SGD",
                        "Total credits: 125,000.00 SGD"
                ],
                "reason": "August books checked"
        },
        "lock · month reopened (from the first day of that month)": {
                "title": "Month reopened from 01/08/2026",
                "part": null,
                "lines": [
                        "Period locked before: 01/09/2026 → 01/08/2026"
                ],
                "reason": "Late supplier invoice"
        },
        "lock · a month closed before the log (from the close row alone)": {
                "title": "Month closed up to 31/07/2026",
                "part": null,
                "lines": [
                        "Entries: 40",
                        "Total debits: 9,000.00 SGD",
                        "Total credits: 9,000.00 SGD"
                ],
                "reason": null
        },
        "GST · registration switched on (key event)": {
                "title": "GST registration switched on",
                "part": null,
                "lines": [
                        "Registered for GST: No → Yes",
                        "GST registration number: (empty) → M90312345A"
                ],
                "reason": null
        },
        "GST · registration number corrected (field edit)": {
                "title": "GST settings changed",
                "part": null,
                "lines": [
                        "GST registration number: M90312345A → M90312345B"
                ],
                "reason": null
        },
        "GST · registration switched off": {
                "title": "GST registration switched off",
                "part": null,
                "lines": [
                        "Registered for GST: Yes → No"
                ],
                "reason": null
        },
        "company profile · address changed (field edit)": {
                "title": "Company profile changed",
                "part": null,
                "lines": [
                        "Address: 1 Tuas Ave → 8 Tuas South Link"
                ],
                "reason": null
        },
        "company profile · bank account changed, read without data.view_banking (Restricted)": {
                "title": "Company profile changed",
                "part": null,
                "lines": [
                        "Bank account number: Restricted → Restricted"
                ],
                "reason": null
        },
        "year close · closed (key event; the closing journal is a line)": {
                "title": "Year closed up to 31/12/2026",
                "part": null,
                "lines": [
                        "Net result: 48,250.50 SGD",
                        "Closing journal: JE-2026-0200"
                ],
                "reason": "FY2026"
        },
        "year close · reopened (the reversal journal is a line)": {
                "title": "Year reopened · year ending 31/12/2026",
                "part": null,
                "lines": [
                        "Reversal journal: JE-2027-0004"
                ],
                "reason": "Audit adjustment"
        },
        "journal request · new manual journal sent for approval (key event)": {
                "title": "Manual journal sent for approval",
                "part": "manual journal #3",
                "lines": [
                        "Entry date: 02/10/2026",
                        "Amount (sum of debits): 1,200.00 SGD",
                        "Memo: Accrue October rent"
                ],
                "reason": null
        },
        "journal request · approved and posted (the approval folds in; the posted journal is a block)": {
                "title": "Manual journal approved",
                "part": "manual journal #3",
                "lines": [
                        "[Journal posted · JE-2026-0150]"
                ],
                "reason": "OK"
        },
        "journal request · withdrawn": {
                "title": "Manual journal request withdrawn",
                "part": "manual journal #3",
                "lines": [],
                "reason": "Wrong month"
        },
        "expense claim · submitted (key event)": {
                "title": "Expense claim submitted · CLM-2026-0005",
                "part": null,
                "lines": [
                        "Employee: Chooer",
                        "Spend date: 01/10/2026",
                        "Amount: 86.40 SGD"
                ],
                "reason": "Taxi to the port"
        },
        "expense claim · approved, its expense recorded in the same operation": {
                "title": "Expense claim approved · CLM-2026-0005",
                "part": null,
                "lines": [
                        "[Expense recorded · EXP-2026-0030]",
                        "Amount: 86.40 SGD"
                ],
                "reason": "Receipt attached"
        },
        "expense claim · the claimant on /me: the decision row is Restricted (M8 · Q4)": {
                "title": "Expense claim approved · CLM-2026-0005",
                "part": null,
                "lines": [
                        "(Part of this change is restricted.)"
                ],
                "reason": "Receipt attached"
        },
        "expense claim · description corrected (field edit)": {
                "title": "Expense claim changed · CLM-2026-0005",
                "part": null,
                "lines": [
                        "Description: Taxi → Taxi to the port"
                ],
                "reason": null
        },
        "bank transfer · made (key event)": {
                "title": "Bank transfer made",
                "part": null,
                "lines": [
                        "Transfer date: 02/10/2026",
                        "From account: Cash at Bank – SGD",
                        "To account: Cash at Bank – USD",
                        "Amount out (source currency): 1,350.00 SGD",
                        "Amount in (destination currency): 1,000.00 USD",
                        "Bank reference: DBS 7781",
                        "[Journal posted · JE-2026-0151]"
                ],
                "reason": null
        },
        "bank transfer · reversed": {
                "title": "Bank transfer reversed",
                "part": null,
                "lines": [
                        "Reversal journal: JE-2026-0152"
                ],
                "reason": null
        },
        "bank transfer · bank reference corrected (field edit)": {
                "title": "Bank transfer changed",
                "part": null,
                "lines": [
                        "Bank reference: DBS 7781 → DBS 7787"
                ],
                "reason": null
        },
        "WHT remittance · remitted (key event)": {
                "title": "WHT remitted · WHT-2026-0002",
                "part": null,
                "lines": [
                        "Withholding month: 01/09/2026",
                        "Amount: 340.00 SGD",
                        "Paid on: 02/10/2026",
                        "IRAS filing reference: IRAS 55120",
                        "[Journal posted · JE-2026-0160]"
                ],
                "reason": null
        },
        "WHT remittance · reversed through its request (Q30: one sentence, the reversal journal a line)": {
                "title": "WHT remittance reversed · PREQ-2026-0009",
                "part": null,
                "lines": [
                        "Reversed by: JE-2026-0161"
                ],
                "reason": "Filed against the wrong month"
        },
        "WHT remittance · reversed with no request (before PAY-REQ-1)": {
                "title": "WHT remittance reversed",
                "part": null,
                "lines": [
                        "Reversed by: JE-2026-0161"
                ],
                "reason": "Filed against the wrong month"
        },
        "cash forecast · frozen, replacing the earlier one (Q16: one operation, two records)": {
                "title": "Cash forecast frozen · FCST-2026-0002",
                "part": null,
                "lines": [
                        "Week starting: 05/10/2026",
                        "Horizon (weeks): 13",
                        "Base currency: SGD",
                        "[Cash forecast replaced · FCST-2026-0001]",
                        "Replaced by: FCST-2026-0002"
                ],
                "reason": "Customer paid early"
        },
        "recurring line · added (key event)": {
                "title": "Recurring line added",
                "part": "Office rent",
                "lines": [
                        "Direction: Money out",
                        "Amount: 4,200.00 SGD",
                        "How often: Monthly",
                        "First occurrence: 01/10/2026"
                ],
                "reason": null
        },
        "recurring line · amount changed (field edit)": {
                "title": "Recurring line changed",
                "part": "Office rent",
                "lines": [
                        "Amount: 4,200.00 SGD → 4,400.00 SGD"
                ],
                "reason": null
        },
        "recurring line · switched off": {
                "title": "Recurring line switched off",
                "part": "Office rent",
                "lines": [],
                "reason": null
        },
        "import mapping · saved (key event)": {
                "title": "Import mapping saved",
                "part": "DBS business CSV",
                "lines": [
                        "Bank account: Cash at Bank – SGD",
                        "Column mapping: Details recorded"
                ],
                "reason": null
        },
        "import mapping · renamed (field edit)": {
                "title": "Import mapping changed",
                "part": "DBS business CSV",
                "lines": [
                        "Mapping name: DBS CSV → DBS business CSV"
                ],
                "reason": null
        },
        "import mapping · deleted": {
                "title": "Import mapping deleted",
                "part": "DBS business CSV",
                "lines": [],
                "reason": null
        },
        "FX · a bulk save of three rates (Q16: one entry)": {
                "title": "Exchange rates recorded · 3 rates",
                "part": null,
                "lines": [
                        "USD · TT selling rate · 02/10/2026: 1.3521",
                        "USD · TT buying rate · 02/10/2026: 1.3388",
                        "USD · Mid rate · 02/10/2026: 1.3455"
                ],
                "reason": null
        },
        "journal · a depreciation run on its own page (each asset a line)": {
                "title": "Depreciation posted · JE-2026-0170",
                "part": null,
                "lines": [
                        "Entry date: 31/10/2026",
                        "Source: Depreciation",
                        "FA-2026-0001: 200.00 SGD",
                        "FA-2026-0002: 75.50 SGD"
                ],
                "reason": null
        },
        "journal · an FX revaluation run on its own page": {
                "title": "FX revaluation posted · JE-2026-0171",
                "part": null,
                "lines": [
                        "Entry date: 31/10/2026",
                        "Source: FX revaluation",
                        "Memo: Month-end revaluation"
                ],
                "reason": null
        }
    }
    const got10 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 38) problems.gold10.push(`⑩ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD10', order: 1, prelog: false, at: '2026-10-03T02:00:00+00:00', key: { id: uuid() },
            actor: { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        // ★ 不带单据币种:这几个根(设置那一行、公司资料、年结、预测……)没有币种列,AuditTrail 取不到;ListTrail 根本不给 ——
        //   第一版在这里塞了 'SGD',于是"月结合计没有币种"那一处缺陷金句看不见,是线上的回滚证明读出来的
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold10.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        const w = WANT[c.label]
        if (w && w.none) { if (es.length) problems.gold10.push(`${c.label}:净值什么都没改,应当一条都不说,造出了「${es.map((x) => x.title).join(' | ')}」`); got10[c.label] = { got: { none: true } }; continue }
        if (es.length !== 1) { problems.gold10.push(`${c.label}:一次操作应当是一条,造出了 ${es.length} 条`); continue }
        const e = es[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null }
        got10[c.label] = { e, got }
        if (!w) { problems.gold10.push(`${c.label}:金句表里没有这一句`); continue }
        if (got.title !== w.title) problems.gold10.push(`${c.label}:标题「${got.title}」≠「${w.title}」`)
        if (got.part !== w.part) problems.gold10.push(`${c.label}:标题后那一段「${got.part}」≠「${w.part}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold10.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
        if (got.reason !== w.reason) problems.gold10.push(`${c.label}:理由「${got.reason}」≠「${w.reason}」`)
    }
    if (process.env.TRAIL_GOLD10_PRINT) console.log(JSON.stringify(Object.fromEntries(Object.entries(got10).map(([k, v]) => [k, v.got])), null, 8))
    // 链接:年结那一句里的结转分录、缴纳冲销那一句里的冲销分录是点得过去的单据
    const hrefOf = (label, text) => got10[label]?.e?.lines?.find((l) => l.t === 'value' && l.value.text === text)?.value?.href
    if (!hrefOf('year close · closed (key event; the closing journal is a line)', 'JE-2026-0200')?.startsWith('/finance/journal/')) problems.gold10.push('year close:结转分录那一行不是链接')
    if (!hrefOf('WHT remittance · reversed through its request (Q30: one sentence, the reversal journal a line)', 'JE-2026-0161')?.startsWith('/finance/journal/')) problems.gold10.push('WHT 冲销:冲销分录那一行不是链接')

    // Q16:清单块真的把一次操作碰到的几条记录并成一条(mergeByOperation —— 与 ListTrail 同一支)。冻结预测:新一张 + 旧一张;
    //   批量汇率:三条汇率各读回自己那一行,op_key 相同。两条记录各读一次、合起来必须是【一】条,Record 一栏列出碰到的几条
    {
        const opRow = (r) => ({ group: 'G', order: 1, prelog: false, at: '2026-10-05T02:00:00+00:00', key: { id: uuid() }, actor: { state: 'person', name: 'Sandra' },
            cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, opKey: 'L9001', ...r })
        const fc = C.find((c) => c.label.startsWith('cash forecast · frozen')).rows.map(opRow)
        const m1 = R.mergeByOperation(dict, [{ row: fc[0], rec: { subject: 'cash_forecast', id: f2, label: 'FCST-2026-0002 · week of 05/10/2026' } },
                                              { row: fc[1], rec: { subject: 'cash_forecast', id: f1, label: 'FCST-2026-0001 · week of 05/10/2026 (replaced)' } }])
        if (m1.length !== 1) problems.gold10.push(`Q16 预测:冻结 + 作废旧的一张应当是一条,并出了 ${m1.length} 条`)
        else if (!m1[0].recordText.includes('FCST-2026-0001') || !m1[0].recordText.includes('FCST-2026-0002')) problems.gold10.push(`Q16 预测:Record 一栏没有列出两张:${m1[0].recordText}`)
        const fx = C.find((c) => c.label.startsWith('FX · a bulk save')).rows.map(opRow)
        const m2 = R.mergeByOperation(dict, fx.map((row, i) => ({ row, rec: { subject: 'fx_rate', id: row.key.id, label: `rate ${i + 1}`, href: `/finance/fx/${row.key.id}/edit` } })))
        if (m2.length !== 1) problems.gold10.push(`Q16 批量汇率:三条应当并成一条,并出了 ${m2.length} 条`)
        else {
            if (m2[0].title !== 'Exchange rates recorded · 3 rates') problems.gold10.push(`Q16 批量汇率:标题「${m2[0].title}」`)
            if (m2[0].recordHref !== null) problems.gold10.push('Q16 批量汇率:一次操作碰到三条,Record 一栏不该只链到其中一条')
        }
        const one = R.mergeByOperation(dict, [{ row: fx[0], rec: { subject: 'fx_rate', id: fx[0].key.id, label: 'rate 1', href: '/finance/fx/x/edit' } }])
        if (one[0]?.recordHref !== '/finance/fx/x/edit') problems.gold10.push('清单块:只碰到一条、而它有自己的页时,Record 一栏应当是一个链接')
    }

    // 机器字扫描:十二个主语各自的表,按【这一页】的说法(subject)造样本跑一遍(④ 的通用扫描不带 subject,走不到 describeLedger3)
    const SUBS10 = ['finance_lock', 'finance_gst', 'company_profile', 'year_close', 'journal_request', 'expense_claim', 'my_expense_claim',
        'bank_transfer', 'wht_remittance', 'cash_forecast', 'cash_forecast_line', 'bank_import_profile']
    let fin10 = 0
    for (const sub of SUBS10) {
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
                    fin10++
                }
            }
        }
        // 关账 / 反结 / 挪锁 / 注册开关 / 年结与反结 / 预测被取代 / 常设行开关 / 映射删掉,按这一页说一遍
        sweep(`${sub} · month close`, [row('period_closes', 'INSERT', { new: { period_end: '2026-08-31', entries_count: 1, total_debits: 1, total_credits: 1 } }),
            row('finance_settings', 'UPDATE', { key: { id: true }, cols: ['locked_before'], old: { locked_before: '2026-08-01' }, new: { locked_before: '2026-09-01' } })], sub)
        sweep(`${sub} · month reopen`, [row('period_closes', 'UPDATE', { cols: ['reopened_at', 'reopen_reason'], old: { reopened_at: null }, new: { reopened_at: '2026-09-02T00:00:00Z', reopen_reason: 'why' }, ctx: { period_end: '2026-08-31' } })], sub)
        sweep(`${sub} · GST switch`, [row('finance_settings', 'UPDATE', { key: { id: true }, cols: ['gst_registered'], old: { gst_registered: false }, new: { gst_registered: true } })], sub)
        sweep(`${sub} · year reopen`, [row('year_closes', 'UPDATE', { cols: ['reopened_at', 'reversal_journal_id'], old: { reopened_at: null }, new: { reopened_at: '2027-01-02T00:00:00Z', reversal_journal_id: uuid() }, ctx: { year_end: '2026-12-31' } })], sub)
        sweep(`${sub} · forecast replaced`, [row('cash_forecasts', 'UPDATE', { cols: ['superseded_at', 'superseded_by'], old: { superseded_at: null }, new: { superseded_at: '2026-10-05T00:00:00Z', superseded_by: uuid() } })], sub)
        sweep(`${sub} · line switched off`, [row('cash_forecast_lines', 'UPDATE', { cols: ['is_active'], old: { is_active: true }, new: { is_active: false } })], sub)
        sweep(`${sub} · mapping deleted`, [row('bank_import_profiles', 'UPDATE', { cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-05T00:00:00Z' } })], sub)
        sweep(`${sub} 整条看不见`, [row(R.SUBJECT_TABLES[sub][0], null, { hidden: true, table: null, actor: null })], sub)
        fin10 += 8
    }
    // 应当造的句数由登记表算出来(每张表 4 个样本 × 3 种操作 · 每个主语 7 句关键事件 + 1 句整条看不见)
    const fin10Want = SUBS10.reduce((n, sub) => n + (R.SUBJECT_TABLES[sub] ?? []).length * 12 + 8, 0)
    if (fin10 !== fin10Want || fin10 < 300) problems.coverage.push(`期末与清单页那十二个主语的机器字扫描造了 ${fin10} 句,登记表要求 ${fin10Want} 句 —— 造样本那一段瞎了`)
    if (FAULT === 'wording-drift-1c3' && !problems.gold10.length) problems.gold10.push('(注入 wording-drift-1c3 没有咬人 —— 这一臂瞎了)')
}

// ── ⑪ 账号、设置与员工(AUDIT-TRAIL-1d-1)──────────────────────────────────────────────────────────
// 十二个主语(账号 · 审批方针 · 员工 · 部门 · 培训记录 · 导入批次 · 六本字典)与角色页上的授权,各一次字段编辑与关键事件,逐字;
//   加上:停用失败那一对并成一句(Q9)· 一次建立被回滚 · 授权从账号与从角色两边说(Q22)· 员工页上账号事件对人事读者是
//   Restricted(Q21)· 入职经 save_employee 是一条(Q8)· 履历里系统写的三种说明(Q10)· 匿名化只说一句、那个人读作
//   "A former employee"(Q30)· 审批方针只说它那四列(M6)且修改史与那一行设置是一件事(M7)。每一句都先由造句器造出来、
//   逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/AUDIT-TRAIL-1d-1.md §8 逐条列出。注入 wording-drift-1d1 → 这一臂必须红。
problems.gold11 = []
if (FAULT === 'wording-drift-1d1') dict.text = { ...dict.text, 'acct.grantedTo': 'Role given to {who}' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const ref = (col, v, label, href) => ({ [col]: { [v]: href ? { label, href } : { label } } })
    const person = (col, v, name) => ({ [col]: { [v]: { person: { state: 'person', name } } } })
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows) => C.push({ label, opts, rows })
    const acc = id('acc'), cfo = id('cfo'), emp = id('emp'), ur = id('ur')
    const A = { subject: 'account', recordId: acc }
    // ── 账号(M9)──
    add('account · created', A, [{ table: 'auth.users', op: 'ACCOUNT_CREATE', key: { id: acc }, new: { email: 'sandra@evoltrya.test', role_id: cfo } }])
    add('account · disabled', A, [{ table: 'auth.users', op: 'ACCOUNT_DISABLE', key: { id: acc }, new: { email: 'sandra@evoltrya.test' } }])
    add('account · disabling failed (Q9: the event and its failure are one line)', A, [
        { table: 'auth.users', op: 'ACCOUNT_DISABLE', key: { id: acc }, new: { email: 'sandra@evoltrya.test' }, group: 'GOLD11-A', at: '2026-10-03T01:59:58+00:00' },
        { table: 'auth.users', op: 'ACCOUNT_DISABLE_FAILED', key: { id: acc }, new: { email: 'sandra@evoltrya.test', error: 'timeout' } }])
    add('account · re-enabled', A, [{ table: 'auth.users', op: 'ACCOUNT_ENABLE', key: { id: acc }, new: { email: 'sandra@evoltrya.test' } }])
    add('account · a creation rolled back', A, [{ table: 'auth.users', op: 'ACCOUNT_DELETE', key: { id: acc }, new: { email: 'sandra@evoltrya.test', reason: 'create_rolled_back' } }])
    add('account · created before the log (Q12: from the account itself)', A, [
        { table: 'auth.users', op: 'INSERT', prelog: true, key: { id: acc }, new: { id: acc, email: 'sandra@evoltrya.test', created_at: '2026-09-01T02:00:00Z', banned_until: null } }])
    add('account · role granted (key event)', A, [
        { table: 'user_roles', op: 'INSERT', key: { id: ur }, new: { user_id: acc, role_id: cfo, granted_by: id('g') }, refs: { ...ref('role_id', cfo, 'CFO'), ...person('user_id', acc, 'Sandra') } }])
    add('account · role removed, with its reason', A, [
        { table: 'user_roles', op: 'UPDATE', key: { id: ur }, cols: ['revoked_at', 'revoked_by', 'revoke_reason'], old: { revoked_at: null, revoke_reason: null },
          new: { revoked_at: '2026-10-03T02:00:00Z', revoke_reason: 'Moved to sales' }, ctx: { user_id: acc, role_id: cfo },
          refs: { ...ref('role_id', cfo, 'CFO'), ...person('user_id', acc, 'Sandra') } }])
    add('account · additional login linked (the link and its history row are one event)', A, [
        { table: 'employee_accounts', op: 'INSERT', key: { user_id: acc }, new: { user_id: acc, employee_id: emp }, refs: person('employee_id', emp, 'Sandra Tan') },
        { table: 'employee_account_history', op: 'INSERT', key: { id: id('eah') }, new: { user_id: acc, employee_id: emp, action: 'linked' } }])
    add('account · additional login unlinked', A, [
        { table: 'employee_accounts', op: 'DELETE', key: { user_id: acc }, old: { user_id: acc, employee_id: emp }, refs: person('employee_id', emp, 'Sandra Tan') },
        { table: 'employee_account_history', op: 'INSERT', key: { id: id('eah2') }, new: { user_id: acc, employee_id: emp, action: 'unlinked' } }])
    add('account · login linked to an employee (M10: only user_id)', A, [
        { table: 'employees', op: 'UPDATE', key: { id: emp }, cols: ['user_id'], old: { user_id: null }, new: { user_id: acc }, ctx: { code: 'EMP-2026-0004' } }])
    add('account · login unlinked from an employee', A, [
        { table: 'employees', op: 'UPDATE', key: { id: emp }, cols: ['user_id'], old: { user_id: acc }, new: { user_id: null }, ctx: { code: 'EMP-2026-0004' } }])
    // ── 角色页:授给了谁(Q22)──
    const R1 = { subject: 'role', recordId: cfo }
    add('role · granted to an account', R1, [
        { table: 'user_roles', op: 'INSERT', key: { id: ur }, new: { user_id: acc, role_id: cfo }, refs: { ...ref('role_id', cfo, 'CFO'), ...person('user_id', acc, 'Sandra') } }])
    add('role · removed from an account', R1, [
        { table: 'user_roles', op: 'UPDATE', key: { id: ur }, cols: ['revoked_at', 'revoked_by', 'revoke_reason'], old: { revoked_at: null },
          new: { revoked_at: '2026-10-03T02:00:00Z', revoke_reason: 'Moved to sales' }, ctx: { user_id: acc, role_id: cfo },
          refs: { ...ref('role_id', cfo, 'CFO'), ...person('user_id', acc, 'Sandra') } }])
    // ── 员工(Q28)──
    const E = { subject: 'employee', recordId: emp }
    const dept = id('dept'), dept2 = id('dept2')
    add('employee · hired through one save (Q8: the employee and the hired row are one entry)', E, [
        { table: 'employees', op: 'INSERT', key: { id: emp }, new: { code: 'EMP-2026-0007', legal_name: 'Lim Wei Ming', first_name: 'Wei Ming', department_id: dept,
          employment_type: 'full_time', work_category: 'office', hire_date: '2026-10-01', employment_status: 'probation', is_site_staff: false },
          refs: ref('department_id', dept, 'Operations') },
        { table: 'employment_history', op: 'INSERT', key: { id: id('h1') }, new: { employee_id: emp, effective_date: '2026-10-01', change_type: 'hired',
          department_id: dept, employment_type: 'full_time', employment_status: 'probation' }, refs: ref('department_id', dept, 'Operations') }])
    add('employee · details changed (field edit; identity Restricted for a reader without data.view_identity)', E, [
        { table: 'employees', op: 'UPDATE', key: { id: emp }, cols: ['preferred_name', 'work_phone'], old: { preferred_name: null, work_phone: RESTRICTED },
          new: { preferred_name: 'Wei', work_phone: RESTRICTED } }])
    add('employee · transferred (the form\'s own summary note is not said — the lines say it)', E, [
        { table: 'employment_history', op: 'INSERT', key: { id: id('h2') }, new: { employee_id: emp, effective_date: '2026-11-01', change_type: 'transfer',
          department_id: dept2, employment_type: 'full_time', employment_status: 'active', notes: 'department: OPS → SALES' }, refs: ref('department_id', dept2, 'Sales') }])
    add('employee · confirmed through a review (Q10: the review note in English)', E, [
        { table: 'employment_history', op: 'INSERT', key: { id: id('h3') }, new: { employee_id: emp, effective_date: '2027-01-01', change_type: 'confirmed',
          employment_status: 'active', notes: `Probation confirmed by performance review ${id('rv')}` } }])
    add('employee · salary changed through a request (Q10: the request label)', E, [
        { table: 'employment_history', op: 'INSERT', key: { id: id('h4') }, new: { employee_id: emp, effective_date: '2027-02-01', change_type: 'salary_change',
          old_monthly_salary: 4200, new_monthly_salary: 4500, notes: 'Salary change approved with request EMP-2026-0007 · 2027-02' } }])
    add('employee · first salary set, read without data.view_pay (Restricted)', E, [
        { table: 'employment_history', op: 'INSERT', key: { id: id('h5') }, new: { employee_id: emp, effective_date: '2026-10-01', change_type: 'salary_change',
          old_monthly_salary: null, new_monthly_salary: RESTRICTED } }])
    const scr = id('scr')
    add('employee · salary change requested', E, [
        { table: 'salary_change_requests', op: 'INSERT', key: { id: scr }, new: { employee_id: emp, label: 'EMP-2026-0007 · 2027-02', status: 'submitted',
          old_monthly_salary: 4200, new_monthly_salary: 4500, effective_date: '2027-02-01', reason: 'Annual increment' } }])
    add('employee · salary change approved (the approval folds in)', E, [
        { table: 'salary_change_requests', op: 'UPDATE', key: { id: scr }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes', 'executed_at'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Agreed at review' } },
        { table: 'approval_log', op: 'INSERT', key: { id: id('al1') }, new: { subject_type: 'salary_change_request', subject_id: scr, decision: 'approved', level: 1, note: 'Agreed at review' } }])
    add('employee · salary change request withdrawn', E, [
        { table: 'salary_change_requests', op: 'UPDATE', key: { id: scr }, cols: ['status', 'withdrawn_at', 'withdrawn_by', 'withdraw_reason'],
          old: { status: 'submitted' }, new: { status: 'withdrawn', withdraw_reason: 'Raised by mistake' } }])
    add('employee · login account linked (on the employee page)', E, [
        { table: 'employees', op: 'UPDATE', key: { id: emp }, cols: ['user_id'], old: { user_id: null }, new: { user_id: acc } }])
    add('employee · deleted', E, [
        { table: 'employees', op: 'UPDATE', key: { id: emp }, cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-03T02:00:00Z' } }])
    add('employee · personal data anonymised (Q30: one sentence, the cleared values never said)', E, [
        { table: 'employees', op: 'UPDATE', key: { id: emp }, cols: ['anonymised_at', 'anonymised_by', 'legal_name', 'first_name', 'identity_no'],
          old: { anonymised_at: null, legal_name: null, first_name: null, identity_no: null }, new: { anonymised_at: '2026-10-03T02:00:00Z', legal_name: null, first_name: null, identity_no: null } },
        { table: 'employment_history', op: 'UPDATE', key: { id: id('h4') }, cols: ['old_monthly_salary', 'new_monthly_salary'], old: { old_monthly_salary: 4200, new_monthly_salary: 4500 },
          new: { old_monthly_salary: null, new_monthly_salary: null } }])
    add('employee · the account mirror for an HR reader (Q21: a grant visible, the account event Restricted)', E, [
        { table: 'user_roles', op: 'INSERT', key: { id: ur }, new: { user_id: acc, role_id: cfo }, refs: { ...ref('role_id', cfo, 'CFO'), ...person('user_id', acc, 'Sandra') } },
        { hidden: true, table: null, op: null, actor: null }])
    add('training · recorded', { subject: 'training_record', recordId: id('tr') }, [
        { table: 'training_records', op: 'INSERT', key: { id: id('tr') }, new: { employee_id: emp, training_name: 'Forklift safety', category: 'safety', completed_date: '2026-09-20',
          provider: 'SafeWorks' }, refs: person('employee_id', emp, 'Lim Wei Ming') }])
    add('training · deleted', { subject: 'training_record', recordId: id('tr') }, [
        { table: 'training_records', op: 'UPDATE', key: { id: id('tr') }, cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-03T02:00:00Z' }, ctx: { training_name: 'Forklift safety' } }])
    add('department · created', { subject: 'department', recordId: dept }, [
        { table: 'departments', op: 'INSERT', key: { id: dept }, new: { code: 'OPS', name_en: 'Operations', name_zh: '运营部', is_active: true } }])
    add('department · deactivated', { subject: 'department', recordId: dept }, [
        { table: 'departments', op: 'UPDATE', key: { id: dept }, cols: ['is_active'], old: { is_active: true }, new: { is_active: false }, ctx: { name_en: 'Operations' } }])
    add('department · deleted', { subject: 'department', recordId: dept }, [
        { table: 'departments', op: 'UPDATE', key: { id: dept }, cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-03T02:00:00Z' }, ctx: { name_en: 'Operations' } }])
    // ── 审批方针(M6 · M7)──
    const P = { subject: 'approval_policy', recordId: 'true' }
    add('approval policy · switched on (the settings row and its history row are one event)', P, [
        { table: 'finance_settings', op: 'UPDATE', key: { id: true }, cols: ['approvals_enabled', 'approval_level1_role_code', 'approval_threshold_base'],
          old: { approvals_enabled: false, approval_level1_role_code: null, approval_threshold_base: null },
          new: { approvals_enabled: true, approval_level1_role_code: 'finance', approval_threshold_base: 1000 },
          refs: ref('approval_level1_role_code', 'finance', 'Finance') },
        { table: 'finance_settings_history', op: 'INSERT', key: { id: id('fsh') }, new: { old_approvals_enabled: false, new_approvals_enabled: true } }])
    add('approval policy · switched on before the log (from its history row)', P, [
        { table: 'finance_settings_history', op: 'INSERT', prelog: true, key: { id: id('fsh0') }, new: { old_approvals_enabled: false, new_approvals_enabled: true,
          old_approval_level1_role_code: 'finance', new_approval_level1_role_code: 'finance', old_approval_level2_role_code: 'cfo', new_approval_level2_role_code: 'cfo',
          old_approval_threshold_base: 1000, new_approval_threshold_base: 1000 } }])
    add('approval policy · threshold changed', P, [
        { table: 'finance_settings', op: 'UPDATE', key: { id: true }, cols: ['approval_threshold_base'], old: { approval_threshold_base: 1000 }, new: { approval_threshold_base: 2500 } },
        { table: 'finance_settings_history', op: 'INSERT', key: { id: id('fsh2') }, new: { old_approval_threshold_base: 1000, new_approval_threshold_base: 2500 } }])
    add('approval policy · level-2 approver changed before the log (role names, not codes)', P, [
        { table: 'finance_settings_history', op: 'INSERT', prelog: true, key: { id: id('fsh3') }, new: { old_approvals_enabled: true, new_approvals_enabled: true,
          old_approval_level2_role_code: 'cfo', new_approval_level2_role_code: 'cco' },
          refs: { ...ref('old_approval_level2_role_code', 'cfo', 'CFO'), ...ref('new_approval_level2_role_code', 'cco', 'CCO') } }])
    // ── 字典(M11)· 导入批次 ──
    const K = { subject: 'dictionary_substances', recordId: 'all' }
    add('dictionary · a value added', K, [{ table: 'substances', op: 'INSERT', key: { code: 'CO' }, new: { code: 'CO', name_en: 'Cobalt', name_zh: '钴', symbol: 'Co', is_active: true } }])
    add('dictionary · a value deactivated', K, [{ table: 'substances', op: 'UPDATE', key: { code: 'CO' }, cols: ['is_active'], old: { is_active: true }, new: { is_active: false }, ctx: { name_en: 'Cobalt' } }])
    add('dictionary · a value renamed (field edit)', { subject: 'dictionary_laboratories', recordId: 'all' }, [
        { table: 'laboratories', op: 'UPDATE', key: { code: 'SGS' }, cols: ['name_en'], old: { name_en: 'SGS Singapore' }, new: { name_en: 'SGS Testing Singapore' } }])
    add('import · a batch of suppliers', { subject: 'import_batch', recordId: id('ib') }, [
        { table: 'import_batches', op: 'INSERT', key: { id: id('ib') }, new: { target_table: 'suppliers', file_name: 'suppliers-oct.csv', row_count: 2, code_first: 'SUP-2026-0018', code_last: 'SUP-2026-0019' } }])
    add('import · a single material', { subject: 'import_batch', recordId: id('ib2') }, [
        { table: 'import_batches', op: 'INSERT', key: { id: id('ib2') }, new: { target_table: 'materials', file_name: 'one.csv', row_count: 1, code_first: 'MAT-0042', code_last: 'MAT-0042' } }])

    const WANT = {
            "account · created": {
                    "title": "Account created",
                    "part": null,
                    "lines": [
                            "Email: sandra@evoltrya.test"
                    ],
                    "reason": null
            },
            "account · disabled": {
                    "title": "Account disabled",
                    "part": null,
                    "lines": [
                            "Email: sandra@evoltrya.test"
                    ],
                    "reason": null
            },
            "account · disabling failed (Q9: the event and its failure are one line)": {
                    "title": "Account could not be disabled",
                    "part": null,
                    "lines": [
                            "Email: sandra@evoltrya.test"
                    ],
                    "reason": null
            },
            "account · re-enabled": {
                    "title": "Account re-enabled",
                    "part": null,
                    "lines": [
                            "Email: sandra@evoltrya.test"
                    ],
                    "reason": null
            },
            "account · a creation rolled back": {
                    "title": "Account removed (it was never finished)",
                    "part": null,
                    "lines": [
                            "Email: sandra@evoltrya.test"
                    ],
                    "reason": null
            },
            "account · created before the log (Q12: from the account itself)": {
                    "title": "Account created",
                    "part": null,
                    "lines": [
                            "Email: sandra@evoltrya.test"
                    ],
                    "reason": null
            },
            "account · role granted (key event)": {
                    "title": "Role granted: CFO",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "account · role removed, with its reason": {
                    "title": "Role removed: CFO",
                    "part": null,
                    "lines": [],
                    "reason": "Moved to sales"
            },
            "account · additional login linked (the link and its history row are one event)": {
                    "title": "Additional login linked",
                    "part": null,
                    "lines": [
                            "Employee: Sandra Tan"
                    ],
                    "reason": null
            },
            "account · additional login unlinked": {
                    "title": "Additional login unlinked",
                    "part": null,
                    "lines": [
                            "Employee: Sandra Tan"
                    ],
                    "reason": null
            },
            "account · login linked to an employee (M10: only user_id)": {
                    "title": "Login linked to employee EMP-2026-0004",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "account · login unlinked from an employee": {
                    "title": "Login unlinked from employee EMP-2026-0004",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "role · granted to an account": {
                    "title": "Role granted to Sandra",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "role · removed from an account": {
                    "title": "Role removed from Sandra",
                    "part": null,
                    "lines": [],
                    "reason": "Moved to sales"
            },
            "employee · hired through one save (Q8: the employee and the hired row are one entry)": {
                    "title": "Employee added",
                    "part": null,
                    "lines": [
                            "Legal name: Lim Wei Ming",
                            "First name: Wei Ming",
                            "Department: Operations",
                            "Employment type: Full-time",
                            "Category: Office",
                            "Hire date: 01/10/2026",
                            "Employment status: On probation",
                            "Site staff: No",
                            "[Hired]",
                            "Effective date: 01/10/2026",
                            "Department: Operations",
                            "Employment type: Full-time",
                            "Employment status: On probation"
                    ],
                    "reason": null
            },
            "employee · details changed (field edit; identity Restricted for a reader without data.view_identity)": {
                    "title": "Employee details changed",
                    "part": null,
                    "lines": [
                            "Preferred name: (empty) → Wei",
                            "Work phone: Restricted → Restricted"
                    ],
                    "reason": null
            },
            "employee · transferred (the form's own summary note is not said — the lines say it)": {
                    "title": "Transferred",
                    "part": null,
                    "lines": [
                            "Effective date: 01/11/2026",
                            "Department: Sales",
                            "Employment type: Full-time",
                            "Employment status: Active"
                    ],
                    "reason": null
            },
            "employee · confirmed through a review (Q10: the review note in English)": {
                    "title": "Confirmed after probation",
                    "part": null,
                    "lines": [
                            "Effective date: 01/01/2027",
                            "Employment status: Active",
                            "(Confirmed through a performance review)"
                    ],
                    "reason": null
            },
            "employee · salary changed through a request (Q10: the request label)": {
                    "title": "Salary changed",
                    "part": null,
                    "lines": [
                            "Effective date: 01/02/2027",
                            "Previous monthly salary: 4,200.00 SGD",
                            "New monthly salary: 4,500.00 SGD",
                            "Salary change request: EMP-2026-0007 · 2027-02"
                    ],
                    "reason": null
            },
            "employee · first salary set, read without data.view_pay (Restricted)": {
                    "title": "Salary set",
                    "part": null,
                    "lines": [
                            "Effective date: 01/10/2026",
                            "New monthly salary: Restricted"
                    ],
                    "reason": null
            },
            "employee · salary change requested": {
                    "title": "Salary change requested",
                    "part": null,
                    "lines": [
                            "Effective date: 01/02/2027",
                            "Current monthly salary: 4,200.00 SGD",
                            "New monthly salary: 4,500.00 SGD"
                    ],
                    "reason": "Annual increment"
            },
            "employee · salary change approved (the approval folds in)": {
                    "title": "Salary change approved",
                    "part": null,
                    "lines": [],
                    "reason": "Agreed at review"
            },
            "employee · salary change request withdrawn": {
                    "title": "Salary change request withdrawn",
                    "part": null,
                    "lines": [],
                    "reason": "Raised by mistake"
            },
            "employee · login account linked (on the employee page)": {
                    "title": "Login account linked",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "employee · deleted": {
                    "title": "Employee deleted",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "employee · personal data anonymised (Q30: one sentence, the cleared values never said)": {
                    "title": "Personal data anonymised",
                    "part": null,
                    "lines": [],
                    "reason": null
            },
            "employee · the account mirror for an HR reader (Q21: a grant visible, the account event Restricted)": {
                    "title": "Role granted: CFO",
                    "part": null,
                    "lines": [
                            "(Part of this change is restricted.)"
                    ],
                    "reason": null
            },
            "training · recorded": {
                    "title": "Training recorded",
                    "part": "Forklift safety",
                    "lines": [
                            "Employee: Lim Wei Ming",
                            "Category: Safety",
                            "Completed on: 20/09/2026",
                            "Provider: SafeWorks"
                    ],
                    "reason": null
            },
            "training · deleted": {
                    "title": "Training record deleted",
                    "part": "Forklift safety",
                    "lines": [],
                    "reason": null
            },
            "department · created": {
                    "title": "Department created",
                    "part": "Operations",
                    "lines": [
                            "Code: OPS",
                            "Name (Chinese): 运营部",
                            "Active: Yes"
                    ],
                    "reason": null
            },
            "department · deactivated": {
                    "title": "Department deactivated",
                    "part": "Operations",
                    "lines": [],
                    "reason": null
            },
            "department · deleted": {
                    "title": "Department deleted",
                    "part": "Operations",
                    "lines": [],
                    "reason": null
            },
            "approval policy · switched on (the settings row and its history row are one event)": {
                    "title": "Approvals switched on",
                    "part": null,
                    "lines": [
                            "Approvals are in force: No → Yes",
                            "Level-1 approver role: (empty) → Finance",
                            "Approval threshold (base currency): (empty) → 1,000.00 SGD"
                    ],
                    "reason": null
            },
            "approval policy · switched on before the log (from its history row)": {
                    "title": "Approvals switched on",
                    "part": null,
                    "lines": [
                            "Approvals are in force: No → Yes"
                    ],
                    "reason": null
            },
            "approval policy · threshold changed": {
                    "title": "Approval policy changed",
                    "part": null,
                    "lines": [
                            "Approval threshold (base currency): 1,000.00 SGD → 2,500.00 SGD"
                    ],
                    "reason": null
            },
            "approval policy · level-2 approver changed before the log (role names, not codes)": {
                    "title": "Approval policy changed",
                    "part": null,
                    "lines": [
                            "Level-2 approver role (at or above the threshold): CFO → CCO"
                    ],
                    "reason": null
            },
            "dictionary · a value added": {
                    "title": "Substance added",
                    "part": "Cobalt",
                    "lines": [
                            "Name (Chinese): 钴",
                            "Symbol: Co",
                            "Active: Yes"
                    ],
                    "reason": null
            },
            "dictionary · a value deactivated": {
                    "title": "Substance deactivated",
                    "part": "Cobalt",
                    "lines": [],
                    "reason": null
            },
            "dictionary · a value renamed (field edit)": {
                    "title": "Laboratory changed",
                    "part": "SGS Testing Singapore",
                    "lines": [
                            "Name (English): SGS Singapore → SGS Testing Singapore"
                    ],
                    "reason": null
            },
            "import · a batch of suppliers": {
                    "title": "2 supplier records imported from a file",
                    "part": "suppliers-oct.csv",
                    "lines": [
                            "First number: SUP-2026-0018",
                            "Last number: SUP-2026-0019"
                    ],
                    "reason": null
            },
            "import · a single material": {
                    "title": "1 material imported from a file",
                    "part": "one.csv",
                    "lines": [
                            "First number: MAT-0042",
                            "Last number: MAT-0042"
                    ],
                    "reason": null
            }
    }
    const got11 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 35) problems.gold11.push(`⑪ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD11', order: 1, prelog: false, at: '2026-10-03T02:00:00+00:00', key: { id: uuid() },
            actor: { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold11.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        if (es.length !== 1) { problems.gold11.push(`${c.label}:一次操作应当是一条,造出了 ${es.length} 条(${es.map((x) => x.title).join(' | ')})`); continue }
        const e = es[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null }
        got11[c.label] = got
        const w = WANT[c.label]
        if (!w) { problems.gold11.push(`${c.label}:金句表里没有这一句`); continue }
        if (got.title !== w.title) problems.gold11.push(`${c.label}:标题「${got.title}」≠「${w.title}」`)
        if (got.part !== w.part) problems.gold11.push(`${c.label}:标题后那一段「${got.part}」≠「${w.part}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold11.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
        if (got.reason !== w.reason) problems.gold11.push(`${c.label}:理由「${got.reason}」≠「${w.reason}」`)
    }
    if (process.env.TRAIL_GOLD11_PRINT) console.log(JSON.stringify(got11, null, 8))
    // 匿名化之后,那个人做过的事读作 "A former employee"(trail_actor 给 anonymised;Q30)
    {
        const es = R.buildEntries(dict, [{ group: 'GA', order: 1, prelog: false, at: '2026-10-03T02:00:00+00:00', table: 'departments', key: { id: uuid() },
            op: 'INSERT', actor: { state: 'anonymised' }, cols: null, old: null, new: { code: 'X', name_en: 'X' }, ctx: null, refs: {}, hidden: false, restricted: false }],
            { subject: 'department' })
        if (es[0]?.who.text !== 'A former employee') problems.gold11.push(`匿名化之后那个人应当读作 "A former employee",造出了「${es[0]?.who.text}」`)
    }

    // 机器字扫描:十二个主语(与角色页的授权)各自的表,按【这一页】的说法(subject)造样本跑一遍
    const SUBS11 = ['account', 'approval_policy', 'employee', 'department', 'training_record', 'import_batch', 'role',
        'dictionary_substances', 'dictionary_battery_chemistries', 'dictionary_material_kinds', 'dictionary_inbound_safety_states',
        'dictionary_laboratories', 'dictionary_inbound_source_reasons']
    let s11 = 0
    for (const sub of SUBS11) {
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
                    s11++
                }
            }
        }
        // 账号事件每一种、匿名化、履历每一种 change_type,按这一页说一遍
        for (const ev of ['ACCOUNT_CREATE', 'ACCOUNT_DELETE', 'ACCOUNT_DISABLE', 'ACCOUNT_DISABLE_FAILED', 'ACCOUNT_ENABLE', 'ACCOUNT_ENABLE_FAILED']) {
            sweep(`${sub} · ${ev}`, [row('auth.users', ev, { new: { email: 'a@b.test', role_id: uuid(), employee_id: uuid(), reason: 'create_rolled_back' } })], sub)
        }
        for (const ct of checkValues('employment_history', 'change_type') ?? []) {
            sweep(`${sub} · history ${ct}`, [row('employment_history', 'INSERT', { new: { change_type: ct, effective_date: '2026-10-01', notes: `Probation confirmed by performance review ${uuid()}` } })], sub)
        }
        sweep(`${sub} · anonymised`, [row('employees', 'UPDATE', { cols: ['anonymised_at', 'legal_name'], old: { anonymised_at: null, legal_name: null }, new: { anonymised_at: '2026-10-03T00:00:00Z', legal_name: null } })], sub)
        sweep(`${sub} 整条看不见`, [row(R.SUBJECT_TABLES[sub][0], null, { hidden: true, table: null, actor: null })], sub)
        s11 += 6 + (checkValues('employment_history', 'change_type') ?? []).length + 2
    }
    const s11Want = SUBS11.reduce((n, sub) => n + (R.SUBJECT_TABLES[sub] ?? []).length * 12 + 6 + (checkValues('employment_history', 'change_type') ?? []).length + 2, 0)
    if (s11 !== s11Want || s11 < 300) problems.coverage.push(`账号、设置与员工那十三个主语的机器字扫描造了 ${s11} 句,登记表要求 ${s11Want} 句 —— 造样本那一段瞎了`)
    if (FAULT === 'wording-drift-1d1' && !problems.gold11.length) problems.gold11.push('(注入 wording-drift-1d1 没有咬人 —— 这一臂瞎了)')
}

// ── ⑫ 请假与考勤(AUDIT-TRAIL-1d-2)──────────────────────────────────────────────────────────────
// 九个主语(请假与本人的请假 · 假期发放 · 假别 · 公共假期 · 医疗报销与本人的报销 · 加班 · 考勤)与费用页上的医疗报销(Q37),
//   各一次字段编辑与关键事件,逐字;加上:请假的决定与审批留痕、扣减并成一句(之后与之前两种都证 —— Q12 的那一对戳按状态说)·
//   本人取消从那一对戳读出来 · 退回照页面的话说 "Overtime sent back"(Q35)且审批人那一格里系统追加的中文被剥掉(Q10)·
//   送审 / 批准整批重盖的 day_kind 与冲销作废的每一行不说 · 一次结转是一条 · 硬删的假期说出它最后的样子 · 考勤完成是一句、
//   之前那一段只剩最近一次(照直说)· /me 上本人读到的审批与消耗是 Restricted(M8 · Q14)。每一句都先由造句器造出来、
//   逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/AUDIT-TRAIL-1d-2.md §8 逐条列出。注入 wording-drift-1d2 → 这一臂必须红。
problems.gold12 = []
if (FAULT === 'wording-drift-1d2') dict.text = { ...dict.text, 'ot.sentBack': 'Overtime rejected' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const ref = (col, v, label, href) => ({ [col]: { [v]: href ? { label, href } : { label } } })
    const person = (col, v, name) => ({ [col]: { [v]: { person: { state: 'person', name } } } })
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows, actor) => C.push({ label, opts, rows, actor })
    const emp = id('emp'), lv = id('lv')
    const L = { subject: 'leave_request', recordId: lv }
    const lvRefs = { ...ref('leave_type_code', 'annual', 'Annual leave'), ...person('employee_id', emp, 'Lim Wei Ming') }
    const lvRow = { code: 'LV-2026-0007', employee_id: emp, leave_type_code: 'annual', start_date: '2026-10-12', end_date: '2026-10-13', days: 2 }
    // ── 请假 ──
    add('leave · requested', L, [{ table: 'leave_requests', op: 'INSERT', key: { id: lv }, new: { ...lvRow, status: 'pending', reason: 'Family trip' }, refs: lvRefs }])
    // U1-A(UNBLOCK-1 Q8):不持 data.view_health 的读者 —— 事由、病假单号与例外理由是受限标记;理由那一行说 Restricted,不消失
    add('leave · requested, read without data.view_health (U1-A Q8: the reason says Restricted)', L, [{ table: 'leave_requests', op: 'INSERT', key: { id: lv },
        new: { ...lvRow, status: 'pending', reason: RESTRICTED, certificate_ref: RESTRICTED, is_exception: true, exception_reason: RESTRICTED }, refs: lvRefs }])
    add('leave · requested as an exception (days entered by hand)', L, [{ table: 'leave_requests', op: 'INSERT', key: { id: lv },
        new: { ...lvRow, days: 1.5, end_half_day: true, status: 'pending', is_exception: true, exception_reason: 'Six-day roster' }, refs: lvRefs }])
    const draw = (k, n, pre = false) => ({ table: 'leave_consumption', op: 'INSERT', prelog: pre, key: { id: id(k) }, new: { leave_request_id: lv, entry_type: 'draw', days: n, accrual_year: 2026 } })
    add('leave · approved (the approval row and the draws fold in)', L, [
        { table: 'leave_requests', op: 'UPDATE', key: { id: lv }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'pending', decision_notes: null }, new: { status: 'approved', decision_notes: 'Enjoy' }, ctx: lvRow, refs: lvRefs },
        { table: 'approval_log', op: 'INSERT', key: { id: id('al1') }, new: { subject_type: 'leave_request', subject_id: lv, subject_code: 'LV-2026-0007', decision: 'approved', note: 'Enjoy' } },
        draw('d1', 2)])
    add('leave · approved before the log (Q12: the stamp, the approval row and the draw are one moment)', L, [
        { table: 'leave_requests', op: 'UPDATE', prelog: true, key: { id: lv }, cols: ['decided_at', 'decided_by', 'status', 'decision_notes'],
          new: { status: 'approved', decision_notes: 'Enjoy' }, ctx: lvRow, refs: lvRefs },
        { table: 'approval_log', op: 'INSERT', prelog: true, key: { id: id('al0') }, new: { subject_type: 'leave_request', subject_id: lv, subject_code: 'LV-2026-0007', decision: 'approved', note: 'Enjoy' } },
        draw('d0', 2, true)])
    add('leave · rejected', L, [
        { table: 'leave_requests', op: 'UPDATE', key: { id: lv }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'pending' }, new: { status: 'rejected', decision_notes: 'Year-end stocktake that week' }, ctx: lvRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('al2') }, new: { subject_type: 'leave_request', subject_id: lv, decision: 'rejected', note: 'Year-end stocktake that week' } }])
    add('leave · cancelled by the employee before the log (Q12: read from the decision stamp)', L, [
        { table: 'leave_requests', op: 'UPDATE', prelog: true, key: { id: lv }, cols: ['decided_at', 'decided_by', 'status', 'decision_notes'],
          new: { status: 'cancelled', decision_notes: null }, ctx: lvRow }])
    add('leave · cancelled after approval (days returned, with the reason)', L, [
        { table: 'leave_requests', op: 'UPDATE', key: { id: lv }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'approved', decision_notes: 'Enjoy' }, new: { status: 'cancelled', decision_notes: 'Trip called off' }, ctx: lvRow },
        { table: 'leave_consumption', op: 'INSERT', key: { id: id('r1') }, new: { leave_request_id: lv, entry_type: 'release', days: 2, accrual_year: 2026 } }])
    add('leave · request changed (field edit)', L, [
        { table: 'leave_requests', op: 'UPDATE', key: { id: lv }, cols: ['certificate_ref', 'updated_at'], old: { certificate_ref: null }, new: { certificate_ref: 'MC 448812' }, ctx: lvRow }])
    add('leave · approved before the log and cancelled later (only the approval row is left for that moment)', L, [
        { table: 'approval_log', op: 'INSERT', prelog: true, key: { id: id('al3') }, new: { subject_type: 'leave_request', subject_id: lv, decision: 'approved', note: null } },
        draw('d3', 1, true)])
    add('my leave · approved, read by the employee (M8 · Q14: the approval and the draw are Restricted)', { subject: 'my_leave_request', recordId: lv }, [
        { table: 'leave_requests', op: 'UPDATE', key: { id: lv }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'pending' }, new: { status: 'approved', decision_notes: 'Enjoy' }, ctx: lvRow },
        { hidden: true, table: null, op: null, actor: null }, { hidden: true, table: null, op: null, actor: null }])
    add('leave · on the summary page (no page subject: the number is said)', {}, [
        { table: 'leave_requests', op: 'UPDATE', key: { id: lv }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'pending' }, new: { status: 'rejected', decision_notes: null }, ctx: lvRow }])
    // ── 假期发放 ──
    const G = { subject: 'leave_grant', recordId: id('g1') }
    const grant = (k, e, name, n) => ({ table: 'leave_grants', op: 'INSERT', key: { id: id(k) },
        new: { employee_id: e, leave_type_code: 'annual', leave_year: 2027, days: n, granted_on: '2026-12-31', expires_on: '2027-12-31', grant_type: 'carry_forward' },
        refs: { ...person('employee_id', e, name), ...ref('leave_type_code', 'annual', 'Annual leave') } })
    add('leave grants · one carry-forward run is one entry (Q16)', G, [grant('g1', id('e1'), 'Lim Wei Ming', 4), grant('g2', id('e2'), 'Sandra Tan', 1), grant('g3', id('e3'), 'Fu Sheng', 6.5)])
    add('leave grants · carried forward for one person', G, [grant('g4', id('e1'), 'Lim Wei Ming', 4)])
    add('leave grants · a grant removed', G, [{ table: 'leave_grants', op: 'UPDATE', key: { id: id('g1') }, cols: ['deleted_at'], old: { deleted_at: null }, new: { deleted_at: '2026-10-03T02:00:00Z' } }])
    // ── 假别 · 公共假期(M11 集合)──
    const LT = { subject: 'leave_types', recordId: 'all' }
    add('leave types · standard days changed (field edit)', LT, [{ table: 'leave_types', op: 'UPDATE', key: { code: 'annual' }, cols: ['default_days_per_year', 'updated_at'],
        old: { default_days_per_year: 14 }, new: { default_days_per_year: 18 }, ctx: { name_en: 'Annual leave' } }])
    add('leave types · deactivated', LT, [{ table: 'leave_types', op: 'UPDATE', key: { code: 'unpaid' }, cols: ['is_active'], old: { is_active: true }, new: { is_active: false }, ctx: { name_en: 'Unpaid leave' } }])
    add('leave types · two seeded before the log (one moment, one entry)', LT, [
        { table: 'leave_types', op: 'INSERT', prelog: true, key: { code: 'annual' }, new: { code: 'annual', name_en: 'Annual leave', name_zh: '年假', is_paid: true, is_accrued: true, default_days_per_year: 14, gender_restriction: null, is_active: true, sort_order: 1 } },
        { table: 'leave_types', op: 'INSERT', prelog: true, key: { code: 'maternity' }, new: { code: 'maternity', name_en: 'Maternity leave', name_zh: '产假', is_paid: true, is_accrued: false, default_days_per_year: 112, gender_restriction: 'female', is_active: true, sort_order: 5 } }])
    const PH = { subject: 'public_holidays', recordId: 'all' }
    const hol = id('hol')
    add('public holidays · added', PH, [{ table: 'public_holidays', op: 'INSERT', key: { id: hol }, new: { holiday_date: '2027-01-01', name_en: "New Year's Day", name_zh: '元旦', country: 'SG', is_active: true, holiday_key: 'new-year', is_in_lieu: false } }])
    add('public holidays · date changed (field edit)', PH, [{ table: 'public_holidays', op: 'UPDATE', key: { id: hol }, cols: ['holiday_date', 'updated_at'],
        old: { holiday_date: '2027-02-06' }, new: { holiday_date: '2027-02-07' }, ctx: { name_en: 'Chinese New Year' } }])
    add('public holidays · hard-deleted (its last values are the record)', PH, [{ table: 'public_holidays', op: 'DELETE', key: { id: hol },
        old: { holiday_date: '2027-05-21', name_en: 'Vesak Day (in lieu)', name_zh: '卫塞节(补假)', country: 'SG', is_active: true, holiday_key: 'vesak', is_in_lieu: true } }])
    // ── 医疗报销 ──
    const mc = id('mc'), exp = id('exp')
    const M = { subject: 'medical_claim', recordId: mc }
    const mcRow = { code: 'MC-2026-0003', employee_id: emp, claim_date: '2026-10-01', amount_sgd: 85, status: 'submitted' }
    add('medical claim · submitted', M, [{ table: 'medical_claims', op: 'INSERT', key: { id: mc }, new: { ...mcRow, description: 'GP visit — fever', receipt_ref: 'RC-5512' }, refs: person('employee_id', emp, 'Lim Wei Ming') }])
    add('medical claim · approved (the approval row folds in)', M, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Within limit' }, ctx: mcRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('al4') }, new: { subject_type: 'medical_claim', subject_id: mc, decision: 'approved', note: 'Within limit' } }])
    add('medical claim · rejected', M, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'rejected', decision_notes: 'Dental is not covered' }, ctx: mcRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('al5') }, new: { subject_type: 'medical_claim', subject_id: mc, decision: 'rejected', note: 'Dental is not covered' } }])
    add('medical claim · withdrawn before the log (Q12: no person was recorded)', M, [
        { table: 'medical_claims', op: 'UPDATE', prelog: true, key: { id: mc }, cols: ['withdrawn_at', 'status'], new: { withdrawn_at: '2026-09-20T02:00:00Z', status: 'withdrawn' }, ctx: mcRow }],
        { state: 'unknown' })
    add('medical claim · expense raised to pay it (the expense and its journal are lines of the same operation)', M, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['expense_id', 'updated_by', 'updated_at'], old: { expense_id: null }, new: { expense_id: exp }, ctx: mcRow,
          refs: ref('expense_id', exp, 'EXP-2026-0012', `/finance/expenses/${exp}`) },
        { table: 'expenses', op: 'INSERT', key: { id: exp }, new: { code: 'EXP-2026-0012', amount_ccy: 85, currency: 'SGD', notes: 'Medical claim MC-2026-0003 (EMP-2026-0007)' } },
        { table: 'journal_entries', op: 'INSERT', key: { id: id('je') }, new: { code: 'JE-2026-0101', entry_date: '2026-10-02', source_type: 'expense' } }])
    add('medical claim · description changed (field edit)', M, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['description', 'updated_at'], old: { description: 'GP visit' }, new: { description: 'GP visit — fever' }, ctx: mcRow }])
    add('expense page · the medical claim that raised it (Q37)', { subject: 'expense', recordId: exp }, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Within limit' }, ctx: mcRow }])
    add('my medical claim · approved, read by the employee (M8: the approval is Restricted)', { subject: 'my_medical_claim', recordId: mc }, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Within limit' }, ctx: mcRow },
        { hidden: true, table: null, op: null, actor: null }])
    // ── 加班(Q35 · Q10)──
    const ob = id('ob'), ol1 = id('ol1'), ol2 = id('ol2')
    const O = { subject: 'overtime_batch', recordId: ob }
    const obRow = { label: 'OT 2026-10 #1', period_month: '2026-10-01' }
    const machine = '审批流未启用(finance_settings.approvals_enabled = false)—— 加班不受审批开关管,决定仍是仓库这个人按下去的'
    const restamp = (k, h) => ({ table: 'overtime_lines', op: 'UPDATE', key: { id: k }, cols: ['day_kind'], old: { day_kind: 'weekday' }, new: { day_kind: 'weekday' }, ctx: { batch_id: ob, hours: h, employee_id: emp } })
    add('overtime · batch started', O, [{ table: 'overtime_batches', op: 'INSERT', key: { id: ob }, new: { ...obRow, status: 'draft' } }])
    add('overtime · line added', O, [{ table: 'overtime_lines', op: 'INSERT', key: { id: ol1 }, new: { batch_id: ob, employee_id: emp, work_date: '2026-10-05', hours: 3.5, day_kind: 'rest_day', note: 'Container unloading' },
        refs: person('employee_id', emp, 'Lim Wei Ming') }])
    add('overtime · line removed (hard delete: its last values)', O, [{ table: 'overtime_lines', op: 'DELETE', key: { id: ol2 }, old: { batch_id: ob, employee_id: emp, work_date: '2026-10-06', hours: 2, day_kind: 'weekday' },
        refs: person('employee_id', emp, 'Lim Wei Ming') }])
    add('overtime · sent for approval (the day_kind restamp is not said; the approval row folds in)', O, [
        { table: 'overtime_batches', op: 'UPDATE', key: { id: ob }, cols: ['status', 'submitted_at', 'submitted_by'], old: { status: 'draft' }, new: { status: 'submitted' }, ctx: obRow },
        restamp(ol1, 3.5), restamp(id('ol3'), 2.5),
        { table: 'approval_log', op: 'INSERT', key: { id: id('al6') }, new: { subject_type: 'overtime_batch', subject_id: ob, decision: 'submitted', note: null } }])
    add('overtime · taken back for changes', O, [
        { table: 'overtime_batches', op: 'UPDATE', key: { id: ob }, cols: ['status', 'submitted_at', 'submitted_by'], old: { status: 'submitted' }, new: { status: 'draft' }, ctx: obRow }])
    add('overtime · sent back (Q35; the machine suffix is stripped from the approver note — Q10)', O, [
        { table: 'overtime_batches', op: 'UPDATE', key: { id: ob }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'rejected', decision_notes: 'Fri hours look doubled' }, ctx: obRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('al7') }, new: { subject_type: 'overtime_batch', subject_id: ob, decision: 'rejected', note: `Fri hours look doubled · ${machine}` } }])
    add('overtime · approved with approvals off (the note is only machine text: no reason)', O, [
        { table: 'overtime_batches', op: 'UPDATE', key: { id: ob }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'approved', decision_notes: null }, ctx: obRow },
        restamp(ol1, 3.5),
        { table: 'approval_log', op: 'INSERT', key: { id: id('al8') }, new: { subject_type: 'overtime_batch', subject_id: ob, decision: 'approved', note: machine } }])
    add('overtime · reversed (the voided lines are not said)', O, [
        { table: 'overtime_batches', op: 'UPDATE', key: { id: ob }, cols: ['status', 'reversed_at', 'reversed_by', 'reverse_reason'], old: { status: 'approved' }, new: { status: 'reversed', reverse_reason: 'Entered against the wrong month' }, ctx: obRow },
        { table: 'overtime_lines', op: 'UPDATE', key: { id: ol1 }, cols: ['voided_at'], old: { voided_at: null }, new: { voided_at: '2026-10-20T02:00:00Z' }, ctx: { batch_id: ob } }])
    add('overtime · discarded before the log (Q12: the stamp; the voided lines fold in)', O, [
        { table: 'overtime_batches', op: 'UPDATE', prelog: true, key: { id: ob }, cols: ['discarded_at', 'discarded_by', 'status'], new: { status: 'discarded' }, ctx: obRow },
        { table: 'overtime_lines', op: 'UPDATE', prelog: true, key: { id: ol1 }, cols: ['voided_at'], new: { voided_at: '2026-09-20T02:00:00Z' }, ctx: { batch_id: ob } }])
    add('overtime · sent back before the log (only the approval row; suffix stripped)', O, [
        { table: 'approval_log', op: 'INSERT', prelog: true, key: { id: id('al9') }, new: { subject_type: 'overtime_batch', subject_id: ob, subject_code: 'OT 2026-10 #1', decision: 'rejected', note: `Check Sunday · ${machine}` } }])
    add('overtime · a line read by the warehouse approver (Q20: the employee is Restricted)', O, [
        { table: 'overtime_lines', op: 'INSERT', key: { id: ol1 }, new: { batch_id: ob, employee_id: emp, work_date: '2026-10-05', hours: 3.5, day_kind: 'rest_day' },
          refs: { employee_id: { [emp]: { person: { state: 'restricted' } } } } }])
    add('overtime · sent back, on the summary page (the batch is named)', {}, [
        { table: 'approval_log', op: 'INSERT', key: { id: id('al10') }, new: { subject_type: 'overtime_batch', subject_id: ob, subject_code: 'OT 2026-10 #1', decision: 'rejected', note: 'Check Sunday' } }])
    // ── 考勤 ──
    const ap = id('ap')
    const A = { subject: 'attendance_period', recordId: ap }
    const apRow = { code: 'ATT-2026-10', period_month: '2026-10-01' }
    const aline = (k, op, over = {}) => ({ table: 'attendance_lines', op, key: { id: id(k) }, ...over })
    add('attendance · period opened (one line per staff member)', A, [
        { table: 'attendance_periods', op: 'INSERT', key: { id: ap }, new: { ...apRow, status: 'open' } },
        aline('a1', 'INSERT', { new: { period_id: ap, employee_id: id('e1') } }), aline('a2', 'INSERT', { new: { period_id: ap, employee_id: id('e2') } }),
        aline('a3', 'INSERT', { new: { period_id: ap, employee_id: id('e3') } })])
    add('attendance · a line recorded', A, [aline('a1', 'UPDATE', { cols: ['note', 'recorded_at', 'recorded_by'], old: { note: null, recorded_at: null }, new: { note: 'MC 2 days', recorded_at: '2026-10-28T02:00:00Z' },
        ctx: { employee_id: emp }, refs: person('employee_id', emp, 'Lim Wei Ming') })])
    add('attendance · new joiners added', A, [aline('a4', 'INSERT', { new: { period_id: ap, employee_id: emp }, refs: person('employee_id', emp, 'Lim Wei Ming') })])
    add('attendance · period completed (the mass updates are one sentence)', A, [
        { table: 'attendance_periods', op: 'UPDATE', key: { id: ap }, cols: ['status', 'completed_at', 'completed_by'], old: { status: 'open' }, new: { status: 'complete' }, ctx: apRow },
        aline('a1', 'UPDATE', { cols: ['unpaid_days', 'frozen_at', 'active_from', 'active_to'], old: { unpaid_days: null }, new: { unpaid_days: 0 } }),
        aline('a2', 'UPDATE', { cols: ['unpaid_days', 'frozen_at'], old: { unpaid_days: null }, new: { unpaid_days: 1 } }),
        aline('a1', 'UPDATE', { cols: ['ot_normal_hours'], old: { ot_normal_hours: 0 }, new: { ot_normal_hours: 3.5 } }),
        aline('a3', 'UPDATE', { cols: ['ot_normal_hours'], old: { ot_normal_hours: 0 }, new: { ot_normal_hours: 0 } })])
    add('attendance · period reopened', A, [
        { table: 'attendance_periods', op: 'UPDATE', key: { id: ap }, cols: ['status', 'completed_at', 'completed_by', 'reopened_at', 'reopened_by', 'reopen_reason'],
          old: { status: 'complete', completed_at: '2026-10-31T02:00:00Z', reopened_at: null, reopen_reason: null },
          new: { status: 'open', completed_at: null, reopened_at: '2026-11-03T02:00:00Z', reopen_reason: 'Late MC from Sandra' }, ctx: apRow }])
    add('attendance · completed before the log (Q12: latest only, said so)', A, [
        { table: 'attendance_periods', op: 'UPDATE', prelog: true, key: { id: ap }, cols: ['completed_at', 'completed_by', 'status'], new: { status: 'complete' }, ctx: apRow },
        aline('a1', 'UPDATE', { prelog: true, cols: ['frozen_at'], new: { frozen_at: '2026-09-01T02:00:00Z' } }),
        aline('a2', 'UPDATE', { prelog: true, cols: ['frozen_at'], new: { frozen_at: '2026-09-01T02:00:00Z' } })])
    add('attendance · reopened before the log (Q12: latest only, said so)', A, [
        { table: 'attendance_periods', op: 'UPDATE', prelog: true, key: { id: ap }, cols: ['reopened_at', 'reopened_by', 'reopen_reason'], new: { reopen_reason: 'Payroll query' }, ctx: apRow }])

    const WANT = {
        "leave · requested": {
            "title": "Leave requested: 2 days of Annual leave",
            "part": null,
            "lines": [
                "Start: 12/10/2026",
                "End: 13/10/2026"
            ],
            "reason": "Family trip",
            "who": "Sandra"
        },
        "leave · requested, read without data.view_health (U1-A Q8: the reason says Restricted)": {
            "title": "Leave requested: 2 days of Annual leave",
            "part": null,
            "lines": [
                "Start: 12/10/2026",
                "End: 13/10/2026",
                "Medical certificate: Restricted",
                "(Days entered by hand (exception))",
                "Reason for the exception: Restricted"
            ],
            "reason": "Restricted",
            "who": "Sandra"
        },
        "leave · requested as an exception (days entered by hand)": {
            "title": "Leave requested: 1.5 days of Annual leave",
            "part": null,
            "lines": [
                "Start: 12/10/2026",
                "End: 13/10/2026",
                "Half day on the last day: Yes",
                "(Days entered by hand (exception))",
                "Reason for the exception: Six-day roster"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "leave · approved (the approval row and the draws fold in)": {
            "title": "Leave approved",
            "part": null,
            "lines": [
                "Days taken from the balance: 2 days"
            ],
            "reason": "Enjoy",
            "who": "Sandra"
        },
        "leave · approved before the log (Q12: the stamp, the approval row and the draw are one moment)": {
            "title": "Leave approved",
            "part": null,
            "lines": [
                "Days taken from the balance: 2 days"
            ],
            "reason": "Enjoy",
            "who": "Sandra"
        },
        "leave · rejected": {
            "title": "Leave rejected",
            "part": null,
            "lines": [],
            "reason": "Year-end stocktake that week",
            "who": "Sandra"
        },
        "leave · cancelled by the employee before the log (Q12: read from the decision stamp)": {
            "title": "Leave cancelled",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "leave · cancelled after approval (days returned, with the reason)": {
            "title": "Leave cancelled",
            "part": null,
            "lines": [
                "Days returned to the balance: 2 days"
            ],
            "reason": "Trip called off",
            "who": "Sandra"
        },
        "leave · request changed (field edit)": {
            "title": "Leave request changed",
            "part": null,
            "lines": [
                "Medical certificate: (empty) → MC 448812"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "leave · approved before the log and cancelled later (only the approval row is left for that moment)": {
            "title": "Leave approved",
            "part": null,
            "lines": [
                "Days taken from the balance: 1 day"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "my leave · approved, read by the employee (M8 · Q14: the approval and the draw are Restricted)": {
            "title": "Leave approved",
            "part": null,
            "lines": [
                "(Part of this change is restricted.)"
            ],
            "reason": "Enjoy",
            "who": "Sandra"
        },
        "leave · on the summary page (no page subject: the number is said)": {
            "title": "Leave rejected · LV-2026-0007",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "leave grants · one carry-forward run is one entry (Q16)": {
            "title": "Unused leave carried forward · 3 people",
            "part": null,
            "lines": [
                "Lim Wei Ming: 4 days",
                "Sandra Tan: 1 day",
                "Fu Sheng: 6.5 days"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "leave grants · carried forward for one person": {
            "title": "Unused leave carried forward: 4 days",
            "part": null,
            "lines": [
                "Employee: Lim Wei Ming",
                "Leave type: Annual leave",
                "Leave year: 2027",
                "Source: Carried forward",
                "Lapses on: 31/12/2027"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "leave grants · a grant removed": {
            "title": "Leave grant removed",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "leave types · standard days changed (field edit)": {
            "title": "Leave type changed",
            "part": "Annual leave",
            "lines": [
                "Standard days: 14 → 18"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "leave types · deactivated": {
            "title": "Leave type deactivated",
            "part": "Unpaid leave",
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "leave types · two seeded before the log (one moment, one entry)": {
            "title": "Leave type added",
            "part": "Annual leave",
            "lines": [
                "Name (Chinese): 年假",
                "Paid: Yes",
                "Accrues: Yes",
                "Standard days: 14",
                "Active: Yes",
                "[Leave type added · Maternity leave]",
                "Name (Chinese): 产假",
                "Paid: Yes",
                "Accrues: No",
                "Standard days: 112",
                "Only for: Women",
                "Active: Yes"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "public holidays · added": {
            "title": "Public holiday added",
            "part": "New Year's Day",
            "lines": [
                "Date: 01/01/2027",
                "Name (Chinese): 元旦",
                "Holiday in lieu (of a Sunday): No",
                "Country: SG",
                "Active: Yes"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "public holidays · date changed (field edit)": {
            "title": "Public holiday changed",
            "part": "Chinese New Year",
            "lines": [
                "Date: 06/02/2027 → 07/02/2027"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "public holidays · hard-deleted (its last values are the record)": {
            "title": "Public holiday deleted",
            "part": "Vesak Day (in lieu)",
            "lines": [
                "Date: 21/05/2027",
                "Name (Chinese): 卫塞节(补假)",
                "Holiday in lieu (of a Sunday): Yes",
                "Country: SG",
                "Active: Yes"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "medical claim · submitted": {
            "title": "Medical claim submitted: 85.00 SGD",
            "part": null,
            "lines": [
                "Employee: Lim Wei Ming",
                "Date: 01/10/2026",
                "Description: GP visit — fever",
                "Receipt reference: RC-5512"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "medical claim · approved (the approval row folds in)": {
            "title": "Medical claim approved",
            "part": null,
            "lines": [],
            "reason": "Within limit",
            "who": "Sandra"
        },
        "medical claim · rejected": {
            "title": "Medical claim rejected",
            "part": null,
            "lines": [],
            "reason": "Dental is not covered",
            "who": "Sandra"
        },
        "medical claim · withdrawn before the log (Q12: no person was recorded)": {
            "title": "Medical claim withdrawn",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Not recorded"
        },
        "medical claim · expense raised to pay it (the expense and its journal are lines of the same operation)": {
            "title": "Expense raised to pay the claim",
            "part": null,
            "lines": [
                "Expense: EXP-2026-0012",
                "[Expense recorded · EXP-2026-0012]",
                "Amount: 85.00 SGD",
                "[Journal posted · JE-2026-0101]"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "medical claim · description changed (field edit)": {
            "title": "Medical claim changed",
            "part": null,
            "lines": [
                "Description: GP visit → GP visit — fever"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "expense page · the medical claim that raised it (Q37)": {
            "title": "Medical claim approved · MC-2026-0003",
            "part": null,
            "lines": [],
            "reason": "Within limit",
            "who": "Sandra"
        },
        "my medical claim · approved, read by the employee (M8: the approval is Restricted)": {
            "title": "Medical claim approved",
            "part": null,
            "lines": [
                "(Part of this change is restricted.)"
            ],
            "reason": "Within limit",
            "who": "Sandra"
        },
        "overtime · batch started": {
            "title": "Overtime batch started",
            "part": null,
            "lines": [
                "Month: 01/10/2026"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · line added": {
            "title": "Overtime line added",
            "part": "Lim Wei Ming",
            "lines": [
                "Date: 05/10/2026",
                "Day: Rest day (Sunday)",
                "Hours: 3.5",
                "Note: Container unloading"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · line removed (hard delete: its last values)": {
            "title": "Overtime line removed",
            "part": "Lim Wei Ming",
            "lines": [
                "Date: 06/10/2026",
                "Day: Weekday",
                "Hours: 2"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · sent for approval (the day_kind restamp is not said; the approval row folds in)": {
            "title": "Overtime sent for approval: 6 hours",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · taken back for changes": {
            "title": "Overtime taken back for changes",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · sent back (Q35; the machine suffix is stripped from the approver note — Q10)": {
            "title": "Overtime sent back",
            "part": null,
            "lines": [],
            "reason": "Fri hours look doubled",
            "who": "Sandra"
        },
        "overtime · approved with approvals off (the note is only machine text: no reason)": {
            "title": "Overtime approved",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · reversed (the voided lines are not said)": {
            "title": "Overtime reversed",
            "part": null,
            "lines": [],
            "reason": "Entered against the wrong month",
            "who": "Sandra"
        },
        "overtime · discarded before the log (Q12: the stamp; the voided lines fold in)": {
            "title": "Overtime batch discarded",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · sent back before the log (only the approval row; suffix stripped)": {
            "title": "Overtime sent back",
            "part": null,
            "lines": [],
            "reason": "Check Sunday",
            "who": "Sandra"
        },
        "overtime · a line read by the warehouse approver (Q20: the employee is Restricted)": {
            "title": "Overtime line added",
            "part": null,
            "lines": [
                "Employee: Restricted",
                "Date: 05/10/2026",
                "Day: Rest day (Sunday)",
                "Hours: 3.5"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "overtime · sent back, on the summary page (the batch is named)": {
            "title": "Overtime sent back · OT 2026-10 #1",
            "part": null,
            "lines": [],
            "reason": "Check Sunday",
            "who": "Sandra"
        },
        "attendance · period opened (one line per staff member)": {
            "title": "Attendance period opened",
            "part": null,
            "lines": [
                "Month: 01/10/2026",
                "People: 3"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "attendance · a line recorded": {
            "title": "Attendance recorded",
            "part": "Lim Wei Ming",
            "lines": [
                "Note: MC 2 days"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "attendance · new joiners added": {
            "title": "New joiners added to the sheet",
            "part": null,
            "lines": [
                "Employee: Lim Wei Ming"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "attendance · period completed (the mass updates are one sentence)": {
            "title": "Attendance period completed",
            "part": null,
            "lines": [
                "People: 3"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "attendance · period reopened": {
            "title": "Attendance period reopened",
            "part": null,
            "lines": [],
            "reason": "Late MC from Sandra",
            "who": "Sandra"
        },
        "attendance · completed before the log (Q12: latest only, said so)": {
            "title": "Attendance period completed",
            "part": null,
            "lines": [
                "People: 2",
                "(Only the latest completion and reopening of this month were kept before the log began.)"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "attendance · reopened before the log (Q12: latest only, said so)": {
            "title": "Attendance period reopened",
            "part": null,
            "lines": [
                "(Only the latest completion and reopening of this month were kept before the log began.)"
            ],
            "reason": "Payroll query",
            "who": "Sandra"
        }
    }
    const got12 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 40) problems.gold12.push(`⑫ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD12', order: 1, prelog: false, at: '2026-10-03T02:00:00+00:00', key: { id: uuid() },
            actor: c.actor ?? { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold12.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        if (es.length !== 1) { problems.gold12.push(`${c.label}:一次操作应当是一条,造出了 ${es.length} 条(${es.map((x) => x.title).join(' | ')})`); continue }
        const e = es[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null, who: e.who.text }
        got12[c.label] = got
        const w = WANT[c.label]
        if (!w) { problems.gold12.push(`${c.label}:金句表里没有这一句`); continue }
        for (const k of ['title', 'part', 'reason', 'who']) if (got[k] !== w[k]) problems.gold12.push(`${c.label}:${k}「${got[k]}」≠「${w[k]}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold12.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
    }
    if (process.env.TRAIL_GOLD12_PRINT) console.log(JSON.stringify(got12, null, 8))
    // 审批人那一格里系统追加的中文:剥掉之后一个中文字都不剩(Q10);只有机器字时整格为空
    if (R.stripOvertimeMachineNote('OK · 审批流未启用(x)—— y') !== 'OK' || R.stripOvertimeMachineNote('审批流未启用(x)') !== null || R.stripOvertimeMachineNote('人写的') !== '人写的')
        problems.gold12.push('stripOvertimeMachineNote 没有照约定剥(人的话留下、系统追加的那一截去掉、只有系统那一截时为空)')

    // 机器字扫描:九个主语各自的表,按【这一页】的说法(subject)造样本跑一遍;外加每一种审批决定、每一种加班状态
    const SUBS12 = ['leave_request', 'my_leave_request', 'leave_grant', 'leave_types', 'public_holidays', 'medical_claim', 'my_medical_claim',
        'overtime_batch', 'attendance_period']
    let s12 = 0
    for (const sub of SUBS12) {
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
                for (const [op, o] of [['INSERT', { new: img, prelog: variant === 3 }], ['UPDATE', { cols: cols.map(([c]) => c), old, new: neu, ctx: img, prelog: variant === 3 }], ['DELETE', { old: img }]]) {
                    sweep(`${sub} · ${t} · ${op} · 样本 ${variant}`, [row(t, op, { ...o, refs })], sub)
                    s12++
                }
            }
        }
        for (const st of ['leave_request', 'medical_claim', 'overtime_batch']) for (const dec of checkValues('approval_log', 'decision') ?? []) {
            sweep(`${sub} · approval ${st} ${dec}`, [row('approval_log', 'INSERT', { new: { subject_type: st, subject_id: uuid(), subject_code: 'X-2026-0001', decision: dec, note: 'n · 审批流未启用(x)' } })], sub)
            s12++
        }
        for (const st of checkValues('overtime_batches', 'status') ?? []) {
            sweep(`${sub} · overtime → ${st}`, [row('overtime_batches', 'UPDATE', { cols: ['status'], old: { status: 'submitted' }, new: { status: st, label: 'OT 2026-10 #1' } })], sub)
            s12++
        }
        sweep(`${sub} 整条看不见`, [row(R.SUBJECT_TABLES[sub][0], null, { hidden: true, table: null, actor: null })], sub)
        s12++
    }
    const decisions = (checkValues('approval_log', 'decision') ?? []).length, otStates = (checkValues('overtime_batches', 'status') ?? []).length
    const s12Want = SUBS12.reduce((n, sub) => n + (R.SUBJECT_TABLES[sub] ?? []).length * 12 + 3 * decisions + otStates + 1, 0)
    if (s12 !== s12Want || s12 < 300 || !decisions || !otStates) problems.coverage.push(`请假与考勤那九个主语的机器字扫描造了 ${s12} 句,登记表要求 ${s12Want} 句(审批决定 ${decisions} 种、加班状态 ${otStates} 种)—— 造样本那一段瞎了`)
    if (FAULT === 'wording-drift-1d2' && !problems.gold12.length) problems.gold12.push('(注入 wording-drift-1d2 没有咬人 —— 这一臂瞎了)')
}

// ── ⑬ 工资与评审(AUDIT-TRAIL-1d-3)──────────────────────────────────────────────────────────────
// 六个主语(工资期 · 评审与审核人的那一份 · 评审轮次 · 评分刻度 · KPI 条目)与员工页上评审定的调薪,各一次字段编辑与关键事件,逐字;
//   加上:工资行按员工配对 —— 没变的一对不说、变了的一对是一行(Q11),看不见金额的读者那一次保存只说一行 Restricted ·
//   撤销追加在备注里的那一行是 "Payroll unposted" 的理由、从不说成改了备注(Q10)· 审批说明后面那一截中英两段的机器字剥掉、
//   换成一行英文(Q10)· label 里原样的种类不上屏(Q10)· 分录按结构认出是哪一笔(过账 · 发薪 · CPF · 撤销)· 不持财务的读者
//   读到的分录号是 Restricted(与页头同一条)· 年度评审以它的轮次开头(Q6)· 批准按评审自己的几列说结论、新月薪照今天遮蔽(Q7)·
//   审核人那一份里审批是 Restricted(Q5)· 作废与撤回的那一个戳(Q12)· KPI 一次生成是一条。每一句都先由造句器造出来、
//   逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/AUDIT-TRAIL-1d-3.md §8 逐条列出。注入 wording-drift-1d3 → 这一臂必须红。
problems.gold13 = []
if (FAULT === 'wording-drift-1d3') dict.text = { ...dict.text, 'prl.unposted': 'Payroll reversed' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const ref = (col, v, label, href) => ({ [col]: { [v]: href ? { label, href } : { label } } })
    const person = (col, v, name) => ({ [col]: { [v]: { person: { state: 'person', name } } } })
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows, actor) => C.push({ label, opts, rows, actor })
    const ea = id('ea'), eb = id('eb'), ec = id('ec')
    const empRefs = (e, name) => person('employee_id', e, name)
    // ── 工资期 ──
    const pp = id('pp')
    const P = { subject: 'payroll_period', recordId: pp, currency: 'SGD' }
    const ppRow = { code: 'PAY-2026-0010', period_month: '2026-10-01', payment_date: '2026-10-30', currency: 'SGD', fx_rate: 1, status: 'draft' }
    const pline = (k, op, e, name, gross, net, extra = {}) => ({ table: 'payroll_lines', op, key: { id: id(k) },
        ...(op === 'DELETE' ? { old: { payroll_period_id: pp, employee_id: e, gross_pay: gross, employer_cpf: 0, employee_cpf: gross - net, other_deductions: 0, net_pay: net, ...extra } }
                            : { new: { payroll_period_id: pp, employee_id: e, gross_pay: gross, employer_cpf: 0, employee_cpf: gross - net, other_deductions: 0, net_pay: net, ...extra } }),
        refs: empRefs(e, name) })
    add('payroll · recorded (the period and its lines are one operation)', P, [
        { table: 'payroll_periods', op: 'INSERT', key: { id: pp }, new: { ...ppRow, gross_total: 0, net_pay_total: 0, source_note: 'Provider file Oct.xlsx' } },
        pline('l1', 'INSERT', ea, 'Lim Wei Ming', 5000, 4000), pline('l2', 'INSERT', eb, 'Sandra Tan', 4000, 3200),
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['gross_total', 'net_pay_total', 'updated_by'], old: { gross_total: 0, net_pay_total: 0 }, new: { gross_total: 9000, net_pay_total: 7200 }, ctx: ppRow }])
    add('payroll · re-saved: an unchanged pair says nothing, a changed pair is one line each (Q11)', P, [
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['payment_date', 'updated_by'], old: { payment_date: '2026-10-30' }, new: { payment_date: '2026-10-29' }, ctx: ppRow },
        pline('l1', 'DELETE', ea, 'Lim Wei Ming', 5000, 4000), pline('l2', 'DELETE', eb, 'Sandra Tan', 4000, 3200),
        pline('l3', 'INSERT', ea, 'Lim Wei Ming', 5000, 4000), pline('l4', 'INSERT', eb, 'Sandra Tan', 4200, 3360),
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['gross_total', 'net_pay_total', 'updated_by'], old: { gross_total: 9000, net_pay_total: 7200 }, new: { gross_total: 9200, net_pay_total: 7360 }, ctx: ppRow }])
    const R13 = { $restricted: true }
    const rline = (k, op, e, name) => ({ table: 'payroll_lines', op, key: { id: id(k) },
        [op === 'DELETE' ? 'old' : 'new']: { payroll_period_id: pp, employee_id: e, gross_pay: R13, employer_cpf: R13, employee_cpf: R13, other_deductions: R13, net_pay: R13, notes: null },
        refs: empRefs(e, name) })
    add('payroll · re-saved, read without data.view_pay (whether a line changed is pay data: one Restricted line)', P, [
        rline('l1', 'DELETE', ea, 'Lim Wei Ming'), rline('l2', 'DELETE', eb, 'Sandra Tan'), rline('l3', 'INSERT', ea, 'Lim Wei Ming'), rline('l4', 'INSERT', eb, 'Sandra Tan'),
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['gross_total', 'net_pay_total', 'updated_by'], old: { gross_total: 9000, net_pay_total: 7200 }, new: { gross_total: 9200, net_pay_total: 7360 }, ctx: ppRow }])
    add('payroll · re-saved: one person left the sheet, one joined', P, [
        pline('l1', 'DELETE', ea, 'Lim Wei Ming', 5000, 4000), pline('l2', 'DELETE', eb, 'Sandra Tan', 4000, 3200),
        pline('l3', 'INSERT', ea, 'Lim Wei Ming', 5000, 4000), pline('l5', 'INSERT', ec, 'Fu Sheng', 3000, 2400),
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['gross_total', 'net_pay_total', 'updated_by'], old: { gross_total: 9000, net_pay_total: 7200 }, new: { gross_total: 8000, net_pay_total: 6400 }, ctx: ppRow }])
    const rq = id('rq'), rq2 = id('rq2')
    const rqRow = { payroll_period_id: pp, kind: 'post', label: 'PAY-2026-0010 · post #1', currency: 'SGD', fx_rate: 1, gross_total: 9200, amount_base: 9200 }
    const own = '本期含审批人自己的工资行 · this period includes the approver\'s own pay line: EMP-2026-0004'
    const autoNote = '审批关着时提交:申请生下来就是 approved,没有人按过批准'
    add('payroll · posting sent for approval (the approval row folds in)', P, [
        { table: 'payroll_requests', op: 'INSERT', key: { id: rq }, new: { ...rqRow, status: 'submitted' } },
        { table: 'approval_log', op: 'INSERT', key: { id: id('a1') }, new: { subject_type: 'payroll_request', subject_id: rq, subject_code: 'PAY-2026-0010 · post #1', decision: 'submitted', note: null } }])
    add('payroll · posting approved automatically (approvals off: the machine note is not said)', P, [
        { table: 'payroll_requests', op: 'INSERT', key: { id: rq }, new: { ...rqRow, status: 'approved' } },
        { table: 'approval_log', op: 'INSERT', key: { id: id('a2') }, new: { subject_type: 'payroll_request', subject_id: rq, subject_code: 'PAY-2026-0010 · post #1', decision: 'auto_approved', note: autoNote } }])
    add("payroll · posting approved; the approver's own pay line (Q10: the bilingual suffix is said in English)", P, [
        { table: 'payroll_requests', op: 'UPDATE', key: { id: rq }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Checked against the provider file' }, ctx: rqRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('a3') }, new: { subject_type: 'payroll_request', subject_id: rq, subject_code: 'PAY-2026-0010 · post #1', decision: 'approved', note: `Checked against the provider file\n${own}` } }])
    add('payroll · unposting rejected', P, [
        { table: 'payroll_requests', op: 'UPDATE', key: { id: rq2 }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'rejected', decision_notes: 'Wait for the bonus run' }, ctx: { ...rqRow, kind: 'reversal', label: 'PAY-2026-0010 · reversal #1' } },
        { table: 'approval_log', op: 'INSERT', key: { id: id('a4') }, new: { subject_type: 'payroll_request', subject_id: rq2, subject_code: 'PAY-2026-0010 · reversal #1', decision: 'rejected', note: `Wait for the bonus run\n${own}` } }])
    add('payroll · posting request withdrawn before the log (Q12: the stamp is the only record)', P, [
        { table: 'payroll_requests', op: 'UPDATE', prelog: true, key: { id: rq }, cols: ['withdrawn_at', 'withdrawn_by', 'status'], new: { withdrawn_at: '2026-09-20T02:00:00Z', status: 'withdrawn' }, ctx: rqRow }])
    const je1 = id('je1'), je2 = id('je2'), je3 = id('je3'), je4 = id('je4')
    add('payroll · posted (the journal and the executed request fold in)', P, [
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['status', 'journal_entry_id', 'updated_by'], old: { status: 'draft', journal_entry_id: null }, new: { status: 'posted', journal_entry_id: je1 }, ctx: ppRow,
          refs: ref('journal_entry_id', je1, 'JE-2026-0120', `/finance/journal/${je1}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: je1 }, new: { code: 'JE-2026-0120', entry_date: '2026-10-30', source_type: 'payroll', source_id: pp, memo: 'Payroll PAY-2026-0010', status: 'posted' } },
        { table: 'payroll_requests', op: 'UPDATE', key: { id: rq }, cols: ['status', 'executed_at', 'executed_by', 'result_journal_entry_id'], old: { status: 'approved' }, new: { status: 'executed', result_journal_entry_id: je1 }, ctx: rqRow }])
    add('payroll · posted, read without finance (the journal number is Restricted, as on the page)', P, [
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['status', 'journal_entry_id', 'updated_by'], old: { status: 'draft', journal_entry_id: null }, new: { status: 'posted', journal_entry_id: je1 }, ctx: ppRow,
          refs: ref('journal_entry_id', je1, 'JE-2026-0120', `/finance/journal/${je1}`) },
        { hidden: true, table: null, op: null, actor: null },
        { table: 'payroll_requests', op: 'UPDATE', key: { id: rq }, cols: ['status', 'executed_at', 'executed_by', 'result_journal_entry_id'], old: { status: 'approved' }, new: { status: 'executed', result_journal_entry_id: je1 }, ctx: rqRow }])
    add('payroll · unposted (Q10: the machine line in the notes is the reason, never "Notes changed")', P, [
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['status', 'journal_entry_id', 'notes', 'updated_by'],
          old: { status: 'posted', journal_entry_id: je1, notes: 'Includes the October bonus' },
          new: { status: 'draft', journal_entry_id: null, notes: 'Includes the October bonus\n[2026-11-02 09:15 unposted] Wrong CPF rate for two people' }, ctx: ppRow },
        { table: 'journal_entries', op: 'UPDATE', key: { id: je1 }, cols: ['status', 'reversed_by'], old: { status: 'posted', reversed_by: null }, new: { status: 'reversed', reversed_by: je2 },
          ctx: { code: 'JE-2026-0120' }, refs: ref('reversed_by', je2, 'JE-2026-0131', `/finance/journal/${je2}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: je2 }, new: { code: 'JE-2026-0131', entry_date: '2026-11-02', source_type: 'payroll', source_id: je1, memo: 'Payroll reversal PAY-2026-0010', status: 'posted' } },
        { table: 'payroll_requests', op: 'UPDATE', key: { id: rq2 }, cols: ['status', 'executed_at', 'executed_by', 'result_journal_entry_id'], old: { status: 'approved' }, new: { status: 'executed', result_journal_entry_id: je2 }, ctx: { ...rqRow, kind: 'reversal' } }])
    add("payroll · salaries paid (each line's paid stamp folds in)", P, [
        { table: 'payroll_lines', op: 'UPDATE', key: { id: id('l3') }, cols: ['paid_at', 'paid_journal_entry_id'], old: { paid_at: null }, new: { paid_at: '2026-10-30T02:00:00Z', paid_journal_entry_id: je3 }, ctx: { employee_id: ea }, refs: empRefs(ea, 'Lim Wei Ming') },
        { table: 'payroll_lines', op: 'UPDATE', key: { id: id('l4') }, cols: ['paid_at', 'paid_journal_entry_id'], old: { paid_at: null }, new: { paid_at: '2026-10-30T02:00:00Z', paid_journal_entry_id: je3 }, ctx: { employee_id: eb }, refs: empRefs(eb, 'Sandra Tan') },
        { table: 'journal_entries', op: 'INSERT', key: { id: je3 }, new: { code: 'JE-2026-0121', entry_date: '2026-10-30', source_type: 'payroll', source_id: pp, memo: 'Salary payment PAY-2026-0010', status: 'posted' } }])
    add('payroll · CPF paid', P, [
        { table: 'payroll_periods', op: 'UPDATE', key: { id: pp }, cols: ['cpf_paid_at', 'cpf_journal_entry_id'], old: { cpf_paid_at: null }, new: { cpf_paid_at: '2026-11-12', cpf_journal_entry_id: je4 }, ctx: ppRow,
          refs: ref('cpf_journal_entry_id', je4, 'JE-2026-0140', `/finance/journal/${je4}`) },
        { table: 'journal_entries', op: 'INSERT', key: { id: je4 }, new: { code: 'JE-2026-0140', entry_date: '2026-11-12', source_type: 'payroll', source_id: pp, memo: 'CPF PAY-2026-0010', status: 'posted' } }])
    add('payroll · posted before the log (only the journal is left; known by structure, not by its memo)', P, [
        { table: 'journal_entries', op: 'INSERT', prelog: true, key: { id: je1 }, new: { code: 'JE-2026-0017', entry_date: '2026-09-26', source_type: 'payroll', source_id: pp, memo: 'Payroll PAY-2026-0001', status: 'posted' } },
        { group: 'OTHER', table: 'payroll_periods', op: 'INSERT', prelog: true, key: { id: pp }, new: { ...ppRow, status: 'posted', journal_entry_id: je1 }, ctx: { ...ppRow, status: 'posted', journal_entry_id: je1 } }])
    add('payroll · salaries paid before the log (the lines that journal paid are counted from the page)', P, [
        { table: 'journal_entries', op: 'INSERT', prelog: true, key: { id: je3 }, new: { code: 'JE-2026-0018', entry_date: '2026-09-26', source_type: 'payroll', source_id: pp, memo: 'Salary payment PAY-2026-0001', status: 'posted' } },
        { group: 'OTHER', table: 'payroll_lines', op: 'INSERT', prelog: true, key: { id: id('l9') }, new: { payroll_period_id: pp, employee_id: ea }, ctx: { payroll_period_id: pp, employee_id: ea, paid_journal_entry_id: je3 }, refs: empRefs(ea, 'Lim Wei Ming') }])
    add("payroll · posting approved before the log (only the approval row; the label's raw kind is not said)", P, [
        { table: 'approval_log', op: 'INSERT', prelog: true, key: { id: id('a5') }, new: { subject_type: 'payroll_request', subject_id: rq, subject_code: 'PAY-2026-0010 · post #1', decision: 'approved', note: null } }])
    add('payroll · lines saved before the log, apart from the period (the last save; no person was recorded)', P, [
        { ...pline('l6', 'INSERT', ea, 'Lim Wei Ming', 5000, 4000), prelog: true }, { ...pline('l7', 'INSERT', eb, 'Sandra Tan', 4000, 3200), prelog: true }], { state: 'unknown' })
    add('payroll · posting approved, on the summary page (the period is named, the kind is not)', {}, [
        { table: 'payroll_requests', op: 'UPDATE', key: { id: rq }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'], old: { status: 'submitted' }, new: { status: 'approved', decision_notes: null }, ctx: rqRow }])
    // ── 评审 ──
    const rv = id('rv'), cyc = id('cyc'), rev = id('rev')
    const RV = { subject: 'performance_review', recordId: rv }
    const rvRow = { employee_id: ea, review_type: 'annual', cycle_id: cyc, period_start: '2026-01-01', period_end: '2026-12-31', reviewer_employee_id: rev }
    const rvRefs = { ...empRefs(ea, 'Lim Wei Ming'), ...person('reviewer_employee_id', rev, 'Sandra Tan'), ...ref('cycle_id', cyc, 'FY2026 annual'),
        rating_code: { MEETS: { label: 'Meets Expectations' }, EXCEEDS: { label: 'Exceeds Expectations' } } }
    add('review · annual review opened (Q6: the cycle is named)', RV, [
        { table: 'performance_reviews', op: 'INSERT', key: { id: rv }, new: { ...rvRow, status: 'draft' }, refs: rvRefs }])
    add('review · probation review opened', RV, [
        { table: 'performance_reviews', op: 'INSERT', key: { id: rv }, new: { ...rvRow, review_type: 'probation', cycle_id: null, period_start: '2026-07-01', period_end: '2026-09-30', status: 'draft' }, refs: rvRefs }])
    add('review · opened for self-assessment', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status'], old: { status: 'draft', self_assessment_submitted_at: null }, new: { status: 'self_review' }, ctx: rvRow, refs: rvRefs }])
    add("review · self-assessment reopened (Q35: the page's \"Reopen self-assessment\")", RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'self_assessment_submitted_at'], old: { status: 'self_review', self_assessment_submitted_at: '2026-10-20T02:00:00Z' }, new: { status: 'self_review', self_assessment_submitted_at: null }, ctx: rvRow, refs: rvRefs }])
    const g1 = id('g1')
    add('review · self-assessment finalised (the goal results are lines of it)', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['self_assessment_text', 'self_assessment_submitted_at'], old: { self_assessment_text: null, self_assessment_submitted_at: null },
          new: { self_assessment_text: 'A steady year; the stocktake work went well.', self_assessment_submitted_at: '2026-10-21T02:00:00Z' }, ctx: rvRow, refs: rvRefs },
        { table: 'review_goals', op: 'UPDATE', key: { id: g1 }, cols: ['employee_result_text', 'actual_value'], old: { employee_result_text: null, actual_value: null },
          new: { employee_result_text: 'All counts done on time', actual_value: 12 }, ctx: { review_id: rv, sequence: 1, objective_text: 'Run the monthly stocktake', target_value: 12, unit: 'counts' } }])
    add('review · self-assessment saved as a draft', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['self_assessment_text'], old: { self_assessment_text: null }, new: { self_assessment_text: 'First thoughts' }, ctx: rvRow, refs: rvRefs }])
    add('review · conclusion changed', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['rating_code', 'summary_text'], old: { rating_code: 'MEETS', summary_text: null }, new: { rating_code: 'EXCEEDS', summary_text: 'Ran every count; trained two new staff.' }, ctx: rvRow, refs: rvRefs }])
    add('review · reviewer changed', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['reviewer_employee_id'], old: { reviewer_employee_id: eb }, new: { reviewer_employee_id: rev }, ctx: rvRow,
          refs: { reviewer_employee_id: { [eb]: { person: { state: 'person', name: 'Fu Sheng' } }, [rev]: { person: { state: 'person', name: 'Sandra Tan' } } } } }])
    add('review · submitted for approval (the approval row folds in)', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'submitted_at', 'submitted_by'], old: { status: 'self_review' }, new: { status: 'submitted' }, ctx: { ...rvRow, rating_code: 'EXCEEDS' }, refs: rvRefs },
        { table: 'approval_log', op: 'INSERT', key: { id: id('ra1') }, new: { subject_type: 'performance_review', subject_id: rv, subject_code: 'EMP-2026-0007', decision: 'submitted', note: null } }])
    const probRow = { ...rvRow, review_type: 'probation', cycle_id: null, rating_code: 'MEETS', probation_outcome: 'confirm', salary_effective_date: '2026-11-01' }
    add('review · approved (Q7: the outcome from the review\'s own columns; the salary masked as today)', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'approved_at', 'approved_by'], old: { status: 'submitted' }, new: { status: 'approved' },
          ctx: { ...probRow, new_monthly_salary: R13 }, refs: rvRefs },
        { table: 'approval_log', op: 'INSERT', key: { id: id('ra2') }, new: { subject_type: 'performance_review', subject_id: rv, subject_code: 'EMP-2026-0007', decision: 'approved', note: null } }])
    add('review · approved, read with data.view_pay', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'approved_at', 'approved_by'], old: { status: 'submitted' }, new: { status: 'approved' },
          ctx: { ...probRow, new_monthly_salary: 5200 }, refs: rvRefs },
        { table: 'approval_log', op: 'INSERT', key: { id: id('ra3') }, new: { subject_type: 'performance_review', subject_id: rv, subject_code: 'EMP-2026-0007', decision: 'approved', note: null } }])
    add("review · approved before the log (only the approval row; the outcome is today's review)", RV, [
        { table: 'approval_log', op: 'INSERT', prelog: true, key: { id: id('ra4') }, new: { subject_type: 'performance_review', subject_id: rv, subject_code: 'EMP-2026-0007', decision: 'approved', note: null } },
        { group: 'OTHER', table: 'performance_reviews', op: 'INSERT', prelog: true, key: { id: rv }, new: { ...rvRow, rating_code: 'MEETS', status: 'approved' }, ctx: { ...rvRow, rating_code: 'MEETS', status: 'approved' }, refs: rvRefs }])
    add('review · acknowledged by the employee', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'acknowledged_at'], old: { status: 'approved' }, new: { status: 'acknowledged' }, ctx: rvRow, refs: rvRefs },
        { table: 'approval_log', op: 'INSERT', key: { id: id('ra5') }, new: { subject_type: 'performance_review', subject_id: rv, subject_code: 'EMP-2026-0007', decision: 'acknowledged', note: null } }])
    add('review · voided', RV, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'void_reason', 'voided_at', 'voided_by'], old: { status: 'draft' }, new: { status: 'void', void_reason: 'Opened for the wrong person' }, ctx: rvRow, refs: rvRefs }])
    add('review · voided before the log (Q12: the stamp is the only record, with its reason)', RV, [
        { table: 'performance_reviews', op: 'UPDATE', prelog: true, key: { id: rv }, cols: ['voided_at', 'voided_by', 'status', 'void_reason'], new: { status: 'void', void_reason: 'Duplicate of the probation review' }, ctx: rvRow, refs: rvRefs }])
    add('review · goal added', RV, [
        { table: 'review_goals', op: 'INSERT', key: { id: g1 }, new: { review_id: rv, sequence: 1, objective_text: 'Run the monthly stocktake', target_value: 12, unit: 'counts' } }])
    add('review · goal changed (field edit)', RV, [
        { table: 'review_goals', op: 'UPDATE', key: { id: g1 }, cols: ['target_value'], old: { target_value: 12 }, new: { target_value: 10 }, ctx: { review_id: rv, sequence: 1, objective_text: 'Run the monthly stocktake', unit: 'counts' } }])
    add('review · goal removed (hard delete: its last values)', RV, [
        { table: 'review_goals', op: 'DELETE', key: { id: g1 }, old: { review_id: rv, sequence: 2, objective_text: 'Cut forklift idle time', target_value: 10, unit: '%' } }])
    add('my review · approved, read by a reviewer without hr.view (Q5: the approval row is Restricted)', { subject: 'my_review', recordId: rv }, [
        { table: 'performance_reviews', op: 'UPDATE', key: { id: rv }, cols: ['status', 'approved_at', 'approved_by'], old: { status: 'submitted' }, new: { status: 'approved' },
          ctx: { ...rvRow, rating_code: 'MEETS', new_monthly_salary: R13 }, refs: { ...rvRefs, employee_id: { [ea]: { person: { state: 'restricted' } } } } },
        { hidden: true, table: null, op: null, actor: null }], { state: 'restricted' })
    add('review · approved, on the summary page (the employee code is named)', {}, [
        { table: 'approval_log', op: 'INSERT', key: { id: id('ra6') }, new: { subject_type: 'performance_review', subject_id: rv, subject_code: 'EMP-2026-0007', decision: 'approved', note: null } }])
    // ── 评审轮次(Q6)──
    const CY = { subject: 'review_cycle', recordId: cyc }
    add('review cycle · created', CY, [{ table: 'review_cycles', op: 'INSERT', key: { id: cyc }, new: { name: 'FY2026 annual', period_start: '2026-01-01', period_end: '2026-12-31', due_date: '2027-01-31', status: 'draft' } }])
    add('review cycle · opened (Q6: the reviews it creates are not on the cycle)', CY, [
        { table: 'review_cycles', op: 'UPDATE', key: { id: cyc }, cols: ['status'], old: { status: 'draft' }, new: { status: 'open' }, ctx: { name: 'FY2026 annual' } }])
    add('review cycle · closed', CY, [{ table: 'review_cycles', op: 'UPDATE', key: { id: cyc }, cols: ['status'], old: { status: 'open' }, new: { status: 'closed' }, ctx: { name: 'FY2026 annual' } }])
    add('review cycle · due date changed (field edit)', CY, [{ table: 'review_cycles', op: 'UPDATE', key: { id: cyc }, cols: ['due_date'], old: { due_date: '2027-01-31' }, new: { due_date: '2027-02-15' }, ctx: { name: 'FY2026 annual' } }])
    // ── 评分刻度(M11 集合)──
    const SC = { subject: 'review_rating_scale', recordId: 'all' }
    add('rating scale · a rating added', SC, [{ table: 'review_rating_scale', op: 'INSERT', key: { code: 'FAR_BELOW' }, new: { code: 'FAR_BELOW', name_en: 'Far Below Expectations', name_zh: '远低于预期', sort_order: 50, is_active: true, is_probation_pass: false } }])
    add('rating scale · description changed (field edit)', SC, [{ table: 'review_rating_scale', op: 'UPDATE', key: { code: 'MEETS' }, cols: ['description_en'], old: { description_en: 'Met the objectives set for the period.' },
        new: { description_en: 'Met every objective set for the period.' }, ctx: { name_en: 'Meets Expectations' } }])
    add('rating scale · deactivated', SC, [{ table: 'review_rating_scale', op: 'UPDATE', key: { code: 'BELOW' }, cols: ['is_active'], old: { is_active: true }, new: { is_active: false }, ctx: { name_en: 'Below Expectations' } }])
    add('rating scale · two seeded before the log (one moment, one entry)', SC, [
        { table: 'review_rating_scale', op: 'INSERT', prelog: true, key: { code: 'OUTSTANDING' }, new: { code: 'OUTSTANDING', name_en: 'Outstanding', name_zh: '卓越', sort_order: 10, is_active: true, is_probation_pass: true } },
        { table: 'review_rating_scale', op: 'INSERT', prelog: true, key: { code: 'MEETS' }, new: { code: 'MEETS', name_en: 'Meets Expectations', name_zh: '符合预期', sort_order: 30, is_active: true, is_probation_pass: true } }], { state: 'unknown' })
    // ── KPI 条目 ──
    const K = { subject: 'kpi_entry', recordId: id('k1') }
    const kpi = (k, ref_, title, w) => ({ table: 'kpi_entries', op: 'INSERT', key: { id: id(k) },
        new: { employee_id: ea, kpi_ref: ref_, title, weight_pct: w, target_text: 'As set by the template', org_codes: ['O1'], is_provisional: false }, refs: empRefs(ea, 'Lim Wei Ming') })
    add('KPI · five entries generated for one person (one operation, Q16)', K, [
        kpi('k1', 'F1', 'Stocktake accuracy', 30), kpi('k2', 'F2', 'Receiving turnaround', 20), kpi('k3', 'C5', 'Planned maintenance done', 20),
        kpi('k4', 'S1', 'Safety observations', 15), kpi('k5', 'T3', 'Training hours', 15)])
    const kRow = { employee_id: ea, kpi_ref: 'F1', title: 'Stocktake accuracy', weight_pct: 30 }
    add('KPI · scored (judged, with evidence and feedback)', K, [
        { table: 'kpi_entries', op: 'UPDATE', key: { id: id('k1') }, cols: ['score', 'score_kind', 'evidence_note', 'feedback_note', 'scored_by', 'scored_at', 'updated_by'],
          old: { score: null, score_kind: null }, new: { score: 4, score_kind: 'judged', evidence_note: 'Three counts, one variance found and cleared', feedback_note: 'Keep the Friday count' }, ctx: kRow, refs: empRefs(ea, 'Lim Wei Ming') }])
    add('KPI · re-scored, capped by a safety override', K, [
        { table: 'kpi_entries', op: 'UPDATE', key: { id: id('k1') }, cols: ['score', 'override_cap', 'override_reason', 'scored_by', 'scored_at'],
          old: { score: 4, override_cap: null }, new: { score: 5, override_cap: 2, override_reason: 'Forklift near-miss on 14/10' }, ctx: { ...kRow, score_kind: 'judged' }, refs: empRefs(ea, 'Lim Wei Ming') }])
    add('KPI · scored before the log (the stamp is the only record of that scoring)', K, [
        { table: 'kpi_entries', op: 'UPDATE', prelog: true, key: { id: id('k1') }, cols: ['scored_at', 'scored_by', 'score', 'score_kind'], new: { score: 3, score_kind: 'computed' }, ctx: kRow }])
    add('KPI · evidence changed, the score unchanged (field edit)', K, [
        { table: 'kpi_entries', op: 'UPDATE', key: { id: id('k1') }, cols: ['evidence_note', 'scored_at', 'scored_by'], old: { evidence_note: 'Three counts' }, new: { evidence_note: 'Three counts, all within tolerance' }, ctx: kRow }])
    // ── 员工页:评审定的调薪(Q10,approve_review 的另一句)──
    add('employee · salary changed through a review (the review\'s machine note is said in English)', { subject: 'employee', recordId: ea }, [
        { table: 'employment_history', op: 'INSERT', key: { id: id('h1') }, new: { employee_id: ea, effective_date: '2026-11-01', change_type: 'salary_change', old_monthly_salary: 5000, new_monthly_salary: 5200,
          notes: `Salary change approved with performance review ${rv}` } }])

    const WANT = {
        "payroll · recorded (the period and its lines are one operation)": {
            "title": "Payroll recorded · 2 people",
            "part": null,
            "lines": [
                "Month: 01/10/2026",
                "Payment date: 30/10/2026",
                "Currency: SGD",
                "Gross total: 9,000.00 SGD",
                "Net total: 7,200.00 SGD",
                "Source: Provider file Oct.xlsx"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · re-saved: an unchanged pair says nothing, a changed pair is one line each (Q11)": {
            "title": "Payroll changed",
            "part": null,
            "lines": [
                "Payment date: 30/10/2026 → 29/10/2026",
                "Gross total: 9,000.00 SGD → 9,200.00 SGD",
                "Net total: 7,200.00 SGD → 7,360.00 SGD",
                "Line · Sandra Tan · Gross pay: 4,000.00 SGD → 4,200.00 SGD",
                "Line · Sandra Tan · Employee CPF: 800.00 SGD → 840.00 SGD",
                "Line · Sandra Tan · Net pay: 3,200.00 SGD → 3,360.00 SGD"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · re-saved, read without data.view_pay (whether a line changed is pay data: one Restricted line)": {
            "title": "Payroll changed",
            "part": null,
            "lines": [
                "Gross total: 9,000.00 SGD → 9,200.00 SGD",
                "Net total: 7,200.00 SGD → 7,360.00 SGD",
                "Pay lines · 2 people: Restricted"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · re-saved: one person left the sheet, one joined": {
            "title": "Payroll changed",
            "part": null,
            "lines": [
                "Gross total: 9,000.00 SGD → 8,000.00 SGD",
                "Net total: 7,200.00 SGD → 6,400.00 SGD",
                "Line added · Fu Sheng: 3,000.00 SGD",
                "Line removed · Sandra Tan: 4,000.00 SGD"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posting sent for approval (the approval row folds in)": {
            "title": "Payroll posting sent for approval",
            "part": null,
            "lines": [
                "Gross total: 9,200.00 SGD"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posting approved automatically (approvals off: the machine note is not said)": {
            "title": "Payroll posting approved",
            "part": null,
            "lines": [
                "(Approved automatically (approvals were switched off))",
                "Gross total: 9,200.00 SGD"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posting approved; the approver's own pay line (Q10: the bilingual suffix is said in English)": {
            "title": "Payroll posting approved",
            "part": null,
            "lines": [
                "(This period includes the approver's own pay line: EMP-2026-0004)"
            ],
            "reason": "Checked against the provider file",
            "who": "Sandra"
        },
        "payroll · unposting rejected": {
            "title": "Payroll unposting rejected",
            "part": null,
            "lines": [
                "(This period includes the approver's own pay line: EMP-2026-0004)"
            ],
            "reason": "Wait for the bonus run",
            "who": "Sandra"
        },
        "payroll · posting request withdrawn before the log (Q12: the stamp is the only record)": {
            "title": "Payroll posting request withdrawn",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posted (the journal and the executed request fold in)": {
            "title": "Payroll posted",
            "part": null,
            "lines": [
                "Journal: JE-2026-0120"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posted, read without finance (the journal number is Restricted, as on the page)": {
            "title": "Payroll posted",
            "part": null,
            "lines": [
                "Journal: Restricted",
                "(Part of this change is restricted.)"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · unposted (Q10: the machine line in the notes is the reason, never \"Notes changed\")": {
            "title": "Payroll unposted",
            "part": null,
            "lines": [
                "Reversal journal: JE-2026-0131"
            ],
            "reason": "Wrong CPF rate for two people",
            "who": "Sandra"
        },
        "payroll · salaries paid (each line's paid stamp folds in)": {
            "title": "Salaries paid · 2 people",
            "part": null,
            "lines": [
                "Journal: JE-2026-0121"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · CPF paid": {
            "title": "CPF paid",
            "part": null,
            "lines": [
                "CPF paid on: 12/11/2026",
                "Journal: JE-2026-0140"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posted before the log (only the journal is left; known by structure, not by its memo)": {
            "title": "Payroll posted",
            "part": null,
            "lines": [
                "Journal: JE-2026-0017"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · salaries paid before the log (the lines that journal paid are counted from the page)": {
            "title": "Salaries paid · 1 person",
            "part": null,
            "lines": [
                "Journal: JE-2026-0018"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · posting approved before the log (only the approval row; the label's raw kind is not said)": {
            "title": "Payroll posting approved",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "payroll · lines saved before the log, apart from the period (the last save; no person was recorded)": {
            "title": "Pay lines saved · 2 people",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Not recorded"
        },
        "payroll · posting approved, on the summary page (the period is named, the kind is not)": {
            "title": "Payroll posting approved · PAY-2026-0010",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review · annual review opened (Q6: the cycle is named)": {
            "title": "Annual review opened (cycle FY2026 annual)",
            "part": null,
            "lines": [
                "Employee: Lim Wei Ming",
                "Period start: 01/01/2026",
                "Period end: 31/12/2026",
                "Reviewer: Sandra Tan"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · probation review opened": {
            "title": "Probation review opened",
            "part": null,
            "lines": [
                "Employee: Lim Wei Ming",
                "Period start: 01/07/2026",
                "Period end: 30/09/2026",
                "Reviewer: Sandra Tan"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · opened for self-assessment": {
            "title": "Opened for self-assessment",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review · self-assessment reopened (Q35: the page's \"Reopen self-assessment\")": {
            "title": "Self-assessment reopened",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review · self-assessment finalised (the goal results are lines of it)": {
            "title": "Self-assessment finalised",
            "part": null,
            "lines": [
                "Self-assessment: A steady year; the stocktake work went well.",
                "[Goal 1 · Run the monthly stocktake]",
                "Employee result: (empty) → All counts done on time",
                "Actual: (empty) → 12"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · self-assessment saved as a draft": {
            "title": "Self-assessment saved",
            "part": null,
            "lines": [
                "Self-assessment: (empty) → First thoughts"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · conclusion changed": {
            "title": "Review conclusion changed",
            "part": null,
            "lines": [
                "Rating: Meets Expectations → Exceeds Expectations",
                "Written summary: (empty) → Ran every count; trained two new staff."
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · reviewer changed": {
            "title": "Reviewer changed",
            "part": null,
            "lines": [
                "Reviewer: Fu Sheng → Sandra Tan"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · submitted for approval (the approval row folds in)": {
            "title": "Review submitted for approval",
            "part": null,
            "lines": [
                "Rating: Exceeds Expectations"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · approved (Q7: the outcome from the review's own columns; the salary masked as today)": {
            "title": "Review approved",
            "part": null,
            "lines": [
                "Rating: Meets Expectations",
                "Probation outcome: Confirm",
                "New monthly salary: Restricted",
                "Effective from: 01/11/2026"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · approved, read with data.view_pay": {
            "title": "Review approved",
            "part": null,
            "lines": [
                "Rating: Meets Expectations",
                "Probation outcome: Confirm",
                "New monthly salary: 5,200.00 SGD",
                "Effective from: 01/11/2026"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · approved before the log (only the approval row; the outcome is today's review)": {
            "title": "Review approved",
            "part": null,
            "lines": [
                "Rating: Meets Expectations"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · acknowledged by the employee": {
            "title": "Review acknowledged by the employee",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review · voided": {
            "title": "Review voided",
            "part": null,
            "lines": [],
            "reason": "Opened for the wrong person",
            "who": "Sandra"
        },
        "review · voided before the log (Q12: the stamp is the only record, with its reason)": {
            "title": "Review voided",
            "part": null,
            "lines": [],
            "reason": "Duplicate of the probation review",
            "who": "Sandra"
        },
        "review · goal added": {
            "title": "Goal added",
            "part": "Run the monthly stocktake",
            "lines": [
                "Target: 12",
                "Unit: counts"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · goal changed (field edit)": {
            "title": "Goal changed",
            "part": "Run the monthly stocktake",
            "lines": [
                "Target: 12 → 10"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review · goal removed (hard delete: its last values)": {
            "title": "Goal removed",
            "part": "Cut forklift idle time",
            "lines": [
                "Target: 10",
                "Unit: %"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "my review · approved, read by a reviewer without hr.view (Q5: the approval row is Restricted)": {
            "title": "Review approved",
            "part": null,
            "lines": [
                "Rating: Meets Expectations",
                "New monthly salary: Restricted",
                "(Part of this change is restricted.)"
            ],
            "reason": null,
            "who": "Restricted"
        },
        "review · approved, on the summary page (the employee code is named)": {
            "title": "Review approved · EMP-2026-0007",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review cycle · created": {
            "title": "Review cycle created",
            "part": "FY2026 annual",
            "lines": [
                "Period start: 01/01/2026",
                "Period end: 31/12/2026",
                "Due date: 31/01/2027"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "review cycle · opened (Q6: the reviews it creates are not on the cycle)": {
            "title": "Review cycle opened",
            "part": "FY2026 annual",
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review cycle · closed": {
            "title": "Review cycle closed",
            "part": "FY2026 annual",
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "review cycle · due date changed (field edit)": {
            "title": "Review cycle changed",
            "part": "FY2026 annual",
            "lines": [
                "Due date: 31/01/2027 → 15/02/2027"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "rating scale · a rating added": {
            "title": "Rating added",
            "part": "Far Below Expectations",
            "lines": [
                "Name (Chinese): 远低于预期",
                "Usually passes probation: No",
                "Active: Yes"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "rating scale · description changed (field edit)": {
            "title": "Rating changed",
            "part": "Meets Expectations",
            "lines": [
                "Description (English): Met the objectives set for the period. → Met every objective set for the period."
            ],
            "reason": null,
            "who": "Sandra"
        },
        "rating scale · deactivated": {
            "title": "Rating deactivated",
            "part": "Below Expectations",
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "rating scale · two seeded before the log (one moment, one entry)": {
            "title": "Rating added",
            "part": "Outstanding",
            "lines": [
                "Name (Chinese): 卓越",
                "Usually passes probation: Yes",
                "Active: Yes",
                "[Rating added · Meets Expectations]",
                "Name (Chinese): 符合预期",
                "Usually passes probation: Yes",
                "Active: Yes"
            ],
            "reason": null,
            "who": "Not recorded"
        },
        "KPI · five entries generated for one person (one operation, Q16)": {
            "title": "KPI entries generated · 5",
            "part": null,
            "lines": [
                "Employee: Lim Wei Ming",
                "F1: Stocktake accuracy (30%)",
                "F2: Receiving turnaround (20%)",
                "C5: Planned maintenance done (20%)",
                "S1: Safety observations (15%)",
                "T3: Training hours (15%)"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "KPI · scored (judged, with evidence and feedback)": {
            "title": "KPI scored: 4",
            "part": "F1 · Stocktake accuracy",
            "lines": [
                "How it was scored: Judged",
                "Evidence: Three counts, one variance found and cleared",
                "Feedback: Keep the Friday count"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "KPI · re-scored, capped by a safety override": {
            "title": "KPI re-scored: 4 → 5",
            "part": "F1 · Stocktake accuracy",
            "lines": [
                "How it was scored: Judged",
                "Safety / regulatory cap: 2",
                "Reason for the cap: Forklift near-miss on 14/10"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "KPI · scored before the log (the stamp is the only record of that scoring)": {
            "title": "KPI scored: 3",
            "part": "F1 · Stocktake accuracy",
            "lines": [
                "How it was scored: Computed"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "KPI · evidence changed, the score unchanged (field edit)": {
            "title": "KPI entry changed",
            "part": "F1 · Stocktake accuracy",
            "lines": [
                "Evidence: Three counts → Three counts, all within tolerance"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "employee · salary changed through a review (the review's machine note is said in English)": {
            "title": "Salary changed",
            "part": null,
            "lines": [
                "Effective date: 01/11/2026",
                "Previous monthly salary: 5,000.00 SGD",
                "New monthly salary: 5,200.00 SGD",
                "(Changed through a performance review)"
            ],
            "reason": null,
            "who": "Sandra"
        }
    }
    const got13 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 45) problems.gold13.push(`⑬ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD13', order: r.group ? 2 : 1, prelog: false, at: '2026-10-03T02:00:00+00:00', key: { id: uuid() },
            actor: c.actor ?? { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold13.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        const mine = es.filter((x) => x.key === 'GOLD13')
        if (mine.length !== 1) { problems.gold13.push(`${c.label}:一次操作应当是一条,造出了 ${mine.length} 条(${mine.map((x) => x.title).join(' | ')})`); continue }
        const e = mine[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null, who: e.who.text }
        got13[c.label] = got
        const w = WANT[c.label]
        if (!w) { problems.gold13.push(`${c.label}:金句表里没有这一句`); continue }
        for (const k of ['title', 'part', 'reason', 'who']) if (got[k] !== w[k]) problems.gold13.push(`${c.label}:${k}「${got[k]}」≠「${w[k]}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold13.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
    }
    if (process.env.TRAIL_GOLD13_PRINT) console.log(JSON.stringify(got13, null, 8))
    // 两支剥机器字的函数:人的话留下、系统追加的那一截去掉、只有系统那一截时为空;撤销追加的理由取最后一次
    const dn = R.splitPayrollDecisionNote(`OK\n${own}`), dn2 = R.splitPayrollDecisionNote(own), dn3 = R.splitPayrollDecisionNote('Fine')
    if (dn.text !== 'OK' || dn.ownLine !== 'EMP-2026-0004' || dn2.text !== null || dn2.ownLine !== 'EMP-2026-0004' || dn3.text !== 'Fine' || dn3.ownLine !== null)
        problems.gold13.push('splitPayrollDecisionNote 没有照约定剥(人的话留下、那一行的员工编号取出、只有系统那一截时为空)')
    const un = R.splitPayrollUnpostNote('Bonus\n[2026-10-01 10:00 unposted] First\n[2026-10-02 11:00 unposted] Second')
    if (un.notes !== 'Bonus' || un.reason !== 'Second' || un.unposts !== 2 || R.splitPayrollUnpostNote('[2026-10-01 10:00 unposted] Only').notes !== null)
        problems.gold13.push('splitPayrollUnpostNote 没有照约定剥(人写的备注留下、理由取最后一次、时间戳不留)')

    // 机器字扫描:六个主语各自的表,按【这一页】的说法(subject)造样本跑一遍;外加两种审批的每一种决定、工资申请与评审的每一种状态
    const SUBS13 = ['payroll_period', 'performance_review', 'my_review', 'review_cycle', 'review_rating_scale', 'kpi_entry']
    let s13 = 0
    for (const sub of SUBS13) {
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
                for (const [op, o] of [['INSERT', { new: img, prelog: variant === 3 }], ['UPDATE', { cols: cols.map(([c]) => c), old, new: neu, ctx: img, prelog: variant === 3 }], ['DELETE', { old: img }]]) {
                    sweep(`${sub} · ${t} · ${op} · 样本 ${variant}`, [row(t, op, { ...o, refs })], sub)
                    s13++
                }
            }
        }
        for (const st of ['payroll_request', 'performance_review']) for (const dec of checkValues('approval_log', 'decision') ?? []) {
            sweep(`${sub} · approval ${st} ${dec}`, [row('approval_log', 'INSERT', { new: { subject_type: st, subject_id: uuid(), subject_code: 'PAY-2026-0001 · post #1', decision: dec,
                note: `n\n本期含审批人自己的工资行 · this period includes the approver's own pay line: EMP-2026-0001` } })], sub)
            s13++
        }
        for (const st of checkValues('payroll_requests', 'status') ?? []) {
            sweep(`${sub} · payroll request → ${st}`, [row('payroll_requests', 'UPDATE', { cols: ['status'], old: { status: 'submitted' }, new: { status: st, kind: 'reversal', label: 'PAY-2026-0001 · reversal #2' } })], sub)
            s13++
        }
        for (const st of checkValues('performance_reviews', 'status') ?? []) {
            sweep(`${sub} · review → ${st}`, [row('performance_reviews', 'UPDATE', { cols: ['status'], old: { status: 'draft', self_assessment_submitted_at: '2026-10-01T02:00:00Z' }, new: { status: st } })], sub)
            s13++
        }
        sweep(`${sub} · payroll unposted`, [row('payroll_periods', 'UPDATE', { cols: ['status', 'notes'], old: { status: 'posted', notes: 'x' }, new: { status: 'draft', notes: 'x\n[2026-10-04 21:16 unposted] Wrong rate' } })], sub)
        s13++
        sweep(`${sub} 整条看不见`, [row(R.SUBJECT_TABLES[sub][0], null, { hidden: true, table: null, actor: null })], sub)
        s13++
    }
    const decisions13 = (checkValues('approval_log', 'decision') ?? []).length
    const prStates = (checkValues('payroll_requests', 'status') ?? []).length, rvStates = (checkValues('performance_reviews', 'status') ?? []).length
    const s13Want = SUBS13.reduce((n, sub) => n + (R.SUBJECT_TABLES[sub] ?? []).length * 12 + 2 * decisions13 + prStates + rvStates + 2, 0)
    if (s13 !== s13Want || s13 < 200 || !decisions13 || !prStates || !rvStates) problems.coverage.push(`工资与评审那六个主语的机器字扫描造了 ${s13} 句,登记表要求 ${s13Want} 句(审批决定 ${decisions13} 种、申请状态 ${prStates} 种、评审状态 ${rvStates} 种)—— 造样本那一段瞎了`)
    if (FAULT === 'wording-drift-1d3' && !problems.gold13.length) problems.gold13.push('(注入 wording-drift-1d3 没有咬人 —— 这一臂瞎了)')
}

// ── ⑭ U1-B 的工作流与剩下的泄漏(UNBLOCK-1 Q15 · Q20 · Q25 · U1-A close-out 两件)────────────────────────
// 每一句都先由造句器造出来、逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/U1-B.md 逐条列出。
//   停机作废(带理由,不是"恢复运行"也不是"更正")· 一段已结束的停机被改了结束时刻是"更正",不是第二次"恢复运行" ·
//   采购单关闭 / 重开的理由来自它们自己的列(与修改史那一行并成一条,不再说成一次没有理由的"修改")·
//   深度放电判断是一条关键事件 · 工资分录的冲销申请对不持 data.view_pay 的读者金额是 Restricted ·
//   医疗报销的批准理由与审批说明对不持 data.view_health 的读者是 Restricted(不是消失)。
//   注入 wording-drift-u1b → 这一臂必须红。
problems.gold14 = []
if (FAULT === 'wording-drift-u1b') dict.text = { ...dict.text, 'eq.downVoided': 'Downtime deleted' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows, actor) => C.push({ label, opts, rows, actor })
    const R14 = { $restricted: true }
    // ── 停机(固定资产页与设备页同一支造句器)──
    const fa = id('fa'), dt = id('dt')
    const dtRow = { equipment_id: fa, started_at: '2026-10-01T01:00:00Z', ended_at: null, reason: 'Belt snapped' }
    const E = { subject: 'equipment', recordId: fa, currency: 'SGD' }
    add('downtime · voided with a reason (not "came back up", not "corrected")', E, [
        { table: 'equipment_downtime', op: 'UPDATE', key: { id: dt }, cols: ['voided_at', 'voided_by', 'void_reason', 'updated_by'],
          old: { voided_at: null, voided_by: null, void_reason: null }, new: { voided_at: '2026-10-05T02:00:00Z', voided_by: id('u1'), void_reason: 'Entered on the wrong machine' }, ctx: dtRow }])
    add('downtime · a closed period whose end time is corrected (a correction, not a second "came back up")', E, [
        { table: 'equipment_downtime', op: 'UPDATE', key: { id: dt }, cols: ['ended_at', 'updated_by'],
          old: { ended_at: '2026-10-01T05:00:00Z' }, new: { ended_at: '2026-10-01T04:30:00Z' }, ctx: { ...dtRow, ended_at: '2026-10-01T05:00:00Z' } }])
    add('downtime · start time and reason corrected', E, [
        { table: 'equipment_downtime', op: 'UPDATE', key: { id: dt }, cols: ['started_at', 'reason', 'updated_by'],
          old: { started_at: '2026-10-01T01:00:00Z', reason: 'Belt snapped' }, new: { started_at: '2026-10-01T00:30:00Z', reason: 'Belt snapped on the feeder' }, ctx: dtRow }])
    add('downtime · ended (the first end time is still "came back up")', E, [
        { table: 'equipment_downtime', op: 'UPDATE', key: { id: dt }, cols: ['ended_at', 'updated_by'],
          old: { ended_at: null }, new: { ended_at: '2026-10-01T05:00:00Z' }, ctx: dtRow }])
    // ── 销售单(Q14):给一张发完的单加一行 —— 状态翻回部分发货是改单的结果,标题是改单 ──
    const so14 = id('so')
    add('sales order · a line added to a fully shipped order (the status flip sits under the amendment)', { subject: 'sales_order', recordId: so14, currency: 'SGD' }, [
        { table: 'sales_orders', op: 'UPDATE', key: { id: so14 }, cols: ['status', 'updated_by'], old: { status: 'shipped' }, new: { status: 'partially_shipped' },
          ctx: { code: 'SO-2026-0031', currency: 'SGD', status: 'shipped' } },
        { table: 'sales_order_history', op: 'INSERT', key: { id: id('soh') }, new: { sales_order_id: so14, change_type: 'line_add', line_no: 2,
          new_quantity: 5, new_unit_price: 10, amend_reason: 'The customer wants 5 more' } }])
    // ── 采购单 ──
    const po = id('po'), ln = id('ln')
    const poRow = { code: 'PO-2026-0031', status: 'receiving', currency: 'SGD', notes: 'Deliver to bay 2' }
    const P = { subject: 'purchase_order', recordId: po, currency: 'SGD' }
    add('purchase order · closed with a reason (the history row folds in; Notes untouched)', P, [
        { table: 'purchase_orders', op: 'UPDATE', key: { id: po }, cols: ['status', 'closed_at', 'closed_by', 'close_reason', 'updated_by'],
          old: { status: 'receiving', closed_at: null, closed_by: null, close_reason: null },
          new: { status: 'closed', closed_at: '2026-10-05T03:00:00Z', closed_by: id('u1'), close_reason: 'Supplier cannot deliver the rest' }, ctx: poRow },
        { table: 'purchase_order_history', op: 'INSERT', key: { id: id('h1') }, new: { purchase_order_id: po, change_type: 'closed', amend_reason: 'Supplier cannot deliver the rest' } }])
    add('purchase order · reopened with a reason', P, [
        { table: 'purchase_orders', op: 'UPDATE', key: { id: po }, cols: ['status', 'closed_at', 'closed_by', 'close_reason', 'reopened_at', 'reopened_by', 'reopen_reason', 'updated_by'],
          old: { status: 'closed', closed_at: '2026-10-05T03:00:00Z', closed_by: id('u1'), close_reason: 'Supplier cannot deliver the rest', reopened_at: null, reopened_by: null, reopen_reason: null },
          new: { status: 'receiving', closed_at: null, closed_by: null, close_reason: null, reopened_at: '2026-10-06T03:00:00Z', reopened_by: id('u1'), reopen_reason: 'Supplier found the remaining stock' }, ctx: poRow },
        { table: 'purchase_order_history', op: 'INSERT', key: { id: id('h2') }, new: { purchase_order_id: po, change_type: 'reopened', amend_reason: 'Supplier found the remaining stock' } }])
    add('purchase order · closed with no reason given', P, [
        { table: 'purchase_orders', op: 'UPDATE', key: { id: po }, cols: ['status', 'closed_at', 'closed_by', 'updated_by'],
          old: { status: 'receiving', closed_at: null, closed_by: null }, new: { status: 'closed', closed_at: '2026-10-05T03:00:00Z', closed_by: id('u1') }, ctx: poRow },
        { table: 'purchase_order_history', op: 'INSERT', key: { id: id('h3') }, new: { purchase_order_id: po, change_type: 'closed', amend_reason: null } }])
    add('purchase order · deep discharge judgement recorded on a line (a key event, not an amendment)', P, [
        { table: 'purchase_order_lines', op: 'UPDATE', key: { id: ln }, cols: ['deep_discharge_judgement_code'],
          old: { deep_discharge_judgement_code: null }, new: { deep_discharge_judgement_code: 'cannot' },
          ctx: { purchase_order_id: po, line_no: 1, material_id: id('mat') },
          refs: { material_id: { [id('mat')]: { label: 'MAT-2026-0001 · NMC Cathode Foil' } }, deep_discharge_judgement_code: { cannot: { label: 'Cannot be deep-discharged' } } } }])
    // ── 工资分录的冲销申请 ──
    const jr = id('jr'), je = id('je')
    const J = { subject: 'journal_request', recordId: jr, currency: 'SGD' }
    const jrNew = { kind: 'reversal', status: 'submitted', label: 'Reversal of JE-2026-0018', entry_date: '2026-10-05', memo: 'Paid twice', target_entry_id: je, credits_bank: true }
    add('journal request · a payroll reversal read without data.view_pay (the amount is Restricted)', J, [
        { table: 'journal_requests', op: 'INSERT', key: { id: jr }, new: { ...jrNew, amount_base: R14 },
          refs: { target_entry_id: { [je]: { label: 'JE-2026-0018', href: `/finance/journal/${je}` } } } }])
    add('journal request · the same request read with data.view_pay', J, [
        { table: 'journal_requests', op: 'INSERT', key: { id: jr }, new: { ...jrNew, amount_base: 4677 },
          refs: { target_entry_id: { [je]: { label: 'JE-2026-0018', href: `/finance/journal/${je}` } } } }])
    // ── 医疗报销(报销单页与它生成的费用单页)──
    const mc = id('mc')
    const M = { subject: 'medical_claim', recordId: mc, currency: 'SGD' }
    const mcRow = { code: 'MC-2026-0007', employee_id: id('emp'), status: 'submitted' }
    add('medical claim · approved, read without data.view_health (the reason is Restricted, never dropped)', M, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: R14 }, ctx: mcRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('ap1') }, new: { subject_type: 'medical_claim', subject_id: mc, subject_code: 'MC-2026-0007', decision: 'approved', level: 1, note: R14, amount_ccy: R14, amount_base: R14 } }])
    add('medical claim · approved, read with data.view_health', M, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: 'Covered under the outpatient benefit' }, ctx: mcRow },
        { table: 'approval_log', op: 'INSERT', key: { id: id('ap2') }, new: { subject_type: 'medical_claim', subject_id: mc, subject_code: 'MC-2026-0007', decision: 'approved', level: 1, note: 'Covered under the outpatient benefit', amount_ccy: 120, amount_base: 120 } }])
    const ex = id('ex')
    add('expense page · the medical claim it came from is approved, read without data.view_health', { subject: 'expense', recordId: ex, currency: 'SGD' }, [
        { table: 'medical_claims', op: 'UPDATE', key: { id: mc }, cols: ['status', 'decided_at', 'decided_by', 'decision_notes'],
          old: { status: 'submitted' }, new: { status: 'approved', decision_notes: R14 }, ctx: { ...mcRow, expense_id: ex } }])
    const WANT = {
        "sales order · a line added to a fully shipped order (the status flip sits under the amendment)": {
            "title": "Sales order amended · line added · Line 2",
            "part": null,
            "lines": [
                "Quantity: (empty) → 5",
                "Unit price: (empty) → 10.00 SGD",
                "[Sales order status changed]",
                "Status: Shipped → Partially shipped"
            ],
            "reason": "The customer wants 5 more",
            "who": "Sandra"
        },
        "downtime · voided with a reason (not \"came back up\", not \"corrected\")": {
            "title": "Downtime voided",
            "part": null,
            "lines": [
                "Went down: 01/10/2026 09:00"
            ],
            "reason": "Entered on the wrong machine",
            "who": "Sandra"
        },
        "downtime · a closed period whose end time is corrected (a correction, not a second \"came back up\")": {
            "title": "Downtime corrected",
            "part": null,
            "lines": [
                "Came back up: 01/10/2026 13:00 → 01/10/2026 12:30"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "downtime · start time and reason corrected": {
            "title": "Downtime corrected",
            "part": null,
            "lines": [
                "Went down: 01/10/2026 09:00 → 01/10/2026 08:30",
                "Reason: Belt snapped → Belt snapped on the feeder"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "downtime · ended (the first end time is still \"came back up\")": {
            "title": "Downtime ended",
            "part": null,
            "lines": [
                "Came back up: 01/10/2026 13:00"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "purchase order · closed with a reason (the history row folds in; Notes untouched)": {
            "title": "Purchase order closed",
            "part": null,
            "lines": [],
            "reason": "Supplier cannot deliver the rest",
            "who": "Sandra"
        },
        "purchase order · reopened with a reason": {
            "title": "Purchase order reopened",
            "part": null,
            "lines": [],
            "reason": "Supplier found the remaining stock",
            "who": "Sandra"
        },
        "purchase order · closed with no reason given": {
            "title": "Purchase order closed",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Sandra"
        },
        "purchase order · deep discharge judgement recorded on a line (a key event, not an amendment)": {
            "title": "Deep discharge judgement recorded",
            "part": null,
            "lines": [
                "[Line 1 · MAT-2026-0001 · NMC Cathode Foil]",
                "Deep discharge judgement: (empty) → Cannot be deep-discharged"
            ],
            "reason": null,
            "who": "Sandra"
        },
        "journal request · a payroll reversal read without data.view_pay (the amount is Restricted)": {
            "title": "Reversal sent for approval",
            "part": "Reversal of JE-2026-0018",
            "lines": [
                "Entry date: 05/10/2026",
                "Amount (sum of debits): Restricted"
            ],
            "reason": "Paid twice",
            "who": "Sandra"
        },
        "journal request · the same request read with data.view_pay": {
            "title": "Reversal sent for approval",
            "part": "Reversal of JE-2026-0018",
            "lines": [
                "Entry date: 05/10/2026",
                "Amount (sum of debits): 4,677.00 SGD"
            ],
            "reason": "Paid twice",
            "who": "Sandra"
        },
        "medical claim · approved, read without data.view_health (the reason is Restricted, never dropped)": {
            "title": "Medical claim approved",
            "part": null,
            "lines": [],
            "reason": "Restricted",
            "who": "Sandra"
        },
        "medical claim · approved, read with data.view_health": {
            "title": "Medical claim approved",
            "part": null,
            "lines": [],
            "reason": "Covered under the outpatient benefit",
            "who": "Sandra"
        },
        "expense page · the medical claim it came from is approved, read without data.view_health": {
            "title": "Medical claim approved · MC-2026-0007",
            "part": null,
            "lines": [],
            "reason": "Restricted",
            "who": "Sandra"
        }
    }
    const got14 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 13) problems.gold14.push(`⑭ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD14', order: 1, prelog: false, at: '2026-10-05T02:00:00+00:00', key: { id: uuid() },
            actor: c.actor ?? { state: 'person', name: 'Sandra' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold14.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        const mine = es.filter((x) => x.key === 'GOLD14')
        if (mine.length !== 1) { problems.gold14.push(`${c.label}:一次操作应当是一条,造出了 ${mine.length} 条(${mine.map((x) => x.title).join(' | ')})`); continue }
        const e = mine[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null, who: e.who.text }
        got14[c.label] = got
        const w = WANT[c.label]
        if (!w) { problems.gold14.push(`${c.label}:金句表里没有这一句`); continue }
        for (const k of ['title', 'part', 'reason', 'who']) if (got[k] !== w[k]) problems.gold14.push(`${c.label}:${k}「${got[k]}」≠「${w[k]}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold14.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
    }
    if (process.env.TRAIL_GOLD14_PRINT) console.log(JSON.stringify(got14, null, 8))
    if (FAULT === 'wording-drift-u1b' && !problems.gold14.length) problems.gold14.push('(注入 wording-drift-u1b 没有咬人 —— 这一臂瞎了)')
}

// ── ⑮ MES-1 的设备与网关钥匙(MES-1 Step 0 Q20 · Q21 · Q22)────────────────────────────────────────────
// 每一句先由造句器造出来、逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/MES-1.md 列出。
//   登记一台网关是一条关键事件(编号在标题里,不再印)· 给心跳间隔是一次"修改" · 停用带理由 ·
//   发钥匙与撤钥匙各一块,只说那 8 个字符的前缀(哈希一个字都不提 —— 它在变更记录里被 never 规则遮住)·
//   采集上限的修改是"Ingestion limits changed"。注入 wording-drift-mes1 → 这一臂必须红。
problems.gold15 = []
if (FAULT === 'wording-drift-mes1') dict.text = { ...dict.text, 'dev.keyRevoked': 'Gateway key deleted' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows, actor) => C.push({ label, opts, rows, actor })
    const gw = id('gw')
    const gwRow = { code: 'DEV-2026-0001', name: 'Line 1 gateway', kind: 'gateway', interface_status: 'reserved', heartbeat_interval_s: null }
    const D15 = { subject: 'device', recordId: gw, currency: null }
    add('device · a gateway registered', D15, [
        { table: 'devices', op: 'INSERT', key: { id: gw }, new: { ...gwRow, term_protocol: 'not_confirmed', station: 'Line 1' } }])
    add('device · its heartbeat interval set', D15, [
        { table: 'devices', op: 'UPDATE', key: { id: gw }, cols: ['heartbeat_interval_s', 'updated_at', 'updated_by'],
          old: { heartbeat_interval_s: null }, new: { heartbeat_interval_s: 60 }, ctx: gwRow }])
    add('device · a contract term confirmed', D15, [
        { table: 'devices', op: 'UPDATE', key: { id: gw }, cols: ['term_point_list', 'updated_at', 'updated_by'],
          old: { term_point_list: 'not_confirmed' }, new: { term_point_list: 'confirmed' }, ctx: gwRow }])
    add('device · retired with a reason', D15, [
        { table: 'devices', op: 'UPDATE', key: { id: gw }, cols: ['retired_at', 'retired_by', 'retire_reason', 'updated_at', 'updated_by'],
          old: { retired_at: null, retired_by: null, retire_reason: null },
          new: { retired_at: '2026-10-06T02:00:00Z', retired_by: id('u'), retire_reason: 'Replaced by the new gateway' }, ctx: gwRow }])
    add('gateway key · issued (the prefix only, never the hash)', D15, [
        { table: 'gateway_keys', op: 'INSERT', key: { id: id('k1') },
          new: { gateway_id: gw, key_prefix: '1a2b3c4d', key_hash: { $restricted: true }, issued_at: '2026-10-06T01:00:00Z', issued_by: id('u') } }])
    add('gateway key · revoked with a reason', D15, [
        { table: 'gateway_keys', op: 'UPDATE', key: { id: id('k1') }, cols: ['revoked_at', 'revoked_by', 'revoke_reason'],
          old: { revoked_at: null, revoked_by: null, revoke_reason: null },
          new: { revoked_at: '2026-10-06T03:00:00Z', revoked_by: id('u'), revoke_reason: 'Rotated to the new key' },
          ctx: { gateway_id: gw, key_prefix: '1a2b3c4d' } }])
    add('ingestion limits · the payload cap changed', { subject: 'ingest_settings', recordId: 'true', currency: null }, [
        { table: 'ingest_settings', op: 'UPDATE', key: { id: true }, cols: ['max_payload_bytes', 'updated_at', 'updated_by'],
          old: { max_payload_bytes: 262144 }, new: { max_payload_bytes: 524288 }, ctx: { id: true } }])
    const WANT = {
        "device · a gateway registered": {
            "title": "Device registered",
            "part": null,
            "lines": [
                "Name: Line 1 gateway",
                "Kind: Gateway",
                "Interface: Not yet connected — entered by hand",
                "Standard industrial protocol: Not yet confirmed",
                "Station: Line 1"
            ],
            "reason": null,
            "who": "Phua"
        },
        "device · its heartbeat interval set": {
            "title": "Device changed",
            "part": null,
            "lines": [
                "Heartbeat interval (seconds): (empty) → 60"
            ],
            "reason": null,
            "who": "Phua"
        },
        "device · a contract term confirmed": {
            "title": "Device changed",
            "part": null,
            "lines": [
                "Complete list of readable parameters: Not yet confirmed → Confirmed"
            ],
            "reason": null,
            "who": "Phua"
        },
        "device · retired with a reason": {
            "title": "Device retired",
            "part": null,
            "lines": [],
            "reason": "Replaced by the new gateway",
            "who": "Phua"
        },
        "gateway key · issued (the prefix only, never the hash)": {
            "title": "Gateway key issued",
            "part": "1a2b3c4d…",
            "lines": [],
            "reason": null,
            "who": "Phua"
        },
        "gateway key · revoked with a reason": {
            "title": "Gateway key revoked",
            "part": "1a2b3c4d…",
            "lines": [],
            "reason": "Rotated to the new key",
            "who": "Phua"
        },
        "ingestion limits · the payload cap changed": {
            "title": "Ingestion limits changed",
            "part": null,
            "lines": [
                "Largest call (bytes): 262,144 → 524,288"
            ],
            "reason": null,
            "who": "Phua"
        }
    }
    const got15 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 7) problems.gold15.push(`⑮ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD15', order: 1, prelog: false, at: '2026-10-06T02:00:00+00:00', key: { id: uuid() },
            actor: c.actor ?? { state: 'person', name: 'Phua' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold15.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        const mine = es.filter((x) => x.key === 'GOLD15')
        if (mine.length !== 1) { problems.gold15.push(`${c.label}:一次操作应当是一条,造出了 ${mine.length} 条(${mine.map((x) => x.title).join(' | ')})`); continue }
        const e = mine[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null, who: e.who.text }
        got15[c.label] = got
        const w = WANT[c.label]
        if (!w) { problems.gold15.push(`${c.label}:金句表里没有这一句`); continue }
        for (const k of ['title', 'part', 'reason', 'who']) if (got[k] !== w[k]) problems.gold15.push(`${c.label}:${k}「${got[k]}」≠「${w[k]}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold15.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
        if (JSON.stringify(got).includes('key_hash') || /Key hash/i.test(JSON.stringify(got))) problems.gold15.push(`${c.label}:钥匙的哈希出现在记录里`)
    }
    if (process.env.TRAIL_GOLD15_PRINT) console.log(JSON.stringify(got15, null, 8))
    if (FAULT === 'wording-drift-mes1' && !problems.gold15.length) problems.gold15.push('(注入 wording-drift-mes1 没有咬人 —— 这一臂瞎了)')
}

// ── ⑯ MES-2 的校准记录与地磅单(MES-2 Step 0 Q11 · Q16 · Q19 · Q21 · Q24 · Q33)────────────────────────────────────
// 每一句先由造句器造出来、逐句人工核过,再钉在这里 —— 交回报告 docs/handbacks/MES-2.md 列出。
//   设备主语多了校准记录(记一次 · 作废带理由);地磅单是新主语:开单(方向与车牌)· 一磅(角色、读数、仪器)·
//   更正一磅(带理由,不说成"修改")· 完成(第二磅落下那一次,不说成"修改")· 分一份(收货单的数量与份不同的理由)·
//   照片(只说文件名)· 撤下照片与作废地磅单带理由。注入 wording-drift-mes2 → 这一臂必须红。
problems.gold16 = []
if (FAULT === 'wording-drift-mes2') dict.text = { ...dict.text, 'wb.weighingCorrected': 'Weighing edited' }
{
    const ids = {}
    const id = (k) => (ids[k] ??= uuid())
    const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
        : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
    const C = []
    const add = (label, opts, rows, actor) => C.push({ label, opts, rows, actor })
    const dev = id('dev')
    const D16 = { subject: 'device', recordId: dev, currency: null }
    add('calibration · recorded', D16, [
        { table: 'instrument_calibrations', op: 'INSERT', key: { id: 7 },
          new: { id: 7, device_id: dev, calibrated_on: '2026-10-01', valid_until: '2027-09-30', result: 'passed', certificate_no: 'CAL-2026-118',
                 calibrating_body: 'Accredited Lab', notes: null, recorded_at: '2026-10-06T02:00:00Z', recorded_by: id('u') } }])
    add('calibration · voided with a reason', D16, [
        { table: 'instrument_calibrations', op: 'UPDATE', key: { id: 7 }, cols: ['voided_at', 'voided_by', 'void_reason'],
          old: { voided_at: null, voided_by: null, void_reason: null },
          new: { voided_at: '2026-10-06T03:00:00Z', voided_by: id('u'), void_reason: 'Certificate belonged to another scale' },
          ctx: { device_id: dev, calibrated_on: '2026-10-01' } }])
    const tk = id('tk')
    const T16 = { subject: 'weighbridge_ticket', recordId: tk, currency: null }
    add('ticket · opened', T16, [
        { table: 'weighbridge_tickets', op: 'INSERT', key: { id: tk },
          new: { code: 'WB-2026-0001', direction: 'inbound', vehicle_reg: 'GBA 1234 X', notes: null, completed_at: null } }])
    add('ticket · the gross weighing', T16, [
        { table: 'weighings', op: 'INSERT', key: { id: id('w1') },
          new: { ticket_id: tk, role: 'gross', weight_kg: 12000, source: 'device', device_id: null, captured_at: '2026-10-06T01:00:00Z',
                 confirmed_at: '2026-10-06T01:05:00Z', confirmed_by: id('u'), corrects_id: null, correction_reason: null } }])
    add('ticket · a weighing corrected with a reason', T16, [
        { table: 'weighings', op: 'INSERT', key: { id: id('w2') },
          new: { ticket_id: tk, role: 'gross', weight_kg: 11980, source: 'manual', device_id: null, captured_at: '2026-10-06T01:00:00Z',
                 confirmed_at: '2026-10-06T01:20:00Z', confirmed_by: id('u'), corrects_id: id('w1'), correction_reason: 'Pallet was still on the deck' } }])
    add('ticket · completed by the second weighing', T16, [
        { table: 'weighbridge_tickets', op: 'UPDATE', key: { id: tk }, cols: ['completed_at', 'updated_at', 'updated_by'],
          old: { completed_at: null }, new: { completed_at: '2026-10-06T02:00:00Z' }, ctx: { code: 'WB-2026-0001', direction: 'inbound' } }])
    add('ticket · shared to a receipt, with the quantity reason', T16, [
        { table: 'weighbridge_ticket_shares', op: 'INSERT', key: { id: id('s1') },
          new: { ticket_id: tk, inbound_batch_id: null, shipment_line_id: null, kg: 8000, receipt_quantity_reason: 'Two bags torn, swept and weighed apart' } }])
    add('ticket · a photo added', T16, [
        { table: 'weighbridge_ticket_photos', op: 'INSERT', key: { id: id('p1') },
          new: { ticket_id: tk, file_path: 'x/y-ticket.jpg', file_name: 'ticket-front.jpg', mime_type: 'image/jpeg', size_bytes: 120000 } }])
    add('ticket · a photo withdrawn with a reason', T16, [
        { table: 'weighbridge_ticket_photos', op: 'UPDATE', key: { id: id('p1') }, cols: ['withdrawn_at', 'withdrawn_by', 'withdraw_reason'],
          old: { withdrawn_at: null, withdrawn_by: null, withdraw_reason: null },
          new: { withdrawn_at: '2026-10-06T03:00:00Z', withdrawn_by: id('u'), withdraw_reason: 'Wrong truck' }, ctx: { file_name: 'ticket-front.jpg' } }])
    add('ticket · voided with a reason', T16, [
        { table: 'weighbridge_tickets', op: 'UPDATE', key: { id: tk }, cols: ['voided_at', 'voided_by', 'void_reason', 'updated_at', 'updated_by'],
          old: { voided_at: null, voided_by: null, void_reason: null },
          new: { voided_at: '2026-10-06T04:00:00Z', voided_by: id('u'), void_reason: 'Opened for the wrong vehicle' }, ctx: { code: 'WB-2026-0001' } }])
    const WANT = {
        "calibration · recorded": {
            "title": "Calibration recorded",
            "part": null,
            "lines": [
                "Calibrated on: 01/10/2026",
                "Valid until: 30/09/2027",
                "Result: Passed",
                "Certificate number: CAL-2026-118",
                "Calibrated by: Accredited Lab"
            ],
            "reason": null,
            "who": "Fu Sheng"
        },
        "calibration · voided with a reason": {
            "title": "Calibration voided",
            "part": null,
            "lines": [],
            "reason": "Certificate belonged to another scale",
            "who": "Fu Sheng"
        },
        "ticket · opened": {
            "title": "Ticket opened",
            "part": null,
            "lines": [
                "Direction: Inbound",
                "Vehicle registration: GBA 1234 X"
            ],
            "reason": null,
            "who": "Fu Sheng"
        },
        "ticket · the gross weighing": {
            "title": "Weighing recorded",
            "part": null,
            "lines": [
                "Weighing: Gross",
                "Weight (kg): 12,000",
                "Source: From the instrument",
                "Weighed at: 06/10/2026 09:00"
            ],
            "reason": null,
            "who": "Fu Sheng"
        },
        "ticket · a weighing corrected with a reason": {
            "title": "Weighing corrected",
            "part": null,
            "lines": [
                "Weighing: Gross",
                "Weight (kg): 11,980",
                "Source: Entered by hand",
                "Weighed at: 06/10/2026 09:00"
            ],
            "reason": "Pallet was still on the deck",
            "who": "Fu Sheng"
        },
        "ticket · completed by the second weighing": {
            "title": "Ticket completed",
            "part": null,
            "lines": [],
            "reason": null,
            "who": "Fu Sheng"
        },
        "ticket · shared to a receipt, with the quantity reason": {
            "title": "Share allocated",
            "part": null,
            "lines": [
                "Share (kg): 8,000"
            ],
            "reason": "Two bags torn, swept and weighed apart",
            "who": "Fu Sheng"
        },
        "ticket · a photo added": {
            "title": "Photo added",
            "part": "ticket-front.jpg",
            "lines": [],
            "reason": null,
            "who": "Fu Sheng"
        },
        "ticket · a photo withdrawn with a reason": {
            "title": "Photo withdrawn",
            "part": "ticket-front.jpg",
            "lines": [],
            "reason": "Wrong truck",
            "who": "Fu Sheng"
        },
        "ticket · voided with a reason": {
            "title": "Ticket voided",
            "part": null,
            "lines": [],
            "reason": "Opened for the wrong vehicle",
            "who": "Fu Sheng"
        }
    }
    const got16 = {}
    if (C.length !== Object.keys(WANT).length || C.length < 10) problems.gold16.push(`⑯ 造了 ${C.length} 个样例,金句表里有 ${Object.keys(WANT).length} 句 —— 两边对不上`)
    for (const c of C) {
        const rows = c.rows.map((r) => ({ group: 'GOLD16', order: 1, prelog: false, at: '2026-10-06T02:00:00+00:00', key: { id: uuid() },
            actor: c.actor ?? { state: 'person', name: 'Fu Sheng' }, cols: null, old: null, new: null, ctx: null, refs: {}, hidden: false, restricted: false, ...r }))
        let es
        try { es = R.buildEntries(dict, rows, { currency: null, ...c.opts }) } catch (err) { problems.gold16.push(`${c.label}:造句器抛错 ${err.message}`); continue }
        const mine = es.filter((x) => x.key === 'GOLD16')
        if (mine.length !== 1) { problems.gold16.push(`${c.label}:一次操作应当是一条,造出了 ${mine.length} 条(${mine.map((x) => x.title).join(' | ')})`); continue }
        const e = mine[0]
        const got = { title: e.title, part: e.titlePart?.text ?? null, lines: e.lines.map(lineText), reason: e.reason?.text ?? null, who: e.who.text }
        got16[c.label] = got
        const w = WANT[c.label]
        if (!w) { problems.gold16.push(`${c.label}:金句表里没有这一句`); continue }
        for (const k of ['title', 'part', 'reason', 'who']) if (got[k] !== w[k]) problems.gold16.push(`${c.label}:${k}「${got[k]}」≠「${w[k]}」`)
        if (JSON.stringify(got.lines) !== JSON.stringify(w.lines)) problems.gold16.push(`${c.label}:行 ${JSON.stringify(got.lines)} ≠ ${JSON.stringify(w.lines)}`)
    }
    if (process.env.TRAIL_GOLD16_PRINT) console.log(JSON.stringify(got16, null, 8))
    if (FAULT === 'wording-drift-mes2' && !problems.gold16.length) problems.gold16.push('(注入 wording-drift-mes2 没有咬人 —— 这一臂瞎了)')
}

// ── ⑤ 覆盖 ──────────────────────────────────────────────────────────────────
// AUDIT-TRAIL-1d-1:auth.users 从此在目录里有它自己的列(M9 的安全投影),不再是额外加上的那一张
const expectTables = Object.keys(C.TRAIL_FIELDS).length + (C.TRAIL_FIELDS['auth.users'] ? 0 : 1)
if (tablesSwept.size !== expectTables) problems.coverage.push(`扫过 ${tablesSwept.size} 张表,目录里有 ${expectTables} 张`)
if (scanned < 20000) problems.coverage.push(`只扫了 ${scanned} 句(下限 20,000)—— 造样本那一段悄悄少造了`)

// ── 报告 ────────────────────────────────────────────────────────────────────
const NAMES = { ruler: '① 尺', registry: '② 登记表一致', catalogue: '③ 措辞目录完整', tokens: '④ 机器字', coverage: '⑤ 覆盖', gold: '⑥ 商务样例', gold3: '⑦ 主数据样例', gold8: '⑧ 账上的单据', gold9: '⑨ 其余的单据与合同', gold10: '⑩ 期末、设置与清单页', gold11: '⑪ 账号、设置与员工', gold12: '⑫ 请假与考勤', gold13: '⑬ 工资与评审', gold14: '⑭ U1-B 的工作流与泄漏', gold15: '⑮ MES-1 的设备与网关钥匙', gold16: '⑯ MES-2 的校准记录与地磅单' }
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
