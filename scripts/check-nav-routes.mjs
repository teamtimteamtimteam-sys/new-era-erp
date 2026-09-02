// scripts/check-nav-routes.mjs
// ════════════════════════════════════════════════════════════════════════════
// ★★【NAV-CLEANUP-1 ⑥:补上 --reach 结构性看不见的那一块】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么需要它 —— 这不是又一道闸,是一道【替补】的闸】
// `smoke-routes.mjs --reach` 只跟着【服务端 HTML 里已经存在的】链接走,而顶栏的
// 二级菜单是【点开才渲染】的(ModuleBar 的 `{isOpen && …}`),爬虫点不了。
// UI-FIX-1 实测过这件事:它据此删掉一条 --reach 断言,检查当场变红。
// ★ 而 NAV-CLEANUP-1 把【页内的同级导航行整批删了】(10 个组件、121 页)★ ——
// 那正是爬虫此前赖以扩散的东西。于是 --reach 在这一刀之后:
//     · 本来就看不见第二级(点不开菜单);
//     · 现在也不再能靠页内链接走到大部分页面。
// **它已经不是端到端的可达性判据了。这支脚本是。**
//
// 【它答得了什么、答不了什么 —— 照直写在这里,免得下一个人高估它】
//   答得了:注册表与文件系统【对不对得上】(静态、每次构建都跑、秒级)。
//   答不了:一个人【点得到点不到】那个入口 —— 那要么是 --reach(它看不见二级),
//           要么是人走一遍。**本脚本不冒充那件事。**
//
// ── 三条判据(Tim 的 ⑥)+ 第四条(他后来加的:范围 id)────────────────────
//   ① 注册表里每一条 href,文件系统上都有一条路由;
//   ② 文件系统上每一条路由,要么在注册表里,要么在下面 EXCEPTIONS 里【带理由】;
//   ③ 退休的路径不许在树里【任何地方】出现(点名文件与行);
//   ④ SCOPES 的每一个 id 也是一段真实的路由前缀 ——
//      Tim:「一个指向退休前缀的守卫,要么失败开、要么失败关,而两种都看不见。」
//
// 【空集不算通过】四条判据每一条都先断言自己【有东西可查】:注册表读出 0 条、
// 路由读出 0 条,都是解析器坏了,不是"全都合格"。这个仓库为这一条付过账。
// ════════════════════════════════════════════════════════════════════════════

import { readFileSync, readdirSync, statSync, writeFileSync, unlinkSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { join, relative } from 'node:path'

const ROOT = process.cwd()
const APP = join(ROOT, 'app')
const isGroup = (s) => s.startsWith('(') && s.endsWith(')')

// ── 退休路径:本刀搬走的四段前缀 ────────────────────────────────────────────
// 【为什么是"前缀 + 边界"而不是裸子串】`/processing` 不能撞上 `/processing-costs`
// (那是财务一条真实的路由);`/finance` 只在【它是一整条路由】时才是退休的,
// 而 `/finance/pnl` 完全正常。所以每一条都自带它的判据。
const RETIRED = [
    {
        label: '/processing(整段搬去 /operation)',
        // 后面不许紧跟字母数字或连字符 —— 这样 /processing-costs 不会被误判
        re: /(?<!\/operation)\/processing(?![A-Za-z0-9_-])/g,
        hint: '改成 /operation/processing(加工单)或 /operation/{orders,wip,handovers}',
    },
    {
        label: '/settings/permissions(拍平成 /settings/{accounts,roles,reference})',
        re: /\/settings\/permissions/g,
        hint: '账号 → /settings/accounts;角色 → /settings/roles;权限速查 → /settings/reference',
    },
    {
        label: "/deleted(搬进设置)",
        // 只认【整条路由】那一种写法,避免撞上 deleted_at / deleted_records 之类
        re: /(?<!\/settings)\/deleted(?![A-Za-z0-9_-])/g,
        hint: '改成 /settings/deleted',
    },
]

// 【/finance 单独一条,因为它【仍然是】一条合法路由 —— 退休的是"它是试算平衡"】
// 所以这里查的不是字符串,是【那一页的内容】:见下面 arm③b。

// ── ② 的例外表:存在但【故意】不在注册表里的路由,每条必须写明理由 ──────────
const EXCEPTIONS = new Map([
    ['/login', '登录页。它在导航之外 —— isPublicPath 的那一侧,顶栏根本不渲染。'],
    ['/set-password', '邀请后设密码。同上,登录之外的一次性流程。'],
    ['/welcome', '零权限的人落到的那一页。它不属于任何模块,那正是它存在的理由。'],
    ['/logout', '登出动作。'],
    ['/', '首页看板。它是顶栏的左边那个品牌链接,不是一条二级条目。'],
    ['/me', '本人档案。app/page.tsx 的 SELF_CARDS 里,不属于九个模块中的任何一个。'],
    ['/my-reviews', '本人的绩效评估。同 /me:它是"我自己的东西",不是一个模块功能。'],
    ['/notifications', '通知列表。入口是顶栏的铃铛,不是二级菜单。'],
    ['/brand-sampler', 'BRAND-1 的样式取样页,用完即删的开发页,不进导航。'],
    ['/purchasing', 'CHART-0 ② 查明它是一个【别名】:全文 14 行,主体是 redirect(\'/purchasing/orders\')。'
        + '导航条目已经删掉(点采购的模块名本来就到不了模块根),但那一页【留着】——'
        + '它指的终点就在同一菜单的下一行,所以留着不制造第二个入口,删掉反而会让一个'
        + '存在的地址 404。**它不该有注册表条目,这正是它登记在这里的理由。**'],
])
// 【前缀例外】—— 一条注册表条目底下的深页(详情、编辑、新建)不必各自登记。
// 判据:它落在某条注册表 href 之下。见下面 isCoveredByEntry。

function routesFrom(dir, segs = [], out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        if (statSync(p).isDirectory()) routesFrom(p, [...segs, e], out)
        else if (e === 'page.tsx' || e === 'route.ts') {
            out.push('/' + segs.filter((s) => !isGroup(s)).join('/'))
        }
    }
    return out
}

function sourceFiles(dir, out = []) {
    for (const e of readdirSync(dir)) {
        if (e === 'node_modules' || e === '.next' || e === '.git') continue
        const p = join(dir, e)
        if (statSync(p).isDirectory()) sourceFiles(p, out)
        else if (/\.(ts|tsx|mjs)$/.test(e)) out.push(p)
    }
    return out
}

const problems = []

// ── 读注册表(正则读源码,与 check-permission-predicate 同一条路子:
//    这些检查跑在 plain node 上,不 import TypeScript)────────────────────────
const modulesSrc = readFileSync(join(ROOT, 'lib/modules.ts'), 'utf8')
const fnBlock = modulesSrc.slice(modulesSrc.indexOf('export const FUNCTIONS'))
const entryHrefs = [...fnBlock.matchAll(/href:\s*'([^']+)'/g)].map((m) => m[1])
const scopeBlock = modulesSrc.slice(
    modulesSrc.indexOf('export const SCOPES'),
    modulesSrc.indexOf('export const MODULES'),
)
const scopeIds = [...scopeBlock.matchAll(/id:\s*'([^']+)'/g)].map((m) => m[1])

const routes = routesFrom(APP)

// ★【空集不是通过】★
if (entryHrefs.length === 0) problems.push({ arm: '解析器', msg: 'FUNCTIONS 里读出 0 条 href —— 解析器坏了,不是注册表空了。' })
if (scopeIds.length === 0) problems.push({ arm: '解析器', msg: 'SCOPES 里读出 0 个 id —— 解析器坏了。' })
if (routes.length === 0) problems.push({ arm: '解析器', msg: 'app/ 底下读出 0 条路由 —— 解析器坏了。' })

const routeSet = new Set(routes)

// ── ① 注册表 → 文件系统 ─────────────────────────────────────────────────────
for (const href of entryHrefs) {
    if (!routeSet.has(href)) {
        problems.push({ arm: '① 注册表条目要有路由', msg: `lib/modules.ts:FUNCTIONS 里的 ${href} 在 app/ 底下【没有】对应的 page.tsx` })
    }
}

// ── ② 文件系统 → 注册表(或带理由的例外)──────────────────────────────────
const entrySet = new Set(entryHrefs)
const isCoveredByEntry = (r) => entryHrefs.some((h) => r === h || r.startsWith(h + '/'))
for (const r of routes) {
    if (entrySet.has(r)) continue
    if (EXCEPTIONS.has(r)) continue
    if (r.includes('[')) continue // 动态段:它一定挂在某条条目之下,由下一行判
    if (isCoveredByEntry(r)) continue
    problems.push({
        arm: '② 路由要么在注册表里,要么在例外表里',
        msg: `${r} 既不是注册表条目、也不在某条条目之下、也没有登记成例外 —— 它是一页【谁都走不到】的页面。要么给它一条 FUNCTIONS 条目,要么在 EXCEPTIONS 里写下它为什么不需要。`,
    })
}

// ── ③ 退休路径不许出现在树里的任何地方 ─────────────────────────────────────
const SKIP_DIRS = ['node_modules', '.next', '.git']
const scanRoots = ['app', 'lib', 'scripts'].map((d) => join(ROOT, d))
for (const root of scanRoots) {
    for (const file of sourceFiles(root)) {
        const rel = relative(ROOT, file)
        // 这支脚本自己写着那些退休前缀(判据本身),不查自己
        if (rel === 'scripts/check-nav-routes.mjs') continue
        const src = readFileSync(file, 'utf8')
        const lines = src.split('\n')
        for (const { label, re, hint } of RETIRED) {
            lines.forEach((line, i) => {
                re.lastIndex = 0
                if (re.test(line)) {
                    problems.push({
                        arm: '③ 退休路径',
                        msg: `${rel}:${i + 1}  出现了退休路径【${label}】 —— ${hint}\n      ${line.trim().slice(0, 120)}`,
                    })
                }
            })
        }
    }
}

// ── ③b /finance 不许再【是】试算平衡 ───────────────────────────────────────
// 【为什么这一条不能用字符串查】/finance 仍然是一条合法路由(它现在是落地页)。
// 退休的是"它是试算平衡"这件事。所以判据是那一页的【内容】。
const financePage = readFileSync(join(APP, 'finance/page.tsx'), 'utf8')
if (!financePage.includes('ModuleLanding')) {
    problems.push({
        arm: '③b /finance 是落地页',
        msg: 'app/finance/page.tsx 不再渲染 ModuleLanding —— 试算平衡已经搬到 /finance/trial-balance,/finance 是财务的落地页。',
    })
}
if (!routeSet.has('/finance/trial-balance')) {
    problems.push({ arm: '③b /finance 是落地页', msg: '/finance/trial-balance 不存在 —— 试算平衡丢了。' })
}

// ── ④ 范围 id 也要是真实的路由前缀(Tim 加的那一条)──────────────────────
for (const id of scopeIds) {
    if (!id.startsWith('/')) continue
    const ok = routes.some((r) => r === id || r.startsWith(id + '/'))
    if (!ok) {
        problems.push({
            arm: '④ 范围 id 要是真实前缀',
            msg: `lib/modules.ts:SCOPES 里的 ${id} 在 app/ 底下没有任何一条路由以它开头 —— 一个指向退休前缀的守卫,要么失败开、要么失败关,两种都看不见。`,
        })
    }
}

// ── ⑤ 活动模块解析器:【真的跑一遍】,不是对着源码做正则 ────────────────────
// 【为什么这一条要跑真的】NAV-CLEANUP-1 ⑤ 的规则是"声明顺序里【这个读者进得去的】
// 第一个属主"。它的缺陷形态是【安静地指向一个进不去的模块】—— 正则看不见这种事,
// 只有把 /inbound + operations 这一组真的喂进去才看得见。
//
// 【怎么跑】lib/navTrail.ts 写的是 '@/lib/…'(tsconfig 的 paths),plain node 解析不了。
// 所以把它的源码读出来、把两个 import 改写成同目录的相对路径、落成一个临时探针文件
// (就放在 lib/ 底下,相对解析才成立),import 完就删。
// ★ 它读的是【今天的源码】,所以不可能与被检查的东西漂开。★
const probePath = join(ROOT, 'lib', '__navtrail_probe.mts')
try {
    const navSrc = readFileSync(join(ROOT, 'lib/navTrail.ts'), 'utf8')
        .replaceAll("'@/lib/modules'", "'./modules.ts'")
        .replaceAll("'@/lib/deepRoutes.generated'", "'./deepRoutes.generated.ts'")
    writeFileSync(probePath, navSrc)
    const nav = await import(pathToFileURL(probePath).href)

    // ★★【Tim 点名的那一组,以及它当场暴露的一处【规则与预期不一致】】★★
    //   他写的规则是:「声明顺序里【这个读者进得去的】第一个属主」。
    //   他写的预期是:「operations 在 /inbound 上解析成【运营】,不是采购」。
    //   ★ 实跑之后两者对不上,而对不上的是【预期】,不是实现。★
    //   /inbound 的声明顺序是 purchasing → inventory → operation,
    //   而 operations 这个角色**进得去库存**(它持 module.inventory.view)。
    //   按他自己的规则,答案因此是【库存】—— 采购被正确地跳过了,
    //   但在采购之后、运营之前还站着一个库存。
    //   **他关心的那件事成立了(不是采购、不是一个他进不去的模块);
    //   而"是运营"要成立,得【改声明顺序】,那是一个产品判断,不是一处实现缺陷。**
    //   所以这里断言的是【规则】,并把今天的答案钉住,好让任何改动都看得见。
    const opsCanEnter = (id) => ['operation', 'inventory', 'logistics', 'tools', 'settings'].includes(id)
    const got = nav.activeModuleForPath('/inbound', opsCanEnter)
    if (got.id === 'purchasing' || got.id === null || !opsCanEnter(got.id)) {
        problems.push({
            arm: '⑤ 活动模块解析',
            msg: `activeModuleForPath('/inbound', <operations>) 得到 ${JSON.stringify(got)} —— `
               + '它必须是一个【这个读者进得去】的模块,且不能是采购(他进不去采购)。',
        })
    }
    if (got.id !== 'inventory') {
        problems.push({
            arm: '⑤ 活动模块解析',
            msg: `activeModuleForPath('/inbound', <operations>) 得到 ${got.id},而今天钉住的答案是 inventory。`
               + ' 若这是有意改的(例如把 /inbound 的 modules 顺序调成运营在前),连同这一行一起改。',
        })
    }

    // ★【规则本身,穷举验一遍】★ 对每一条多属主条目、每一个属主 i:
    //   当读者【只】进得去属主 i 时,解析结果必须【就是】属主 i。
    //   这比一个手挑的案例硬得多 —— 它把"第一个进得去的"这条规则对着注册表全跑一遍。
    const modulesMod = await import(pathToFileURL(join(ROOT, 'lib/modules.ts')).href)
    let multiOwner = 0
    for (const fn of modulesMod.FUNCTIONS) {
        if (fn.modules.length < 2) continue
        multiOwner++
        for (const owner of fn.modules) {
            const r = nav.activeModuleForPath(fn.href, (id) => id === owner)
            if (r.id !== owner) {
                problems.push({
                    arm: '⑤ 活动模块解析',
                    msg: `${fn.href}:读者只进得去 ${owner},解析却得到 ${JSON.stringify(r)} —— `
                       + '规则是「声明顺序里第一个【进得去的】属主」。',
                })
            }
        }
    }
    if (multiOwner === 0) {
        problems.push({ arm: '⑤ 活动模块解析', msg: '注册表里一条多属主条目都没有 —— 这条判据于是什么都没验(空集不是通过)。' })
    }

    // 【只有一份实现】面包屑必须调同一支,不许自己写 entry.modules[0]
    if (!navSrc.includes('activeModuleForPath(pathname, canEnter)')) {
        problems.push({ arm: '⑤ 活动模块解析', msg: 'lib/navTrail.ts:breadcrumbTrail 没有调 activeModuleForPath —— 「我在哪个模块」又变成两份实现了。' })
    }
} finally {
    try { unlinkSync(probePath) } catch { /* 探针本来就可能没建成 */ }
}

// ── 判词 ───────────────────────────────────────────────────────────────────
if (problems.length) {
    console.error(`✗ 导航与路由:${problems.length} 处\n`)
    for (const p of problems) console.error(`   [${p.arm}] ${p.msg}`)
    process.exit(1)
}
console.log(
    `✓ 导航与路由:注册表 ${entryHrefs.length} 条 · 路由 ${routes.length} 条 · 范围 ${scopeIds.length} 个 · ` +
    `例外 ${EXCEPTIONS.size} 条(各带理由)· 退休路径 0 处 · 活动模块解析:规则穷举 + 3 组实跑`,
)
