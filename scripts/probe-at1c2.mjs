#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-2 · 页面这一层的探针 —— 「以【真角色】的身份把其余单据与合同那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 242 证的是读法;横幅(Q8 · Q6)、只读、具名拒绝、资产页上那一段旧"Change history"(Q26)、
//   中文界面里审计记录那一段逐字不变(折入 3)住在页面上。形状照 scripts/probe-at1c1.mjs。
// 【受测的人】三个一次性账号:一个授【真的】cfo、一个授 admin(两者都持 data.view_deleted)、一个授 gm(每一个模块,
//   【不】持 data.view_deleted —— 删掉的对账单对它是一句具名拒绝)。
// 【受测的行】线上真有的:八个主语的【每一条】记录(销售 · 运费单 · 资产 · 对账单 · GST 期间 · 汇率 · 管理包 · 合同 —— 今天管理包与
//   合同是 0 张,照直报出来);一张删掉的对账单(BS-2026-0001);一张冲销了的运费单;外加 1a / 1b / 1c-1 各一页(折入 3 的对照)。
// 【断言】
//   Q6   删掉的对账单:admin 只读打开,横幅 "Deleted on DD/MM/YYYY"(没有记人就只说日期)、按钮按不下去、审计记录 entries;
//        gm 得到一句具名拒绝(200,不是 404);/settings/deleted 列出它、链到它
//   Q8   冲销了的运费单:"Reversed on DD/MM/YYYY by <名字>" + 一行链到冲销分录
//   Q26  资产页上原来那一段 FA-HIST-1 "Change history"(它一定印 "This trail starts on …")没有了
//   页面 八个主语的每一条活记录:审计记录 entries,剥掉人敲的字之后一个机器字都没有;中文界面那一段逐字相同 ——
//        不同的话打印两边第一处分开的地方(docs/known-issues.md 的 AT1C1-TRAIL-ZH-EN-ONE-UNEXPLAINED-MISMATCH 要的就是这个位置);
//        1a 的采购单、1b 的批次、1c-1 的分录(JE-2026-0001 —— 上一次没解释的那一张)同样比一遍
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1C2_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1c2.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup, ORDER } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3192            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1(3196)、1b-2(3195)、1b-3(3194)、1c-1(3193)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'banner-noby': '期望冲销了的运费单横幅里【没有】" by " —— Q8 那一条必须红',
    'history-back': '把期望"没有"的那句旧面板文字换成一定在的 "Audit trail" —— Q26 那一条必须红',
    'refusal-wrong': '期望 gm 读到的拒绝是另一句话 —— Q6 的拒绝那一条必须红',
    'cjk': '往中文那一份里塞一个中文字 —— 折入 3 那几条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1C2_PROBE_EXIT=2')
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
async function signIn(email, password) {
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }),
    })).json()
    if (!sess?.access_token) throw new Error(`登录失败(${email}):${JSON.stringify(sess).slice(0, 200)}`)
    return 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
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
    acquireOrExit('scripts/probe-at1c2.mjs', { ownExit: false })
    openPlan('scripts/probe-at1c2.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的;每一种的条数照直报)──────────────────────────────────────
    const ids = async (table, extra = '') => (await restRows(`/rest/v1/${table}?select=id${extra}&order=id`, table))
    const sales = await ids('sales_records')
    const freights = await ids('freight_documents', ',code,status,reversed_by,reversal_entry_id')
    const assets = await ids('fixed_assets', ',code')
    const statements = await ids('bank_statements', ',code,deleted_at')
    const gsts = await ids('gst_periods', ',code')
    const rates = await ids('fx_rates', ',deleted_at')
    const packs = await ids('management_packs', ',code')
    const contracts = await ids('contracts', ',code')
    const counts = { sale: sales.length, freight: freights.length, fixed_asset: assets.length, bank_statement: statements.length,
        gst_period: gsts.length, fx_rate: rates.length, management_pack: packs.length, contract: contracts.length }
    console.log(`· live records per subject: ${JSON.stringify(counts)}`)
    const delStmt = statements.find((s) => s.deleted_at)
    const revFreight = freights.find((f) => f.status === 'reversed' && f.reversal_entry_id)
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const po = await one('/rest/v1/purchase_orders?select=id,code&order=code&limit=1', 'a purchase order')
    const batch = await one('/rest/v1/inbound_batches?select=id,code&deleted_at=is.null&order=code&limit=1', 'an inbound batch')
    const je = await one('/rest/v1/journal_entries?select=id,code&code=eq.JE-2026-0001', 'JE-2026-0001')

    // ── 三个一次性账号:cfo · admin · gm ─────────────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['cfo', 'admin', 'gm']) {
        const email = `at1c2probe-${stamp}-${roleCode}@test.local`
        const r = await rest('/auth/v1/admin/users', { method: 'POST', body: JSON.stringify({ email, password: 'at1c2-probe-1', email_confirm: true }) })
        if (!r.ok) throw new Error(`建 ${roleCode} 账号失败:HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
        const u = await r.json()
        planDelete(`/rest/v1/user_roles?user_id=eq.${u.id}`, `revoke ${roleCode} grant ${u.id}`, ORDER.GRANT)
        planDelete(`/auth/v1/admin/users/${u.id}`, `delete ${roleCode} account ${u.id}`, ORDER.ACCOUNT)
        const rr = await restRows(`/rest/v1/roles?select=id&code=eq.${roleCode}`, `roles ← ${roleCode}`)
        const g = await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(u.id, rr[0].id)) })
        if (!g.ok) throw new Error(`授 ${roleCode} 失败:HTTP ${g.status} ${(await g.text()).slice(0, 200)}`)
        cookies[roleCode] = await signIn(email, 'at1c2-probe-1')
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
        console.log('AT1C2_PROBE_EXIT=2')
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

        // ── Q6:删掉的对账单 —— admin 只读打开;gm 一句具名拒绝;/settings/deleted 列出它、链到它 ──────────────
        if (delStmt) {
            const p = await get('admin', `/finance/bank/statements/${delStmt.id}`)
            const head = bannerHead(p.body, 'deleted')
            check(`Q6  [admin] deleted statement ${delStmt.code}: «${head}», read-only, trail entries`,
                rendered(p) && head !== null && new RegExp(`^Deleted on ${DATE}( by \\S.*)?$`).test(head) && p.body.includes('data-ended-readonly')
                && section(p) === 'entries' && !p.body.includes(`/finance/bank/statements/${delStmt.id}/reconcile`),
                `HTTP ${p.status}, banner «${head}», readonly ${p.body.includes('data-ended-readonly')}, section ${section(p)}`)
            const g = await get('gm', `/finance/bank/statements/${delStmt.id}`)
            const want = INJECT === 'refusal-wrong' ? 'This record never existed.' : 'This record has been deleted.'
            check(`Q6  [gm] deleted statement ${delStmt.code}: a named refusal, not a 404`, g.status === 200 && g.body.includes(want) && section(g) === '(none)',
                `HTTP ${g.status}, refusal text ${g.body.includes(want)}`)
            const w = await get('admin', `/finance/bank/statements/${delStmt.id}/reconcile`)
            check(`Q6  [admin] the deleted statement's workspace sends you to the statement (not a 404)`, w.status === 200 && !THROWN.test(w.body) && w.body.includes('data-ended-banner="deleted"'),
                `HTTP ${w.status}`)
            const l = await get('admin', '/settings/deleted')
            check(`Q6  [admin] /settings/deleted lists ${delStmt.code} with a link`, rendered(l) && l.body.includes(`href="/finance/bank/statements/${delStmt.id}"`),
                `HTTP ${l.status}, link ${l.body.includes(`/finance/bank/statements/${delStmt.id}`)}`)
        } else skipped.push('Q6: no deleted bank statement on live')

        // ── Q8:冲销了的运费单 ────────────────────────────────────────────────────────
        if (revFreight) {
            const p = await get('cfo', `/finance/freight/${revFreight.id}`)
            const head = bannerHead(p.body, 'reversed')
            const want = INJECT === 'banner-noby' ? new RegExp(`^Reversed on ${DATE}$`) : new RegExp(`^Reversed on ${DATE} by \\S.*$`)
            check(`Q8  [cfo] reversed freight ${revFreight.code}: «${head}» + a link to the reversal journal`,
                rendered(p) && head !== null && want.test(head) && p.body.includes(`href="/finance/journal/${revFreight.reversal_entry_id}"`),
                `banner «${head}», link ${p.body.includes(`href="/finance/journal/${revFreight.reversal_entry_id}"`)}`)
        } else skipped.push('Q8: no reversed freight document on live')

        // ── Q26:资产页上旧的 FA-HIST-1 面板没有了 ─────────────────────────────────────────
        for (const a of assets) {
            const p = await get('cfo', `/finance/assets/${a.id}`)
            const gone = INJECT === 'history-back' ? 'Audit trail' : 'This trail starts on'
            check(`Q26 [cfo] asset ${a.code}: the old "Change history" panel is gone, the trail is there`, rendered(p) && !p.body.includes(gone) && section(p) === 'entries',
                `HTTP ${p.status}, old text ${p.body.includes(gone)}, section ${section(p)}`)
        }

        // ── 八个主语的每一条活记录 + 1a / 1b / 1c-1 各一页:entries、没有机器字、中文界面逐字相同 ─────────────────
        const pages = [
            ...sales.map((r) => ['sale', `/finance/receivables/${r.id}`]), ...freights.map((r) => ['freight', `/finance/freight/${r.id}`]),
            ...assets.map((r) => ['fixed_asset', `/finance/assets/${r.id}`]), ...statements.map((r) => ['bank_statement', `/finance/bank/statements/${r.id}`]),
            ...gsts.map((r) => ['gst_period', `/finance/gst/${r.id}`]), ...rates.map((r) => ['fx_rate', `/finance/fx/${r.id}/edit`]),
            ...packs.map((r) => ['management_pack', `/finance/packs/${r.id}`]), ...contracts.map((r) => ['contract', `/contracts/${r.id}`]),
            po && ['1a purchase_order', `/purchasing/orders/${po.id}`], batch && ['1b inbound_batch', `/inbound/${batch.id}/edit`],
            je && ['1c-1 journal_entry', `/finance/journal/${je.id}`],
        ].filter(Boolean)
        for (const sub of ['management_pack', 'contract']) if (!counts[sub]) skipped.push(`${sub}: 0 records on live — proved in fixture 242 and the rolled-back proof (Q25)`)
        for (const [sub, path] of pages) {
            const p = await get('admin', path)
            const text = trailSections(p.body).join(' ')
            const hits = machineTokens(text)
            check(`page [admin] ${sub} ${path}: trail entries, no machine token`, rendered(p) && section(p) === 'entries' && text.length > 20 && !hits.length,
                `HTTP ${p.status}, section ${section(p)}, tokens ${hits.slice(0, 4).map((h) => h.token).join(', ')}`)
            const z = await get('admin', path, 'zh')
            let zt = trailSections(z.body).join(' | ')
            const et = trailSections(p.body).join(' | ')
            if (INJECT === 'cjk') zt += ' 受限'
            let at = 0
            while (at < zt.length && zt[at] === et[at]) at++
            check(`fold-in 3 [admin] ${sub} ${path}: the trail reads the same in the Chinese interface (${et.length} chars)`, z.status === 200 && zt.length > 0 && zt === et,
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
    console.log(`AT1C2_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1C2_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
