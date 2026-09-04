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
// ★★ CONV-10:此前【只读了这张表里的一张】,而 id 的正确取法是【五件事】★★
//
//   探针写的是 `?select=id&limit=1`。冒烟写的是同一句【再加三件】:
//     · SOFT_DELETED  → &deleted_at=is.null
//     · ID_FILTERS    → 例如 tasks 必须 task_type=eq.team、forwarders 必须
//                        counterparty_type=eq.forwarder
//     · ORDER         → 没有 order by 的 limit 1 是一个会漂的判据
//   而 customers / employees / tasks / containers 【全都在 SOFT_DELETED 里】。
//   于是探针把一行【已软删的】记录递给页面,页面自己的查询把它滤掉,notFound(),
//   textLen=76 —— CONV-9 §⑫-5b 量到的那 9 条,一条不多一条不少。
//
//   **那不是"探针和页面各取了一个不同的 id"这么中性的一件事:
//     是探针取的 id【页面按定义不可能接受】。**
//   所以修法不是加一条启发式,是把那四张表【一起】读过来 —— 与原来读 ID_SOURCES
//   逐字同一条判据(一份定义,住在冒烟里,漂了就当场炸)。
function fromSmoke(name, kind) {
    const src = readFileSync(join(ROOT, 'scripts/smoke-routes.mjs'), 'utf8')
    const decl = 'const ' + name + ' = '
    const start = src.indexOf(decl)
    if (start < 0) throw new Error(name + ' not found in smoke-routes.mjs — shape changed')
    let i = start + decl.length
    if (kind === 'scalar') {
        const end = src.indexOf('\n', i)
        return (0, eval)('(' + src.slice(i, end).trim().replace(/,$/, '') + ')')
    }
    const OPEN = { '{': '}', '[': ']', '(': ')' }
    const stack = []
    let begin = -1
    for (; i < src.length; i++) {
        const c = src[i]
        if (OPEN[c]) { if (begin < 0) begin = i; stack.push(OPEN[c]) }
        else if (stack.length && c === stack[stack.length - 1]) {
            stack.pop()
            if (!stack.length) {
                const body = src.slice(begin, i + 1)
                    .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n')
                const expr = name === 'SOFT_DELETED' || name === 'SPECIAL_ID_ROUTES'
                    ? 'new Set(' + body + ')' : body
                return (0, eval)('(' + expr + ')')
            }
        }
    }
    throw new Error(name + ' brackets unbalanced in smoke-routes.mjs')
}
const loadIdSources = () => fromSmoke('ID_SOURCES')

async function rest(path, opts = {}) {
    return fetch(URL_ + path, {
        ...opts,
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`,
                   'Content-Type': 'application/json', ...(opts.headers || {}) },
    })
}
// 与 smoke-routes.mjs 的 firstId() 同形:软删过滤 + 按路由/按表的过滤 + 排序。
// 【为什么 route 也要参与】'/logistics/forwarders' 与 '/suppliers' 是【同一张表】
// (suppliers),而前者只认 counterparty_type=forwarder 的那些行 —— 只按表取,
// 两条路由里必有一条拿到对方的行,然后 404。
async function firstId(table, route, F) {
    const del = F.SOFT_DELETED.has(table) ? '&deleted_at=is.null' : ''
    const filter = F.ID_FILTERS[route] ?? F.ID_FILTERS[table] ?? ''
    const order = F.ORDER_OVERRIDES[table] ?? F.ORDER_DEFAULT
    const r = await rest(`/rest/v1/${table}?select=id&limit=1${del}${filter}${order}`)
    if (!r.ok) return null
    const rows = await r.json()
    return Array.isArray(rows) && rows[0] ? rows[0].id : null
}

// 父子配套 / 段里不是 uuid 的那几条 —— 冒烟在主循环里单独处理,而探针此前
// 【根本没有这段】,所以这几条一律落进 unresolved 或落进一个 404。
async function specialUrl(route) {
    const one = async (q) => { const r = await rest(q); if (!r.ok) return null
                               const j = await r.json(); return Array.isArray(j) ? j[0] : null }
    if (route === '/inbound/[id]/assays/[assayId]') {
        const x = await one('/rest/v1/assay_results?select=id,inbound_batch_id&deleted_at=is.null&inbound_batch_id=not.is.null&limit=1')
        return x ? route.replace('[id]', x.inbound_batch_id).replace('[assayId]', x.id) : null
    }
    if (route === '/output/[id]/assays/[assayId]') {
        const x = await one('/rest/v1/assay_results?select=id,output_batch_id&deleted_at=is.null&output_batch_id=not.is.null&limit=1')
        return x ? route.replace('[id]', x.output_batch_id).replace('[assayId]', x.id) : null
    }
    if (route === '/finance/ledger/[account]') {
        const x = await one('/rest/v1/journal_lines?select=accounts(code)&limit=1')
        const code = x?.accounts?.code
        return code ? `${route.replace('[account]', encodeURIComponent(code))}?mode=bs` : null
    }
    if (route === '/settings/import/template/[table]') return route.replace('[table]', 'materials')
    return undefined      // undefined = 不是特例;null = 是特例但没有数据
}

// ── CDP ─────────────────────────────────────────────────────────────────────
class Cdp {
    // ★ CONV-10:这个客户端此前【只收命令的回执,把事件整个丢掉】——
    //   于是 `Network.enable` 开着,却没有任何一行代码收得到 responseReceived。
    //   探针把一张 404 记成「可用」的直接机制就在这里:它【没有别的办法】看见
    //   HTTP 状态,只好去猜 textLen。加一条事件分发,那个猜测就不必存在了。
    constructor(ws) { this.ws = ws; this.id = 0; this.waiting = new Map(); this.sessions = new Map()
        this.listeners = []
        ws.onmessage = (e) => {
            const m = JSON.parse(e.data)
            if (m.id && this.waiting.has(m.id)) {
                const { res, rej } = this.waiting.get(m.id); this.waiting.delete(m.id)
                m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result)
            } else if (m.method) {
                for (const fn of this.listeners) { try { fn(m.method, m.params) } catch {} }
            }
        }
    }
    on(fn) { this.listeners.push(fn) }
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
    // 四张同源的表,与 ID_SOURCES 一起从冒烟里读出来(见 fromSmoke 上面那段)
    const F = {
        SOFT_DELETED:    fromSmoke('SOFT_DELETED'),
        ID_FILTERS:      fromSmoke('ID_FILTERS'),
        ORDER_OVERRIDES: fromSmoke('ORDER_OVERRIDES'),
        ORDER_DEFAULT:   fromSmoke('ORDER_DEFAULT', 'scalar'),
    }
    if (!F.SOFT_DELETED.size || !F.ORDER_DEFAULT)
        throw new Error('id filters read back empty from smoke-routes.mjs — a broken reader, not an empty set')
    console.error(`· id filters from smoke: ${F.SOFT_DELETED.size} soft-deleted tables · `
        + `${Object.keys(F.ID_FILTERS).length} row filters · ${Object.keys(F.ORDER_OVERRIDES).length} order overrides`)
    const resolved = [], unresolved = []
    const idCache = new Map()
    for (const route of allRoutes) {
        if (!route.includes('[')) { resolved.push({ route, url: route, dynamic: false }); continue }
        const special = await specialUrl(route)
        if (special !== undefined) {
            special ? resolved.push({ route, url: special, dynamic: true }) : unresolved.push(route)
            continue
        }
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
            // ★ 缓存键必须带上过滤器,否则 /suppliers/[id] 会把它那一行
            //   喂给 /logistics/forwarders/[id](同一张 suppliers 表,不同的行)
            const key = table + '|' + (F.ID_FILTERS[route] ?? F.ID_FILTERS[table] ?? '')
            if (!idCache.has(key)) idCache.set(key, await firstId(table, route, F))
            const id = idCache.get(key)
            if (!id) { ok = false; break }
            url = url.replace(seg, id)
        }
        ok ? resolved.push({ route, url, dynamic: true }) : unresolved.push(route)
    }
    console.error(`· routes: ${resolved.length} measurable (${resolved.filter(r=>r.dynamic).length} dynamic) · ${unresolved.length} unresolvable (no live row / no id source)`)

    // --ids-only:把【取 id】那一半单独跑出来,不起 dev server、不开浏览器。
    // 它存在是因为 id 那一半正是 CONV-9 §⑫-5b 那个盲区的病根,而一个要等
    // 三分钟编译才能验一次的判据,没有人会去验第二次。
    if (process.argv.includes('--ids-only')) {
        for (const r of resolved.filter((x) => x.dynamic)) console.log(`  RESOLVED  ${r.route}\n            ${r.url}`)
        for (const r of unresolved) console.log(`  UNRESOLVED ${r}`)
        console.log(`\nids: ${resolved.filter((x) => x.dynamic).length} resolved · ${unresolved.length} unresolved`)
        release(); process.exit(0)
    }

    // ════════════════════════════════════════════════════════════════════
    // ★★【第四层盲区,而它比前三层都便宜、也都致命:一次 `npm run build`
    //     会让【每一条动态路由】404,而旧口径把它们【全部】记成 USABLE】★★
    //
    //   CONV-10 实测,同一棵树、同一批 id、相隔十分钟:
    //       .next 里有生产构建  → 16 / 16 条路由 HTTP 404(页面照常画出 404 页,
    //                             ovf=0 clip=0,旧口径记 16/16 USABLE)
    //       rm -rf .next 之后   → 0 条 404,20 / 20 真的量到
    //
    //   **为什么它特别毒:** 「先跑 build 确认绿,再跑探针量手机」是任何人都会
    //   采用的顺序 —— 而那个顺序【恰好】制造出一份全绿的假数据。
    //   CONV-9 §⑫-5b 量到的 9 条 textLen=76 是 id 取错(§⑬-1 修了);
    //   这一条是【另一个】机制,同一个症状,而它一次能毁掉整跑。
    //
    //   判据是结构性的、且不会漂:`next build` 写 `.next/BUILD_ID`,
    //   `next dev` 【不写】(它只写 `.next/dev/`)。实测两遍。
    //
    //   处置:**当场炸,并给出那一行命令**。不自动删 —— 与本仓库一贯的
    //   「响,而不是替人做决定」同条;而且一个自动删掉别人构建产物的探针,
    //   下一次会在别的地方被人诅咒。
    // ════════════════════════════════════════════════════════════════════
    if (existsSync(join(ROOT, '.next/BUILD_ID'))) {
        throw new Error(
            '.next/BUILD_ID exists — there is a PRODUCTION build in .next, and `next dev` on top of '
            + 'it makes EVERY dynamic route return HTTP 404. Measured on one tree ten minutes apart: '
            + '16/16 routes 404 with it, 0/20 without — and the old scoring called all of those "usable". '
            + 'Fix: rm -rf .next (it is a regenerable cache), then re-run. '
            + 'If you just ran `npm run build`, that is exactly how you got here.')
    }

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
    // ★★ CONV-10:这里是那条【结构性】的锚 —— 导航那一次的 HTTP 状态。★★
    //   CONV-9 §⑫-5b 用的是 textLen===76 这个启发式,而它是 Next 的 not-found 页
    //   【今天】的字节数,明天改一个字就漂了。状态码不漂。
    let lastDoc = null
    cdp.on((method, params) => {
        if (method === 'Network.responseReceived' && params?.type === 'Document')
            lastDoc = { url: params.response.url, status: params.response.status }
    })
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
        lastDoc = null
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
            rec = { ...rec, ...r.result.value, ready, httpStatus: lastDoc?.status ?? null }
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
                rec = { ...rec, ...r2.result.value, retried: true, httpStatus: lastDoc?.status ?? null }
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
    // ★★ 一张 404 【不是】一张窄页。★★
    //   它既不溢出、也没有一张表可以被裁 —— 于是旧口径把它记成 USABLE,
    //   而那是这份数里最坏的一种谎:它把「没量到」说成「量到了,很好」。
    //   处置与 redirected 逐字同一条:【单独一桶,并且退出分母】。
    //   不记成 FAILED,是因为一张 404 对这一页的手机表现【两个方向都不是证据】。
    const notFound = results.filter((r) => !r.error && r.httpStatus !== null && r.httpStatus >= 400)
    const nfSet = new Set(notFound)
    const ok = results.filter((r) => !r.error && !(r.landedOn && r.landedOn !== r.url) && !nfSet.has(r))
    // 状态码一条都没收到 = 事件监听坏了,不是"全都是 200"。全 0 要当成脚本坏了。
    const withStatus = results.filter((r) => !r.error && r.httpStatus !== null).length
    if (results.filter((r) => !r.error).length && !withStatus)
        throw new Error('probe self-test FAILED: 0 navigations reported an HTTP status — '
            + 'the Network.responseReceived listener is dead, so a 404 would score as usable again')
    const u1 = ok.filter((r) => r.overflowPx <= 1)
    const u2 = ok.filter((r) => r.clippedTables === 0)
    const usable = ok.filter((r) => r.overflowPx <= 1 && r.clippedTables === 0)
    console.log('\n════ 390px SURVEY ════')
    console.log('measured:', ok.length, ' errored:', results.filter((r) => r.error).length,
                ' redirected (excluded):', redirected.length, ' not-found (excluded):', notFound.length,
                ' unresolvable routes:', unresolved.length)
    for (const r of redirected) console.log('   redirected: ' + r.url + ' -> ' + r.landedOn)
    for (const r of notFound) console.log(`   NOT FOUND (HTTP ${r.httpStatus}): ${r.route}  ← ${r.url}`)
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

    // ★★ 一条 404 是【探针的缺陷】,不是这一页的一个属性 —— 所以它让整跑变红。★★
    //   与 `unresolved` 有意区别对待:unresolved 是【诚实的没有数据】(那一张表
    //   今天零行),而 404 是【取到了一行、而这一页按定义不收它】—— 也就是取 id
    //   那一半与页面自己的查询漂开了。CONV-9 §⑫-5b 量到 9 条这样的路由,
    //   它们被静静记成「可用」了整整一刀。一个只在桶里躺着、不叫的桶,
    //   下一刀照样没有人看 —— unresolved 那 4 条就是这么过去的。
    if (notFound.length) {
        console.error(`\n!! survey-phone FAILED: ${notFound.length} route(s) returned HTTP >= 400.`)
        console.error('   The probe fed the page an id the page itself rejects — the id source has')
        console.error('   drifted from smoke-routes.mjs. These routes were measured as NOTHING:')
        for (const r of notFound) console.error(`     ${r.httpStatus}  ${r.route}  ← ${r.url}`)
        process.exitCode = 1
    }
}

main().then(cleanup).catch(async (e) => { console.error('\n!! survey-phone failed:', e.message); await cleanup(); process.exitCode = 1 })
