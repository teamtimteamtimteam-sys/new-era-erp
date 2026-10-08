// scripts/check-action-view-declared.mjs
// ════════════════════════════════════════════════════════════════════════════
// MES-5b-1(2026-10-08,MES-5a-2 close-out 裁定 f · MES-5b Step 0 Q30,Tim):
// 【一个动作码声明的"要哪几个查看码之一",每一个都真的是一张【用这个码】的页面的门】
// ════════════════════════════════════════════════════════════════════════════
//
// 规矩(docs/role-matrix.md 常设规矩):一个动作码只与【用它的那一页】的查看码一起授。数据库里有三处执行它 ——
// set_role_permissions(ACTION_REQUIRES_VIEW)· role_permissions 引导的自检 · fixture 257 FCHECK —— 而三处读的都是
// permissions.requires_view_any 那一列。**那一列本身对不对,数据库答不了:页面在仓库里,不在库里。** 这支脚本答这一半:
//   ① 每一个声明的查看码 V(或这个码自己 C),都至少是一张【用 C 的页面】的门里的一个码;
//   ② 每一个被某张有门的页面用到的动作码都声明了(没声明 = 那三处对它不设防);
//   ③ 一个声明了、却没有任何一张页面用到的码,是一份过期的声明(它的页面被删了或改了门)。
// 「用」= 页面 page.tsx 或它经相对路径 / '@/app/…' 一路 import 进来的 app/ 下的文件里,出现那个码的字面量(注释不算)。
// 「门」= 页面里的 requireModule(MOD.x) / requireFunction(FN.x) / requireEditPermission('码', …) / requireManagePermissions(),
//   按 lib/modules.ts 的注册表展开成码(all · any · widen 三段都算 —— 持其中一个是进得去的必要条件之一);
//   少数页面自己 can('码') 后渲染拒绝,列在 PAGE_GATES(带理由,并核对那一页真的有那一句)。
// 运行时向库要的码(po_category_raise_code / review_approval_code 回答"要哪一个码")不是字面量,列在 DYNAMIC(带理由,
//   并核对那个 RPC 名字真的在那一页的闭包里)。一张页面的门本身也算一次"用"。
//
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :`db/tables/permissions.sql` 的声明块 · `app/**/page.tsx` 与它们 import 进来的 app/ 文件 · `lib/modules.ts` 的注册表。
//   我声称管的是   :动作码的声明与【页面的门】对得上 —— 声明的每一个码都是一张用这个动作的页面的门。
//   两者不同之处   :★ 我答的是「源码里这个码出现在哪一页、那一页的门写的是什么」,**不是**「一个会话真的进得去」(那是冒烟)。
//                   一个码只经服务端函数用、页面上一个字面量都没有的,我看不见 —— DYNAMIC 那几条就是这一类,手写登记。
// ==========================================================================
//
// 退出码:0 干净 · 1 违规 · 2 量具坏了(selfproof 的三档)。
// 故障注入:CHECK_AVD_FAULT=bogus-view 把一个码的声明换成一张不用它的页面的门 → 必须 exit 1;
//           CHECK_AVD_FAULT=blind 让 import 解析一个文件都读不到 → 必须 exit 2。

import { readFileSync, readdirSync, statSync, writeFileSync, unlinkSync, existsSync } from 'node:fs'
import { join, relative, dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { assertPopulation } from './lib/selfproof.mjs'

const SCRIPT = 'check-action-view-declared'
const ROOT = process.cwd()
const APP = join(ROOT, 'app')
const FAULT = process.env.CHECK_AVD_FAULT ?? ''

// ── 少数页面不经 require*,自己 can('码') 后渲染拒绝(读源码核对,不是信这张表)──────────────
const PAGE_GATES = {
    'app/settings/import/page.tsx': { code: 'action.bulk_import', reason: '批量导入页自己 can(action.bulk_import),拿不到就渲染拒绝(IMPORT-1)' },
}

// ── 不是字面量的码:运行时拼出来的。核对前缀真的在那个文件里 ────────────────────────────────
// 判据:那个 RPC 的名字作为字面量出现在页面的闭包里,或闭包直接 import 的 lib/ 文件里(只看一层,lib 不往下追 ——
//   lib/modules.ts 这种共用文件里满是码,往下追就把每一张页面都算成"用了每一个码")。
const DYNAMIC = [
    { codes: ['action.raise_po_consumables', 'action.raise_po_equipment', 'action.raise_po_office'], marker: "'po_category_raise_code'",
      reason: '开单码按采购单的类别向库要:po_category_raise_code(APR-10),页面不抄第二份对照表' },
    { codes: ['action.approve_review'], marker: "'review_approval_code'",
      reason: '批一张评估要哪一个码向库要:review_approval_code(ROLE-1 Q5 —— CFO 是提交人或主角时换成 action.hr_reviews)' },
]

// ── 声明:db/tables/permissions.sql 的那一块 UPDATE ──────────────────────────────────────────
const permSrc = readFileSync(join(ROOT, 'db/tables/permissions.sql'), 'utf8')
const actionCodes = [...permSrc.matchAll(/\('(action\.[a-z_]+)',\s*'action',/g)].map((m) => m[1])
const declBlock = permSrc.slice(permSrc.indexOf('UPDATE public.permissions p SET requires_view_any'))
const declared = new Map()
for (const m of declBlock.matchAll(/\('(action\.[a-z_]+)',\s*ARRAY\[([^\]]*)\]\)/g)) {
    declared.set(m[1], [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]))
}
if (FAULT === 'bogus-view') declared.set('action.wo_release', ['module.hr.view'])

// ── 注册表:把 lib/modules.ts 原样 import 进来(它没有 import;落成一个临时 .mts 免得 typeless 警告)───────────
const probe = join(ROOT, 'lib', '__avd_probe.mts')
let reg
try {
    writeFileSync(probe, readFileSync(join(ROOT, 'lib/modules.ts'), 'utf8'))
    reg = await import(pathToFileURL(probe).href)
} finally {
    if (existsSync(probe)) unlinkSync(probe)
}
const specCodes = (spec) => (typeof spec === 'string' ? [spec] : [...(spec.all ?? []), ...(spec.any ?? []), ...(spec.widen ?? [])])

// ── 源码:去注释(块注释与行注释;字符串里的 // 由"前面是空白或行首"挡住)────────────────────────────
const strip = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`\w])\/\/[^\n]*/g, '$1')

function walk(dir, out = []) {
    for (const n of readdirSync(dir)) {
        const p = join(dir, n)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (n === 'page.tsx') out.push(p)
    }
    return out
}

const cache = new Map()
function fileOf(spec, from) {
    let base
    if (spec.startsWith('@/app/')) base = join(ROOT, spec.slice(2))
    else if (spec.startsWith('./') || spec.startsWith('../')) base = resolve(dirname(from), spec)
    else return null
    for (const c of [base, base + '.tsx', base + '.ts', join(base, 'index.tsx'), join(base, 'index.ts')]) {
        if (existsSync(c) && statSync(c).isFile() && c.startsWith(APP)) return c
    }
    return null
}
// 一张页面 import 进来的 app/ 文件的闭包(含它自己)
function closure(page) {
    const seen = new Set()
    const stack = [page]
    while (stack.length) {
        const f = stack.pop()
        if (seen.has(f)) continue
        seen.add(f)
        if (FAULT === 'blind') continue
        let src = cache.get(f)
        if (src === undefined) { src = strip(readFileSync(f, 'utf8')); cache.set(f, src) }
        for (const m of src.matchAll(/(?:from|import)\s*\(?\s*['"]([^'"]+)['"]/g)) {
            const g = fileOf(m[1], f)
            if (g) stack.push(g)
        }
    }
    return [...seen]
}
const srcOf = (f) => { let s = cache.get(f); if (s === undefined) { s = strip(readFileSync(f, 'utf8')); cache.set(f, s) } return s }

// ── 每一张页面:它的门、它用到的动作码 ────────────────────────────────────────────────────
const pages = walk(APP)
const problems = []
let gated = 0
let filesRead = 0
const usesByCode = new Map()   // code → [{page, gate:Set}]
for (const page of pages) {
    const rel = relative(ROOT, page)
    const src = srcOf(page)
    const gate = new Set()
    for (const m of src.matchAll(/requireModule\(\s*MOD\.(\w+)\s*\)/g)) {
        const s = reg.MOD[m[1]]
        if (!s) problems.push(`${rel}:requireModule(MOD.${m[1]}) 在注册表里查不到`)
        else specCodes(s.permission).forEach((c) => gate.add(c))
    }
    for (const m of src.matchAll(/requireFunction\(\s*FN\.(\w+)\s*\)/g)) {
        const s = reg.FN[m[1]]
        if (!s) problems.push(`${rel}:requireFunction(FN.${m[1]}) 在注册表里查不到`)
        else specCodes(s.permission).forEach((c) => gate.add(c))
    }
    for (const m of src.matchAll(/requireEditPermission\(\s*'([^']+)'/g)) gate.add(m[1])
    if (/requireManagePermissions\(\s*\)/.test(src)) gate.add('action.manage_permissions')
    const pg = PAGE_GATES[rel]
    if (pg) {
        if (!src.includes(`can('${pg.code}')`)) problems.push(`PAGE_GATES 过期:${rel} 里没有 can('${pg.code}')(${pg.reason})`)
        else gate.add(pg.code)
    }
    if (gate.size > 0) gated++
    const files = closure(page)
    filesRead += files.length
    // 一张页面的门本身就是对那个码的一次"用"(/settings/roles 由 requireManagePermissions() 把门,页面里不必再写一遍字面量)
    const used = new Set([...gate].filter((c) => c.startsWith('action.')))
    const libs = new Set()
    for (const f of files) {
        const s = srcOf(f)
        for (const m of s.matchAll(/['"`](action\.[a-z_]+)['"`]/g)) used.add(m[1])
        for (const m of s.matchAll(/(?:from|import)\s*\(?\s*['"]@\/lib\/([^'"]+)['"]/g)) {
            for (const c of [join(ROOT, 'lib', m[1] + '.ts'), join(ROOT, 'lib', m[1] + '.tsx'), join(ROOT, 'lib', m[1])]) {
                if (existsSync(c) && statSync(c).isFile()) { libs.add(c); break }
            }
        }
    }
    for (const d of DYNAMIC) {
        if ([...files, ...libs].some((f) => srcOf(f).includes(d.marker))) d.codes.forEach((c) => used.add(c))
    }
    for (const c of used) {
        if (!usesByCode.has(c)) usesByCode.set(c, [])
        usesByCode.get(c).push({ page: rel, gate })
    }
}

assertPopulation(SCRIPT, 'app/ 下的 page.tsx', pages.length)
assertPopulation(SCRIPT, '解析出门的页面', gated)
assertPopulation(SCRIPT, '目录里的动作码', actionCodes.length)
assertPopulation(SCRIPT, '声明块里的动作码', declared.size)
assertPopulation(SCRIPT, '在页面里找到用处的动作码', usesByCode.size)
// 一张页面的 import 闭包至少有它自己;读到的文件数必须明显多于页面数,否则 import 解析瞎了
if (filesRead <= pages.length) {
    console.error(`✗ ${SCRIPT}:量具坏了 —— ${pages.length} 张页面只读到 ${filesRead} 个文件,import 解析一个都没有跟进去。`)
    process.exit(2)
}
for (const d of DYNAMIC) {
    if (!d.codes.some((c) => (usesByCode.get(c) ?? []).length > 0)) problems.push(`DYNAMIC 过期:${d.marker} 在任何一张页面里都找不到(${d.reason})`)
}

// ── 判 ─────────────────────────────────────────────────────────────────────────────────
const info = []
for (const c of actionCodes) {
    const uses = (usesByCode.get(c) ?? []).filter((u) => u.gate.size > 0)
    const decl = declared.get(c)
    if (!decl) {
        if (uses.length > 0) problems.push(`${c}:${uses.length} 张有门的页面用它(${uses.map((u) => u.page).join(', ')}),却没有声明 requires_view_any —— 数据库那三处对它不设防`)
        continue
    }
    if (uses.length === 0) { problems.push(`${c}:声明了 ${decl.join(',')},可是没有任何一张有门的页面用它 —— 一份过期的声明`); continue }
    for (const v of decl) {
        const hit = uses.filter((u) => u.gate.has(v))
        if (hit.length === 0) problems.push(`${c}:声明的 ${v} 不是任何一张用它的页面的门(用它的页面:${uses.map((u) => u.page + ' [' + [...u.gate].join('|') + ']').join(', ')})`)
    }
    const undeclaredGates = new Set()
    for (const u of uses) if (![...u.gate].some((g) => decl.includes(g))) [...u.gate].forEach((g) => undeclaredGates.add(g))
    if (undeclaredGates.size) info.push(`${c}:有用它的页面,其门里没有一个声明了的码(${[...undeclaredGates].join(', ')})—— 持那些码而不持声明码的人用不到那几页的这个动作(按"任一"的读法这是允许的)`)
}
for (const c of declared.keys()) if (!actionCodes.includes(c)) problems.push(`声明块里的 ${c} 不在目录里`)

if (problems.length) {
    console.error(`✗ ${SCRIPT}:${problems.length} 处`)
    for (const p of problems) console.error('  · ' + p)
    process.exit(1)
}
console.log(`✓ ${SCRIPT}:${declared.size} 个动作码的声明都是一张用它的页面的门(${pages.length} 张页面 · ${gated} 张解析出门 · ${filesRead} 个文件 · ${usesByCode.size} 个码找到用处)`)
if (info.length) for (const i of info) console.log('  ℹ ' + i)
