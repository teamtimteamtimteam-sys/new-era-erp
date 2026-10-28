#!/usr/bin/env node
// scripts/check-policy-permission-wrap.mjs
// ════════════════════════════════════════════════════════════════════════════
// CHAIN-WALK-COST(Tim 2026-10-28 Q1)· 策略里的权限判断一律包成 (SELECT has_permission(…)) —— 按语句求一次,不按行
// ════════════════════════════════════════════════════════════════════════════
// 【为什么】has_permission() 是 SECURITY DEFINER + SET search_path(永远不内联),每调一次都重新汇总读者的角色:约 177 个缓冲区。
//   直接写在策略里,RLS 对【扫过的每一行】调它一次 —— 一年体量的本地重建上,加工链一次走链 11–12 秒、18 万次调用(97% 的时间)。
//   参数是字面量时,包成标量子查询它就是一个 InitPlan:一条语句求一次,答案不变(docs/surveys/CHAIN-WALK-COST/README.md)。
//   迁移 2026-10-28-chain-walk-cost.sql 把线上的 541 条改成了包着的写法;这道闸让下一条新写或改写的策略不把慢写法带回来。
//
// 【瞄准 · AIM】
//   我读的是      :db/tables/*.sql 与 db/storage/buckets-and-policies.sql 里每一条 CREATE POLICY 语句的文本(到第一个分号);
//                   db/policy-permission-allowlist.tsv。
//   我声称管的是   :① 每一处 has_permission( / has_any_permission( 以及读者身份 current_user_employee() / auth.uid()
//                      都紧跟在 "(SELECT " 后面,除非那一条策略在名单里(身份那两个与权限判断同理:不随行、按语句求一次);
//                   ② 一条调用【随行而变的权限判断】(下面 ROW_HELPERS:can_view_task · can_edit_task · can_write_task · task_is_own ·
//                      approval_log_readable)的策略必须在名单里,带一句理由 —— 它们按行求值是对的,而名单让人看得见它们;
//                   ③ 名单里每一条今天都还命中(死条目 = 红)。
//   两者不同之处   :★ 我读【镜像】,不读线上目录:镜像与线上是否一致由 db/gate.py 的镜像判词回答。
//                   ★ ROW_HELPERS 是一张【点名】的表:一个新写的、名字不在表里的"随行权限判断"我认不出 —— 它不调 has_permission
//                     的话我就看不见它。新写一支这样的函数,把它加进 ROW_HELPERS。
//                   ★ 一个写成 has_permission(t.col) 的调用(参数随行)包起来是错的 —— 那种写法今天 0 处;遇到了它应当进名单,不该包。
//
// 判据 ④ 覆盖是断言:按 CREATE POLICY 语句解析出的条数 = 行首 `CREATE POLICY` 的条数(两条独立的路)。
//
// 故障注入(CHECK_POLICY_WRAP_FAULT=…,每一格都要红在它说的那一行):
//   unwrap:<表>.<策略>  把那一条策略里第一处包着的判断拆回不包 → exit 1 并点名
//   unlist:<策略>       假装名单里没有那一条 → exit 1(随行判断 / storage 未包)
//   stale               名单里多一条不存在的策略 → exit 2(死条目)
//   blind               解析器读出 0 条策略 → exit 2,不许报"干净"
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned, assertAllowlistLive } from './lib/selfproof.mjs'

const SELF = 'check-policy-permission-wrap'
const ROOT = new URL('..', import.meta.url).pathname
const FAULT = process.env.CHECK_POLICY_WRAP_FAULT ?? ''
const ROW_HELPERS = ['can_view_task', 'can_edit_task', 'can_write_task', 'task_is_own', 'approval_log_readable']

const files = [
    ...readdirSync(join(ROOT, 'db/tables')).filter((f) => f.endsWith('.sql')).sort().map((f) => `db/tables/${f}`),
    'db/storage/buckets-and-policies.sql',
]

// ── 名单 ──────────────────────────────────────────────────────────────────────
let allow = readFileSync(join(ROOT, 'db/policy-permission-allowlist.tsv'), 'utf8').split('\n')
    .filter((l) => l.trim() && !l.startsWith('#'))
    .map((l) => { const [file, table, policy, kind, reason] = l.split('\t'); return { file, table, policy, kind, reason } })
if (FAULT === 'stale') allow.push({ file: 'db/tables/nope.sql', table: 'public.nope', policy: 'no such policy', kind: 'row', reason: 'fault injection' })
if (FAULT.startsWith('unlist:')) allow = allow.filter((a) => a.policy !== FAULT.slice(7))
for (const a of allow) {
    if (!['row', 'storage'].includes(a.kind) || !a.reason?.trim()) {
        console.error(`✗ ${SELF}:名单那一行 "${a.policy}" 的种类必须是 row / storage,并带一句理由`)
        process.exit(2)
    }
}
const key = (file, table, policy) => `${file}\t${table}\t${policy}`
const allowed = new Map(allow.map((a) => [key(a.file, a.table, a.policy), a]))

// ── 每一条策略 ────────────────────────────────────────────────────────────────
const POL = /CREATE POLICY\s+(?:"([^"]+)"|([a-z_0-9]+))\s+ON\s+([a-z_.]+)([\s\S]*?);/g
const policies = []
let lineCount = 0
for (const f of files) {
    const src = readFileSync(join(ROOT, f), 'utf8')
    lineCount += (src.match(/^CREATE POLICY\b/gm) ?? []).length
    if (FAULT === 'blind') continue
    for (const m of src.matchAll(POL)) policies.push({ file: f, name: m[1] ?? m[2], table: m[3], body: m[4] })
}
assertPopulation(SELF, 'CREATE POLICY 语句', policies.length)
assertPinned(SELF, '解析出的策略 ↔ 行首 CREATE POLICY 的条数', policies.length, lineCount, '有策略没被解析到(或解析到了注释里的那一句)')

if (FAULT.startsWith('unwrap:')) {
    const [t, ...rest] = FAULT.slice(7).split('.')
    const p = policies.find((x) => x.table === `public.${t}` && x.name === rest.join('.'))
    if (!p) { console.error(`✗ ${SELF}:故障注入找不到策略 ${FAULT}`); process.exit(2) }
    p.body = p.body.replace(/\(SELECT (has_(?:any_)?permission\(|current_user_employee\(\)|auth\.uid\(\))/, '$1')
    console.log(`★ 故障注入:${p.table} "${p.name}" 里第一处判断拆回了不包的写法(应当红在这一条)`)
}

const problems = []
let wrapped = 0, unwrappedAllowed = 0
const hit = new Set()
for (const p of policies) {
    const k = key(p.file, p.table, p.name)
    const a = allowed.get(k)
    let unwrapped = 0
    for (const m of p.body.matchAll(/\bhas_(?:any_)?permission\(|\bcurrent_user_employee\(\)|\bauth\.uid\(\)/g)) {
        if (/\(\s*SELECT\s+$/i.test(p.body.slice(0, m.index))) wrapped++
        else unwrapped++
    }
    const helpers = ROW_HELPERS.filter((h) => new RegExp(`\\b${h}\\(`).test(p.body))
    if (unwrapped && !a) problems.push(`${p.file}:${p.table} "${p.name}" —— ${unwrapped} 处权限 / 身份判断没有包成 (SELECT …);包起来,或(参数随行时)进名单并写理由`)
    if (unwrapped && a) { unwrappedAllowed += unwrapped; hit.add(k) }
    if (helpers.length && !(a && a.kind === 'row')) problems.push(`${p.file}:${p.table} "${p.name}" —— 调了随行的权限判断 ${helpers.join(' / ')},而名单里没有它(kind = row)`)
    if (helpers.length && a) hit.add(k)
}
assertAllowlistLive(SELF, 'db/policy-permission-allowlist.tsv', allow, (a) => hit.has(key(a.file, a.table, a.policy)), (a) => `${a.table} "${a.policy}"`)

if (problems.length) {
    console.error(`✗ ${SELF}:${problems.length} 条策略违反「权限判断按语句求一次」(CHAIN-WALK-COST Q1):`)
    for (const p of problems) console.error('  · ' + p)
    process.exit(1)
}
const rows = allow.filter((a) => a.kind === 'row').length, storage = allow.filter((a) => a.kind === 'storage').length
console.log(`✓ ${SELF}:${policies.length} 条策略 · ${wrapped} 处判断包成 (SELECT …) · 名单 ${allow.length} 条(随行 ${rows} · storage ${storage},其中 ${unwrappedAllowed} 处未包)`)
