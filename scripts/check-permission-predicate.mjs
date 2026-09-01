#!/usr/bin/env node
// scripts/check-permission-predicate.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// 【它回答三个问题,而且只回答这三个】NAV-REG-1
//
//   ① 求值只有一处吗?  —— 除 lib/modules.ts 的 allows() 之外,还有没有别的地方
//                          拿权限码去比对一份权限清单。
//   ② 一个功能能属于几个模块吗?—— FUNCTIONS 里至少有一条声明了多于一个属主,
//                          而且它的判据【只有一份】;跨模块页面不许再手写入口。
//   ③ 进不去的东西说出来了吗?—— 导航层对进不去的项渲染「受限」,而不是过滤掉。
//
// 【为什么这三条要用一个脚本盯着,而不是靠人记住】
// 三条都是【看不见的坏】:漏了不会报错,不会白屏,只会让某个人少看见一样东西,
// 或者对着一个他其实读得到的数字显示「受限」。这个仓库为第二种付过账 ——
// EQP-2d:库里的视图放宽了(arm_permission_widen),而首页那一份判断没跟上,
// 于是一个【拿得到行】的读者在屏幕上看见「受限」。两份实现迟早各错一次。
//
// 与 check-masked-columns 同一类:纯文本、不连库、进 `npm run build`,秒级。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const problems = []

// ── 收集 app/ 与 lib/ 下的所有 ts/tsx ──────────────────────────────────────
function walk(dir, out = []) {
    for (const e of readdirSync(dir)) {
        if (e === 'node_modules' || e === '.next' || e.startsWith('.')) continue
        const p = join(dir, e)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (p.endsWith('.ts') || p.endsWith('.tsx')) out.push(p)
    }
    return out
}
const FILES = [...walk(join(ROOT, 'app')), ...walk(join(ROOT, 'lib'))]
const rel = (p) => p.slice(ROOT.length + 1)
const read = (p) => readFileSync(p, 'utf8')
// 注释不算实现 —— 讲这条规矩的注释里必然会出现被禁的写法。
const stripComments = (s) =>
    s.replace(/\/\*[\s\S]*?\*\//g, '').split('\n').filter((l) => !/^\s*(\/\/|\*)/.test(l)).join('\n')

// ── ① 求值只有一处 ─────────────────────────────────────────────────────────
// 判据:除 lib/modules.ts 外,任何文件都不得把一个权限码拿去比对一份清单。
// 单码判断要走 lib/permissions.ts 的 can(),谓词要走 allows() —— 两者都最终
// 落在 allows() 那一个表达式上。
const EVALUATOR = 'lib/modules.ts'
const BANNED = [
    /\bperms\s*\.\s*includes\s*\(/,
    /\bpermissions\s*\.\s*includes\s*\(/,
    /\bmyPermissions\s*\.\s*includes\s*\(/,
]
for (const f of FILES) {
    if (rel(f) === EVALUATOR) continue
    const body = stripComments(read(f))
    for (const re of BANNED) {
        if (re.test(body)) {
            problems.push({
                axis: '① 求值只有一处',
                msg: `${rel(f)}:自己比对了一份权限清单(${re.source})—— 求值只许在 ${EVALUATOR} 的 allows() 里。`,
            })
        }
    }
}
// allows() 必须真的只定义一次
const modulesSrc = read(join(ROOT, 'lib/modules.ts'))
const defCount = (modulesSrc.match(/export function allows\s*\(/g) ?? []).length
if (defCount !== 1) {
    problems.push({ axis: '① 求值只有一处', msg: `lib/modules.ts:allows() 定义了 ${defCount} 次,应当恰好 1 次。` })
}

// ── ② 一个功能可以属于几个模块 ─────────────────────────────────────────────
const fnBlock = modulesSrc.slice(modulesSrc.indexOf('export const FUNCTIONS'))
const entries = [...fnBlock.matchAll(/href:\s*'([^']+)'[\s\S]*?modules:\s*\[([\s\S]*?)\][\s\S]*?permission:/g)]
if (entries.length === 0) {
    problems.push({ axis: '② 一个功能几个模块', msg: 'lib/modules.ts:FUNCTIONS 里一条都没有 —— 这个机制不存在了。' })
}
const multi = entries.filter((m) => (m[2].match(/'/g) ?? []).length / 2 >= 2)
if (multi.length === 0) {
    problems.push({
        axis: '② 一个功能几个模块',
        msg: 'FUNCTIONS 里没有任何一条声明了【多于一个】属主模块 —— 那正是本机制存在的理由(/margin)。',
    })
}
// 每条 FUNCTIONS 条目的判据只有一份(条目的边界是【下一条的起点】,不是一个定长窗口 ——
// 定长窗口会把下一条的 permission 数进来,那正是本检查第一版的假阳性)。
for (let i = 0; i < entries.length; i++) {
    const from = entries[i].index
    const to = i + 1 < entries.length ? entries[i + 1].index : fnBlock.length
    const n = (fnBlock.slice(from, to).match(/permission:/g) ?? []).length
    if (n !== 1) {
        problems.push({ axis: '② 一个功能几个模块', msg: `FUNCTIONS 的 ${entries[i][1]} 声明了 ${n} 份 permission,应当恰好 1 份。` })
    }
}
// 跨模块功能【不许】再被手写成入口 —— 那是 OPS-15 说的第二份定义。
const REGISTRY_RENDERERS = new Set([
    'app/finance/Subnav.tsx',
    'app/finance/SubnavClient.tsx',
    'app/processing/page.tsx',
    'app/components/NavLinks.tsx',
    'app/components/TopNav.tsx',
])
for (const m of entries) {
    const href = m[1]
    for (const f of FILES) {
        const r = rel(f)
        if (REGISTRY_RENDERERS.has(r)) continue
        if (r.startsWith(`app${href}/`) || r === `app${href}/page.tsx`) continue // 功能自己那一页
        const body = stripComments(read(f))
        if (new RegExp(`<Link[^>]*href=["']${href}["']`).test(body)) {
            problems.push({
                axis: '② 一个功能几个模块',
                msg: `${r}:手写了一个 <Link href="${href}"> —— 跨模块功能的入口必须由注册表派生(getFunctionAccess),` +
                     '否则入口与权限之间没有任何东西保证同步。',
            })
        }
    }
}

// ── ③ 进不去的渲染成具名的「受限」,不是过滤掉 ─────────────────────────────
// 导航层必须【拿到全部】再标记,而不是先过滤。getModuleAccess 返回 MODULES.map,
// 一旦有人把 .filter 加回来,导航条又会对进不去的模块整个消失。
const accessSrc = read(join(ROOT, 'lib/moduleAccess.ts'))
if (!/MODULES\s*\.\s*map\s*\(/.test(accessSrc)) {
    problems.push({ axis: '③ 具名的受限', msg: 'lib/moduleAccess.ts:getModuleAccess 不再是 MODULES.map —— 它必须返回【全部】模块。' })
}
if (/MODULES\s*\.\s*filter\s*\(/.test(stripComments(accessSrc))) {
    problems.push({
        axis: '③ 具名的受限',
        msg: 'lib/moduleAccess.ts:MODULES.filter 回来了 —— R4 的全部内容就是【不过滤】(Tim 的 D5)。',
    })
}
// 三处渲染层都要会画那句「受限」,而且用的是既有的那一套词
for (const r of ['app/components/NavLinks.tsx', 'app/finance/SubnavClient.tsx', 'app/processing/page.tsx']) {
    // 【必须去掉注释再看】讲这条规矩的注释里必然写着 common.restricted ——
    // 第一版就是这样被自己的注释骗过去的:把那句「受限」从 JSX 里删掉,检查照旧是绿的。
    const body = stripComments(read(join(ROOT, r)))
    if (!body.includes('data-module-restricted')) {
        problems.push({ axis: '③ 具名的受限', msg: `${r}:没有 data-module-restricted 标记 —— 按角色的可达性检查靠它,不靠认文案。` })
    }
    if (!body.includes("common.restricted") || !body.includes('dashboard.restrictedHint')) {
        problems.push({
            axis: '③ 具名的受限',
            msg: `${r}:没有同时用上 common.restricted 与 dashboard.restrictedHint —— 同一个意思的第二套说法就是下一次漂移。`,
        })
    }
}

// ── 判词 ───────────────────────────────────────────────────────────────────
if (problems.length === 0) {
    console.log(`✓ 权限谓词:求值一处(allows)· FUNCTIONS ${entries.length} 条(${multi.length} 条跨模块)· 受限具名`)
    process.exit(0)
}
console.log('')
console.log('✗ NAV-REG-1 的三条不变量被破坏了:')
for (const p of problems) console.log(`     [${p.axis}] ${p.msg}`)
console.log('')
console.log('【为什么它非红不可】这三条漏了都不会报错:')
console.log('  ① 两份求值 → 屏幕与数据库对同一个人给出不同答案(EQP-2d 实测过);')
console.log('  ② 手写入口 → 入口与权限各错一次,而没有任何东西会说出来(OPS-15);')
console.log('  ③ 过滤代替标记 → 一个人看不见一个模块的存在,而"不存在"与"你进不去"')
console.log('     在屏幕上一模一样(moduleGuard 抬头那条病的导航版)。')
process.exit(1)
