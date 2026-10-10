#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-3 · 页面这一层的探针 —— 「以【真角色的码】的身份把那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 240 证的是读法与被删记录那张视图;删掉的记录【打不打得开、谁打得开、横幅说了什么、
//   是不是只读】住在页面上,而那一条门(data.view_deleted)是页面问的,不是库问的。冒烟以 admin 登录(admin 持那个码),
//   所以"别人得到一句具名拒绝、不是 404"只有用一个【不持】它的真角色才看得见。形状照 scripts/probe-at1b2.mjs。
//
// 【受测的人】三个一次性账号:一个授【真的】auditor(持 data.view_deleted、各模块的 view 与人事 view)、一个授真的 gm
//   (各模块的 view 都有,【不持】data.view_deleted)、一个授 admin(新页面的审计记录)。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 【受测的行】按种类挑线上【真有】的删掉的记录:一家客户、一家供应商、一种物料、那一张报价(线上只有 ZZ-SMOKE-QT-CJK,它记着谁删的);
//   删掉的定价公式 / 销售订单 / 采购单线上 0 张 —— 照直报 SKIP,由 fixture 240 与代码审读兜着。
//
// 【断言】
//   Q21/Q9  auditor 打开每一条删掉的记录:200、横幅(data-ended-banner="deleted")、只读(data-ended-readonly)、审计记录 entries;
//           横幅:没有记人的只说 "Deleted on DD/MM/YYYY"(不带 by),记了人的说 "Deleted on DD/MM/YYYY by <名字>"
//   拒绝    gm 打开同一条:200 + 具名拒绝(data-access-denied + "This record has been deleted."),不是 404,也没有横幅与数据
//   被删记录 /settings/deleted 列出客户 · 供应商 · 物料三类,每一行的链接都打得开(含原来 404 的报价那一条)
//   页面    物料 · 库位 · 金属价格 · 公式的编辑页、一张任务、三个阈值面板:审计记录在(面板可以是 empty —— 线上那三张设置表
//           一行变更记录都没有),都不是 refused,剥掉人敲的字之后一个机器字都没有
//   Q26     任务页上原来那一段 "Change history" 没有了
//   折入 3  任务页的审计记录,中文界面与英文界面逐字相同
//
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1B3_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1b3.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from './lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3194            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1(3196)、1b-2(3195)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'holder-is-gm': '把持码的那一位换成 gm 去开删掉的记录 —— Q21/Q9 那几条必须红(它证的是 auditor 真的持 data.view_deleted)',
    'refusal-is-auditor': '把被拒的那一位换成 auditor —— "拒绝"那几条必须红(它证的是 gm 真的不持那个码)',
    'banner-guess': '期望没有记人的横幅也带 " by " —— 只说日期那几条必须红',
    'history-back': '把期望"没有"的那句旧标题换成一定在的 "Audit trail" —— Q26 那一条必须红',
    'cjk': '往任务页中文那一份里塞一个中文字 —— 折入 3 那一条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1B3_PROBE_EXIT=2')
    process.exit(2)
}

const rest = (path, opts = {}) => fetch(URL_ + path, {
    ...opts, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
})
async function restRows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let rows = null
    try { rows = JSON.parse(body) } catch { /* 下面统一报 */ }
    if (!r.ok || !Array.isArray(rows)) throw new Error(`${ctx}: HTTP ${r.status} ${body.slice(0, 300)}`)
    return rows
}
function sweepStalePort() {
    let pids = []
    try { pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' }).split('\n').map((s) => s.trim()).filter(Boolean) } catch { return true }
    for (const pid of pids) {
        let ppid = null
        try { ppid = execSync(`ps -o ppid= -p ${pid}`, { encoding: 'utf8' }).trim() } catch { continue }
        if (ppid === '1') { try { process.kill(Number(pid), 'SIGKILL') } catch { /* gone */ } }
        else { console.error(`✗ 端口 ${PORT} 被 pid=${pid} 占着,不杀。`); return false }
    }
    return true
}

// 与 probe-at1b2.mjs 同一个判据(404 由状态码回答,不由 RSC 负载里那句 not-found 文字回答)
const THROWN = /Application error: a server-side exception|__next_error__/
const failures = []
const passed = []
const skipped = []
function check(label, ok, why) { (ok ? passed : failures).push(ok ? label : `${label}: ${why}`) }

/** 一段审计记录的文字,人敲的字剥掉 */
function trailSections(html) {
    const out = []
    for (const m of html.matchAll(/<section[^>]*data-(?:audit-trail|change-history)="[^"]*"[^>]*>([\s\S]*?)<\/section>/g)) {
        out.push(m[1].replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' '))
    }
    return out
}
/** 横幅第一行(时刻与人)的文字 */
function bannerHead(html) {
    const m = html.match(/data-ended-banner="deleted"[^>]*>\s*<p[^>]*>([\s\S]*?)<\/p>/)
    return m ? m[1].replace(/<[^>]+>/g, '').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' ').trim() : null
}

async function main() {
    acquireOrExit('scripts/probe-at1b3.mjs', { ownExit: false })
    openPlan('scripts/probe-at1b3.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 按种类挑受测的行 ─────────────────────────────────────────────────────
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const deleted = {
        customer: await one('/rest/v1/customers?select=id,code&deleted_at=not.is.null&order=code&limit=1', '删掉的客户'),
        supplier: await one('/rest/v1/suppliers?select=id,code&deleted_at=not.is.null&order=code&limit=1', '删掉的供应商'),
        material: await one('/rest/v1/materials?select=id,code&deleted_at=not.is.null&order=code&limit=1', '删掉的物料'),
        quote: await one('/rest/v1/quotes?select=id,code,deleted_by&deleted_at=not.is.null&order=code&limit=1', '删掉的报价'),
        pricing_formula: await one('/rest/v1/pricing_formulas?select=id,code&deleted_at=not.is.null&order=code&limit=1', '删掉的公式'),
        sales_order: await one('/rest/v1/sales_orders?select=id,code&deleted_at=not.is.null&order=code&limit=1', '删掉的订单'),
        purchase_order: await one('/rest/v1/purchase_orders?select=id,code&deleted_at=not.is.null&order=code&limit=1', '删掉的采购单'),
    }
    const HREF = {
        customer: (id) => `/sales/customers/${id}`, supplier: (id) => `/suppliers/${id}/edit`, material: (id) => `/materials/${id}/edit`,
        quote: (id) => `/sales/quotes/${id}`, pricing_formula: (id) => `/tools/pricing/formulas/${id}/edit`,
        sales_order: (id) => `/sales/orders/${id}`, purchase_order: (id) => `/purchasing/orders/${id}`,
    }
    const live = {
        material: await one('/rest/v1/materials?select=id,code&deleted_at=is.null&order=code&limit=1', '一种物料'),
        location: await one('/rest/v1/storage_locations?select=id,code&order=code&limit=1', '一个库位'),
        price: await one('/rest/v1/metal_prices?select=id,metal&deleted_at=is.null&order=price_date.desc&limit=1', '一条金属价格'),
        formula: await one('/rest/v1/pricing_formulas?select=id,code&deleted_at=is.null&order=code&limit=1', '一张公式'),
        task: await one('/rest/v1/tasks?select=id,code&deleted_at=is.null&order=code&limit=1', '一张任务'),
    }
    for (const [k, v] of Object.entries(live)) if (!v) throw new Error(`线上找不到${k}`)
    console.log('· 删掉的:' + Object.entries(deleted).map(([k, v]) => `${k} ${v?.code ?? '(线上 0 条)'}`).join(' · '))

    // ── 三个一次性账号:auditor(持 data.view_deleted)· gm(不持)· admin ───────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['auditor', 'gm', 'admin']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1b3probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1b3probe', label: roleCode, stamp, password: 'at1b3-probe-1',
            codes: roleCode === 'admin' ? 'all' : { cloneOf: roleCode } })
        cookies[roleCode] = tw.cookie
    }
    const holder = INJECT === 'holder-is-gm' ? 'gm' : 'auditor'
    const refused = INJECT === 'refusal-is-auditor' ? 'auditor' : 'gm'

    // ── dev server ──────────────────────────────────────────────────────────
    const logChunks = []
    const dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT })
    devProc = dev
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    const t0 = Date.now()
    let ready = false
    while (Date.now() - t0 < 90_000) {
        await new Promise((r) => setTimeout(r, 1000))
        if (logChunks.join('').includes('Ready in')) { ready = true; break }
        if (dev.exitCode !== null) break
    }
    if (!ready) {
        console.error('✗ dev server 没起来:\n' + logChunks.join('').split('\n').slice(-25).join('\n'))
        console.log('AT1B3_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p) => p.status === 200 && !THROWN.test(p.body)
        const section = (p) => (p.body.match(/data-audit-trail="(\w+)"/) ?? [])[1] ?? '(none)'
        const DATE = '\\d{2}/\\d{2}/\\d{4}'

        // ── Q21 / Q9:删掉的记录 ──────────────────────────────────────────────
        for (const [kind, rec] of Object.entries(deleted)) {
            if (!rec) { skipped.push(`${kind}: 线上 0 条删掉的 —— 由 fixture 240 与代码审读兜着`); continue }
            const path = HREF[kind](rec.id)
            const p = await get(holder, path)
            const head = bannerHead(p.body)
            const recordsPerson = kind === 'quote' && !!rec.deleted_by
            const wantBy = recordsPerson || INJECT === 'banner-guess'
            const shapeOk = head !== null && (wantBy ? new RegExp(`^Deleted on ${DATE} by \\S`).test(head) : new RegExp(`^Deleted on ${DATE}$`).test(head))
            check(`Q21 [${holder}] deleted ${kind} ${rec.code} opens read-only with its banner «${head}» and trail`,
                rendered(p) && p.body.includes('data-ended-readonly') && section(p) === 'entries' && shapeOk,
                `HTTP ${p.status}, readonly ${p.body.includes('data-ended-readonly')}, section ${section(p)}, banner «${head}»`)
            const q = await get(refused, path)
            check(`Q9  [${refused}] deleted ${kind} ${rec.code}: a named refusal, not a 404`,
                q.status === 200 && q.body.includes('data-access-denied') && q.body.includes('This record has been deleted.')
                    && !q.body.includes('data-ended-banner') && section(q) === '(none)',
                `HTTP ${q.status}, refusal ${q.body.includes('data-access-denied')}, banner ${q.body.includes('data-ended-banner')}, section ${section(q)}`)
        }

        // ── /settings/deleted:四类在,每一行的链接都打得开 ────────────────────────
        const sd = await get(holder, '/settings/deleted')
        for (const [kind, label] of [['customer', 'Customer'], ['supplier', 'Supplier'], ['material', 'Material']]) {
            const rec = deleted[kind]
            check(`Q9  [${holder}] /settings/deleted lists ${label.toLowerCase()} rows with a link`,
                rendered(sd) && sd.body.includes(`>${label}<`) && (!rec || sd.body.includes(`href="${HREF[kind](rec.id)}"`)),
                `HTTP ${sd.status}, kind label ${sd.body.includes(`>${label}<`)}, link ${rec ? sd.body.includes(`href="${HREF[kind](rec.id)}"`) : '(none)'}`)
        }
        if (deleted.quote) {
            const href = HREF.quote(deleted.quote.id)
            const p = await get(holder, href)
            check(`Q9  [${holder}] the quote link on /settings/deleted (a 404 before) opens`, sd.body.includes(`href="${href}"`) && rendered(p) && p.body.includes('data-ended-banner'),
                `link ${sd.body.includes(`href="${href}"`)}, HTTP ${p.status}`)
        }

        // ── 页面:新的审计记录在、不是 refused、一个机器字都没有 ─────────────────────
        const pages = [
            [`/materials/${live.material.id}/edit`, false], [`/inventory/locations/${live.location.id}/edit`, false],
            [`/tools/pricing/metal-prices/${live.price.id}/edit`, false], [`/tools/pricing/formulas/${live.formula.id}/edit`, false],
            [`/tools/tasks/${live.task.id}`, false],
            ['/operation/orders', true], ['/tools/pricing/metal-prices', true], ['/purchasing/discrepancies', true],
        ]
        for (const [path, emptyOk] of pages) {
            const p = await get('admin', path)
            const text = trailSections(p.body).join(' ')
            const hits = machineTokens(text)
            const st = section(p)
            check(`page [admin] ${path} has its trail (${emptyOk ? 'entries or empty' : 'entries'}) with no machine token`,
                rendered(p) && (st === 'entries' || (emptyOk && st === 'empty')) && text.length > 20 && !hits.length,
                `HTTP ${p.status}, section ${st}, ${text.length} chars, tokens ${hits.slice(0, 4).map((h) => h.token).join(', ')}`)
        }

        // ── Q26:任务页上原来那一段 "Change history" 没有了 ─────────────────────
        const gone = INJECT === 'history-back' ? 'Audit trail' : '>Change history</h2>'
        const tp = await get('admin', `/tools/tasks/${live.task.id}`)
        check(`Q26 [admin] the task page no longer renders its old Change history section`, tp.status === 200 && !tp.body.includes(gone), `页面上还有 ${gone}`)

        // ── 折入 3:中文界面,任务页的审计记录逐字不变 ───────────────────────────
        const z = await get('admin', `/tools/tasks/${live.task.id}`, 'zh')
        let zt = trailSections(z.body).join(' | ')
        const et = trailSections(tp.body).join(' | ')
        if (INJECT === 'cjk') zt += ' 受限'
        let why = ''
        if (z.status !== 200) why = `HTTP ${z.status}`
        else if (!zt.length) why = '找不到审计记录那一段'
        else if (zt !== et) {
            let i = 0
            while (i < zt.length && zt[i] === et[i]) i++
            why = `zh 与 en 在第 ${i} 个字处分开:zh "…${zt.slice(Math.max(0, i - 30), i + 20)}…" · en "…${et.slice(Math.max(0, i - 30), i + 20)}…"`
        }
        check(`fold-in 3 [admin] the task page's trail reads the same in the Chinese interface`, !why, why)
    } finally {
        await runPlan()
        dev.kill()
    }

    console.log('\n== 结果 ==')
    for (const p of passed) console.log('  ✓ ' + p)
    for (const s of skipped) console.log('  · SKIP ' + s)
    for (const f of failures) console.log('  ✗ ' + f)
    if (INJECT) console.log(`\n· 本跑带着注入 --inject=${INJECT}(${INJECTIONS[INJECT]})`)
    const code = failures.length ? 1 : (process.exitCode || 0)
    console.log(`\n${passed.length} passed · ${failures.length} failed · ${skipped.length} skipped`)
    console.log(`AT1B3_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1B3_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
