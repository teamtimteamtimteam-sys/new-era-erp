#!/usr/bin/env node
// scripts/survey-phone.mjs
// ════════════════════════════════════════════════════════════════════════════
// ★ SURVEY TOOL — NOT A GATE. PAGE-0 (2026-09-03).
//   It asserts nothing, gates nothing, and is called by no build/gate/smoke
//   path. It exists to answer ONE question with a measured number rather than
//   an estimate: **how many pages are usable on Tim's 390px phone today.**
//   Re-run it from any later conversion cut to see the number move.
//
//   Usage: node scripts/survey-phone.mjs [--limit=N] [--only=/prefix]
//   Output: scratchpad JSON + a human summary on stdout. Exit 0 unless it
//   crashes — a red exit here would mean the SCRIPT broke, never the pages.
//
// ── WHAT "USABLE AT 390px" MEANS HERE (stated before counting) ──────────────
//   Measured in a real browser (chrome-headless-shell over CDP), against a
//   real server-rendered page with a real admin session, reading
//   getBoundingClientRect / getComputedStyle / scrollWidth. Not screenshots.
//
//   U1 · PAN-FREE      documentElement.scrollWidth <= innerWidth + 1
//                      The page does not force the reader to pan sideways to
//                      read a row. Failing U1 is the loud failure.
//   U2 · NO CLIPPED    every <table> either fits its container, or has an
//        LEDGER        ancestor whose computed overflow-x is auto|scroll.
//                      A table wider than a NON-scrolling ancestor has columns
//                      that cannot be reached at all — data that is simply
//                      gone on a phone, with nothing on screen saying so.
//                      This is the quiet failure, and it is the worse one.
//
//   USABLE  ==  U1 AND U2.  Both are mechanism, not taste.
//
//   Counted alongside, but deliberately NOT part of "usable", because the
//   threshold is a judgement and this document must not smuggle one in:
//   T · touch targets — interactive elements whose smaller side < 44 CSS px
//       (WCAG 2.5.5 AAA / Apple HIG). Reported per page as a raw count.
//
// ── WHAT IT CANNOT SEE ──────────────────────────────────────────────────────
//   * Anything behind an interaction. It measures first paint only: menus,
//     dialogs, expanded rows and tab panels are never opened. A page that is
//     fine on arrival and overflows once a panel opens reads as usable here.
//   * Whether a page is COMPREHENSIBLE at 390px. Fitting is not the same as
//     being readable; that needs a person (docs/manual-walk-list.md).
//   * Dynamic routes with no live row — they render an empty state, so their
//     widest table never draws and the page looks narrower than it is. Those
//     are reported separately as `no-rows`, never counted as usable.
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, mkdirSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { acquireOrExit, release } from './liveLock.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3198              // NOT 3199 — that one is the smoke's
const CDP_PORT = 9333
const OUT_DIR = process.env.SURVEY_OUT || join(ROOT, '.survey-out')
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ── routes ──────────────────────────────────────────────────────────────────
function* walk(dir) {
    for (const name of readdirSync(dir)) {
        const p = join(dir, name)
        if (statSync(p).isDirectory()) { if (name !== 'brand-sampler') yield* walk(p) }
        else if (name === 'page.tsx') yield p
    }
}
const allRoutes = [...walk(join(ROOT, 'app'))]
    .map((p) => p.slice(ROOT.length + 3).replace(/\/page\.tsx$/, '') || '/')
    .sort()

// ── dynamic-segment ids: ONE definition, and it lives in the smoke ──────────
// Copying smoke's ID_SOURCES table into this file is exactly the two-drifting-
// implementations disease this repo has paid for four times. So it is read OUT
// of scripts/smoke-routes.mjs at runtime. If the shape there changes, this
// FAILS LOUDLY and the dynamic routes are reported as unmeasured — it never
// silently falls back to "no id", which would quietly turn detail pages into
// 404s that read like narrow, usable pages.
function loadIdSources() {
    const src = readFileSync(join(ROOT, 'scripts/smoke-routes.mjs'), 'utf8')
    const start = src.indexOf('const ID_SOURCES = {')
    if (start < 0) throw new Error('ID_SOURCES not found in smoke-routes.mjs — shape changed')
    let i = src.indexOf('{', start), depth = 0, end = -1
    for (; i < src.length; i++) {
        if (src[i] === '{') depth++
        else if (src[i] === '}') { depth--; if (depth === 0) { end = i + 1; break } }
    }
    if (end < 0) throw new Error('ID_SOURCES braces unbalanced')
    const body = src.slice(src.indexOf('{', start), end)
        .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n')
    return (0, eval)('(' + body + ')')
}

async function rest(path, opts = {}) {
    return fetch(URL_ + path, {
        ...opts,
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`,
                   'Content-Type': 'application/json', ...(opts.headers || {}) },
    })
}
async function firstId(table) {
    const r = await rest(`/rest/v1/${table}?select=id&limit=1`)
    if (!r.ok) return null
    const rows = await r.json()
    return Array.isArray(rows) && rows[0] ? rows[0].id : null
}

// ── CDP ─────────────────────────────────────────────────────────────────────
class Cdp {
    constructor(ws) { this.ws = ws; this.id = 0; this.waiting = new Map(); this.sessions = new Map()
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
            setTimeout(() => { if (this.waiting.has(id)) { this.waiting.delete(id); rej(new Error('CDP timeout: ' + method)) } }, 60000)
        })
    }
}

// ── the measurement, run inside the page ────────────────────────────────────
// Kept as a single string so what runs in the browser is visible here verbatim.
const MEASURE = `(() => {
  // ★ The viewport width is documentElement.clientWidth — the LAYOUT viewport.
  //   NOT window.innerWidth: under device emulation innerWidth tracks the
  //   VISUAL viewport, which shrink-to-fit widens to match overflowing content.
  //   Using innerWidth makes 'scrollWidth > innerWidth' unable to ever fire —
  //   the probe reads every page as green. The fault-injection self-test in
  //   this script exists because that is exactly what it did on the first run.
  const de = document.documentElement;
  const vw = de.clientWidth;
  const pageScrollW = Math.max(de.scrollWidth, document.body ? document.body.scrollWidth : 0);
  const overflowPx = Math.round(pageScrollW - vw);
  const viewportMeta = (document.querySelector('meta[name="viewport"]') || {}).content || null;

  const scrolls = (el) => {
    const s = getComputedStyle(el).overflowX;
    return s === 'auto' || s === 'scroll';
  };
  const inScroller = (el) => {
    for (let p = el.parentElement; p; p = p.parentElement) if (scrolls(p)) return p;
    return null;
  };

  // U1 culprits: elements sticking out past the viewport that are NOT inside a
  // horizontal scroller (inside one, sticking out is intended).
  const culprits = [];
  if (overflowPx > 1) {
    for (const el of document.querySelectorAll('*')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      if (r.right <= vw + 1) continue;
      if (inScroller(el)) continue;
      culprits.push({
        tag: el.tagName.toLowerCase(),
        cls: (el.getAttribute('class') || '').slice(0, 120),
        right: Math.round(r.right), width: Math.round(r.width),
        depth: (() => { let d = 0; for (let p = el.parentElement; p; p = p.parentElement) d++; return d; })(),
      });
    }
    culprits.sort((a, b) => b.depth - a.depth);
  }

  // U2: a table wider than a NON-scrolling ancestor = columns unreachable.
  const tables = [];
  for (const t of document.querySelectorAll('table')) {
    const sc = inScroller(t);
    const host = sc || t.parentElement;
    const hostW = host ? host.clientWidth : vw;
    const cols = (() => {
      const hr = t.querySelector('tr');
      return hr ? hr.children.length : 0;
    })();
    const bodyRows = t.querySelectorAll('tbody tr').length;
    tables.push({
      w: Math.round(t.scrollWidth), hostW: Math.round(hostW),
      scrollable: !!sc, cols, rows: bodyRows,
      clipped: !sc && t.scrollWidth > hostW + 1,
    });
  }

  // Touch targets (reported, not part of "usable").
  let small = 0, smallest = null;
  for (const el of document.querySelectorAll('a,button,input,select,textarea,[role="button"]')) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    const m = Math.min(r.width, r.height);
    if (m < 44) small++;
    if (smallest === null || m < smallest) smallest = Math.round(m);
  }

  // ── RESPONSIVE TWINS ────────────────────────────────────────────────────
  // docs/manual-walk-list.md 19.2 and 20.4 both record the SAME blocked
  // assertion: /hr/org and /tools/calendar each ship BOTH a narrow rendering
  // and a wide one into the DOM and pick between them with CSS, so no
  // HTML-text assertion can tell which one a phone shows -- "to see it you
  // need a browser that changes the viewport, and this repo has none".
  // This probe IS that browser: it reads computed style, so it can say which
  // twin is actually painted. Recorded for every page, not just those two.
  const twins = [];
  for (const el of document.querySelectorAll('[class*="md:hidden"],[class*="md:block"],[class*="sm:hidden"],[class*="sm:block"],[class*="lg:hidden"],[class*="lg:block"]')) {
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    twins.push({ cls: (el.getAttribute('class') || '').slice(0, 70),
                 display: cs.display, painted: r.width > 0 && r.height > 0 });
  }

  // ★ Where did we actually END UP. A signed-in request to /login redirects
  //   (LOGIN-1-fu1), and without this the probe files the DESTINATION page's
  //   measurements under /login -- a page that has no table was reported as
  //   having a 7-column one. Any route whose landedOn differs from what was
  //   requested is excluded from the counts rather than quietly folded in.
  const landedOn = location.pathname;

  const denied = !!document.querySelector('[data-access-denied]');
  const bodyText = (document.body ? document.body.innerText : '') || '';
  return {
    vw, innerW: window.innerWidth, viewportMeta, pageScrollW, overflowPx,
    culprits: culprits.slice(0, 4),
    tables, tableCount: tables.length,
    clippedTables: tables.filter(t => t.clipped).length,
    scrollerTables: tables.filter(t => t.scrollable).length,
    maxCols: tables.reduce((a, t) => Math.max(a, t.cols), 0),
    maxRows: tables.reduce((a, t) => Math.max(a, t.rows), 0),
    tablesWithRows: tables.filter(t => t.rows > 0).length,
    smallTargets: small, smallestTarget: smallest,
    denied, twins, landedOn,
    textLen: bodyText.length,
  };
})()`

// ── main ────────────────────────────────────────────────────────────────────
let dev = null, chrome = null, accountId = null
async function cleanup() {
    try { if (chrome) chrome.kill('SIGKILL') } catch {}
    try { if (dev) process.kill(-dev.pid, 'SIGKILL') } catch {}
    if (accountId) {
        try {
            await rest(`/rest/v1/user_roles?user_id=eq.${accountId}`, { method: 'DELETE' })
            await rest(`/auth/v1/admin/users/${accountId}`, { method: 'DELETE' })
            console.error('· cleaned up ephemeral survey account')
        } catch (e) { console.error('!! COULD NOT DELETE SURVEY ACCOUNT ' + accountId + ': ' + e.message) }
    }
    try { release('scripts/survey-phone.mjs') } catch {}
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, async () => { await cleanup(); process.exit(130) })

async function main() {
    acquireOrExit('scripts/survey-phone.mjs')
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    mkdirSync(OUT_DIR, { recursive: true })

    // stale port (only orphans — never blind-kill; same rule as the smoke)
    try {
        const pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' }).trim().split('\n').filter(Boolean)
        for (const pid of pids) {
            const ppid = execSync(`ps -o ppid= -p ${pid} || echo 0`, { encoding: 'utf8' }).trim()
            if (ppid === '1') { execSync(`kill -9 ${pid}`); console.error(`· killed orphan on :${PORT} (pid ${pid})`) }
            else { throw new Error(`port ${PORT} held by a LIVE process (pid ${pid}, ppid ${ppid}) — not killing it; another run is in progress`) }
        }
    } catch (e) { if (/held by a LIVE/.test(e.message)) throw e }

    // ephemeral admin — NOT the smoke's `smoke-` prefix, so the smoke's
    // sweepScratch (which deletes every smoke-*@test.local without looking at
    // age or ownership) cannot delete this run's session out from under it.
    const email = `survey-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'survey-pass-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('could not create survey account: ' + JSON.stringify(cu).slice(0, 300))
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify({ user_id: accountId, role_id: roles[0].id }) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'survey-pass-1' }) })).json()
    if (!sess?.access_token) throw new Error('survey sign-in failed: ' + JSON.stringify(sess).slice(0, 200))
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
    console.error('· ephemeral admin session ready')

    // resolve dynamic segments
    const ID_SOURCES = loadIdSources()
    const resolved = [], unresolved = []
    const idCache = new Map()
    for (const route of allRoutes) {
        if (!route.includes('[')) { resolved.push({ route, url: route, dynamic: false }); continue }
        let url = route, ok = true
        for (const seg of route.match(/\[[^\]]+\]/g)) {
            const map = ID_SOURCES[seg]
            if (!map) { ok = false; break }
            let table = map['']
            if (!table) {
                let best = ''
                for (const pre of Object.keys(map)) if (route.startsWith(pre) && pre.length > best.length) best = pre
                table = best ? map[best] : null
            }
            if (!table) { ok = false; break }
            if (!idCache.has(table)) idCache.set(table, await firstId(table))
            const id = idCache.get(table)
            if (!id) { ok = false; break }
            url = url.replace(seg, id)
        }
        ok ? resolved.push({ route, url, dynamic: true }) : unresolved.push(route)
    }
    console.error(`· routes: ${resolved.length} measurable (${resolved.filter(r=>r.dynamic).length} dynamic) · ${unresolved.length} unresolvable (no live row / no id source)`)

    // dev server
    console.error('· starting next dev on :' + PORT)
    dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    await new Promise((res, rej) => {
        const to = setTimeout(() => rej(new Error('dev server did not become ready in 180s')), 180000)
        const on = (b) => { if (/Ready in|started server|Local:/i.test(b.toString())) { clearTimeout(to); res() } }
        dev.stdout.on('data', on); dev.stderr.on('data', on)
    })
    await sleep(2000)

    // chrome
    console.error('· launching chrome-headless-shell')
    chrome = spawn(CHROME, [
        `--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--hide-scrollbars', '--window-size=390,844',
        `--user-data-dir=${join(OUT_DIR, 'chrome-profile')}`, 'about:blank',
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    let wsUrl = null
    for (let i = 0; i < 60 && !wsUrl; i++) {
        await sleep(500)
        try { wsUrl = (await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()).webSocketDebuggerUrl } catch {}
    }
    if (!wsUrl) throw new Error('chrome never opened its debugging port')
    const ws = new WebSocket(wsUrl)
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP ws failed')) })
    const cdp = new Cdp(ws)

    // The tab is re-creatable on purpose. A long sweep wedges the renderer
    // eventually — one run died at route ~170 and every route after it timed
    // out at 60s, which reads in the log exactly like "these pages are slow".
    // A probe whose failure mode impersonates a finding is worse than useless,
    // so a wedged tab is detected, thrown away and replaced.
    let sessionId = null
    const S = (m, p) => cdp.send(m, p, sessionId)
    async function newTab() {
        if (sessionId) { try { await cdp.send('Target.closeTarget', { targetId: currentTarget }) } catch {} }
        const t = await cdp.send('Target.createTarget', { url: 'about:blank' })
        currentTarget = t.targetId
        const a = await cdp.send('Target.attachToTarget', { targetId: currentTarget, flatten: true })
        sessionId = a.sessionId
        await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
        await S('Emulation.setDeviceMetricsOverride', {
            width: 390, height: 844, deviceScaleFactor: 3, mobile: true,
            screenWidth: 390, screenHeight: 844,
        })
        await S('Network.setCookies', { cookies: [{
            name: cookieName, value: cookieValue, domain: 'localhost', path: '/', httpOnly: false, secure: false }] })
    }
    let currentTarget = null
    await newTab()

    // warm the compiler once — the first dev-server hit on a route compiles it
    await S('Page.navigate', { url: `http://localhost:${PORT}/` }); await sleep(8000)

    // ── FAULT INJECTION ─────────────────────────────────────────────────────
    // A probe that has never been shown a failure is a probe that reports
    // "all green" for free. Before measuring anything, prove it can SEE both
    // failure modes — by injecting them into a live page and reading them back.
    // Injection is done in the browser only; no repo file is touched.
    {
        const evalIn = async (expr) =>
            (await S('Runtime.evaluate', { expression: expr, returnByValue: true })).result.value
        const clean = `document.querySelectorAll('[data-survey-inject]').forEach(e => e.remove())`

        const base = await evalIn(MEASURE)
        if (base.overflowPx > 1) throw new Error('self-test void: / already overflows, cannot prove detection')
        // The whole 390px measurement is meaningless without a viewport meta:
        // without it a phone lays the page out at ~980px and zooms out, so
        // nothing ever "overflows" and every page reads as usable.
        if (!base.viewportMeta || !/width=device-width/.test(base.viewportMeta))
            throw new Error('self-test FAILED: no width=device-width viewport meta — a 390px measurement would be meaningless. got: ' + base.viewportMeta)
        if (base.vw !== 390) throw new Error('self-test FAILED: layout viewport is ' + base.vw + ', expected 390')

        // ① page-level overflow
        await evalIn(`(() => { const d = document.createElement('div');
            d.setAttribute('data-survey-inject','1'); d.className = 'survey-probe-wide';
            d.style.cssText = 'width:900px;height:8px'; document.body.appendChild(d); })()`)
        const f1 = await evalIn(MEASURE)
        if (!(f1.overflowPx > 400)) {
            const diag = await evalIn(`(() => { const d = document.querySelector('[data-survey-inject]');
              const r = d.getBoundingClientRect(); const de = document.documentElement; const b = document.body;
              const chain = []; for (let p = d.parentElement; p; p = p.parentElement)
                chain.push(p.tagName + '.' + (p.getAttribute('class')||'').slice(0,50) + ' ovx=' + getComputedStyle(p).overflowX + ' w=' + Math.round(p.clientWidth) + ' sw=' + p.scrollWidth);
              return { injRect: [Math.round(r.left), Math.round(r.right), Math.round(r.width)],
                deSW: de.scrollWidth, deCW: de.clientWidth, bodySW: b.scrollWidth, bodyCW: b.clientWidth,
                innerW: innerWidth, docElOvx: getComputedStyle(de).overflowX, bodyOvx: getComputedStyle(b).overflowX,
                chain }; })()`)
            await evalIn(clean)
            throw new Error('self-test FAILED: injected a 900px div, probe read overflow=' + f1.overflowPx + '\n  diag: ' + JSON.stringify(diag, null, 2))
        }
        await evalIn(clean)
        if (!f1.culprits?.some((c) => c.cls.includes('survey-probe-wide')))
            throw new Error('self-test FAILED: overflow seen but the culprit walk did not name the injected element')

        // ② table clipped by a NON-scrolling ancestor
        await evalIn(`(() => { const h = document.createElement('div');
            h.setAttribute('data-survey-inject','1');
            h.style.cssText = 'width:200px;overflow-x:hidden';
            h.innerHTML = '<table><tbody><tr>' + Array.from({length:12},
                (_,i)=>'<td style="min-width:80px">c'+i+'</td>').join('') + '</tr></tbody></table>';
            document.body.appendChild(h); })()`)
        const f2 = await evalIn(MEASURE)
        await evalIn(clean)
        if (f2.clippedTables < 1) throw new Error(`self-test FAILED: injected a table clipped by a non-scrolling box, probe read clippedTables=${f2.clippedTables}`)

        // ③ and the same table inside a SCROLLING ancestor must NOT count as clipped
        await evalIn(`(() => { const h = document.createElement('div');
            h.setAttribute('data-survey-inject','1');
            h.style.cssText = 'width:200px;overflow-x:auto';
            h.innerHTML = '<table><tbody><tr>' + Array.from({length:12},
                (_,i)=>'<td style="min-width:80px">c'+i+'</td>').join('') + '</tr></tbody></table>';
            document.body.appendChild(h); })()`)
        const f3 = await evalIn(MEASURE)
        await evalIn(clean)
        if (f3.clippedTables !== 0) throw new Error(`self-test FAILED: a table inside overflow-x:auto was miscounted as clipped (${f3.clippedTables})`)

        const after = await evalIn(MEASURE)
        if (after.overflowPx > 1 || after.clippedTables > 0) throw new Error('self-test FAILED: injections did not clean up')
        console.error(`· self-test PASSED — overflow injection read +${f1.overflowPx}px and named its culprit; clipped-table injection read ${f2.clippedTables}; scrolling ancestor correctly read 0`)
        if (process.argv.includes('--selftest')) { console.log('SELFTEST_OK'); return }
    }

    const limit = Number((process.argv.find((a) => a.startsWith('--limit=')) || '').split('=')[1] || 0)
    const only = (process.argv.find((a) => a.startsWith('--only=')) || '').split('=')[1]
    // --routes=/a,/b — re-measure an explicit set. A full 187-route sweep wedges
    // the dev server somewhere past ~170 routes (reproduced twice: every route
    // after that point times out, on a fresh tab too). Until that is diagnosed,
    // the tail is re-measured on a fresh server and merged. Recorded here
    // rather than in a comment elsewhere because the NEXT person to run a full
    // sweep will see the same thing and needs to know it is the harness.
    const routesArg = (process.argv.find((a) => a.startsWith('--routes=')) || '').split('=')[1]
    let targets = resolved
    if (only) targets = targets.filter((t) => t.route.startsWith(only))
    if (routesArg) {
        const want = new Set(routesArg.split(','))
        targets = targets.filter((t) => want.has(t.route))
        const missing = [...want].filter((w) => !targets.some((t) => t.route === w))
        if (missing.length) throw new Error('--routes named routes that are not measurable: ' + missing.join(', '))
    }
    if (limit) targets = targets.slice(0, limit)

    const results = []
    const t0 = Date.now()
    for (let i = 0; i < targets.length; i++) {
        const tgt = targets[i]
        let rec = { ...tgt }
        try {
            await S('Page.navigate', { url: `http://localhost:${PORT}${tgt.url}` })
            // dev-server compiles on first hit; poll for the document to settle
            let ready = false
            for (let k = 0; k < 60 && !ready; k++) {
                await sleep(500)
                const r = await S('Runtime.evaluate', { expression: 'document.readyState === "complete" && !!document.body && document.body.innerText.length > 0', returnByValue: true })
                ready = r.result?.value === true
            }
            await sleep(400)
            const r = await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true, awaitPromise: false })
            if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 200))
            rec = { ...rec, ...r.result.value, ready }
        } catch (e) {
            // One retry on a FRESH tab. If it fails twice it is the page, not
            // the probe — and the record says which, so the two can never be
            // confused in the counts.
            try {
                await newTab()
                await S('Page.navigate', { url: `http://localhost:${PORT}${tgt.url}` })
                let ready2 = false
                for (let k = 0; k < 80 && !ready2; k++) {
                    await sleep(500)
                    const r0 = await S('Runtime.evaluate', { expression: 'document.readyState === "complete" && !!document.body && document.body.innerText.length > 0', returnByValue: true })
                    ready2 = r0.result?.value === true
                }
                await sleep(400)
                const r2 = await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true })
                if (r2.exceptionDetails) throw new Error('eval threw on retry')
                rec = { ...rec, ...r2.result.value, retried: true }
            } catch (e2) {
                rec.error = e.message.slice(0, 160)
                rec.retryError = e2.message.slice(0, 160)
            }
        }
        results.push(rec)
        const el = ((Date.now() - t0) / 1000).toFixed(0)
        console.error(`  [${String(i + 1).padStart(3)}/${targets.length}] ${el}s  ovf=${rec.overflowPx ?? '?'} clip=${rec.clippedTables ?? '?'} ${rec.route}`)
    }

    const outFile = join(OUT_DIR, 'phone-390.json')
    writeFileSync(outFile, JSON.stringify({ measuredAt: new Date().toISOString(), viewport: '390x844', unresolved, results }, null, 2))

    // ── summary ─────────────────────────────────────────────────────────────
    const redirected = results.filter((r) => !r.error && r.landedOn && r.landedOn !== r.url)
    const ok = results.filter((r) => !r.error && !(r.landedOn && r.landedOn !== r.url))
    const u1 = ok.filter((r) => r.overflowPx <= 1)
    const u2 = ok.filter((r) => r.clippedTables === 0)
    const usable = ok.filter((r) => r.overflowPx <= 1 && r.clippedTables === 0)
    console.log('\n════ 390px SURVEY ════')
    console.log('measured:', ok.length, ' errored:', results.filter((r) => r.error).length,
                ' redirected (excluded):', redirected.length, ' unresolvable routes:', unresolved.length)
    for (const r of redirected) console.log('   redirected: ' + r.url + ' -> ' + r.landedOn)
    console.log('U1 pan-free (no page overflow):      ', u1.length, '/', ok.length)
    console.log('U2 no clipped ledger:                ', u2.length, '/', ok.length)
    console.log('USABLE (U1 AND U2):                  ', usable.length, '/', ok.length)
    console.log('\npages FAILING U1 (page overflows):', ok.length - u1.length)
    for (const r of ok.filter((x) => x.overflowPx > 1).sort((a, b) => b.overflowPx - a.overflowPx))
        console.log(`   +${String(r.overflowPx).padStart(5)}px  ${r.route}   culprit: ${r.culprits?.[0] ? r.culprits[0].tag + '.' + r.culprits[0].cls.slice(0, 60) : '?'}`)
    console.log('\npages FAILING U2 (table clipped by a non-scrolling ancestor):', ok.length - u2.length)
    for (const r of ok.filter((x) => x.clippedTables > 0))
        console.log(`   ${r.clippedTables} table(s)  maxCols=${r.maxCols}  ${r.route}`)
    console.log('\ntouch targets < 44px (reported, not part of "usable"):')
    const withSmall = ok.filter((r) => r.smallTargets > 0)
    console.log('   pages with >=1:', withSmall.length, '/', ok.length,
                ' median per page:', withSmall.length ? withSmall.map(r=>r.smallTargets).sort((a,b)=>a-b)[Math.floor(withSmall.length/2)] : 0)
    console.log('\nwrote', outFile)
}

main().then(cleanup).catch(async (e) => { console.error('\n!! survey-phone failed:', e.message); await cleanup(); process.exitCode = 1 })
