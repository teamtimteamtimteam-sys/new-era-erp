#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// INPUT-0(2026-09-10)· 控件族的普查 + 【390px 行高基线】
// ════════════════════════════════════════════════════════════════════════════
// 【它为什么存在,一句话】
//   下一族刀要改的是**会推动行高**的那一族控件(输入框、下拉、日期、数字),
//   而表格那一族刚刚逐张判过「390px 上哪几列装得下」—— 判的依据是**今天的行高**。
//   ☞ **一次先于基线的施工,说不出自己有没有推翻那些判断。**
//   所以这一支先把基线量下来,而且**一个字节都不改**。
//
// 【它不是一道闸】它不在 npm run build 里,也不该进去。它报的是【数】不是【违规】。
//   退出码沿用本仓库三档:0 干净 / 1 找到了违规 / 2 **量具自己坏了**。
//   本支用 0 与 2;`--mode=compare` 另外用 1 —— 见下面 §COMPARE。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :chrome-headless-shell 通过 CDP,在**真实渲染并水合之后**的
//                   DOM 上读 getComputedStyle 的**解析值** —— 高度、内边距、
//                   边框、圆角、字号、字重、行高、颜色、resize;以及每一个
//                   `<table>` 的**表头行高与每一行的行高**(getBoundingClientRect)。
//                   不是 class 串,不是截图,不是从源码推算的。
//   我声称管的是   :这套系统里**单行控件、多行框、勾选框/单选框今天渲染成了
//                   几种值**,其中**有多少住在表格里**,以及**含控件的表在
//                   390px 上的行高基线**。
//
//   两者不同之处   :★★ 这一段是本支最重要的几行,请读完再看数 ★★
//
//     ① **我只走【静态路由】。** 142 条静态路由走满两个视口;**58 条带 [id] 的
//        详情/编辑页一条都不走。** 取 id 那套机制(ID_SOURCES,约 60 条
//        表名映射 + 一组按路由的过滤器)住在 `scripts/smoke-routes.mjs` 里,
//        **复制它就是仓库里第二份会漂的定义**。
//        ☞ **于是详情页与编辑页上的控件是【未测量】,不是【不存在】。**
//        §UNREACHED 把那 58 条逐条报出来,而不是让它们从分母里消失。
//
//     ② **我量的是首屏。** 对话框、下拉展开、Tab 面板、折叠行从不打开。
//        一个「点开才出现」的控件在我这里读成不存在 —— 那个零的准确含义是
//        **「首屏上一次都没出现」**,不是「系统里没有」。
//
//     ③ **我走硬导航,人走软导航。** 根布局在客户端换页时不重画,
//        所以本支关于**应用外壳**的读数对「一次全新打开」成立,
//        对「一个人点着链接走过去」未经验证。
//
//     ④ **行高是【内容决定的】。** 同一张表换一批数据,行高会变。
//        所以基线里每一行都带着**它那一行的第一格文字**(截断到 32 字),
//        好让后来的刀分得清「行长高了」与「换了一行数据」。
//        ☞ 这一条是本支能给出的最强保证,**它不等于把数据钉死**。
//
// ════════════════════════════════════════════════════════════════════════════
// 【§COMPARE — 比【成员名单】,不比【总数】】
//   STYLE-1 的 `pick-a` 致盲证过一次:把 A 那一节冒充成 C,**两边总数都是 1046**,
//   只看总数的比对器会说「没变化」。所以本支的比对器:
//     · 逐个成员比 —— 成员 id = 视口|路由|角色|序号(行高是 视口|路由|表签名|行号);
//     · 报三个数:**多出来的成员 / 少掉的成员 / 值变了的成员**;
//     · **三个数全是 0 → EXIT 1**,判定「这一条致盲不作数」——
//       一次什么都没拿走的致盲证明不了任何事,而这句话必须由机器说出来。
// ════════════════════════════════════════════════════════════════════════════
//
// ════════════════════════════════════════════════════════════════════════════
// 【§EDIT — 为什么还有第三个模式】
//   首屏读数量出来一件要紧事:**`<EditableTable>` 的行在首屏上是只读的**,
//   格子里要点一下「编辑」才长出 `<input>`。于是首屏基线在那些表上读到的
//   控件数是 **0** —— 而**那正是下一刀最可能碰到的那一族表**。
//   `--mode=edit` 只做一件事:把那一颗、且只有那一颗按钮点下去,再量一遍。
//
//   ★ 判据窄到只认它,是因为【乱点是会改数据的】:同一张表里还有「停用」
//     一类按钮,而探针账号是 admin。所以候选只收
//     **住在 `tbody tr` 里、className 含 `text-blue-600`、且文字等于
//     `<EditableTable>` 自己那个 `labels.edit`** 的按钮 ——
//     它的 onClick 是 `begin(row)`,**纯本地 state,不发一个请求**。
//   ★ 点完之后要求【那张表里的控件数真的变多】。没变多就记成
//     `clickHadNoEffect`,那是一个读数,不是一次沉默。
// ════════════════════════════════════════════════════════════════════════════
//
// Usage:
//   node scripts/survey-controls.mjs --mode=spec   [--blind=NAME]
//   node scripts/survey-controls.mjs --mode=drift  [--blind=NAME] [--limit=N] [--only=/a,/b]
//   node scripts/survey-controls.mjs --mode=edit   [--blind=NAME]
//   node scripts/survey-controls.mjs --mode=compare --a=FILE --b=FILE
//
// Blindings (--blind=):
//   noop         什么都不拿走 —— 【登记在案的废致盲】,留着是为了让比对器判它不作数
//   round-height 高度磨成 10 的倍数 —— 成员一个不变,值变
//   same-table   每个控件都算作住在第 0 张表里 —— 成员 id 换人,总数不变
//   no-native    原生控件不再被当作控件 —— 空总体断言当场红
//   no-tables    不再认表格 —— 「住在表里的控件」那条断言当场红
//   one-viewport 拿掉 390px 那一遍 —— 视口总体断言当场红

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, mkdirSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join } from 'node:path'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'survey-controls'
const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3196              // 3197 是 survey-variant-c 的,3198 survey-phone,3199 冒烟
const CDP_PORT = 9335
const OUT_DIR = process.env.SURVEY_OUT || join(ROOT, '.survey-out')
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')

const arg = (k) => { const a = process.argv.find((x) => x.startsWith(k + '=')); return a ? a.slice(k.length + 1) : null }
const MODE = arg('--mode') || 'drift'
const BLIND = arg('--blind') || ''
const LIMIT = Number(arg('--limit') || 0)
const ONLY = (arg('--only') || '').split(',').map((s) => s.trim()).filter(Boolean)

const KNOWN_BLINDS = ['', 'noop', 'round-height', 'same-table', 'no-native', 'no-tables', 'one-viewport']
if (!KNOWN_BLINDS.includes(BLIND)) { console.error('unknown --blind=' + BLIND); process.exit(2) }

// ════════════════════════════════════════════════════════════════════════════
// §COMPARE —— 比对器。它先跑,因为它不需要浏览器、不需要数据库、不需要锁。
// ════════════════════════════════════════════════════════════════════════════
function memberMap(doc) {
    const m = new Map()
    for (const vp of Object.keys(doc.routes || {})) {
        for (const [route, r] of Object.entries(doc.routes[vp] || {})) {
            if (!r || r.failed) continue
            for (const row of r.rows || []) {
                m.set(`${vp}|${route}|${row.role}|${row.idx}|tbl=${row.tbl}`, row.sig)
            }
            for (const t of r.tables || []) {
                m.set(`${vp}|${route}|TABLE|${t.key}|head`, String(t.headH))
                ;(t.rowH || []).forEach((h, i) => { m.set(`${vp}|${route}|TABLE|${t.key}|row${i}`, String(h)) })
            }
        }
    }
    // spec 模式把读数放在 sections 里
    for (const vp of Object.keys(doc.spec || {})) {
        for (const [sec, rows] of Object.entries(doc.spec[vp].sections || {})) {
            for (const row of rows) m.set(`${vp}|SPEC|${sec}|${row.role}|${row.idx}`, row.sig)
        }
    }
    return m
}

if (MODE === 'compare') {
    const fa = arg('--a'), fb = arg('--b')
    if (!fa || !fb) { console.error('compare 需要 --a=FILE --b=FILE'); process.exit(2) }
    const A = memberMap(JSON.parse(readFileSync(fa, 'utf8')))
    const B = memberMap(JSON.parse(readFileSync(fb, 'utf8')))
    assertPopulation(SELF, '基线里的成员', A.size, 1)
    const added = [...B.keys()].filter((k) => !A.has(k))
    const removed = [...A.keys()].filter((k) => !B.has(k))
    const changed = [...A.keys()].filter((k) => B.has(k) && B.get(k) !== A.get(k))
    console.log(`成员:A=${A.size}  B=${B.size}`)
    console.log(`  多出来的成员 : ${added.length}`)
    console.log(`  少掉的成员   : ${removed.length}`)
    console.log(`  值变了的成员 : ${changed.length}`)
    for (const k of added.slice(0, 5)) console.log(`    + ${k}`)
    for (const k of removed.slice(0, 5)) console.log(`    - ${k}`)
    for (const k of changed.slice(0, 5)) console.log(`    ~ ${k}\n        A=${A.get(k)}\n        B=${B.get(k)}`)
    if (added.length === 0 && removed.length === 0 && changed.length === 0) {
        console.error('✗ 这一条【不作数】:成员名单与每一个值都逐字相同 —— 这次致盲什么都没拿走。')
        console.error('  一次什么都没拿走的致盲证明不了任何事。')
        process.exit(1)
    }
    console.log('✓ 这一条作数:名单或值确实动了。')
    process.exit(0)
}

// ════════════════════════════════════════════════════════════════════════════
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

// ── 路由 ────────────────────────────────────────────────────────────────────
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

// ── §EDIT:哪几条路由上住着 <EditableTable> ──────────────────────────────────
// ★ 这份名单是【算出来的,不是抄下来的】:走 app/ 找 import 了 editable-table
//   的文件,再从那个文件往上走到最近的一个 page.tsx。抄一份路由清单
//   就是仓库里第二份会漂的定义 —— 这一族刀为那个形状付过账。
function editableTableRoutes() {
    const out = []
    function* walkAll(dir) {
        for (const name of readdirSync(dir)) {
            const p = join(dir, name)
            if (statSync(p).isDirectory()) { if (name !== 'brand-sampler') yield* walkAll(p) }
            else if (p.endsWith('.tsx')) yield p
        }
    }
    for (const p of walkAll(join(ROOT, 'app'))) {
        if (p.includes('/components/ui/')) continue
        if (!/from ['"][^'"]*editable-table['"]/.test(readFileSync(p, 'utf8'))) continue
        // 从这个文件往上走到最近的一个 page.tsx
        let dir = p.slice(0, p.lastIndexOf('/'))
        let route = null
        while (dir.length > join(ROOT, 'app').length) {
            if (existsSync(join(dir, 'page.tsx'))) { route = dir.slice(ROOT.length + 3) || '/'; break }
            dir = dir.slice(0, dir.lastIndexOf('/'))
        }
        out.push({ file: p.slice(ROOT.length), route })
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════
// 页面里跑的那一段 —— 原样写在这里,好让读数的人看见它到底读了什么
// ════════════════════════════════════════════════════════════════════════════
const STYLE_KEYS = [
    'height', 'minHeight', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
    'borderTopWidth', 'borderBottomWidth', 'borderTopColor',
    'borderTopLeftRadius', 'fontSize', 'fontWeight', 'lineHeight', 'color',
    'backgroundColor', 'resize', 'boxSizing',
]

// 角色 —— 靠 data-slot 与 type,不靠 class 串。
// 【库 vs 手搓】是本刀最关键的一条分账,所以每一类都拆成 .lib 与 .native 两行。
const ROLE_SELECTORS = [
    ['input.lib', 'input[data-slot="input"]'],
    ['input.text', 'input:not([data-slot]):not([type]), input:not([data-slot])[type="text"], input:not([data-slot])[type="search"], input:not([data-slot])[type="email"], input:not([data-slot])[type="tel"], input:not([data-slot])[type="password"]'],
    ['input.date', 'input:not([data-slot])[type="date"], input:not([data-slot])[type="month"], input:not([data-slot])[type="week"], input:not([data-slot])[type="time"], input:not([data-slot])[type="datetime-local"]'],
    ['input.number', 'input:not([data-slot])[type="number"]'],
    ['input.file', 'input[type="file"]'],
    ['input.checkbox', 'input[type="checkbox"]'],
    ['input.radio', 'input[type="radio"]'],
    ['select.trigger', '[data-slot="select-trigger"]'],
    ['select.native', 'select'],
    ['textarea.lib', 'textarea[data-slot="textarea"]'],
    ['textarea.native', 'textarea:not([data-slot])'],
    ['label.lib', 'label[data-slot="label"]'],
    ['label.native', 'label:not([data-slot])'],
]

function buildMeasure({ blind }) {
    return `(() => {
  const SK = ${JSON.stringify(STYLE_KEYS)};
  const ROLES = ${JSON.stringify(ROLE_SELECTORS)};
  const BLIND = ${JSON.stringify(blind)};
  const round = (n) => Math.round(n * 100) / 100;
  const txt = (el) => (el && el.textContent || '').replace(/\\s+/g, ' ').trim();

  // ── 表格先认,因为控件要按【住在哪张表】归属 ──────────────────────────────
  const tables = BLIND === 'no-tables' ? [] : [...document.querySelectorAll('table')];
  // ★ 表的【签名】—— 基线要能跨跑次比对,所以身份不能只是一个序号:
  //   序号会因为页面上多一张表而整体错位。签名 = 表头格文字(前 8 个,各截 16 字)。
  //   没有表头的表(TABLE-CONVERT 一族点过名的那几张)退回到「第一行第一格的文字」。
  function tableKey(t, i) {
    const hs = [...t.querySelectorAll('thead th, thead td')].slice(0, 8).map((h) => txt(h).slice(0, 16));
    if (hs.length) return 'h:' + hs.join('/');
    const first = t.querySelector('tr');
    return 'n' + i + ':' + (first ? txt(first).slice(0, 40) : '');
  }
  const tblOf = (el) => {
    if (BLIND === 'no-tables') return -1;
    if (BLIND === 'same-table') return tables.length ? 0 : -1;
    const t = el.closest ? el.closest('table') : null;
    return t ? tables.indexOf(t) : -1;
  };

  const SIGK = ['height','paddingTop','paddingRight','paddingBottom','paddingLeft',
                'borderTopWidth','borderBottomWidth','borderTopColor','borderTopLeftRadius',
                'fontSize','fontWeight','lineHeight','color','backgroundColor','resize'];

  function m(el) {
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    const o = { tag: el.tagName.toLowerCase(), rectH: round(r.height), rectW: round(r.width) };
    for (const k of SK) o[k] = cs[k];
    if (BLIND === 'round-height') {
      o.height = (Math.round(parseFloat(o.height) / 10) * 10) + 'px';
      o.rectH = Math.round(o.rectH / 10) * 10;
    }
    o.type = el.getAttribute('type') || null;
    o.rowsAttr = el.tagName === 'TEXTAREA' ? (el.getAttribute('rows') || null) : null;
    o.scrollH = el.tagName === 'TEXTAREA' ? el.scrollHeight : null;
    o.disabled = !!el.disabled;
    o.cls = (el.getAttribute('class') || '').slice(0, 300);
    // ★ 【在 DOM 里】不等于【在屏幕上】—— 一个关着的 <details> 里的勾选框
    //   querySelectorAll 找得到,而人看不见。两者必须分得开,否则一个"13"
    //   会被读成"取样页画了 13 个勾选框",而那是一句假话。
    o.vis = typeof el.checkVisibility === 'function'
      ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) : null;
    o.inClosedDetails = !!(el.closest && el.closest('details:not([open])'));
    o.sig = SIGK.map((k) => o[k]).join('|');
    return o;
  }

  const rows = [];
  const seen = new Set();
  for (const [role, sel] of ROLES) {
    if (BLIND === 'no-native' && role.indexOf('.lib') === -1 && role !== 'select.trigger') continue;
    let els = [];
    try { els = [...document.querySelectorAll(sel)]; } catch (e) { els = []; }
    els.forEach((el, i) => {
      if (seen.has(el)) return;      // 一个元素只归一个角色 —— 否则分账会重复计数
      seen.add(el);
      rows.push(Object.assign({ role: role, idx: i, tbl: tblOf(el) }, m(el)));
    });
  }

  // ── 表:表头行高 + 每一行的行高 ──────────────────────────────────────────
  const tblOut = tables.map((t, i) => {
    const head = t.querySelector('thead tr');
    const bodyRows = [...t.querySelectorAll('tbody tr')];
    // 这张表里住着几个控件 —— 用刚才收好的 rows,不重新查一遍(两份判据会漂)
    const nCtl = rows.filter((r) => r.tbl === i && r.role.indexOf('label') !== 0).length;
    // 横向:表自己的滚动壳。DataTable 把表包在一个 overflow-x-auto 的 div 里。
    let shell = t.parentElement;
    while (shell && shell !== document.body && getComputedStyle(shell).overflowX !== 'auto' && getComputedStyle(shell).overflowX !== 'scroll') shell = shell.parentElement;
    const hasShell = !!shell && shell !== document.body;
    return {
      key: tableKey(t, i),
      idx: i,
      cols: head ? head.children.length : (t.querySelector('tr') ? t.querySelector('tr').children.length : 0),
      nBodyRows: bodyRows.length,
      nControls: nCtl,
      headH: head ? round(head.getBoundingClientRect().height) : null,
      rowH: bodyRows.map((tr) => round(tr.getBoundingClientRect().height)).map((h) => BLIND === 'round-height' ? Math.round(h / 10) * 10 : h),
      rowFirstCell: bodyRows.map((tr) => txt(tr.children[0] || tr).slice(0, 32)),
      tableW: round(t.getBoundingClientRect().width),
      shellW: hasShell ? round(shell.getBoundingClientRect().width) : null,
      shellScrollW: hasShell ? shell.scrollWidth : null,
      overflowsShell: hasShell ? (shell.scrollWidth > shell.clientWidth + 1) : null,
    };
  });

  return {
    url: location.pathname,
    viewportW: document.documentElement.clientWidth,
    rows: rows,
    tables: tblOut,
    tableCount: tables.length,
    totalElements: document.querySelectorAll('*').length,
    docScrollW: document.documentElement.scrollWidth,
    docClientW: document.documentElement.clientWidth,
    hydrated: !!(window.next && window.next.appDir !== undefined) || !!document.querySelector('[data-slot]'),
    hydrationMark: window.__INPUT0_HYDRATED__ === true,
  };
})()`
}

// ════════════════════════════════════════════════════════════════════════════
// §EDIT · 那一颗、且只有那一颗按钮
//   返回点到了几颗。判据窄到只认 <EditableTable> 的行内「编辑」:
//     住在 tbody tr 里 · className 含 text-blue-600 · 不带 aria-expanded
//     (aria-expanded 那颗是手机上的展开箭头,不是编辑)
//   它的 onClick 是 begin(row) —— 纯本地 state。**一个请求都不发。**
// ════════════════════════════════════════════════════════════════════════════
const CLICK_EDIT = `(() => {
  const cands = [...document.querySelectorAll('tbody tr button')].filter((b) =>
    (b.getAttribute('class') || '').indexOf('text-blue-600') !== -1 &&
    !b.hasAttribute('aria-expanded') && !b.disabled);
  // 每张表只点【第一行】那一颗 —— 要看的是"一行变成输入之后有多高",
  // 不是"把整张表都打开"。
  const seen = new Set(); const clicked = [];
  for (const b of cands) {
    const t = b.closest('table'); if (!t || seen.has(t)) continue;
    seen.add(t); clicked.push((b.textContent || '').trim().slice(0, 12)); b.click();
  }
  return { nClicked: clicked.length, labels: clicked, nCandidates: cands.length };
})()`

// ── spec 模式:取样页的 C 那一节 ─────────────────────────────────────────────
const SPEC_MEASURE = `(() => {
  const SK = ${JSON.stringify(STYLE_KEYS)};
  const ROLES = ${JSON.stringify(ROLE_SELECTORS)};
  const round = (n) => Math.round(n * 100) / 100;
  const SIGK = ['height','minHeight','paddingTop','paddingRight','paddingBottom','paddingLeft',
                'borderTopWidth','borderTopColor','borderTopLeftRadius','fontSize','fontWeight',
                'lineHeight','color','backgroundColor','resize'];
  function m(el) {
    const cs = getComputedStyle(el); const r = el.getBoundingClientRect();
    const o = { tag: el.tagName.toLowerCase(), rectH: round(r.height), rectW: round(r.width) };
    for (const k of SK) o[k] = cs[k];
    o.rowsAttr = el.tagName === 'TEXTAREA' ? (el.getAttribute('rows') || null) : null;
    o.scrollH = el.tagName === 'TEXTAREA' ? el.scrollHeight : null;
    o.cls = (el.getAttribute('class') || '').slice(0, 300);
    o.type = el.getAttribute('type') || null;
    o.vis = typeof el.checkVisibility === 'function'
      ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) : null;
    o.inClosedDetails = !!(el.closest && el.closest('details:not([open])'));
    o.sig = SIGK.map((k) => o[k]).join('|');
    return o;
  }
  const secs = [...document.querySelectorAll('section')];
  const found = {};
  for (const s of secs) {
    const h2 = s.querySelector('h2'); if (!h2) continue;
    const t = (h2.textContent || '').trim();
    if (t.indexOf('A · ') === 0) found.A = s;
    else if (t.indexOf('B · ') === 0) found.B = s;
    else if (t.indexOf('C · ') === 0) found.C = s;
    else if (t.indexOf('BASE-1') === 0) found.BASE1 = s;
  }
  const sections = {};
  for (const k of Object.keys(found)) {
    const out = []; const seen = new Set();
    for (const [role, sel] of ROLES) {
      let els = []; try { els = [...found[k].querySelectorAll(sel)]; } catch (e) { els = []; }
      els.forEach((el, i) => { if (seen.has(el)) return; seen.add(el); out.push(Object.assign({ role: role, idx: i }, m(el))); });
    }
    sections[k] = out;
  }
  // 整页(含应用外壳的顶栏 / dock)—— 取样页【不在 BARE_CHROME_PATHS 里】,
  // 它带着完整外壳渲染,所以「整页」与「A/B/C/BASE-1 四节之和」不是同一个数。
  {
    const out = []; const seen = new Set();
    for (const [role, sel] of ROLES) {
      let els = []; try { els = [...document.querySelectorAll(sel)]; } catch (e) { els = []; }
      els.forEach((el, i) => { if (seen.has(el)) return; seen.add(el); out.push(Object.assign({ role: role, idx: i }, m(el))); });
    }
    sections.__PAGE__ = out;
  }
  const rootCs = getComputedStyle(document.documentElement);
  const tokens = {};
  for (const t of ['--brand-radius', '--brand-border', '--brand-border-strong', '--brand-ocean', '--brand-text', '--brand-surface']) tokens[t] = rootCs.getPropertyValue(t).trim();
  // ★ 取样页【没有】什么 —— 整页跑同一套选择器,零必须是一次测量
  const ZERO = [
    ['input[type=file]', 'input[type="file"]'],
    ['input[type=date]', 'input[type="date"]'],
    ['input[type=number]', 'input[type="number"]'],
    ['select(native)', 'select'],
    ['input[type=checkbox]', 'input[type="checkbox"]'],
    ['input[type=radio]', 'input[type="radio"]'],
    ['h4', 'h4'], ['h5', 'h5'], ['h6', 'h6'],
    ['input[type=month]', 'input[type="month"]'],
    ['input[type=search]', 'input[type="search"]'],
    ['dialog', 'dialog, [role="dialog"]'],
    ['tablist', '[role="tablist"]'],
    ['tooltip', '[role="tooltip"]'],
  ];
  const zeros = {}; const zerosC = {};
  for (const [name, sel] of ZERO) {
    zeros[name] = document.querySelectorAll(sel).length;
    zerosC[name] = found.C ? found.C.querySelectorAll(sel).length : -1;
  }
  return { sections: sections, sectionsFound: Object.keys(found), zerosWholePage: zeros, zerosSectionC: zerosC,
           tokens: tokens, viewportW: document.documentElement.clientWidth };
})()`

// ════════════════════════════════════════════════════════════════════════════
class Cdp {
    constructor(ws) {
        this.ws = ws; this.id = 0; this.waiting = new Map(); this.listeners = []
        ws.onmessage = (e) => {
            const msg = JSON.parse(e.data)
            if (msg.id && this.waiting.has(msg.id)) {
                const { res, rej } = this.waiting.get(msg.id); this.waiting.delete(msg.id)
                if (msg.error) rej(new Error(JSON.stringify(msg.error)))
                else res(msg.result)
            } else if (msg.method) { for (const fn of this.listeners) { try { fn(msg.method, msg.params) } catch { /* 监听器自己的错不该杀掉连接 */ } } }
        }
    }
    on(fn) { this.listeners.push(fn) }
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
    try { if (chrome) chrome.kill('SIGKILL') } catch { /* 已经死了 */ }
    try { if (dev) process.kill(-dev.pid, 'SIGKILL') } catch { /* 已经死了 */ }
}
async function cleanup() { await runPlan(); killChildren() }
installExitHooks({ onFinish: () => { killChildren(); release('scripts/survey-controls.mjs') } })
// installExitHooks 挂不到一次直接的 process.exit(),而 selfproof 的 die() 正是
// 直接 exit(2) —— 于是 next dev 与 chrome 会活下来(ppid=1),下一跑撞在端口守卫上。
// 'exit' 只跑得了同步代码,而 killChildren 正好是同步的。
process.on('exit', () => { try { killChildren() } catch { /* 收工时不再抛 */ } })

// ════════════════════════════════════════════════════════════════════════════
async function main() {
    acquireOrExit('scripts/survey-controls.mjs', { ownExit: false })
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    openPlan('scripts/survey-controls.mjs')
    await reapStalePlans()
    mkdirSync(OUT_DIR, { recursive: true })

    if (existsSync(join(ROOT, '.next/BUILD_ID'))) {
        throw new Error('.next/BUILD_ID exists — a PRODUCTION build is in .next, and `next dev` on top '
            + 'of it serves 404s. Fix: rm -rf .next (it is a regenerable cache), then re-run.')
    }

    try {
        const pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' }).trim().split('\n').filter(Boolean)
        for (const pid of pids) {
            const ppid = execSync(`ps -o ppid= -p ${pid} || echo 0`, { encoding: 'utf8' }).trim()
            if (ppid === '1') { execSync(`kill -9 ${pid}`); console.error(`· killed orphan on :${PORT} (pid ${pid})`) }
            else throw new Error(`port ${PORT} held by a LIVE process (pid ${pid}) — not killing it`)
        }
    } catch (e) { if (/held by a LIVE/.test(e.message)) throw e }

    // ── 用完即删的 admin ────────────────────────────────────────────────────
    const email = `input0-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', {
        method: 'POST', body: JSON.stringify({ email, password: 'input0-pass-1', email_confirm: true }),
    })).json()
    accountId = cu.id
    if (!accountId) throw new Error('could not create probe account: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke input0 grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete input0 account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'input0-pass-1' }),
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

    let cdp = null, ws = null, sessionId = null, currentTarget = null
    let lastDoc = null

    async function launchChrome() {
        console.error('· launching chrome-headless-shell')
        chrome = spawn(CHROME, [
            `--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu', '--no-sandbox',
            '--hide-scrollbars', `--user-data-dir=${join(OUT_DIR, 'chrome-profile-input0')}`, 'about:blank',
        ], { stdio: ['ignore', 'pipe', 'pipe'] })
        let wsUrl = null
        for (let i = 0; i < 60 && !wsUrl; i++) {
            await sleep(500)
            try { wsUrl = (await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()).webSocketDebuggerUrl } catch { /* 还没开口 */ }
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
        try { if (chrome) chrome.kill('SIGKILL') } catch { /* 已经死了 */ }
        try { if (ws) ws.close() } catch { /* 已经关了 */ }
        chrome = null; ws = null; cdp = null
        await sleep(1500)
        await launchChrome()
        await newTab(vp)
    }

    await launchChrome()
    const S = (m, p, t) => cdp.send(m, p, sessionId, t)

    async function newTab(vp) {
        if (sessionId) { try { await cdp.send('Target.closeTarget', { targetId: currentTarget }) } catch { /* 标签页已经没了 */ } }
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
        // ★★ 水合的证据,不是一次 sleep ★★
        //   在【每一次导航之前】注入一段脚本:它用 requestIdleCallback 之外的
        //   办法证明 React 真的接管过 —— 监听 Next 自己在水合完成后才会挂上的
        //   那些东西。见 waitReady() 的注释。
        await S('Page.addScriptToEvaluateOnNewDocument', {
            source: `(() => {
              window.__INPUT0_HYDRATED__ = false;
              // React 18/19 水合完成之后,根容器上会出现 __reactContainer$… 这个键。
              // 它是 React 自己挂的,不是我造的 —— 所以它是【证据】,不是一次等待。
              // App Router 把根挂在 document 上,不是 body —— 所以三处都看。
              const check = () => {
                for (const el of [document, document.documentElement, document.body]) {
                  if (el && Object.keys(el).some((k) => k.indexOf('__reactContainer$') === 0)) {
                    window.__INPUT0_HYDRATED__ = true; return true;
                  }
                }
                return false;
              };
              const iv = setInterval(() => { if (check()) clearInterval(iv); }, 50);
            })()`,
        })
    }

    // ════════════════════════════════════════════════════════════════════════
    // ★★ 一个 waiter,不是七个 ★★
    //   就绪 = ①文档 complete ②body 有字 ③**React 已经水合**(__reactContainer$)。
    //   三条在【同一个轮询】里判,判到就走,判不到就到时限报错 ——
    //   没有另一处 sleep 在替它兜底,因为一个兜底的 sleep 会把「没水合」
    //   悄悄变成「等久一点就好了」,而那正是读数不可信的来源。
    //   连续三次拿不到答复就当场抛,由外层换标签页 / 重开 chrome。
    // ════════════════════════════════════════════════════════════════════════
    const READY_EXPR = `(() => {
      if (document.readyState !== 'complete') return 'doc';
      if (!document.body || document.body.innerText.length === 0) return 'empty';
      if (window.__INPUT0_HYDRATED__ !== true) return 'hydrate';
      return 'ok';
    })()`

    async function go(route) {
        lastDoc = null
        await S('Page.navigate', { url: `http://localhost:${PORT}${route}` }, 30000)
        let consecFail = 0
        let last = 'never'
        const deadline = Date.now() + 45000
        while (Date.now() < deadline) {
            await sleep(300)
            try {
                const r = await S('Runtime.evaluate', { expression: READY_EXPR, returnByValue: true }, 15000)
                consecFail = 0
                last = r.result.value
                if (last === 'ok') return { doc: lastDoc, ready: 'ok' }
            } catch (e) {
                if (++consecFail >= 3) throw new Error(`renderer wedged at ${route}: ${e.message}`)
            }
        }
        // 到点还没就绪 —— 这是一个【读数】,不是一次沉默:记下卡在哪一步。
        return { doc: lastDoc, ready: last }
    }

    const VIEWPORTS = [
        { name: 'desktop', w: 1440, h: 900, dsf: 1, mobile: false },
        { name: 'phone', w: 390, h: 844, dsf: 3, mobile: true },
    ].filter((v) => !(BLIND === 'one-viewport' && v.name === 'phone'))

    const MEASURE = buildMeasure({ blind: BLIND })
    const out = {
        mode: MODE, blind: BLIND || null, at: new Date().toISOString(),
        viewports: [], routes: {}, spec: {}, notes: {},
    }
    const TAG = (BLIND ? 'blind-' + BLIND : 'baseline')
    const OUT_FILE = join(OUT_DIR, `controls-${MODE}-${TAG}.json`)
    const flush = () => { try { writeFileSync(OUT_FILE, JSON.stringify(out, null, 1)) } catch (e) { console.error('  !! flush 失败:' + e.message) } }

    if (MODE === 'spec') {
        for (const vp of VIEWPORTS) {
            await newTab(vp)
            const { doc, ready } = await go('/brand-sampler')
            if (doc && doc.status >= 400) throw new Error(`/brand-sampler returned HTTP ${doc.status}`)
            if (ready !== 'ok') throw new Error(`/brand-sampler never became ready @ ${vp.name}: stuck at "${ready}"`)
            const r = await S('Runtime.evaluate', { expression: SPEC_MEASURE, returnByValue: true })
            if (!r.result || r.result.subtype === 'error' || !r.result.value)
                throw new Error('SPEC_MEASURE did not return a value: ' + JSON.stringify(r).slice(0, 400))
            out.viewports.push(vp.name)
            out.spec[vp.name] = r.result.value
            const C = r.result.value.sections.C || []
            console.error(`· sampler @ ${vp.name}: sections=${r.result.value.sectionsFound.join(',')} rowsC=${C.length}`)
        }
    } else if (MODE === 'edit') {
        const cand = editableTableRoutes()
        out.notes.editableTableFiles = cand
        const routes = [...new Set(cand.map((c) => c.route).filter((r) => r && !r.includes('[')))].sort()
        out.notes.routesAttempted = routes
        out.notes.editableRoutesUnreachable = cand.filter((c) => !c.route || c.route.includes('['))
        console.error(`· <EditableTable> 住在 ${cand.length} 个文件里 → ${routes.length} 条静态路由`)
        for (const vp of VIEWPORTS) {
            await newTab(vp)
            out.viewports.push(vp.name)
            out.routes[vp.name] = {}
            for (const route of routes) {
                let rec = null
                try {
                    const g = await go(route)
                    if (g.ready !== 'ok') throw new Error('never became ready: ' + g.ready)
                    const before = (await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true }, 30000)).result.value
                    const click = (await S('Runtime.evaluate', { expression: CLICK_EDIT, returnByValue: true }, 30000)).result.value
                    // ★ 一个 waiter:等【那张表里的控件数真的变多】,不是等一段时间。
                    const beforeN = before.rows.filter((r) => r.tbl >= 0 && !r.role.startsWith('label')).length
                    let after = null
                    const deadline = Date.now() + 8000
                    while (Date.now() < deadline) {
                        await sleep(200)
                        after = (await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true }, 30000)).result.value
                        if (after.rows.filter((r) => r.tbl >= 0 && !r.role.startsWith('label')).length > beforeN) break
                    }
                    const afterN = after.rows.filter((r) => r.tbl >= 0 && !r.role.startsWith('label')).length
                    rec = Object.assign({ http: g.doc ? g.doc.status : null, ready: g.ready, click,
                        controlsInTablesBefore: beforeN, controlsInTablesAfter: afterN,
                        clickHadNoEffect: afterN <= beforeN,
                        tablesBefore: before.tables }, after)
                } catch (e) { rec = { failed: true, err: e.message } }
                out.routes[vp.name][route] = rec
                console.error(`  · ${route} @ ${vp.name}: ` + (rec.failed ? '!! ' + rec.err
                    : `点了 ${rec.click.nClicked} 颗(候选 ${rec.click.nCandidates})· 表内控件 ${rec.controlsInTablesBefore} → ${rec.controlsInTablesAfter}`))
                flush()
                try { await newTab(vp) } catch { await relaunchChrome(vp, '换标签页失败') }
            }
        }
    } else {
        let routes = staticRoutes.filter((r) => !ONLY.length || ONLY.some((o) => r === o || r.startsWith(o)))
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
                if (n > 1 && n % 25 === 1) { try { await newTab(vp) } catch { await relaunchChrome(vp, '换标签页失败') } }
                let doc = null, ready = null, val = null, err = null
                try {
                    const g = await go(route)
                    doc = g.doc; ready = g.ready
                    const r = await S('Runtime.evaluate', { expression: MEASURE, returnByValue: true }, 30000)
                    val = r.result && r.result.value
                } catch (e) { err = e.message }
                if (!val) {
                    out.routes[vp.name][route] = { failed: true, err: err || 'no value', http: doc ? doc.status : null, ready }
                    console.error(`  !! ${route} @ ${vp.name}: ${err || 'no value'} (ready=${ready})`)
                    try { await newTab(vp) } catch { try { await relaunchChrome(vp, '标签页换不动') } catch (e2) { console.error('  !! chrome 重开失败:' + e2.message); throw e2 } }
                    flush()
                    continue
                }
                out.routes[vp.name][route] = Object.assign({ http: doc ? doc.status : null, ready }, val)
                if (n % 10 === 0) { console.error(`  · ${vp.name} ${n}/${routes.length} …`); flush() }
            }
            console.error(`· ${vp.name}: measured ${Object.keys(out.routes[vp.name]).length} routes`)
            flush()
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ★ 覆盖断言 —— 零必须是一次测量,不是一次缺席 ★
    // ════════════════════════════════════════════════════════════════════════
    let ran = 0
    assertPopulation(SELF, '量到的视口', out.viewports.length, 2); ran++
    if (MODE === 'spec') {
        const v0 = out.spec[out.viewports[0]]
        assertPopulation(SELF, '取样页上认出来的变体小节', (v0.sectionsFound || []).length, 4); ran++
        const C = v0.sections.C || []
        assertPopulation(SELF, 'variant C 那一节里量到的控件', C.length, 1); ran++
        for (const need of ['input.lib', 'select.trigger', 'textarea.lib', 'label.lib']) {
            assertPopulation(SELF, `variant C · ${need}`, C.filter((r) => r.role === need).length, 1); ran++
        }
        // 双向钉住:DOM 数出来的 ↔ 源码里独立数出来的
        const src = readFileSync(join(ROOT, 'app/brand-sampler/Variant.tsx'), 'utf8')
        const srcInputs = (src.match(/<Input(?=[\s/>])/g) || []).length
        assertPinned(SELF, 'variant C 的 <Input> 数(DOM ↔ Variant.tsx 里的 <Input>)',
            C.filter((r) => r.role === 'input.lib').length, srcInputs,
            'Variant.tsx 那张表单每个变体渲染一遍,所以 C 那一节的数应当等于源码里的开标签数。'); ran++
        const srcTextarea = (src.match(/<Textarea(?=[\s/>])/g) || []).length
        assertPinned(SELF, 'variant C 的 <Textarea> 数(DOM ↔ 源码)',
            C.filter((r) => r.role === 'textarea.lib').length, srcTextarea, ''); ran++
    } else if (MODE === 'edit') {
        const dv = out.routes[out.viewports[0]]
        const okRoutes = Object.values(dv).filter((r) => !r.failed)
        assertPopulation(SELF, '量到的可编辑表路由', okRoutes.length, 1); ran++
        assertPopulation(SELF, '找到的 <EditableTable> 宿主文件', (out.notes.editableTableFiles || []).length, 1); ran++
        assertPopulation(SELF, '点下去的「编辑」按钮', okRoutes.reduce((a, r) => a + (r.click ? r.click.nClicked : 0), 0), 1); ran++
        // ★ 双向钉住:每一条路由都必须【要么点出了控件,要么明写 clickHadNoEffect】。
        //   没有第三种,而"第三种"正是一次沉默会长成的样子。
        assertPinned(SELF, '有结论的路由 ↔ 量到的路由',
            okRoutes.filter((r) => r.clickHadNoEffect === true || r.controlsInTablesAfter > r.controlsInTablesBefore).length,
            okRoutes.length, '一条既没点出控件、又没被记成 clickHadNoEffect 的路由,是一次沉默。'); ran++
    } else {
        const dv = out.routes[out.viewports[0]]
        const okRoutes = Object.values(dv).filter((r) => !r.failed)
        assertPopulation(SELF, '量到的路由', okRoutes.length, 1); ran++
        const allRows = okRoutes.flatMap((r) => r.rows)
        assertPopulation(SELF, '量到的控件读数', allRows.length, 1); ran++
        assertPopulation(SELF, '原生单行控件(input.text/date/number + select.native)',
            allRows.filter((r) => ['input.text', 'input.date', 'input.number', 'select.native'].includes(r.role)).length, 1); ran++
        assertPopulation(SELF, '量到的表格', okRoutes.reduce((a, r) => a + r.tables.length, 0), 1); ran++
        assertPopulation(SELF, '住在表格里的控件',
            allRows.filter((r) => r.tbl >= 0 && !r.role.startsWith('label')).length, 1); ran++
        assertPopulation(SELF, '量到的表体行高读数',
            okRoutes.reduce((a, r) => a + r.tables.reduce((b, t) => b + t.rowH.length, 0), 0), 1); ran++
        // ★ 水合:每一条量到的路由都必须是水合过的 —— 否则读数是 SSR 的静态影子
        const notHydrated = okRoutes.filter((r) => r.hydrationMark !== true).length
        assertPinned(SELF, '水合过的路由 ↔ 量到的路由', okRoutes.length - notHydrated, okRoutes.length,
            '一条没水合的路由上,客户端组件(Radix 的 SelectTrigger 等)根本没渲染 —— 读数会把它读成不存在。'); ran++
    }
    console.error(`· coverage assertions run: ${ran}`)

    flush()
    console.log('wrote ' + OUT_FILE)
}

main().then(cleanup).catch(async (e) => {
    console.error('\n!! survey-controls failed:', e.message)
    await cleanup()
    process.exitCode = process.exitCode || 2
})
