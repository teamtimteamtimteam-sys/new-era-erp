#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// STYLE-1(2026-09-09)· 把 variant C 从【一页会被删掉的代码】量成【一份数值】
// ════════════════════════════════════════════════════════════════════════════
// 【它为什么存在】STYLE-0 交回的那 12 个输入框高度是【由 class 串推算的】,
// 它自己在抬头写明了这一点。本支把那一半换掉:chrome-headless-shell + CDP,
// 读 getComputedStyle 的**解析值**,不是 class 串,也不是截图。
//
// 【它不是一道闸】它不在 npm run build 里,也不该进去。普查报的是【数】,
// 不是【违规】——接进构建会把基线漂移变成构建红,而那种红最后一定被按掉。
// 退出码沿用本仓库的三档:0 干净 / 1 找到了违规 / 2 **量具自己坏了**。
// 本支只会用 0 与 2:它不判违规,它只报数,或者说自己没量准。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :chrome-headless-shell 通过 CDP 读**真实渲染后**的 DOM 上,
//                   每一个元素的 getComputedStyle **解析值**(高度、内边距、
//                   边框、圆角、字号、字重、行高、颜色、投影、字族)。
//   我声称管的是   :`--mode=spec` 时 —— **variant C 那一栏在屏幕上到底长什么样**,
//                   并声称那份读数就是这套系统的样式标准;
//                   `--mode=drift` 时 —— 真实页面上同类元素**实际渲染成了几种值**,
//                   以及每一种离 spec 有多远。
//
//   两者不同之处   :★★ 这一段是本支最重要的几行,请读完再看数 ★★
//
//     ① **我读的是取样页,而我声称它定义整个系统。** 那是一次【推论】,
//        不是一次测量。它的授权在两处:`docs/login-page.md:3`(LOGIN-1 把
//        variant C 当作整套视觉语言用),以及 Tim 在 STYLE-1 里的原话
//        ——「pick one of A, B, C, and then make EVERY front-end element in
//        the system match the one I picked」。
//        ☞ **它可能错在哪里:取样页里【没有】的元素类型,这份读数一个字都没说。**
//          文件上传、日期框、数字框、原生 <select>、分页控件、对话框、
//          面包屑、顶栏、Tab —— 取样页一个都不含。
//          **对那些元素,本支的正确答案是「没有标准」,不是一个我挑的数。**
//          §UNCOVERED 会把它们逐条列出来,而不是替它们编一个值。
//
//     ② **我量的是首屏。** 菜单、对话框、展开行、Tab 面板从不打开。
//        一个打开面板之后才不一致的地方,在我这里读成一致。
//
//     ③ **我走硬导航,人走软导航。** 与 scripts/survey-phone.mjs 抬头同一条:
//        根布局在客户端换页时不重画,于是脚本拿到的树与人点着链接看到的可能不同。
//
//     ④ **`--mode=drift` 只走【静态路由】。** 带 [id] 的详情/编辑页需要一个
//        页面自己肯收的行 id,那套取法住在 smoke-routes.mjs 里。本支不碰它 ——
//        于是**详情页与编辑页上的控件是【未测量】,不是【不存在】**。
//        §UNREACHED 逐条报出来。
// ════════════════════════════════════════════════════════════════════════════
//
// Usage:
//   node scripts/survey-variant-c.mjs --mode=spec  [--blind=NAME]
//   node scripts/survey-variant-c.mjs --mode=drift [--limit=N] [--only=/prefix]
//
// Blindings (--blind=): noop | pick-a | no-variant | no-buttons | desktop-only | round-height
//   `noop` 是【登记在案的废致盲】:它什么都不拿走,于是它证明不了任何事 ——
//   留着它,是为了让比对器当场判它「不作数」,好证明比对器自己不瞎。

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, mkdirSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join } from 'node:path'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'survey-variant-c'
const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3197              // 3198 是 survey-phone 的,3199 是冒烟的
const CDP_PORT = 9334
const OUT_DIR = process.env.SURVEY_OUT || join(ROOT, '.survey-out')
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')

const arg = (k) => { const a = process.argv.find((x) => x.startsWith(k + '=')); return a ? a.slice(k.length + 1) : null }
const MODE = arg('--mode') || 'spec'
const BLIND = arg('--blind') || ''
const LIMIT = Number(arg('--limit') || 0)
const ONLY = arg('--only') || ''

const KNOWN_BLINDS = ['', 'noop', 'pick-a', 'no-variant', 'no-buttons', 'desktop-only', 'round-height']
if (!KNOWN_BLINDS.includes(BLIND)) { console.error('unknown --blind=' + BLIND); process.exit(2) }

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let dev = null, chrome = null, accountId = null

async function rest(path, opts = {}) {
    return fetch(URL_ + path, {
        ...opts,
        headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json', ...(opts.headers || {}) },
    })
}

// ── 静态路由(drift 用)──────────────────────────────────────────────────────
// 【为什么只要静态的】见 AIM ④。带 [ ] 的段需要一个页面自己肯收的 id,
// 那套取法住在冒烟里;本支不复制它(复制=第二份会漂的定义)。
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
const staticRoutes = allRoutes.filter((r) => !r.includes('['))
const dynamicRoutes = allRoutes.filter((r) => r.includes('['))

// ════════════════════════════════════════════════════════════════════════════
// 页面里跑的那一段 —— 【原样写在这里,好让读数的人看见它到底读了什么】
// ════════════════════════════════════════════════════════════════════════════
const STYLE_KEYS = [
    'height', 'minHeight', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
    'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
    'borderTopColor', 'borderRightColor', 'borderBottomColor', 'borderLeftColor',
    'borderTopLeftRadius', 'fontSize', 'fontWeight', 'lineHeight', 'color',
    'backgroundColor', 'boxShadow', 'fontFamily', 'fontStyle', 'textAlign',
]

// 角色表 —— 靠 data-slot,不靠 class 串。库组件全都带 data-slot(实测 41 种)。
// 原生控件单列:它们【正是】Tim 第一条抱怨里那种"浏览器自己画的东西"。
const ROLE_SELECTORS = [
    ['input.text', 'input[data-slot="input"]'],
    ['input.native', 'input:not([data-slot]):not([type="checkbox"]):not([type="radio"]):not([type="hidden"]):not([type="submit"]):not([type="file"]):not([type="date"]):not([type="number"])'],
    ['input.date', 'input[type="date"]'],
    ['input.number', 'input[type="number"]'],
    ['input.file', 'input[type="file"]'],
    ['select.trigger', '[data-slot="select-trigger"]'],
    ['select.native', 'select'],
    ['textarea', 'textarea'],
    ['label', 'label'],
    ['card', '[data-slot="card"]'],
    ['card.header', '[data-slot="card-header"]'],
    ['card.title', '[data-slot="card-title"]'],
    ['card.description', '[data-slot="card-description"]'],
    ['card.content', '[data-slot="card-content"]'],
    ['table', 'table'],
    ['table.headerRow', 'thead tr'],
    ['table.th', 'th'],
    ['table.td', 'td'],
    ['table.bodyRow', 'tbody tr'],
    ['badge', '[data-slot="badge"]'],
    ['alert', '[data-slot="alert"]'],
    ['alert.title', '[data-slot="alert-title"]'],
    ['alert.description', '[data-slot="alert-description"]'],
    ['refusal', '[data-slot="refusal"]'],
    ['skeleton', '[data-slot="skeleton"]'],
    ['h1', 'h1'], ['h2', 'h2'], ['h3', 'h3'], ['h4', 'h4'],
    ['p', 'p'],
    ['a', 'a'],
]

function buildMeasure({ blind }) {
    return `(() => {
  const SK = ${JSON.stringify(STYLE_KEYS)};
  const ROLES = ${JSON.stringify(ROLE_SELECTORS)};
  const BLIND = ${JSON.stringify(blind)};
  const de = document.documentElement;
  const round = (n) => Math.round(n * 100) / 100;

  function m(el) {
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    const o = {
      tag: el.tagName.toLowerCase(),
      rectH: round(r.height),
      rectW: round(r.width),
      cls: (el.getAttribute('class') || '').slice(0, 400),
      text: (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 48),
    };
    for (const k of SK) o[k] = cs[k];
    // ★ 致盲 round-height:把高度磨成 10 的倍数。【处数一个不变,值变】——
    //   它专门用来试比对器是不是只会比总数。
    if (BLIND === 'round-height') { o.height = (Math.round(parseFloat(o.height) / 10) * 10) + 'px'; o.rectH = Math.round(o.rectH / 10) * 10; }
    return o;
  }

  function collect(scope, prefix) {
    const out = [];
    const claimed = new Set();
    for (const [role, sel] of ROLES) {
      let els = [];
      try { els = [...scope.querySelectorAll(sel)]; } catch (e) { els = []; }
      els.forEach((el, i) => { claimed.add(el); out.push(Object.assign({ role: prefix + role, idx: i }, m(el))); });
    }
    // 按钮单列 —— 要把 variant 与 size 一起带出来,那正是 Tim 裁定的那件事。
    // ★★ 这个筛子是【被自己的断言抓出来改过的】,记在这里 ★★
    //   第一版写的是 \`button, [data-slot="button"]\`,于是 DOM 数出 6 颗而
    //   Variant.tsx 里只有 5 个 <Button> —— 多出来的那一颗是
    //   **Radix 的 SelectTrigger,它渲染的就是一个 <button>**。
    //   把一个下拉框记成一颗按钮,会同时污染两边:按钮那一栏多一个不存在的档,
    //   下拉框那一栏少一个。所以这里排掉【带着别人 data-slot 的 button】。
    if (BLIND !== 'no-buttons') {
      [...scope.querySelectorAll('button, [data-slot="button"]')].filter((el) => {
        const ds = el.getAttribute('data-slot');
        return !ds || ds === 'button';
      }).forEach((el, i) => {
        claimed.add(el);
        const v = el.getAttribute('data-variant');
        const s = el.getAttribute('data-size');
        const role = prefix + 'button.' + (v || 'RAW') + '.' + (s || 'RAW') + (el.disabled ? '.disabled' : '');
        out.push(Object.assign({ role: role, idx: i, btnVariant: v, btnSize: s, isLibrary: !!v }, m(el)));
      });
    }
    // ── 完备性:这一段【不是】按名单走的,它数的是 scope 里的每一个元素 ──────
    //   名单是地板不是天花板 —— 没被任何角色认领的标签,原样报出来。
    const every = [...scope.querySelectorAll('*')];
    const unclaimed = {};
    for (const el of every) if (!claimed.has(el)) {
      const t = el.tagName.toLowerCase();
      unclaimed[t] = (unclaimed[t] || 0) + 1;
    }
    return { rows: out, totalElements: every.length, claimedElements: claimed.size, unclaimed: unclaimed };
  }

  const res = { viewportW: de.clientWidth, url: location.pathname, sections: {}, page: null };

  // ── spec 模式:按 h2 的开头把三个变体分开 ──────────────────────────────────
  const secs = [...document.querySelectorAll('section')];
  const found = {};
  for (const s of secs) {
    const h2 = s.querySelector('h2');
    if (!h2) continue;
    const t = (h2.textContent || '').trim();
    if (t.indexOf('A · ') === 0) found.A = s;
    else if (t.indexOf('B · ') === 0) found.B = s;
    else if (t.indexOf('C · ') === 0) found.C = s;
    else if (t.indexOf('BASE-1') === 0) found.BASE1 = s;
  }
  // ★ 致盲 pick-a:把 A 的那一节【当作 C】交出去。处数完全相同(三个变体渲染
  //   的是同一份内容),只有【值】不同 —— 于是只比总数的比对器会说"没变化"。
  if (BLIND === 'pick-a' && found.A) found.C = found.A;
  // ★ 致盲 no-variant:C 的选择器一个都命不中 → 空总体断言当场响。
  if (BLIND === 'no-variant') delete found.C;

  for (const k of Object.keys(found)) {
    res.sections[k] = collect(found[k], '');
  }
  res.sectionsFound = Object.keys(found);

  // 取样页里【拒绝态那个片】没有 data-slot(它是 sampler 自己画的三种之一),
  // 所以按位置取:标题以「拒绝态」开头的那张卡,表格第一列里的 span。
  for (const k of Object.keys(found)) {
    const cards = [...found[k].querySelectorAll('[data-slot="card"]')];
    const rc = cards.find((c) => {
      const t = c.querySelector('[data-slot="card-title"]');
      return t && (t.textContent || '').trim().indexOf('拒绝态') === 0;
    });
    if (!rc) continue;
    const chips = [...rc.querySelectorAll('tbody tr > td:first-child > span')];
    res.sections[k].rows.push(...chips.map((el, i) => Object.assign({ role: 'refusal.sampler', idx: i }, m(el))));
    res.sections[k].refusalChips = chips.length;
  }

  // 整页(drift 模式与页面级排版都用这一支)
  res.page = collect(document.body, '');
  return res;
})()`
}

// ── 签名:一行读数压成一个可比的字符串 ───────────────────────────────────────
const SIG_KEYS = ['height', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
    'borderTopWidth', 'borderBottomWidth', 'borderTopColor', 'borderBottomColor',
    'borderTopLeftRadius', 'fontSize', 'fontWeight', 'lineHeight', 'color',
    'backgroundColor', 'boxShadow', 'fontStyle']
const sigOf = (r) => SIG_KEYS.map((k) => r[k]).join('|')

// ════════════════════════════════════════════════════════════════════════════
class Cdp {
    constructor(ws) {
        this.ws = ws; this.id = 0; this.waiting = new Map(); this.listeners = []
        ws.onmessage = (e) => {
            const m = JSON.parse(e.data)
            if (m.id && this.waiting.has(m.id)) {
                const { res, rej } = this.waiting.get(m.id); this.waiting.delete(m.id)
                // 【不写成三目表达式】survey-phone.mjs 那一行是 `m.error ? rej(…) : res(…)`,
                // eslint 的 no-unused-expressions 为它记着一条警告。本仓库的 lint 是
                // 【冻结】的(42 errors / 88 warnings,按 file+rule 记),新开一个
                // file+rule 就是把冻结推高一格 —— 而那正是棘轮存在时最不该做的事。
                if (m.error) rej(new Error(JSON.stringify(m.error)))
                else res(m.result)
            } else if (m.method) { for (const fn of this.listeners) { try { fn(m.method, m.params) } catch {} } }
        }
    }
    on(fn) { this.listeners.push(fn) }
    // ★ 超时可以按调用点给 —— 就绪轮询要的是【快速失败】,不是等满 60 秒。
    send(method, params = {}, sessionId, timeoutMs = 60000) {
        const id = ++this.id
        return new Promise((res, rej) => {
            this.waiting.set(id, { res, rej })
            try { this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })) } catch (e) { rej(e); return }
            setTimeout(() => { if (this.waiting.has(id)) { this.waiting.delete(id); rej(new Error('CDP timeout: ' + method)) } }, timeoutMs)
        })
    }
}

function killChildren() {
    try { if (chrome) chrome.kill('SIGKILL') } catch {}
    try { if (dev) process.kill(-dev.pid, 'SIGKILL') } catch {}
}
async function cleanup() { await runPlan(); killChildren() }
installExitHooks({ onFinish: () => { killChildren(); release('scripts/survey-variant-c.mjs') } })
// ★★ 这一行是【本支自己漏掉过一次】的东西,记在这里 ★★
//   installExitHooks 挂的是信号与 uncaught,**挂不到一次直接的 `process.exit()`** ——
//   而 lib/selfproof.mjs 的 die() 正是直接 exit(2)。于是第一次覆盖断言变红时,
//   `next dev` 与 chrome 双双活了下来(ppid=1),下一跑撞在自己的端口守卫上。
//   'exit' 只跑得了同步代码,而 killChildren 正好是同步的;
//   那几次 REST 清理跑不掉不要紧 —— 计划文件在盘上,下一跑的 reapStalePlans 会补删
//   (实测就是这么补上的)。
process.on('exit', () => { try { killChildren() } catch {} })

// ════════════════════════════════════════════════════════════════════════════
async function main() {
    acquireOrExit('scripts/survey-variant-c.mjs', { ownExit: false })
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    openPlan('scripts/survey-variant-c.mjs')
    await reapStalePlans()
    mkdirSync(OUT_DIR, { recursive: true })

    // ★ 与 survey-phone 抬头同一条,逐字沿用:.next 里有生产构建时,
    //   `next dev` 会让每一条动态路由 404。本支只走静态路由,但那个坑
    //   同样会把页面画成 404 页 —— 所以照样当场炸,并给出那一行命令。
    if (existsSync(join(ROOT, '.next/BUILD_ID'))) {
        throw new Error('.next/BUILD_ID exists — a PRODUCTION build is in .next, and `next dev` on top '
            + 'of it serves 404s. Fix: rm -rf .next (it is a regenerable cache), then re-run.')
    }

    // 端口:只收孤儿,绝不盲杀
    try {
        const pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' }).trim().split('\n').filter(Boolean)
        for (const pid of pids) {
            const ppid = execSync(`ps -o ppid= -p ${pid} || echo 0`, { encoding: 'utf8' }).trim()
            if (ppid === '1') { execSync(`kill -9 ${pid}`); console.error(`· killed orphan on :${PORT} (pid ${pid})`) }
            else throw new Error(`port ${PORT} held by a LIVE process (pid ${pid}) — not killing it`)
        }
    } catch (e) { if (/held by a LIVE/.test(e.message)) throw e }

    // ── 用完即删的 admin(取样页仍然在登录后面,见 docs/brand-tokens.md §7)──
    const email = `stylec-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', {
        method: 'POST', body: JSON.stringify({ email, password: 'stylec-pass-1', email_confirm: true }),
    })).json()
    accountId = cu.id
    if (!accountId) throw new Error('could not create probe account: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke style-c grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete style-c account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'stylec-pass-1' }),
    })).json()
    if (!sess?.access_token) throw new Error('probe sign-in failed: ' + JSON.stringify(sess).slice(0, 200))
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
    console.error('· ephemeral admin session ready')

    console.error('· starting next dev on :' + PORT)
    dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    await new Promise((res, rej) => {
        const to = setTimeout(() => rej(new Error('dev server did not become ready in 180s')), 180000)
        const on = (b) => { if (/Ready in|started server|Local:/i.test(b.toString())) { clearTimeout(to); res() } }
        dev.stdout.on('data', on); dev.stderr.on('data', on)
    })
    await sleep(2000)

    // ════════════════════════════════════════════════════════════════════════
    // ★★ chrome 的启动抽成一支可以【再来一次】的函数 —— 这不是整洁,是必需 ★★
    //   实测(2026-09-09,本支自己的第一跑):跑到第 141+10 条路由时,
    //   **chrome 的调试端口整个不应答了** —— `curl -m 8 /json/version` 退 28、
    //   http=000,而进程全都活着。那时换一个【标签页】是没有用的:
    //   卡死的不是那一页,是整个浏览器。所以恢复的最后一招必须是重开 chrome。
    // ════════════════════════════════════════════════════════════════════════
    let cdp = null, ws = null, sessionId = null, currentTarget = null
    let lastDoc = null

    async function launchChrome() {
        console.error('· launching chrome-headless-shell')
        chrome = spawn(CHROME, [
            `--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu', '--no-sandbox',
            '--hide-scrollbars', `--user-data-dir=${join(OUT_DIR, 'chrome-profile-stylec')}`, 'about:blank',
        ], { stdio: ['ignore', 'pipe', 'pipe'] })
        let wsUrl = null
        for (let i = 0; i < 60 && !wsUrl; i++) {
            await sleep(500)
            try { wsUrl = (await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()).webSocketDebuggerUrl } catch {}
        }
        if (!wsUrl) throw new Error('chrome never opened its debugging port')
        ws = new WebSocket(wsUrl)
        await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP ws failed')) })
        cdp = new Cdp(ws)
        sessionId = null; currentTarget = null
        cdp.on((method, params) => {
            if (method === 'Network.responseReceived' && params?.type === 'Document')
                lastDoc = { url: params.response.url, status: params.response.status }
        })
    }

    async function relaunchChrome(vp, why) {
        console.error(`  ↻ 重开 chrome(${why})`)
        try { if (chrome) chrome.kill('SIGKILL') } catch {}
        try { if (ws) ws.close() } catch {}
        chrome = null; ws = null; cdp = null
        await sleep(1500)
        await launchChrome()
        await newTab(vp)
    }

    await launchChrome()
    const S = (m, p, t) => cdp.send(m, p, sessionId, t)

    async function newTab(vp) {
        if (sessionId) { try { await cdp.send('Target.closeTarget', { targetId: currentTarget }) } catch {} }
        const t = await cdp.send('Target.createTarget', { url: 'about:blank' })
        currentTarget = t.targetId
        const a = await cdp.send('Target.attachToTarget', { targetId: currentTarget, flatten: true })
        sessionId = a.sessionId
        await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
        await S('Emulation.setDeviceMetricsOverride', {
            width: vp.w, height: vp.h, deviceScaleFactor: vp.dsf, mobile: vp.mobile,
            screenWidth: vp.w, screenHeight: vp.h,
        })
        await S('Network.setCookies', {
            cookies: [{ name: cookieName, value: cookieValue, domain: 'localhost', path: '/', httpOnly: false, secure: false }],
        })
    }

    // ════════════════════════════════════════════════════════════════════════
    // ★★★ 这个循环的第一版里,那句 `catch {}` 是【本支最贵的一行】★★★
    //   它把「渲染器不应答了」吞成「还没就绪」,于是 120 圈 × 每圈 60 秒的
    //   CDP 超时 = **一条路由卡两个小时,而日志上一个字都不会多**。
    //   实测代价:桌面那 141 条量完之后卡死,34 分钟没有任何一行输出,
    //   而进程全都活着 —— **它不是"假装成一个发现",是假装成【进度】。**
    //   本仓库对这个形状有明文规矩(「一次失败不是一个空集」/ 不许 `?? []`),
    //   而我把它写进了自己的量具里。
    //
    //   现在:连续三次拿不到答复就【当场抛】,由外层换标签页 / 重开 chrome。
    //   就绪轮询的超时也压到 15 秒 —— 它要的是快速失败,不是等满一分钟。
    // ════════════════════════════════════════════════════════════════════════
    async function go(route) {
        lastDoc = null
        await S('Page.navigate', { url: `http://localhost:${PORT}${route}` }, 30000)
        let consecFail = 0
        const deadline = Date.now() + 45000
        while (Date.now() < deadline) {
            await sleep(400)
            try {
                const r = await S('Runtime.evaluate', {
                    expression: 'document.readyState === "complete" && !!document.body && document.body.innerText.length > 0',
                    returnByValue: true,
                }, 15000)
                consecFail = 0
                if (r.result.value) break
            } catch (e) {
                if (++consecFail >= 3) throw new Error(`renderer wedged at ${route}: ${e.message}`)
            }
        }
        await sleep(900)   // 让客户端组件(Radix 的 SelectTrigger 等)水合完
        return lastDoc
    }

    // ★★ 两个视口 —— 委托书点名:桌面一遍,390px 一遍 ★★
    //    致盲 desktop-only 把 390 那一遍拿掉,好让"视口总体"那条断言响。
    const VIEWPORTS = [
        { name: 'desktop', w: 1440, h: 900, dsf: 1, mobile: false },
        { name: 'phone', w: 390, h: 844, dsf: 3, mobile: true },
    ].filter((v) => !(BLIND === 'desktop-only' && v.name === 'phone'))

    const MEASURE = buildMeasure({ blind: BLIND })
    const out = { mode: MODE, blind: BLIND || null, at: new Date().toISOString(), viewports: [], routes: {}, notes: {} }

    // ════════════════════════════════════════════════════════════════════════
    // ★★ 落盘要【边跑边写】,不能只在收尾写一次 ★★
    //   第一跑就是这么亏掉的:桌面 141 条已经量完,而 JSON 只在两个视口都跑完
    //   之后才写 —— 手机那一半卡死,一杀,**141 条完好的读数一条不剩**。
    //   一支要跑半小时的普查,它的中间结果必须在盘上;否则任何一次中止
    //   (卡死、断电、Ctrl-C)都等于从头再来。
    // ════════════════════════════════════════════════════════════════════════
    const TAG = (BLIND ? 'blind-' + BLIND : 'baseline')
    const OUT_FILE = join(OUT_DIR, `variant-c-${MODE}-${TAG}.json`)
    const flush = () => { try { writeFileSync(OUT_FILE, JSON.stringify(out, null, 1)) } catch (e) { console.error('  !! flush 失败:' + e.message) } }

    if (MODE === 'spec') {
        for (const vp of VIEWPORTS) {
            await newTab(vp)
            const doc = await go('/brand-sampler')
            if (doc && doc.status >= 400) throw new Error(`/brand-sampler returned HTTP ${doc.status}`)
            const r = await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true })
            if (!r.result || r.result.subtype === 'error' || !r.result.value)
                throw new Error('MEASURE did not return a value: ' + JSON.stringify(r).slice(0, 400))
            out.viewports.push(vp.name)
            out.routes[vp.name] = r.result.value
            console.error(`· measured /brand-sampler @ ${vp.name} (${vp.w}px): `
                + `sections=${r.result.value.sectionsFound.join(',')} `
                + `rowsC=${r.result.value.sections.C ? r.result.value.sections.C.rows.length : 0}`)
        }
    } else {
        let routes = staticRoutes.filter((r) => !ONLY || r.startsWith(ONLY))
        if (LIMIT) routes = routes.slice(0, LIMIT)
        out.notes.routesAttempted = routes
        out.notes.dynamicRoutesSkipped = dynamicRoutes
        for (const vp of VIEWPORTS) {
            await newTab(vp)
            out.viewports.push(vp.name)
            out.routes[vp.name] = {}
            let n = 0
            for (const route of routes) {
                n++
                // ★ 主动回收标签页:实测卡死发生在一条标签页连开一百多页之后,
                //   所以不要等它卡了再换。25 是随手取的一个小数,便宜。
                if (n > 1 && n % 25 === 1) { try { await newTab(vp) } catch { await relaunchChrome(vp, '换标签页失败') } }
                let doc = null, val = null, err = null
                try {
                    doc = await go(route)
                    const r = await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true }, 30000)
                    val = r.result && r.result.value
                } catch (e) { err = e.message }
                if (!val) {
                    // 一个量不到的路由必须留下痕迹 —— 空着与"这一页没有控件"长得一样。
                    out.routes[vp.name][route] = { failed: true, err: err || 'no value', http: doc ? doc.status : null }
                    console.error(`  !! ${route} @ ${vp.name}: ${err || 'no value'}`)
                    // 恢复分两级:先换标签页;换不动(整个浏览器卡死)就重开 chrome。
                    try { await newTab(vp) } catch { try { await relaunchChrome(vp, '标签页换不动') } catch (e2) { console.error('  !! chrome 重开失败:' + e2.message); throw e2 } }
                    flush()
                    continue
                }
                out.routes[vp.name][route] = {
                    http: doc ? doc.status : null,
                    rows: val.page.rows,
                    totalElements: val.page.totalElements,
                    claimedElements: val.page.claimedElements,
                    unclaimed: val.page.unclaimed,
                }
                if (n % 10 === 0) { console.error(`  · ${vp.name} ${n}/${routes.length} …`); flush() }
            }
            console.error(`· ${vp.name}: measured ${Object.keys(out.routes[vp.name]).length} routes`)
            flush()   // ★ 一个视口跑完就落盘 —— 下一个视口卡死也不会把它带走
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ★ 覆盖断言 —— 零必须是一次测量,不是一次缺席 ★
    // ════════════════════════════════════════════════════════════════════════
    let ran = 0
    assertPopulation(SELF, '量到的视口', out.viewports.length, 2); ran++
    if (MODE === 'spec') {
        const dv = out.routes[out.viewports[0]]
        assertPopulation(SELF, '取样页上认出来的变体小节', (dv.sectionsFound || []).length, 4); ran++
        const C = dv.sections.C
        assertPopulation(SELF, 'variant C 那一节里量到的元素', C ? C.rows.length : 0, 1); ran++
        // 逐类非空 —— 每一类都是取样页【确实含有】的,空了就是选择器瞎了
        for (const need of ['input.text', 'select.trigger', 'textarea', 'label', 'table.th', 'table.td', 'card', 'badge', 'alert', 'refusal.sampler']) {
            assertPopulation(SELF, `variant C · ${need}`, C.rows.filter((r) => r.role === need).length, 1); ran++
        }
        assertPopulation(SELF, 'variant C · 按钮', C.rows.filter((r) => r.role.startsWith('button.')).length, 1); ran++
        // ── 双向钉住:DOM 数出来的 ↔ 源码里独立数出来的 ──────────────────────
        const src = readFileSync(join(ROOT, 'app/brand-sampler/Variant.tsx'), 'utf8')
        const dataSrc = readFileSync(join(ROOT, 'app/brand-sampler/data.ts'), 'utf8')
        const headCount = (src.match(/<TableHead\b/g) || []).length
        assertPinned(SELF, 'variant C 批次表的表头格数(DOM ↔ Variant.tsx 里的 <TableHead>)',
            C.rows.filter((r) => r.role === 'table.th').length, headCount,
            'C 那一节只有第一张卡有表头行,第二张(拒绝态)只有 tbody。'); ran++
        const refusalKinds = (dataSrc.match(/^\s{4}\w+:\s*\{/gm) || []).length
        assertPinned(SELF, 'variant C 拒绝态小片数(DOM ↔ data.ts 里 REFUSALS 的键数)',
            C.refusalChips || 0, refusalKinds, 'REFUSALS 有几个键,那张对照表就有几行。'); ran++
        const btnSrc = (src.match(/<Button\b/g) || []).length
        assertPinned(SELF, 'variant C 的按钮数(DOM ↔ Variant.tsx 里的 <Button>)',
            C.rows.filter((r) => r.role.startsWith('button.')).length, btnSrc,
            '表单里 4 颗 + 空状态里 1 颗。'); ran++
    } else {
        const dv = out.routes[out.viewports[0]]
        const okRoutes = Object.values(dv).filter((r) => !r.failed)
        assertPopulation(SELF, '量到的路由', okRoutes.length, 1); ran++
        assertPopulation(SELF, '量到的元素读数', okRoutes.reduce((a, r) => a + r.rows.length, 0), 1); ran++
    }
    console.error(`· coverage assertions run: ${ran}`)

    flush()
    const outFile = OUT_FILE
    console.log('wrote ' + outFile)

    // ── 人读的摘要 ──────────────────────────────────────────────────────────
    if (MODE === 'spec') {
        for (const vp of out.viewports) {
            const C = out.routes[vp].sections.C
            console.log(`\n══ variant C @ ${vp} ══  (元素 ${C.claimedElements}/${C.totalElements} 被角色认领)`)
            const byRole = new Map()
            for (const r of C.rows) {
                if (!byRole.has(r.role)) byRole.set(r.role, [])
                byRole.get(r.role).push(r)
            }
            for (const [role, rows] of [...byRole].sort()) {
                const sigs = new Set(rows.map(sigOf))
                const a = rows[0]
                console.log(`  ${role.padEnd(26)} n=${String(rows.length).padStart(3)} sigs=${sigs.size}  `
                    + `h=${a.height} pad=${a.paddingTop}/${a.paddingRight}/${a.paddingBottom}/${a.paddingLeft} `
                    + `bw=${a.borderTopWidth} r=${a.borderTopLeftRadius} fs=${a.fontSize} fw=${a.fontWeight} lh=${a.lineHeight}`)
            }
            console.log('  未被认领的标签:', JSON.stringify(C.unclaimed))
        }
    }
}

main().then(cleanup).catch(async (e) => {
    console.error('\n!! survey-variant-c failed:', e.message)
    await cleanup()
    process.exitCode = process.exitCode || 2
})
