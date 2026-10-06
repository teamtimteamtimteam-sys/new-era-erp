#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1 · 页面这一层的探针 —— 「以【真角色的码】的身份把那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 237 / 238 证的是读法(record_trail 返回什么);横幅、只读、英文、分页
//   这几件事住在【页面】上,fixture 看不见。冒烟以 admin 登录,而这一刀有三件事只对【不是 admin】的人才显形
//   (人名受限、设备页不被拒、/inventory 那一块的金额受限)—— 与 scripts/probe-role-crash.mjs 同一个理由。
//
// 【受测的人】两个一次性账号:一个授【真的】warehouse 角色(持加工 / 进料 / 产出 / 库存,不持财务、不持人事),
//   一个授 admin(持人事 —— 横幅上说得出名字)。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 【受测的行】按名挑:一张注销了的进料批次(IN-2026-0002:注销人与理由都记着)、一张回滚了的加工单
//   (PROC-2026-0494:回滚人记着)、一张回滚人没记的(PROC-2026-0002:横幅只说日期,Q8)、第一张资产卡。
//
// 【断言】(每一条都说出它是哪一条裁定)
//   Q21 · Q8  注销的批次 / 回滚的加工单【照常打开】(不是 404)、带横幅、第二行是理由、表单在 <fieldset disabled> 里;
//             没记人的那张只说日期
//   Q22 · Q10 仓库的人打得开设备清单与设备页,审计记录是 entries(不是拒绝)
//   Q12       /inventory 有申请那一块
//   折入 1    仓库的人在批次的审计记录里看到别人是 Restricted
//   折入 2    汇总页 20 条之后是 "Show older entries"(不再是 Newest / Older)
//   折入 3    界面切成中文时,每一段审计记录(data-audit-trail / data-change-history 那一段)的文字与英文界面下【逐字相同】——
//             界面语言碰不到那一段里的任何一个字。★ 第一版判的是"一个中文字都没有",它在汇总页上红了:一条冒烟临时行的【名字】
//             本身就是中文("【SMOKE 冒烟脚本临时行…")。名字是数据,Q8 说数据照原样说;界面语言才是折入 3 管的东西。
//             "中英两份逐字相同"问的正是那一件事 —— 数据里的中文两份都有,界面换出来的中文只在一份里有。
//
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1B1_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1b1.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup } from './ephemeral.mjs'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3196            // 不与冒烟(3199)、版式(3198)、角色探针(3197)撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'live-batch': '把"注销了的批次"换成一张在册的 —— 横幅那一条必须红',
    'cjk': '往扫的那段审计记录文字里塞一个中文字 —— 折入 3 那一条必须红',
    'older-label': '把期望的分页字样换成旧的 "Older" —— 折入 2 那一条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1B1_PROBE_EXIT=2')
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
        const inner = m[1].replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ')
        out.push(inner.replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' '))
    }
    return out
}

async function main() {
    acquireOrExit('scripts/probe-at1b1.mjs', { ownExit: false })
    openPlan('scripts/probe-at1b1.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 按名挑受测的行 ───────────────────────────────────────────────────────
    const pick = async (path, ctx) => { const r = await restRows(path, ctx); if (!r.length) throw new Error(`线上找不到${ctx}`); return r[0] }
    const offBatch = INJECT === 'live-batch'
        ? await pick('/rest/v1/inbound_batches?select=id,code&deleted_at=is.null&order=code&limit=1', '一张在册的进料批次')
        : await pick('/rest/v1/inbound_batches?select=id,code,delete_reason&code=eq.IN-2026-0002', '注销了的 IN-2026-0002')
    const revRun = await pick('/rest/v1/processing_runs?select=id,code,delete_reason&code=eq.PROC-2026-0494', '回滚了的 PROC-2026-0494')
    const revRunNoBy = await pick('/rest/v1/processing_runs?select=id,code&code=eq.PROC-2026-0002', '回滚人没记的 PROC-2026-0002')
    const liveBatch = await pick('/rest/v1/inbound_batches?select=id,code&code=eq.IN-2026-0001', 'IN-2026-0001')
    const asset = await pick('/rest/v1/fixed_assets?select=id,code&order=code&limit=1', '一张资产卡')
    const po = await pick('/rest/v1/purchase_orders?select=id,code&code=eq.PO-2026-0010', 'PO-2026-0010')
    console.log(`· 受测:注销 ${offBatch.code} · 回滚 ${revRun.code} / ${revRunNoBy.code} · 在册 ${liveBatch.code} · 设备 ${asset.code} · ${po.code}`)

    // ── 两个一次性账号:warehouse 与 admin ─────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['warehouse', 'admin']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1b1probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1b1probe', label: roleCode, stamp, password: 'at1b1-probe-1',
            codes: roleCode === 'admin' ? 'all' : { cloneOf: roleCode } })
        cookies[roleCode] = tw.cookie
    }

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
        console.log('AT1B1_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p, code) => p.status === 200 && !THROWN.test(p.body) && (!code || p.body.includes(code))

        // Q21 · Q8:注销的批次(仓库 —— 页面平常的读者)
        const a = await get('warehouse', `/inbound/${offBatch.id}/edit`)
        check(`Q21 [warehouse] ${offBatch.code} opens (not 404)`, rendered(a, offBatch.code), `HTTP ${a.status}`)
        check(`Q21 [warehouse] ${offBatch.code} carries the written-off banner`, a.body.includes('data-ended-banner="writtenOff"'), '没有横幅')
        check(`Q21 [warehouse] ${offBatch.code} is read-only`, a.body.includes('data-ended-readonly'), '表单不在 <fieldset disabled> 里')
        check(`Q8  [warehouse] ${offBatch.code} banner's second line is the reason`,
            !offBatch.delete_reason || a.body.includes(offBatch.delete_reason.slice(0, 20)), '横幅里找不到理由')
        check(`Q21 [warehouse] ${offBatch.code} still has its trail`, a.body.includes('data-audit-trail="entries"'), '审计记录不是 entries')
        // 折入 1:仓库的人不持人事 —— 别人在他眼里是 Restricted
        const aTrail = trailSections(a.body).join(' ')
        check(`fold-in 1 [warehouse] names are Restricted in the batch trail`, /Restricted/.test(aTrail), '审计记录里一个 Restricted 都没有')
        // 管理员:横幅说得出名字
        const a2 = await get('admin', `/inbound/${offBatch.id}/edit`)
        const banner = (a2.body.match(/<div[^>]*data-ended-banner="writtenOff"[\s\S]*?<\/div>/) ?? [''])[0].replace(/<[^>]+>/g, ' ')
        check(`Q8  [admin] ${offBatch.code} banner names who wrote it off`, /Written off on \d{2}\/\d{2}\/\d{4} by\s+\S/.test(banner) && !/Restricted/.test(banner), banner.slice(0, 160))

        // Q21:回滚了的加工单(加工的门)
        const b = await get('warehouse', `/operation/processing/${revRun.id}`)
        check(`Q21 [warehouse] ${revRun.code} opens`, rendered(b, revRun.code), `HTTP ${b.status}`)
        check(`Q21 [warehouse] ${revRun.code} carries the reversed banner`, b.body.includes('data-ended-banner="reversed"'), '没有横幅')
        const b2 = await get('admin', `/operation/processing/${revRunNoBy.id}`)
        const banner2 = (b2.body.match(/<div[^>]*data-ended-banner="reversed"[\s\S]*?<\/div>/) ?? [''])[0].replace(/<[^>]+>/g, ' ')
        check(`Q8  [admin] ${revRunNoBy.code} (no one recorded) banner says the date only`, /Reversed on \d{2}\/\d{2}\/\d{4}/.test(banner2) && !/ by /.test(banner2), banner2.slice(0, 160))

        // Q22 · Q10:设备清单与设备页,仓库的人(持加工、不持财务)
        const c = await get('warehouse', '/operation/equipment')
        check('Q10 [warehouse] /operation/equipment lists the machines', rendered(c, asset.code), `HTTP ${c.status}`)
        const d = await get('warehouse', `/operation/equipment/${asset.id}`)
        check(`Q22 [warehouse] /operation/equipment/${asset.code} opens with its trail (M3: not refused)`,
            rendered(d, asset.code) && d.body.includes('data-audit-trail="entries"'), `HTTP ${d.status}, section ${(d.body.match(/data-audit-trail="(\w+)"/) ?? [])[1]}`)

        // Q12:/inventory 的申请那一块
        const e = await get('warehouse', '/inventory')
        check('Q12 [warehouse] /inventory has the warehouse-request trail block', e.status === 200 && e.body.includes('id="warehouse-request-trail"'), `HTTP ${e.status}`)

        // 折入 2:汇总页 20 条之后是 "Show older entries"
        const f = await get('admin', '/settings/change-history')
        const older = INJECT === 'older-label' ? '>Older<' : 'Show older entries'
        check('fold-in 2 [admin] /settings/change-history pages with "Show older entries"', f.status === 200 && f.body.includes(older) && !f.body.includes('>Newest<'), '分页字样不对')

        // 折入 3:中文界面,每一段审计记录里一个中文字都没有
        const zhPages = [
            ['warehouse', `/inbound/${liveBatch.id}/edit`], ['warehouse', `/inbound/${offBatch.id}/edit`],
            ['warehouse', `/operation/processing/${revRun.id}`], ['warehouse', `/operation/equipment/${asset.id}`],
            ['warehouse', '/inventory'], ['admin', `/purchasing/orders/${po.id}`], ['admin', '/settings/change-history'],
        ]
        for (const [role, path] of zhPages) {
            const z = await get(role, path, 'zh')
            const e = await get(role, path, 'en')
            let zt = trailSections(z.body).join(' | ')
            const et = trailSections(e.body).join(' | ')
            if (INJECT === 'cjk' && path === '/inventory') zt += ' 受限'
            let why = ''
            if (z.status !== 200 || e.status !== 200) why = `HTTP ${z.status} / ${e.status}`
            else if (!zt.length) why = '找不到审计记录那一段'
            else if (zt !== et) {
                let i = 0
                while (i < zt.length && zt[i] === et[i]) i++
                why = `zh 与 en 在第 ${i} 个字处分开:zh "…${zt.slice(Math.max(0, i - 30), i + 20)}…" · en "…${et.slice(Math.max(0, i - 30), i + 20)}…"`
            }
            check(`fold-in 3 [${role}] ${path} trail section reads the same in the Chinese interface`, !why, why)
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
    console.log(`AT1B1_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1B1_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
