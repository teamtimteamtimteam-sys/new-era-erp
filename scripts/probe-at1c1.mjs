#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-1 · 页面这一层的探针 —— 「以【真角色的码】的身份把账上那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 241 证的是读法;"来源"链接(Q15)、横幅(Q8 · Q5)、发票页上那一段旧"历史"(Q26)
//   住在页面上。形状照 scripts/probe-at1b3.mjs。
// 【受测的人】两个一次性账号:一个授【真的】cfo(Tim 那一位的角色)、一个授 admin。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 【受测的行】线上真有的:三张冲销分录(source_id 指着原分录 —— 以前"来源"链接 404 的那三张)、一张被冲销的分录、
//   一张作废的发票、一张被冲销的付款与它的镜像单、一张费用、一个注销了的批次、一张贷项通知。
// 【断言】
//   Q15  每一张冲销分录的"来源"链接【不】指着一个分录 id,并且打得开(200,不是 404)
//   Q8   被冲销的分录 / 付款:"Reversed on DD/MM/YYYY by <名字>" + 一行链到冲销那一张;镜像单 / 冲销分录:"Reversal of …";
//        作废的发票:"Voided on DD/MM/YYYY by <名字>"
//   Q5   注销了的批次在应付页上:横幅 "Written off on …"、附件那一块只读、审计记录 entries
//   Q26  发票页上原来那一段 "Earlier requests" 没有了
//   页面 六页的审计记录 entries,剥掉人敲的字之后一个机器字都没有;中文界面那一段逐字相同(折入 3)
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1C1_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1c1.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3193            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1(3196)、1b-2(3195)、1b-3(3194)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'source-raw': '期望冲销分录的"来源"就是原样拼出来的那一条(指着原分录 id)—— Q15 那几条必须红',
    'banner-noby': '期望被冲销的分录横幅里【没有】" by " —— Q8 那一条必须红',
    'history-back': '把期望"没有"的那句旧标题换成一定在的 "Audit trail" —— Q26 那一条必须红',
    'cjk': '往中文那一份里塞一个中文字 —— 折入 3 那一条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1C1_PROBE_EXIT=2')
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
function bannerHead(html, kind) {
    const m = html.match(new RegExp(`data-ended-banner="${kind}"[^>]*>\\s*<p[^>]*>([\\s\\S]*?)<\\/p>`))
    return m ? m[1].replace(/<[^>]+>/g, '').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' ').trim() : null
}

async function main() {
    acquireOrExit('scripts/probe-at1c1.mjs', { ownExit: false })
    openPlan('scripts/probe-at1c1.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的)──────────────────────────────────────────────────
    const journals = await restRows('/rest/v1/journal_entries?select=id,code,source_type,source_id,status,reversed_by&order=code', 'journals')
    const byId = new Map(journals.map((j) => [j.id, j]))
    const reversalsWithSource = journals.filter((j) => j.source_id && byId.has(j.source_id) && ['purchase', 'allocation', 'writeoff', 'sale', 'processing_cost', 'stocktake'].includes(j.source_type))
    const reversedJe = journals.find((j) => j.status === 'reversed' && j.reversed_by)
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const voidInv = await one('/rest/v1/invoices?select=id,code,voided_by&status=eq.void&order=code&limit=1', 'a voided invoice')
    const revPay = await one('/rest/v1/payments?select=id,code,reversed_by_payment&status=eq.reversed&order=code&limit=1', 'a reversed payment')
    const expense = await one('/rest/v1/expenses?select=id,code&order=code&limit=1', 'an expense')
    const cn = await one('/rest/v1/credit_notes?select=id,code&order=code&limit=1', 'a credit note')
    const woBatch = await one('/rest/v1/inbound_batches?select=id,code&deleted_at=not.is.null&order=code&limit=1', 'a written-off batch')
    console.log(`· reversal journals with a document source: ${reversalsWithSource.map((j) => j.code).join(', ') || '(none)'}`)

    // ── 两个一次性账号:cfo · admin ─────────────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['cfo', 'admin']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1c1probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1c1probe', label: roleCode, stamp, password: 'at1c1-probe-1',
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
        console.log('AT1C1_PROBE_EXIT=2')
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

        // ── Q15:冲销分录的"来源"链接 ──────────────────────────────────────────────
        if (!reversalsWithSource.length) skipped.push('Q15: no live reversal journal with a document source')
        for (const j of reversalsWithSource) {
            const p = await get('cfo', `/finance/journal/${j.id}`)
            // 来源链接可能落在的四种页(进料 · 产出 · 加工单 · 盘点)—— 前缀从数组拼,不写成一段路径字面量
            const SOURCE_PAGES = ['/inbound/', '/output/', ['', 'operation', 'processing', ''].join('/'), '/stocktakes/']
            const hrefs = [...p.body.matchAll(/href="(\/[^"]+)"/g)].map((m) => m[1]).filter((h) => SOURCE_PAGES.some((pre) => h.startsWith(pre)))
            const raw = hrefs.find((h) => h.includes(j.source_id))
            const good = hrefs.find((h) => !h.includes(j.source_id))
            const okHref = INJECT === 'source-raw' ? raw : good
            let target = null
            if (okHref) target = await get('cfo', okHref)
            check(`Q15 [cfo] reversal ${j.code} (${j.source_type}): its Source link «${okHref ?? '(none)'}» points past the original journal and opens`,
                rendered(p) && !raw && !!okHref && !!target && target.status === 200 && !THROWN.test(target.body),
                `HTTP ${p.status}, links ${JSON.stringify(hrefs)}, target ${target?.status ?? '-'}`)
            check(`Q8  [cfo] reversal ${j.code} says "Reversal of …"`, p.body.includes('data-reversal-of') && /Reversal of/.test(p.body), 'no Reversal-of banner')
        }

        // ── Q8:被冲销的分录 / 付款,作废的发票 ─────────────────────────────────────
        if (reversedJe) {
            const p = await get('cfo', `/finance/journal/${reversedJe.id}`)
            const head = bannerHead(p.body, 'reversed')
            const want = INJECT === 'banner-noby' ? new RegExp(`^Reversed on ${DATE}$`) : new RegExp(`^Reversed on ${DATE}( by \\S.*)?$`)
            check(`Q8  [cfo] reversed journal ${reversedJe.code}: «${head}» + a link to its reversal`,
                rendered(p) && head !== null && want.test(head) && p.body.includes(`href="/finance/journal/${reversedJe.reversed_by}"`),
                `banner «${head}», link ${p.body.includes(`href="/finance/journal/${reversedJe.reversed_by}"`)}`)
        }
        if (voidInv) {
            const p = await get('cfo', `/finance/invoices/${voidInv.id}`)
            const head = bannerHead(p.body, 'voided')
            check(`Q8  [cfo] voided invoice ${voidInv.code}: «${head}»`, rendered(p) && head !== null && new RegExp(`^Voided on ${DATE}( by \\S.*)?$`).test(head)
                && (!voidInv.voided_by || / by /.test(head)), `banner «${head}»`)
            const gone = INJECT === 'history-back' ? 'Audit trail' : 'Earlier requests'
            check(`Q26 [cfo] the invoice page no longer lists "Earlier requests"`, rendered(p) && !p.body.includes(gone), `still has «${gone}»`)
        } else skipped.push('Q8: no voided invoice on live')
        if (revPay) {
            const p = await get('cfo', `/finance/payments/${revPay.id}`)
            const head = bannerHead(p.body, 'reversed')
            check(`Q8  [cfo] reversed payment ${revPay.code}: «${head}» + a link to the mirror`,
                rendered(p) && head !== null && p.body.includes(`href="/finance/payments/${revPay.reversed_by_payment}"`), `banner «${head}»`)
            const m = await get('cfo', `/finance/payments/${revPay.reversed_by_payment}`)
            check(`Q8  [cfo] the mirror of ${revPay.code} says "Reversal of ${revPay.code}"`, rendered(m) && m.body.includes('data-reversal-of') && m.body.includes(revPay.code), 'no Reversal-of banner')
        } else skipped.push('Q8: no reversed payment on live')

        // ── Q5:注销了的批次在应付页上 ────────────────────────────────────────────
        if (woBatch) {
            const p = await get('cfo', `/finance/payables/${woBatch.id}`)
            const head = bannerHead(p.body, 'writtenOff')
            check(`Q5  [cfo] written-off batch ${woBatch.code} on the payables page: «${head}», read-only, trail entries`,
                rendered(p) && head !== null && new RegExp(`^Written off on ${DATE}`).test(head) && p.body.includes('data-ended-readonly') && section(p) === 'entries',
                `HTTP ${p.status}, banner «${head}», readonly ${p.body.includes('data-ended-readonly')}, section ${section(p)}`)
        }

        // ── 六页:审计记录 entries,一个机器字都没有;中文界面逐字相同 ─────────────────────
        const pages = [
            reversedJe && `/finance/journal/${reversedJe.id}`, voidInv && `/finance/invoices/${voidInv.id}`, cn && `/finance/credit-notes/${cn.id}`,
            revPay && `/finance/payments/${revPay.id}`, expense && `/finance/expenses/${expense.id}`, woBatch && `/finance/payables/${woBatch.id}`,
        ].filter(Boolean)
        for (const path of pages) {
            const p = await get('admin', path)
            const text = trailSections(p.body).join(' ')
            const hits = machineTokens(text)
            check(`page [admin] ${path}: trail entries, no machine token`, rendered(p) && section(p) === 'entries' && text.length > 20 && !hits.length,
                `HTTP ${p.status}, section ${section(p)}, tokens ${hits.slice(0, 4).map((h) => h.token).join(', ')}`)
            const z = await get('admin', path, 'zh')
            let zt = trailSections(z.body).join(' | ')
            const et = trailSections(p.body).join(' | ')
            if (INJECT === 'cjk') zt += ' 受限'
            let at = 0
            while (at < zt.length && zt[at] === et[at]) at++
            check(`fold-in 3 [admin] ${path}: the trail reads the same in the Chinese interface`, z.status === 200 && zt.length > 0 && zt === et,
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
    console.log(`AT1C1_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1C1_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
