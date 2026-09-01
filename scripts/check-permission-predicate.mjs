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
// ④ 要【报行号】,所以它的那一份去注释【不许删行】—— 删行的版本会让报出来的行号
// 比真实位置小上几行(实测:种在第 15 行,报成第 13 行)。一条报错行号的检查,
// 报错了行号就等于教人不信它。所以块注释按原样换成等量换行,行注释整行留空。
const stripCommentsKeepLines = (s) =>
    s.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
     // 行尾注释也要去掉,但【别把 https:// 当成注释】—— 冒号后面的 // 是 URL。
     // (④ 的两条判据都锚在行首,所以行尾注释本来就不会误报;去掉它是为了
     //  让"这个变量后面还被提起吗"那一问不被注释里的字骗过去。)
     .split('\n').map((l) => (/^\s*(\/\/|\*)/.test(l) ? '' : l.replace(/(?<!:)\/\/.*$/, '')))
     .join('\n')

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

// ── ④ 拒绝的返回值不许丢 ───────────────────────────────────────────────────
// GUARD-FIX-1(2026-09-01)。守卫【算出】一屏拒绝,由调用方【返回】它:
//     const denied = await requireModule(MOD.finance)
//     if (denied) return denied
// 少了第二行,那一屏就被算出来又扔掉,页面照常渲染 —— 于是"你不能进"在屏幕上
// 长成"这里没有东西",正是 moduleGuard 抬头那条病本身,只不过发生在它的调用点。
// 实测(修之前,稳定别名上,给一个没有 module.finance.view 的角色):
//   /finance/claims        200,整页渲染,23,493 字节;有权限的人看到 23,696 字节
//                          —— 两块屏差 203 字节,肉眼与机器都分不出来
//   /finance/cash-forecast 500(RPC 拒绝 → 页面 `if (error) throw`)
// 两个都不是"你不能进"。它们活了四天,因为唯一看得见这类缺陷的检查(--reach)
// 是按需跑的,而那两刀落地之后没有人跑过它。
//
// 【守卫名单是【推导】出来的,不是写死的】写死四个名字,第五个守卫写出来的那天
// 就漏了 —— 那正是本条不变量自己要杀的病高一层的样子。所以名单来自两个守卫文件里
// 的 `export async function require*`,新守卫写出来的当天就被覆盖。
// 而让这条推导成立的是下面那条:守卫【只许】定义在这两个文件里。
//
// 【它证明什么,不证明什么 —— 绿了不等于什么】
//   看得见:调用点写成【语句】(await requireX(...) 独占一行,没有接住);
//           以及接住了却【再也没被提起】(const denied = ... 之后全文再无 denied)。
//   看不见:别名与间接调用(const g = requireModule; await g(...))、
//           把守卫结果传进另一个函数再由那边决定返回、
//           以及跨文件的包装。这三种本仓库现在一个都没有,但检查【看不见它们】——
//           所以绿的构建不等于"守卫一定接对了",只等于"没有以上两种写法"。
//           (与 CCY-VERIFY 同一个 register:说清楚自己证明的边界。)
//   ④ 的第二条【故意保守】:变量名在全文再出现一次就算用了,不追它是不是真的
//   被 return。宁可漏报也不误报 —— 一条会冤枉人的检查,最后会被人加白名单绕开。
const GUARD_FILES = ['app/components/moduleGuard.tsx', 'app/settings/permissions/guard.tsx']
const GUARD_DEF = /export\s+async\s+function\s+(require[A-Za-z0-9_]*)\s*\(/g
const guardNames = []
for (const gf of GUARD_FILES) {
    for (const m of read(join(ROOT, gf)).matchAll(GUARD_DEF)) guardNames.push(m[1])
}
if (guardNames.length === 0) {
    // 推导不出名字就等于这条检查【什么都没检查】,而它会安静地绿 —— 那比没有更坏。
    problems.push({ axis: '④ 拒绝不许丢', msg: `${GUARD_FILES.join(' 与 ')} 里一个 export async function require* 都没有 —— 守卫名单推导不出来,本条检查失效了。` })
}
// 守卫只许定义在那两个文件里 —— 上面那条推导全靠它才成立。
for (const f of FILES) {
    const r = rel(f)
    if (GUARD_FILES.includes(r)) continue
    for (const m of stripCommentsKeepLines(read(f)).matchAll(GUARD_DEF)) {
        problems.push({
            axis: '④ 拒绝不许丢',
            msg: `${r}:定义了守卫 ${m[1]}() —— 守卫只许住在 ${GUARD_FILES.join(' 或 ')} 里,` +
                 '否则 ④ 的名单推导看不见它,它的调用点就没有人管。' +
                 '要么把它挪进守卫文件,要么【有意地】把这个文件加进 GUARD_FILES 并写明理由。',
        })
    }
}
let guardCallSites = 0
if (guardNames.length > 0) {
    const NAMES = `(?:${guardNames.join('|')})`
    const AS_STATEMENT = new RegExp(`^\\s*await\\s+${NAMES}\\s*\\(`)
    const AS_BINDING = new RegExp(`^\\s*(?:const|let|var)\\s+([A-Za-z0-9_$]+)\\s*=\\s*await\\s+${NAMES}\\s*\\(`)
    for (const f of FILES) {
        const r = rel(f)
        if (GUARD_FILES.includes(r)) continue
        // 【必须去掉注释再看】—— 本条规矩的说明文字里必然写着被禁的那一行。
        // ③ 的第一版就是被自己的注释骗过去的(见上面那段),同一个坑不踩第二次。
        const lines = stripCommentsKeepLines(read(f)).split('\n')
        const CALL = new RegExp(`\\b${NAMES}\\s*\\(`)
        lines.forEach((line, i) => {
            if (CALL.test(line) && !/^\s*import\b/.test(line) && !/\bfrom\s+'/.test(line)) guardCallSites++
            if (AS_STATEMENT.test(line)) {
                problems.push({
                    axis: '④ 拒绝不许丢',
                    msg: `${r}:${i + 1}:守卫当成语句调用了 —— 那一屏拒绝被算出来又扔掉,页面照常渲染。` +
                         '写成 `const denied = await …` 再 `if (denied) return denied`。',
                })
                return
            }
            const b = line.match(AS_BINDING)
            if (b && !new RegExp(`\\b${b[1]}\\b`).test(lines.slice(i + 1).join('\n'))) {
                problems.push({
                    axis: '④ 拒绝不许丢',
                    msg: `${r}:${i + 1}:接住了守卫的返回值 \`${b[1]}\`,之后全文再没提起它 —— ` +
                         '这比不接住更坏,它【看起来是对的】。补上 `if (' + b[1] + ') return ' + b[1] + '`。',
                })
            }
        })
    }
}

// ── 判词 ───────────────────────────────────────────────────────────────────
if (problems.length === 0) {
    console.log(`✓ 权限谓词:求值一处(allows)· FUNCTIONS ${entries.length} 条(${multi.length} 条跨模块)· 受限具名 · 守卫 ${guardNames.length} 支的 ${guardCallSites} 处调用都接住了返回值`)
    process.exit(0)
}
console.log('')
console.log('✗ 权限不变量被破坏了:')
for (const p of problems) console.log(`     [${p.axis}] ${p.msg}`)
console.log('')
console.log('【为什么它非红不可】这四条漏了都不会报错:')
console.log('  ① 两份求值 → 屏幕与数据库对同一个人给出不同答案(EQP-2d 实测过);')
console.log('  ② 手写入口 → 入口与权限各错一次,而没有任何东西会说出来(OPS-15);')
console.log('  ③ 过滤代替标记 → 一个人看不见一个模块的存在,而"不存在"与"你进不去"')
console.log('     在屏幕上一模一样(moduleGuard 抬头那条病的导航版)。')
console.log('  ④ 丢掉拒绝 → "你不能进"渲染成"这里没有东西";GUARD-FIX-1 实测两块屏只差 203 字节。')
process.exit(1)
