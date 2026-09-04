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
        label: '/metal-prices(搬到 /pricing 之下)',
        // TOOLS-1 ①b。判据要认【路由写法】,不认【相对路径的一段】:
        //   ✓ 抓 '/metal-prices'、`(/metal-prices)`、注释里裸写的 /metal-prices
        //   ✗ 不抓 '../metal-prices/substanceQuery'(那是 app/tools/pricing/ 底下指向
        //     新位置的合法相对 import)、也不抓 'app/tools/pricing/metal-prices/…'
        // 做法:前面不许是【单词字符或点】—— 路由串前面总是引号/括号/空白,
        // 而相对路径前面总是 `.`,新地址前面总是 `g`(pricing 的末字母)。
        // 【第一版没有 (?<![\w.]) —— 它把三条刚修好的相对 import 报成了退休路径,
        //  而那三条恰恰是【已经改对了】的。一条会对正确代码报红的判据会被关掉。】
        re: /(?<![\w.])\/metal-prices(?![A-Za-z0-9_-])/g,
        hint: '改成 /tools/pricing/metal-prices(CONV-6 ⑤a 之后定价整族住在工具底下)',
    },
    // ══ CONV-6 ⑤ 搬走的四段。判据与上面三条【同形】,不新造写法 ══════════
    // 【为什么四条都不必写 (?<!/tools) / (?<!/sales) 这种反查】新地址的
    // 最后一个字符是词字符(tool**s**/tasks、sale**s**/customers),
    // 而 (?<![\w.]) 已经把"前面是词字符"整类排除了 —— 新地址因此自动不被误判。
    // 这与 /metal-prices 那一条当年学到的是同一课(第一版没有 (?<![\w.]),
    // 把三条刚改对的相对 import 报成了退休路径)。
    {
        label: '/tasks(搬进工具)',
        re: /(?<![\w.])\/tasks(?![A-Za-z0-9_-])/g,
        hint: '改成 /tools/tasks(任务已并入工具)',
    },
    {
        label: '/pricing(整族搬进工具)',
        re: /(?<![\w.])\/pricing(?![A-Za-z0-9_-])/g,
        hint: '改成 /tools/pricing;公式/计价器/金属行情跟着走(/tools/pricing/{formulas,calculator,metal-prices})',
    },
    {
        label: '/customers(整族搬进销售)',
        re: /(?<![\w.])\/customers(?![A-Za-z0-9_-])/g,
        hint: '改成 /sales/customers;重叠检查是 /sales/customers/overlap',
    },
    {
        label: '/commissions(搬进销售)',
        re: /(?<![\w.])\/commissions(?![A-Za-z0-9_-])/g,
        hint: '改成 /sales/commissions(地址搬了,属主仍是采购与销售两个 —— 见 lib/modules.ts)',
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
    // ★【CONV-6 ⑤c:/purchasing 从例外表里【去掉了】】★
    //   它此前登记在这里的理由是「它是一个别名:全文 14 行,主体是
    //   redirect('/purchasing/orders'),所以它不该有注册表条目」。
    //   **Tim 裁定它不许再跳转** —— 那一页现在是采购 Overview,有自己的内容,
    //   于是它在 FUNCTIONS 里有一条真的条目,判据②本来就放行它。
    //   留着这条例外会让【两处】同时声称管着同一条路由,而例外表的每一条
    //   都得是"存在但故意不在注册表里"——它已经在注册表里了。
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
// 【为什么这一条不能用字符串查退休前缀】/finance 仍然是一条合法路由。
// 退休的是"它是试算平衡"这件事,而那是一件【语义】,不是一个字符串。
//
// ★★【CONV-6:这一条此前【靠一句注释通过】—— 一道为错误的理由变绿的闸】★★
//   它原本查的是 `financePage.includes('ModuleLanding')`,写在 NAV-CLEANUP-1
//   把 /finance 做成 <ModuleLanding> 的那一天,当时判据与事实一致。
//   **CONV-7 ② 把那一页换成了财务 Overview,ModuleLanding 一行都不再渲染** ——
//   而这道检查【照旧是绿的】,因为那一页的抬头注释里写着
//   「NAV-CLEANUP-1 ③ 把这一页做成了 <ModuleLanding>」这句【讲历史的话】。
//   也就是说:一道断言"这一页渲染 X"的检查,被一句"这一页从前渲染 X"的注释满足了。
//   这正是本仓库记过的同一个形状(check-permission-predicate 那一条:
//   「第一版就是这样被自己的注释骗过去的」),它的处置也是同一条 ——
//   **先去注释,再判断。**
//
// 【新判据:查那一页【不是】试算平衡,而不是查它【是】某一个组件】
//   查"是什么"要求这条检查跟着每一次改版走(它已经漂开过一次)。
//   查"不是什么"钉住的才是这一条真正在乎的事:试算平衡不许搬回 /finance。
//   两个特征都取自试算平衡自己那一页,而且都在【去掉注释之后】才算数。
const stripComments = (src) =>
    src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')

const financeBody = stripComments(readFileSync(join(APP, 'finance/page.tsx'), 'utf8'))
for (const [needle, what] of [['journal_lines', '按科目聚合 journal_lines'], ['finance.trialBalance', '试算平衡的标题键']]) {
    if (financeBody.includes(needle)) {
        problems.push({
            arm: '③b /finance 不是试算平衡',
            msg: `app/finance/page.tsx 里出现了【${what}】—— 试算平衡住在 /finance/trial-balance,`
               + '/finance 是财务 Overview(docs/module-overview-basis.md)。搬回来会让 CONV-6 ⑥ 那条链接第二次指错。',
        })
    }
}
// 【而 Overview 那一页要【真的】是一张 Overview】—— 它必须画 <Figure>,
// 那是唯一一个强制 spans 的构件(没有它,这一页可以静悄悄退化回卡片墙)。
if (!financeBody.includes('Figure')) {
    problems.push({
        arm: '③b /finance 不是试算平衡',
        msg: 'app/finance/page.tsx 不再渲染 <Figure> —— 一张不用 Figure 的 Overview 没有任何东西强制它说出 spans。',
    })
}
if (!routeSet.has('/finance/trial-balance')) {
    problems.push({ arm: '③b /finance 不是试算平衡', msg: '/finance/trial-balance 不存在 —— 试算平衡丢了。' })
}

// ════════════════════════════════════════════════════════════════════════════
// ── ⑥ 带【查询参数】的站内链接:它指的那一页必须真的读那个参数 ──────────────
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么需要第六条 —— 前五条对这一族【结构性地】看不见】★★
//
// 【实测的那一条(CONV-6 ⑥)】/finance/trial-balance 上「显示零发生额科目」
//   写的是 `href={showAll ? '/finance' : '/finance?all=1'}` —— 一条【自指】链接,
//   在这一页还住在 /finance 的时候是对的。NAV-CLEANUP-1 把它搬走,CONV-7 又把
//   /finance 做成 Overview,于是点它的人落在一张连"零发生额"四个字都不认的页上。
//
// 【前五条为什么一条都没抓到】
//   · ③ 查的是【退休前缀】,而 `/finance` 没有退休 —— 它今天仍是合法路由;
//   · ①② 查的是【注册表 ↔ 文件系统】,而 /finance 两边都在;
//   · ③b 查的是那一页的内容,它不看【谁链向它】。
//   **退休的是"/finance 是试算平衡"这个语义,而语义没法用一张前缀表表达。**
//   能表达的是这一条:**一个参数是一份契约。** 链接说"我要 all=1",
//   目标页要么读得懂,要么这条链接就是坏的 —— 而这一条判得动,因为两边都在树里。
//
// 【判据】对 app/ 与 lib/ 里每一条【字面量】站内链接 `'/x/y?k=v'`:
//   ⓐ 那条路径必须解析得到一条真实路由(动态段 [id] 与模板串 ${…} 互相通配);
//   ⓑ 那条路由【自己目录里】的源码必须真的读 k —— 认四种写法:
//        k?: / k: (searchParams 的类型格)· sp.k / searchParams.k · get('k') · ['k']
//   ★【为什么只看那一层目录,不递归】★ 递归会把这一条【正好在它该红的时候】变绿:
//     /finance?all=1 的目标目录是 app/finance/,而 app/finance/trial-balance/
//     底下【确实】写着 sp.all —— 递归下去它就通过了,而那正是本条要抓的缺陷。
//     一个页面的 searchParams 是它自己那一层的事(Next 的 page.tsx 拿到它,
//     再往下传给同目录的组件),所以"同目录、不递归"既是对的也是最紧的。
// ════════════════════════════════════════════════════════════════════════════
const LINK_WITH_QUERY = /['"`](\/[A-Za-z0-9._$\/{}\[\]-]*)\?([A-Za-z0-9_]+)=/g
const segMatches = (linkSeg, routeSeg) =>
    linkSeg === routeSeg || routeSeg.startsWith('[') || linkSeg.includes('${')
/**
 * 链接路径 → 那一条路由。
 *
 * ★【静态段必须【压过】动态段 —— 第一版没有这一条,当场自证】★
 *   `/finance/payables/export` 同时匹配两条路由:它自己,和 `/finance/payables/[batchId]`
 *   (动态段通配一切)。第一版用 `routes.find` 拿【第一条】,于是它解析成了
 *   `[batchId]` 那一页,然后理直气壮地报告"目标页不读 as_of" ——
 *   **一条对着正确代码报红的判据,会被关掉。** 这正是 /metal-prices 那一条
 *   当年学到的同一课,所以这里按"静态段多的优先"排序再取第一条:
 *   Next 的路由匹配本来就是这个优先级,判据照着它才不会与运行时说两套话。
 */
const resolveRoute = (path) => {
    const l = path.split('/').filter(Boolean)
    const staticness = (r) => r.split('/').filter(Boolean).filter((seg) => !seg.startsWith('[')).length
    return routes
        .filter((r) => {
            const rs = r.split('/').filter(Boolean)
            return rs.length === l.length && rs.every((seg, i) => segMatches(l[i], seg))
        })
        .sort((a, b) => staticness(b) - staticness(a))[0] ?? null
}
/**
 * 那一页读不读这个参数。
 *
 * ★★【两道门,而第一道是注入实测【逼】出来的】★★
 * 第一版只查"这个键出现过",判据里有一条 `\.${key}\b`。把 CONV-6 ⑥ 那条真缺陷
 * (/finance?all=1)注入回去,**它一声不吭地通过了** —— 因为财务 Overview 里写着
 * `Promise.all([...])`,而 `.all` 正好撞上那一条。
 * **一次没有被注入试过的判据,与没有判据一样**(backup.sh 的抬头为同一句话付过账)。
 *
 * 【现在的两道门,必须【同时】成立】
 *   ① 这一页得【真的收 searchParams】—— 不收的页面,任何参数对它都没有意义,
 *      而这一道正好把 Promise.all 那种巧合整类挡在外面(Overview 不收 searchParams);
 *   ② 那个键要以【参数的写法】出现:类型格 `k?:` / `sp.k`、`searchParams.k` /
 *      `get('k')` / `['k']`。裸的 `.k` 不再算数。
 */
const readsParam = (routePath, key) => {
    const dir = join(APP, ...routePath.split('/').filter(Boolean))
    let entries
    try { entries = readdirSync(dir) } catch { return false }
    const re = new RegExp(
        `\\b${key}\\s*\\??\\s*:`
        + `|\\b(?:sp|searchParams|params|query|q)\\.${key}\\b`
        + `|get\\(\\s*['"\`]${key}['"\`]`
        + `|\\[\\s*['"\`]${key}['"\`]\\s*\\]`,
    )
    for (const e of entries) {
        const f = join(dir, e)
        if (statSync(f).isDirectory()) continue          // 【刻意不递归】见上
        if (!/\.(ts|tsx)$/.test(e)) continue
        const body = stripComments(readFileSync(f, 'utf8'))
        if (!body.includes('searchParams')) continue     // 【第一道门】见上
        if (re.test(body)) return true
    }
    return false
}

let queryLinks = 0
for (const root of [join(ROOT, 'app'), join(ROOT, 'lib')]) {
    for (const file of sourceFiles(root)) {
        const rel_ = relative(ROOT, file)
        if (rel_ === 'scripts/check-nav-routes.mjs') continue
        const lines = readFileSync(file, 'utf8').split('\n')
        lines.forEach((line, i) => {
            LINK_WITH_QUERY.lastIndex = 0
            let m
            while ((m = LINK_WITH_QUERY.exec(line)) !== null) {
                const [, path, key] = m
                if (path.startsWith('/rest/') || path.startsWith('/auth/')) continue // PostgREST,不是路由
                queryLinks++
                const route = resolveRoute(path)
                if (!route) {
                    problems.push({
                        arm: '⑥ 带参数的链接',
                        msg: `${rel_}:${i + 1}  链接 ${path}?${key}= 指向一条【不存在的路由】\n      ${line.trim().slice(0, 120)}`,
                    })
                } else if (!readsParam(route, key)) {
                    problems.push({
                        arm: '⑥ 带参数的链接',
                        msg: `${rel_}:${i + 1}  链接 ${path}?${key}= —— 目标页 app${route}/ 【不读】参数 ${key}。\n`
                           + `      这条链接说得出它要什么,而那一页答不上来:点下去参数被静默丢掉。\n`
                           + `      多半是那一页搬过家而链接没跟上(CONV-6 ⑥ 的原型:/finance?all=1)。\n      ${line.trim().slice(0, 120)}`,
                    })
                }
            }
        })
    }
}
// ★【空集不算通过】★ 一处带参数的链接都没扫到 = 正则坏了,不是"树里没有"。
if (queryLinks === 0) {
    problems.push({ arm: '⑥ 带参数的链接', msg: 'app/ 与 lib/ 里扫出 0 条带查询参数的站内链接 —— 正则坏了,不是树里没有。' })
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
    `例外 ${EXCEPTIONS.size} 条(各带理由)· 退休路径 0 处 · 带参数的站内链接 ${queryLinks} 条(目标页都读得懂)· ` +
    `活动模块解析:规则穷举 + 3 组实跑`,
)
