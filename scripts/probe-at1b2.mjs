#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-2 · 页面这一层的探针 —— 「以【真角色的码】的身份把那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 239 证的是读法;页面上的那一段(有没有、是不是 entries、机器字、两段旧"历史"
//   真的拿掉了、中文界面一个字不变)住在页面上。冒烟以 admin 登录,而 M1 的那一位读者【不是 admin】:线上的仓库账号持
//   action.ship_goods、不持 module.sales.view —— 发货单页对他打得开,审计记录也读得到,这件事只有用他的身份才看得见。
//   形状照 scripts/probe-at1b1.mjs(同一套一次性账号、清理计划、dev server、锁)。
//
// 【受测的人】两个一次性账号:一个授【真的】warehouse 角色,一个授 admin。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 【受测的行】按名挑:SHP-2026-0001(M1)、SO-2026-0001 与 QT-2026-0001(替掉的两段历史)、SUP-2026-0003(一个截图文件名里
//   带着日期 —— 人敲的字,标题后面那一段必须画在 data-trail-typed 里,不被当成机器字)、第一家客户 / 集装箱 / 货代。
//
// 【断言】
//   M1        仓库的人(不持 module.sales.view)打得开 SHP-2026-0001,审计记录是 entries;他进不了订单页(那一页是销售的门)
//   页面      九个商务页底都有审计记录,都是 entries,剥掉人敲的字之后一个机器字都没有(与冒烟同一个检出器)
//   Q26       报价页与订单页上那两段"History"没有了(审计记录取代了它们)
//   Q8        SUP-2026-0003 的审计记录里,那个带日期的文件名只出现在 data-trail-typed 里
//   折入 3    订单页与航段页的审计记录,中文界面与英文界面逐字相同
//
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1B2_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1b2.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3195            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1 探针(3196)撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'm1-admin-only': '把仓库账号换成 admin 去读发货单 —— "仓库进不了订单页"那一条必须红(它证的是这一位真的不持销售码)',
    'typed-leak': '剥人敲的字时一个都不剥 —— SUP-2026-0003 的机器字那一条必须红',
    'history-back': '把期望"没有"的那句旧标题换成一定在的 "Audit trail" —— Q26 那一条必须红',
    'cjk': '往订单页中文那一份里塞一个中文字 —— 折入 3 那一条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1B2_PROBE_EXIT=2')
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

// 与 probe-role-crash.mjs 同一个判据。★ 不加 "This page could not be found":dev 的每一页都把 not-found 边界嵌在 RSC 负载里,
//   第一版加了它,四条"打得开"对着四张好好的页面全红(那是判据错,不是页面错)。404 由状态码回答。
const THROWN = /Application error: a server-side exception|__next_error__/
const failures = []
const passed = []
function check(label, ok, why) { (ok ? passed : failures).push(ok ? label : `${label}: ${why}`) }

/** 一段审计记录(data-audit-trail / data-change-history 所在的那个 section)的文字,人敲的字剥掉 */
function trailSections(html) {
    const out = []
    for (const m of html.matchAll(/<section[^>]*data-(?:audit-trail|change-history)="[^"]*"[^>]*>([\s\S]*?)<\/section>/g)) {
        const inner = INJECT === 'typed-leak' ? m[1] : m[1].replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ')
        out.push(inner.replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' '))
    }
    return out
}

async function main() {
    acquireOrExit('scripts/probe-at1b2.mjs', { ownExit: false })
    openPlan('scripts/probe-at1b2.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 按名挑受测的行 ───────────────────────────────────────────────────────
    const pick = async (path, ctx) => { const r = await restRows(path, ctx); if (!r.length) throw new Error(`线上找不到${ctx}`); return r[0] }
    const shp = await pick('/rest/v1/shipments?select=id,code&code=eq.SHP-2026-0001', 'SHP-2026-0001')
    const so = await pick('/rest/v1/sales_orders?select=id,code&code=eq.SO-2026-0001', 'SO-2026-0001')
    const qt = await pick('/rest/v1/quotes?select=id,code&code=eq.QT-2026-0001', 'QT-2026-0001')
    const sup = await pick('/rest/v1/suppliers?select=id,code&code=eq.SUP-2026-0003', 'SUP-2026-0003')
    const cus = await pick('/rest/v1/customers?select=id,code&deleted_at=is.null&order=code&limit=1', '一家客户')
    const ctr = await pick('/rest/v1/containers?select=id,code&deleted_at=is.null&order=code&limit=1', '一只集装箱')
    const fwd = await pick('/rest/v1/suppliers?select=id,code&deleted_at=is.null&counterparty_type=eq.forwarder&order=code&limit=1', '一家货代')
    console.log(`· 受测:${shp.code} · ${so.code} · ${qt.code} · ${sup.code} · ${cus.code} · ${ctr.code} · 货代 ${fwd.code}`)

    // ── 两个一次性账号:warehouse 与 admin ─────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['warehouse', 'admin']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1b2probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1b2probe', label: roleCode, stamp, password: 'at1b2-probe-1',
            codes: roleCode === 'admin' ? 'all' : { cloneOf: roleCode } })
        cookies[roleCode] = tw.cookie
    }
    const shipper = INJECT === 'm1-admin-only' ? 'admin' : 'warehouse'

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
        console.log('AT1B2_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p, code) => p.status === 200 && !THROWN.test(p.body) && (!code || p.body.includes(code))
        const section = (p) => (p.body.match(/data-audit-trail="(\w+)"/) ?? [])[1] ?? '(none)'

        // M1:仓库的人 —— 发货单页打得开、审计记录是 entries;订单页是销售的门,他进不去
        const a = await get(shipper, `/sales/shipments/${shp.id}`)
        check(`M1 [${shipper}] ${shp.code} opens with its trail`, rendered(a, shp.code) && section(a) === 'entries', `HTTP ${a.status}, section ${section(a)}`)
        const a2 = await get(shipper, `/sales/orders/${so.id}`)
        check(`M1 [${shipper}] holds no module.sales.view (the order page refuses him)`, a2.status === 200 && section(a2) === '(none)' && !a2.body.includes(so.code + '</h1>'),
            `订单页对他打开了(section ${section(a2)})`)

        // 页面:九个商务页底都有审计记录,都是 entries,一个机器字都没有
        const pages = [
            [`/sales/quotes/${qt.id}`, qt.code], [`/sales/orders/${so.id}`, so.code], [`/sales/shipments/${shp.id}`, shp.code],
            [`/sales/customers/${cus.id}`, null], [`/suppliers/${sup.id}/edit`, sup.code], [`/logistics/containers/${ctr.id}`, ctr.code],
            [`/logistics/forwarders/${fwd.id}`, fwd.code], ['/logistics/lanes', null], ['/purchasing/licences', null],
        ]
        for (const [path, code] of pages) {
            const p = await get('admin', path)
            const text = trailSections(p.body).join(' ')
            const hits = machineTokens(text)
            check(`page [admin] ${path} has an entries trail with no machine token`,
                rendered(p, code) && section(p) === 'entries' && text.length > 20 && !hits.length,
                `HTTP ${p.status}, section ${section(p)}, ${text.length} chars, tokens ${hits.slice(0, 4).map((h) => h.token).join(', ')}`)
            if (path.startsWith('/suppliers/')) {
                // Q8:人敲的文件名(里面有一个日期)只能出现在 data-trail-typed 里
                check(`Q8  [admin] ${sup.code}: the dated file name sits only in typed text`, !hits.length && p.body.includes('Screenshot 2026-06-28'),
                    hits.length ? `机器字 ${hits.map((h) => h.token).join(', ')}` : '页面上找不到那个文件名')
            }
        }

        // Q26:报价页与订单页上那两段"History"没有了
        const gone = INJECT === 'history-back' ? 'Audit trail' : '>History</h2>'
        for (const path of [`/sales/quotes/${qt.id}`, `/sales/orders/${so.id}`]) {
            const p = await get('admin', path)
            check(`Q26 [admin] ${path} no longer renders its old History section`, p.status === 200 && !p.body.includes(gone), `页面上还有 ${gone}`)
        }

        // 折入 3:中文界面,审计记录那一段逐字不变
        for (const path of [`/sales/orders/${so.id}`, '/logistics/lanes']) {
            const z = await get('admin', path, 'zh')
            const e = await get('admin', path, 'en')
            let zt = trailSections(z.body).join(' | ')
            const et = trailSections(e.body).join(' | ')
            if (INJECT === 'cjk' && path.startsWith('/sales/orders/')) zt += ' 受限'
            let why = ''
            if (z.status !== 200 || e.status !== 200) why = `HTTP ${z.status} / ${e.status}`
            else if (!zt.length) why = '找不到审计记录那一段'
            else if (zt !== et) {
                let i = 0
                while (i < zt.length && zt[i] === et[i]) i++
                why = `zh 与 en 在第 ${i} 个字处分开:zh "…${zt.slice(Math.max(0, i - 30), i + 20)}…" · en "…${et.slice(Math.max(0, i - 30), i + 20)}…"`
            }
            check(`fold-in 3 [admin] ${path} trail section reads the same in the Chinese interface`, !why, why)
        }
    } finally {
        await runPlan()
        dev.kill()
    }

    console.log('\n== 结果 ==')
    for (const p of passed) console.log('  ✓ ' + p)
    for (const f of failures) console.log('  ✗ ' + f)
    if (INJECT) console.log(`\n· 本跑带着注入 --inject=${INJECT}(${INJECTIONS[INJECT]})`)
    const code = failures.length ? 1 : (process.exitCode || 0)
    console.log(`\n${passed.length} passed · ${failures.length} failed`)
    console.log(`AT1B2_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1B2_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
