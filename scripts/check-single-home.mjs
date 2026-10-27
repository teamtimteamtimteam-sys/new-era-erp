#!/usr/bin/env node
// scripts/check-single-home.mjs
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-1(Tim 2.1,2026-10-26)· 每一条二级条目在菜单里【只有一个位置】
// ════════════════════════════════════════════════════════════════════════════
// Tim 的原话(docs/system-map.md 2.1):「EVERY SECOND-LEVEL PAGE HAS EXACTLY ONE PLACE IN THE MENU. No menu entry may belong
// to more than one top-level module; other modules reach it through links on related document pages. A build check enforces
// it: any registry entry declaring two or more modules fails the build.」—— 这一支就是那道构建闸。
//
// 【瞄准 · AIM】
//   我读的是      :lib/modules.ts —— 两条互不依赖的路:① 把它 import 进来读 FUNCTIONS / MODULES 的值;
//                   ② 剥掉注释后的源码文本里 FUNCTIONS 那一段的每一个 `href:` 与它后面的 `modules: [...]`。
//   我声称管的是   :注册表里每一条条目恰好声明一个属主模块,而且那个模块是 MODULES 里的一个 id;
//                   以及每一个模块名下至少有一条菜单条目(一个空模块在顶栏上是一张空下拉)。
//   两者不同之处   :★ 我只看【注册表】。一个页面自己手写一排"模块内导航"、把另一个模块的页画成自己的兄弟,
//                   我看不见 —— 那一类由 check-nav-routes 与人工走查管。★ 我也不判"它被放在了【对的】那个家" ——
//                   哪个家是对的是 Tim 的裁定(docs/system-map.md 2.2 · 2.3),不是一个算得出来的性质。
//
// 判据:
//   ① 每一条 FUNCTIONS 条目 `modules.length === 1`;
//   ② 那一个 id 在 MODULES 里;
//   ③ MODULES 里每一个模块至少有一条【菜单】条目(不带 parent);
//   ④ 覆盖断言(AGENTS.md「覆盖率本身必须是一条断言」):import 读到的条目数 = 文本里数到的 `href:` 数,且 > 0;
//      文本那一路自己也判一遍 ①,两路的违规名单必须逐字相同 —— 一路瞎了,另一路会说出来。
//
// 故障注入(每一格都要红在它说的那一行;CHECK_SINGLE_HOME_FAULT=…):
//   multi:<href>   把那一条在【两条路上】都改成两个属主 → 必须 exit 1 并点名它
//   textonly:<href> 只在文本那一路上改 → 两路名单对不上 → 必须 exit 2(量具自己说它没量准)
//   blind          文本那一路读出 0 个 href → 必须 exit 2,不许报"干净"
//   unknown:<href> 把那一条的家改成一个 MODULES 里没有的 id → 必须 exit 1
// 落地时的真注入(把 lib/modules.ts 里 /inbound 改成两个属主,跑 npm run build)记在 docs/surveys/SYSTEM-MAP-1/。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-single-home'
const ROOT = process.cwd()
const FAULT = process.env.CHECK_SINGLE_HOME_FAULT ?? ''
const [faultKind, faultHref] = FAULT.includes(':') ? [FAULT.slice(0, FAULT.indexOf(':')), FAULT.slice(FAULT.indexOf(':') + 1)] : [FAULT, '']

// ── 路 ①:import ─────────────────────────────────────────────────────────────
const reg = await import(pathToFileURL(join(ROOT, 'lib/modules.ts')).href)
let fns = reg.FUNCTIONS.map((f) => ({ href: f.href, modules: [...f.modules], parent: f.parent ?? null }))
const moduleIds = new Set(reg.MODULES.map((m) => m.id))
if (faultKind === 'multi' || faultKind === 'unknown') {
    const hit = fns.find((f) => f.href === faultHref)
    if (!hit) { console.error(`✗ ${SELF}:注入点名的 ${faultHref} 不在注册表里 —— 注入没有落地`); process.exit(2) }
    hit.modules = faultKind === 'multi' ? [hit.modules[0], 'finance' === hit.modules[0] ? 'people' : 'finance'] : ['no-such-module']
}

// ── 路 ②:源码文本 ──────────────────────────────────────────────────────────
const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/.*$/gm, '$1')
const src = stripComments(readFileSync(join(ROOT, 'lib/modules.ts'), 'utf8'))
const block = src.slice(src.indexOf('export const FUNCTIONS'), src.indexOf('export function functionsForModule'))
let textEntries = [...block.matchAll(/href:\s*'([^']+)'[\s\S]*?modules:\s*\[([^\]]*)\]/g)]
    .map((m) => ({ href: m[1], count: (m[2].match(/'[^']*'/g) ?? []).length }))
if (faultKind === 'blind') textEntries = []
if (faultKind === 'multi' || faultKind === 'textonly') {
    const hit = textEntries.find((e) => e.href === faultHref)
    if (hit) hit.count = 2
}
const roughHrefs = faultKind === 'blind' ? 0 : (block.match(/href:\s*'/g) ?? []).length

assertPopulation(SELF, 'import 读到的 FUNCTIONS 条目', fns.length)
assertPopulation(SELF, '文本里读到的 FUNCTIONS 条目', textEntries.length)
assertPinned(SELF, 'import 的条目数 ↔ 文本里的 href: 数', fns.length, roughHrefs, '两条路数出来的条目不一样多 —— 有一种写法其中一路没认出来')
assertPinned(SELF, '文本里配上了 modules 的条目 ↔ 文本里的 href: 数', textEntries.length, roughHrefs, '有 href 没配上 modules —— 解析器漏了一种写法')

// ── 判 ──────────────────────────────────────────────────────────────────────
const problems = []
const multiByImport = fns.filter((f) => f.modules.length !== 1).map((f) => f.href).sort()
const multiByText = textEntries.filter((e) => e.count !== 1).map((e) => e.href).sort()
assertPinned(SELF, '两条路判出来的违规名单', multiByText.join(' · ') || '(无)', multiByImport.join(' · ') || '(无)',
    'import 与文本对"谁有不止一个家"给了不同的答案 —— 其中一路瞎了')
for (const f of fns) {
    if (f.modules.length !== 1) problems.push(`${f.href} 声明了 ${f.modules.length} 个属主模块(${f.modules.join(', ')}) —— 2.1:恰好一个`)
    else if (!moduleIds.has(f.modules[0])) problems.push(`${f.href} 的家 ${f.modules[0]} 不是 MODULES 里的一个 id`)
}
for (const id of moduleIds) {
    if (!fns.some((f) => !f.parent && f.modules.length === 1 && f.modules[0] === id)) {
        problems.push(`模块 ${id} 名下一条菜单条目都没有 —— 它在顶栏上会是一张空下拉`)
    }
}

if (problems.length) {
    console.error(`✗ ${SELF}:${problems.length} 处`)
    for (const p of problems) console.error(`    ${p}`)
    console.error('  ☞ 每一条二级条目只有一个家(Tim 2.1,docs/system-map.md)。别的模块要够到它,在相关单据页上放一条链接,不要给它第二个属主。')
    process.exit(1)
}
console.log(`✓ ${SELF}:${fns.length} 条注册表条目(两条路数得一样多)各有恰好一个家 · ${moduleIds.size} 个模块各有菜单条目`)
