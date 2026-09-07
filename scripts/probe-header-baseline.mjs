#!/usr/bin/env node
// scripts/probe-header-baseline.mjs
// ════════════════════════════════════════════════════════════════════════════
// ★ SURVEY TOOL — NOT A GATE. BTN-6(2026-09-07)。退出码 0,除非它自己崩了。
//
// 【它为什么存在 —— 一个【被要求量出来、不许推理】的风险】
//   BTN-6 把 ListPage 的 {actions} 包进一个自己的 flex 容器里(§四)。而 ListPage
//   的抬头行是 `items-baseline`:在此之前,一个裸 <Button> 调用点【自己】就是那个
//   flex item,标题与按钮按【按钮的基线】对齐。包一层之后,flex item 变成了那个 div。
//
//   CSS 说 flex 容器的基线取自它第一个 flex item —— 也就是说【应该】没有变化。
//   ★ 但"应该"不是一个测量结果。★ Tim 的裁定原话:如果它动了,那就是这次修复的
//     真实代价,而他要看见那个代价,不是看见一句"已考虑"。
//   所以这支探针把它量出来:同样的路由,改之前跑一遍,改之后跑一遍,比数。
//
// 【量的是什么 —— 判据先说清楚,再数】
//   不量 boundingClientRect 的 top:一个 h-8 的按钮和一行 text-2xl 的标题本来就
//   不同高,它们的 top 本来就不同,比它没有意义。
//   量的是【两段字的墨迹底边之差】:标题的文字节点、按钮标签的文字节点,各自
//   用 Range.getClientRects() 取出真正的文本盒,比它们的 bottom。
//   字号与行高本刀一个字没动,所以墨迹底边之差【就是】基线之差的可观测代理:
//       delta = h1文本底边 − 按钮文本底边
//   改前改后 delta 不变 ⇒ 对齐没有动。变了 ⇒ 变了多少,就是代价。
//
//   同时记下抬头行自己的高度:如果容器让抬头换了行,高度会跳,而那是另一种代价。
//
// 【两个宽度都量】390(手机,本族一直在量的那个)与 1280(桌面,人真正在用的)。
//   只量手机会漏掉桌面回归,只量桌面会漏掉换行 —— 两个都量,便宜。
//
// 用法:node scripts/probe-header-baseline.mjs --tag=before|after
// 输出:scratchpad JSON + 人读的摘要
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const OUT_DIR = process.env.SURVEY_OUT || join(ROOT, '.survey-out')
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const PORT = 3204          // 3198 survey-phone · 3199 smoke · 3201 avatar · 3202 button-tiers
const CDP_PORT = 9340
const TAG = (process.argv.find(a => a.startsWith('--tag=')) || '--tag=run').split('=')[1]

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// ★ 取样路由 —— §4.3 要求「至少三条裸 <Button> 调用点的路由」,这里给了四条,
//   外加三种【别的形状】做对照:div 容器 · 带 shrink-0 的 div · 裸 fragment。
const ROUTES = [
    { path: '/materials',                    shape: 'bare <Button>' },
    { path: '/sales/orders',                 shape: 'bare <Button>' },
    { path: '/hr/departments',               shape: 'bare <Button>' },
    { path: '/purchasing/orders',            shape: 'bare <Button>' },
    { path: '/suppliers',                    shape: 'div flex items-center gap-3' },
    { path: '/inventory/reports/ledger',     shape: 'div flex gap-2 shrink-0' },
    { path: '/finance/fx',                   shape: 'fragment <>' },
]
const WIDTHS = [390, 1280]

let dev = null, chrome = null, accountId = null
const sleep = (ms) => new Promise(r => setTimeout(r, ms))
function killChildren() {
    for (const c of [dev, chrome]) { try { if (c?.pid) process.kill(-c.pid, 'SIGKILL') } catch {} try { c?.kill('SIGKILL') } catch {} }
}
installExitHooks({ onFinish: () => { killChildren(); release('scripts/probe-header-baseline.mjs') } })

class Cdp {
    constructor(ws) {
        this.ws = ws; this.id = 0; this.waiting = new Map()
        ws.onmessage = (e) => {
            const m = JSON.parse(e.data)
            if (m.id && this.waiting.has(m.id)) {
                const { res, rej } = this.waiting.get(m.id); this.waiting.delete(m.id)
                m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result)
            }
        }
    }
    send(method, params = {}, sessionId) {
        const id = ++this.id
        return new Promise((res, rej) => {
            this.waiting.set(id, { res, rej })
            this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }))
            setTimeout(() => { if (this.waiting.has(id)) { this.waiting.delete(id); rej(new Error('CDP timeout ' + method)) } }, 60000)
        })
    }
}
async function rest(path, opts = {}) {
    return fetch(URL_ + path, { ...opts, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers || {}) } })
}

// ── 页面里跑的那段:找抬头、量两段字的墨迹底边 ──────────────────────────────
const MEASURE = `(() => {
  const h1 = document.querySelector('h1');
  if (!h1) return { ok: false, why: 'no h1' };
  // 抬头行 = h1 的父元素(ListPage 里那个 flex flex-wrap items-baseline …)
  const header = h1.parentElement;
  const btn = header ? header.querySelector('[data-slot="button"]') : null;
  // 一段元素里第一个非空文本节点的墨迹盒
  function inkBottom(el) {
    if (!el) return null;
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = w.nextNode())) {
      if (!n.nodeValue || !n.nodeValue.trim()) continue;
      const r = document.createRange();
      r.selectNodeContents(n);
      const rects = r.getClientRects();
      if (rects.length) return { bottom: rects[0].bottom, top: rects[0].top, text: n.nodeValue.trim().slice(0, 24) };
    }
    return null;
  }
  const a = inkBottom(h1);
  const b = inkBottom(btn);
  const hr = header ? header.getBoundingClientRect() : null;
  return {
    ok: true,
    hasButton: !!btn,
    h1Ink: a, btnInk: b,
    delta: (a && b) ? +(a.bottom - b.bottom).toFixed(2) : null,
    headerH: hr ? +hr.height.toFixed(2) : null,
    headerClass: header ? header.className : null,
    actionsWrapper: btn ? (btn.parentElement === header ? 'button is direct child of header'
                          : btn.parentElement.className || '(unclassed parent)') : null,
    overflowPx: Math.round(document.documentElement.scrollWidth - document.documentElement.clientWidth),
  };
})()`

async function main() {
    acquireOrExit('scripts/probe-header-baseline.mjs', { ownExit: false })
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    if (existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID exists — a production build makes dynamic routes 404 under `next dev`. rm -rf .next first.')
    openPlan('scripts/probe-header-baseline.mjs')
    await reapStalePlans()
    mkdirSync(OUT_DIR, { recursive: true })

    try {
        const pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' }).trim().split('\n').filter(Boolean)
        for (const pid of pids) {
            const ppid = execSync(`ps -o ppid= -p ${pid} || echo 0`, { encoding: 'utf8' }).trim()
            if (ppid === '1') { execSync(`kill -9 ${pid}`) }
            else throw new Error(`port ${PORT} held by a LIVE process (pid ${pid}) — another run is in progress`)
        }
    } catch (e) { if (/held by a LIVE/.test(e.message)) throw e }

    const email = `hdrbase-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST', body: JSON.stringify({ email, password: 'hdrbase-pass-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('could not create probe account: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke hdrbase grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete hdrbase account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'hdrbase-pass-1' }) })).json()
    if (!sess?.access_token) throw new Error('probe sign-in failed')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
    console.error('· ephemeral admin session ready')

    console.error('· starting next dev on :' + PORT)
    dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    await new Promise((res, rej) => {
        const to = setTimeout(() => rej(new Error('dev did not start in 180s')), 180000)
        const on = (b) => { if (/Ready in|started server|Local:/i.test(b.toString())) { clearTimeout(to); res() } }
        dev.stdout.on('data', on); dev.stderr.on('data', on)
    })
    await sleep(2000)

    console.error('· launching chrome-headless-shell')
    chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--hide-scrollbars', '--window-size=390,844',
        `--user-data-dir=${join(OUT_DIR, 'hdrbase-profile')}`, 'about:blank'], { stdio: ['ignore', 'pipe', 'pipe'] })
    let wsUrl = null
    for (let i = 0; i < 60 && !wsUrl; i++) { await sleep(500); try { wsUrl = (await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()).webSocketDebuggerUrl } catch {} }
    if (!wsUrl) throw new Error('chrome never opened its debugging port')
    const ws = new WebSocket(wsUrl)
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP ws failed')) })
    const cdp = new Cdp(ws)

    const t = await cdp.send('Target.createTarget', { url: 'about:blank' })
    const a = await cdp.send('Target.attachToTarget', { targetId: t.targetId, flatten: true })
    const sid = a.sessionId
    const S = (m, p) => cdp.send(m, p, sid)
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue, domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    await S('Page.navigate', { url: `http://localhost:${PORT}/` }); await sleep(8000)

    const results = []
    for (const w of WIDTHS) {
        await S('Emulation.setDeviceMetricsOverride', { width: w, height: 844, deviceScaleFactor: 2, mobile: w === 390, screenWidth: w, screenHeight: 844 })
        for (const r of ROUTES) {
            await S('Page.navigate', { url: `http://localhost:${PORT}${r.path}` })
            await sleep(4500)
            let m
            try { m = (await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true })).result.value }
            catch (e) { m = { ok: false, why: 'evaluate failed: ' + e.message } }
            results.push({ width: w, route: r.path, shape: r.shape, ...m })
            const d = m?.delta === null || m?.delta === undefined ? '—' : m.delta
            console.log(`  [${w}] ${r.path.padEnd(32)} delta=${String(d).padStart(7)}  headerH=${m?.headerH ?? '—'}  btn=${m?.hasButton ? 'y' : 'n'}  ovf=${m?.overflowPx ?? '—'}`)
        }
    }

    const out = join(OUT_DIR, `header-baseline-${TAG}.json`)
    writeFileSync(out, JSON.stringify({ tag: TAG, results }, null, 2))
    console.log('')
    console.log('written: ' + out)
    console.log(`量到 ${results.filter(r => r.hasButton).length} / ${results.length} 条取样有抬头按钮。`)
    console.log('★ delta = 标题墨迹底边 − 按钮墨迹底边。改前改后【比这个数】,不比绝对位置。')
}

try { await main() } catch (e) { console.error('✗ 探针自身出错:' + (e?.message ?? e)); process.exitCode = 1 }
finally { await runPlan(); killChildren(); try { release('scripts/probe-header-baseline.mjs') } catch {} }
