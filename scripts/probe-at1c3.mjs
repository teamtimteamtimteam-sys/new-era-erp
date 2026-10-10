#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-3 · 页面这一层的探针 —— 「以【真角色的码】的身份把期末、设置与清单页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 243 证的是读法;一页上的两段(锁期与 GST 各看各的列,Q25 · M6)、月结与反结在锁期那一段里
//   (M7 · Q29)、清单块、每一张报销单一段(Q20)、删掉的对账单那一块对谁打开(Q6 的入口)、中文界面里审计记录那一段逐字不变
//   (折入 3)住在页面上。形状照 scripts/probe-at1c2.mjs。
// 【受测的人】三个一次性账号:一个授【真的】cfo、一个授 admin(两者都持 data.view_deleted)、一个授 gm(每一个模块,【不】持
//   data.view_deleted —— 删掉的对账单那一块对它是一句具名拒绝)。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 【受测的页】1c-3 的每一页:/finance/settings · /finance/close · /finance/company · /finance/revaluation · /finance/assets · /finance/fx ·
//   /finance/cash-forecast · /finance/payroll-payments · /finance/processing-costs · /finance/wht · /finance/bank · /finance/claims ·
//   /finance/bank/import · /finance/bank/statements · /finance/journal;外加 1a / 1b / 1c-1 / 1c-2 各一页(折入 3 的对照)。
//   ★ /me 上报销人自己那一段【不在这里】:它要以一个真的、有报销单的员工身份登录,而一次性账号没有员工 —— 它由 fixture 243 的 E 臂
//     与线上回滚的证明(以报销人自己的账号读 my_expense_claim)钉着,交回报告照直说。
// 【断言】
//   Q25  /finance/settings:锁期那一段读得到记录开始之前的那一次月结,一个 GST 的字都没有;GST 那一段一个月结的字都没有
//   Q29  /finance/close:关账史之下是同一段锁期记录;年结那一块在
//   Q20  /finance/claims:每一张报销单一段,每一段都有它的提交
//   Q6   /finance/bank/statements:删掉的对账单那一块 —— admin 读得到、链到那一张;gm 一句具名拒绝
//   页面 每一页的每一段:剥掉人敲的字之后一个机器字都没有;中文界面那一段逐字相同(不同的话打印两边第一处分开的地方)
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1C3_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1c3.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
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
const PORT = 3191            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1 … 1c-2(3196 … 3192)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'm6-leak': '期望锁期那一段里【有】一句 GST 的话 —— Q25 · M6 那一条必须红',
    'no-close': '期望锁期那一段里【没有】月结 —— Q25 · M7 那一条必须红',
    'refusal-wrong': '期望 gm 读到的是记录而不是拒绝 —— Q6 入口那一条必须红',
    'cjk': '往中文那一份里塞一个中文字 —— 折入 3 那几条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1C3_PROBE_EXIT=2')
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

// 与 probe-at1b3.mjs 同一个判据(404 由状态码回答,不由 RSC 负载里那句 not-found 文字回答)
const THROWN = /Application error: a server-side exception|__next_error__/
const failures = []
const passed = []
const skipped = []
function check(label, ok, why) { (ok ? passed : failures).push(ok ? label : `${label}: ${why}`) }

function trailSections(html) {
    const out = []
    for (const m of html.matchAll(/<section[^>]*data-audit-trail="[^"]*"[^>]*>([\s\S]*?)<\/section>/g)) {
        out.push(m[1].replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' '))
    }
    return out
}

/** 一页上 id="<anchor>" 起的那一段:状态与文字(剥掉人敲的字) */
function sectionAt(html, anchor) {
    const from = html.indexOf(`id="${anchor}"`)
    if (from < 0) return { state: '(none)', text: '' }
    const i = html.indexOf('data-audit-trail="', from)
    if (i < 0) return { state: '(none)', text: '' }
    const state = html.slice(i + 18, html.indexOf('"', i + 18))
    const start = html.lastIndexOf('<section', i), end = html.indexOf('</section>', i)
    const text = html.slice(start, end).replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ').replace(/<[^>]+>/g, ' ')
        .replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' ')
    return { state, text, html: html.slice(start, end) }
}

async function main() {
    acquireOrExit('scripts/probe-at1c3.mjs', { ownExit: false })
    openPlan('scripts/probe-at1c3.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的;每一种的条数照直报)──────────────────────────────────────
    const claims = await restRows('/rest/v1/expense_claims?select=id,code&order=code', 'expense_claims')
    const closes = await restRows('/rest/v1/period_closes?select=id,period_end&order=period_end', 'period_closes')
    const delStmts = await restRows('/rest/v1/bank_statements?select=id,code&deleted_at=not.is.null&order=code', 'deleted statements')
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const po = await one('/rest/v1/purchase_orders?select=id,code&order=code&limit=1', 'a purchase order')
    const batch = await one('/rest/v1/inbound_batches?select=id,code&deleted_at=is.null&order=code&limit=1', 'an inbound batch')
    const je = await one('/rest/v1/journal_entries?select=id,code&code=eq.JE-2026-0001', 'JE-2026-0001')
    const fx = await one('/rest/v1/fx_rates?select=id&deleted_at=is.null&order=rate_date.desc&limit=1', 'an FX rate')
    console.log(`· live: ${claims.length} claims · ${closes.length} month closes · ${delStmts.length} deleted statements`)

    // ── 三个一次性账号:cfo · admin · gm ─────────────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['cfo', 'admin', 'gm']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1c3probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1c3probe', label: roleCode, stamp, password: 'at1c3-probe-1',
            codes: roleCode === 'admin' ? 'all' : { cloneOf: roleCode } })
        cookies[roleCode] = tw.cookie
    }

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
        console.log('AT1C3_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p) => p.status === 200 && !THROWN.test(p.body)
        const fmt = (ymd) => `${ymd.slice(8, 10)}/${ymd.slice(5, 7)}/${ymd.slice(0, 4)}`

        // ── Q25 · Q29:锁期与 GST 两段各看各的列;关账史之下同一段 ─────────────────────────────────
        const s = await get('cfo', '/finance/settings')
        const lock = sectionAt(s.body, 'lock-trail'), gst = sectionAt(s.body, 'gst-trail')
        const firstClose = closes[0] ? `Month closed up to ${fmt(closes[0].period_end)}` : null
        const wantGstWord = INJECT === 'm6-leak'
        check(`Q25 [cfo] /finance/settings lock trail: «${firstClose}» there, no GST wording`,
            rendered(s) && lock.state === 'entries' && (!firstClose || (INJECT === 'no-close' ? !lock.text.includes(firstClose) : lock.text.includes(firstClose)))
            && (wantGstWord ? /GST/.test(lock.text) : !/GST|System start/.test(lock.text)),
            `HTTP ${s.status}, state ${lock.state}, close ${firstClose ? lock.text.includes(firstClose) : '-'}, GST word ${/GST/.test(lock.text)}`)
        check(`Q25 [cfo] /finance/settings GST trail: rendered, no month close, no lock move`,
            rendered(s) && ['entries', 'empty'].includes(gst.state) && !/Month closed|Month reopened|Period lock/.test(gst.text),
            `state ${gst.state}, text «${gst.text.slice(0, 120)}»`)
        const c = await get('cfo', '/finance/close')
        const clock = sectionAt(c.body, 'lock-trail'), ycl = sectionAt(c.body, 'year-close-trail')
        check(`Q29 [cfo] /finance/close: the lock trail under close history, and the year-close block`,
            rendered(c) && clock.state === 'entries' && (!firstClose || clock.text.includes(firstClose)) && ['entries', 'empty'].includes(ycl.state),
            `HTTP ${c.status}, lock ${clock.state}, year close ${ycl.state}`)

        // ── Q20:每一张报销单一段 ────────────────────────────────────────────────────────
        const cl = await get('cfo', '/finance/claims')
        const per = claims.map((x) => ({ code: x.code, sec: sectionAt(cl.body, `claim-trail-${x.id}`) }))
        check(`Q20 [cfo] /finance/claims: one trail per claim (${claims.length}), each with its submission`,
            rendered(cl) && per.every((x) => x.sec.state === 'entries' && /Expense claim submitted/.test(x.sec.text)),
            per.filter((x) => x.sec.state !== 'entries' || !/Expense claim submitted/.test(x.sec.text)).map((x) => `${x.code}: ${x.sec.state}`).join(', '))

        // ── Q6 的入口:删掉的对账单那一块 ─────────────────────────────────────────────────────
        if (delStmts.length) {
            const a = await get('admin', '/finance/bank/statements')
            const blk = sectionAt(a.body, 'deleted-statements-trail')
            check(`Q6  [admin] /finance/bank/statements: the deleted-statements block lists ${delStmts[0].code} with a link`,
                rendered(a) && blk.state === 'entries' && blk.html.includes(`href="/finance/bank/statements/${delStmts[0].id}"`),
                `HTTP ${a.status}, state ${blk.state}, link ${blk.html?.includes(`/finance/bank/statements/${delStmts[0].id}`)}`)
            const g = await get('gm', '/finance/bank/statements')
            const gb = sectionAt(g.body, 'deleted-statements-trail')
            const wantState = INJECT === 'refusal-wrong' ? 'entries' : 'refused'
            check(`Q6  [gm] /finance/bank/statements: the deleted-statements block is a named refusal`,
                rendered(g) && gb.state === wantState && !gb.html.includes(`/finance/bank/statements/${delStmts[0].id}`), `state ${gb.state}`)
        } else skipped.push('Q6 entry point: no deleted bank statement on live')

        // ── 每一页的每一段:没有机器字;中文界面逐字相同 ──────────────────────────────────────────
        const pages = ['/finance/settings', '/finance/close', '/finance/company', '/finance/revaluation', '/finance/assets', '/finance/fx',
            '/finance/cash-forecast', '/finance/payroll-payments', '/finance/processing-costs', '/finance/wht', '/finance/bank', '/finance/claims',
            '/finance/bank/import', '/finance/bank/statements', '/finance/journal',
            po && `/purchasing/orders/${po.id}`, batch && `/inbound/${batch.id}/edit`, je && `/finance/journal/${je.id}`, fx && `/finance/fx/${fx.id}/edit`].filter(Boolean)
        for (const path of pages) {
            const p = await get('admin', path)
            const secs = trailSections(p.body)
            const text = secs.join(' ')
            const hits = machineTokens(text)
            if (path === '/finance/journal' && secs.length === 0) { skipped.push(`/finance/journal: 0 journal requests on live — no per-request trail to read (fixture 243 J · the proof)`); continue }
            check(`page [admin] ${path}: ${secs.length} trail section(s) rendered, no machine token`, rendered(p) && secs.length > 0 && !hits.length,
                `HTTP ${p.status}, sections ${secs.length}, tokens ${hits.slice(0, 4).map((h) => h.token).join(', ')}`)
            const z = await get('admin', path, 'zh')
            let zt = trailSections(z.body).join(' | ')
            const et = secs.join(' | ')
            if (INJECT === 'cjk') zt += ' 受限'
            let at = 0
            while (at < zt.length && zt[at] === et[at]) at++
            check(`fold-in 3 [admin] ${path}: every trail section reads the same in the Chinese interface (${et.length} chars)`, z.status === 200 && zt.length > 0 && zt === et,
                `zh ${zt.length} chars vs en ${et.length}; they part at ${at}: zh "…${zt.slice(Math.max(0, at - 40), at + 30)}…" · en "…${et.slice(Math.max(0, at - 40), at + 30)}…"`)
        }
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
    console.log(`AT1C3_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1C3_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
