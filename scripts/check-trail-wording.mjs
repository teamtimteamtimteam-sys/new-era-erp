#!/usr/bin/env node
// scripts/check-trail-wording.mjs
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :lib/trail/render.ts 在【我自己造的样本行】上造出来的句子;外加 lib/trail/text.ts、
//                   lib/trail/catalogue.generated.ts、db/functions 里的两张登记表与 db/tables 的 CHECK 约束。
//   我声称管的是   :审计记录与 /settings/change-history 上一个机器字都印不出来,措辞目录完整。
//   两者不同之处   :我读的是【样本】,不是线上的真行 —— 真数据里一种我没造过的形状(一个 JSON 列里恰好认得的键、
//                   一张表将来新加的列在目录生成之前)我看不见;扫真页面的是冒烟的 trail 判据(scripts/smoke-routes.mjs)。
//                   目录完整那一臂只管三个主语的表;别的表的枚举值落到 humanize,不是机器字,但措辞未经人过目。
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
//
// 故障注入(TRAIL_WORDING_FAULT=<臂>,每一臂必须在【它那一臂】红):
//   blind-detector · registry-drift · missing-key · dead-key · label-gap · enum-gap · raw-date · raw-ref · raw-json · raw-null · raw-role
// 退出码:0 干净 · 1 有发现 · 3 尺瞎了或覆盖不足(本脚本【不知道】答案)
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
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
function sqlValues(file) {
    const src = read(file).replace(/--[^\n]*/g, '')
    const body = src.slice(src.indexOf('VALUES'), src.lastIndexOf(') AS'))
    return [...body.matchAll(/\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g)].map((m) =>
        [...m[1].matchAll(/'([^']*)'|(\d+)/g)].map((x) => x[1] ?? x[2]))
}
const subjects = sqlValues('db/functions/trail_subjects.sql').filter((r) => r.length >= 3)
    .map(([subject, view, root]) => ({ subject, view, root }))
const members = sqlValues('db/functions/trail_subject_members.sql').filter((r) => r.length >= 4)
    .map(([subject, ord, table, parent]) => ({ subject, ord, table, parent }))
if (subjects.length !== 3 || members.length < 10) {
    problems.registry.push(`解析 SQL 登记表只读出 ${subjects.length} 个主语 / ${members.length} 行成员 —— 解析器瞎了`)
}
const tablesOf = (s) => new Set([subjects.find((x) => x.subject === s)?.root, ...members.filter((m) => m.subject === s).map((m) => m.table)])
const renderSrc = read('lib/trail/render.ts')
const setIn = (name) => new Set([...(renderSrc.match(new RegExp(`const ${name} = new Set\\(\\[([^\\]]*)\\]`))?.[1] ?? '')
    .matchAll(/'([^']+)'/g)].map((m) => m[1]))
const uiSets = { purchase_order: setIn('PO_TABLES'), processing_run: setIn('RUN_TABLES'),
    role: new Set([...(renderSrc.match(/if \(table === '([a-z_]+)' \|\| table === '([a-z_]+)'\) return 'role'/) ?? []).slice(1)]) }
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
    'app/settings/change-history/page.tsx']
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
function mirrorColumns(t) {
    const f = `db/tables/${t}.sql`
    if (!existsSync(join(ROOT, f))) return null
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
function sweep(label, rows) {
    let entries
    try {
        entries = R.buildEntries(dict, rows, { currency: 'SGD' })
    } catch (e) {
        problems.tokens.push(`${label}:造句器抛错 ${e.message}`)
        return
    }
    for (const e of entries) {
        const strings = [e.title, e.who.text, e.atText, e.reason?.text, e.reason?.full]
        for (const l of e.lines) {
            if (l.t === 'heading' || l.t === 'note') strings.push(l.text)
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
for (const op of ['ACCOUNT_CREATE', 'ACCOUNT_DELETE', 'ACCOUNT_DISABLE', 'ACCOUNT_DISABLE_FAILED', 'ACCOUNT_ENABLE', 'ACCOUNT_ENABLE_FAILED']) {
    sweep(`account ${op}`, [row('auth.users', op, { new: { email: 'someone@example.test' } })])
}
sweep('truncate', [row('role_permissions', 'TRUNCATE', {})])
sweep('whole entry hidden', [row('purchase_order_lines', null, { hidden: true, table: null, actor: null })])
sweep('private task', [row('tasks', 'UPDATE', { restricted: true, cols: ['title'], old: { title: RESTRICTED }, new: { title: RESTRICTED } })])

// ── ⑤ 覆盖 ──────────────────────────────────────────────────────────────────
const expectTables = Object.keys(C.TRAIL_FIELDS).length + 1
if (tablesSwept.size !== expectTables) problems.coverage.push(`扫过 ${tablesSwept.size} 张表,目录里有 ${expectTables} 张`)
if (scanned < 20000) problems.coverage.push(`只扫了 ${scanned} 句(下限 20,000)—— 造样本那一段悄悄少造了`)

// ── 报告 ────────────────────────────────────────────────────────────────────
const NAMES = { ruler: '① 尺', registry: '② 登记表一致', catalogue: '③ 措辞目录完整', tokens: '④ 机器字', coverage: '⑤ 覆盖' }
let exit = 0
for (const [k, list] of Object.entries(problems)) {
    if (!list.length) { console.log(`✓ check-trail-wording ${NAMES[k]}`); continue }
    console.error(`✗ check-trail-wording ${NAMES[k]}:${list.length} 处`)
    for (const p of list.slice(0, 25)) console.error('   ' + p)
    if (list.length > 25) console.error(`   …另有 ${list.length - 25} 处`)
    exit = Math.max(exit, k === 'ruler' || k === 'coverage' ? 3 : 1)
}
console.log(`   (三个主语 ${subjectTables.length} 张表 · ${subjectCols} 列;扫过 ${tablesSwept.size} 张表、${scanned} 句;措辞键 ${Object.keys(text).length} 个)`)
if (FAULT) console.log(`   ★ 故障注入:${FAULT}`)
process.exit(exit)
