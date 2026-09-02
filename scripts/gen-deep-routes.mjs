#!/usr/bin/env node
// scripts/gen-deep-routes.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// 【面包屑只在"深"的路由上出现,而"深"必须是【算出来的】,不是抄下来的】
// Tim 的 D4 + IA-BUILD-1 的 3e。
//
// ★ 判据,一句话 ★
//   一条路由的【深度】= 它的路径段里,**不是动态段 `[…]`、不是路由组 `(…)`、
//   也不是叶子动作词 `new` / `edit`** 的那些段的个数。
//   **深 ⟺ 深度 ≥ 3。**
//
// 三条排除各有理由,都不是为了凑数:
//   `[id]`  —— 一个 id 不是信息架构里的一层,它是同一层上的一行;
//   `(组)`  —— 路由组根本不出现在 URL 里;
//   new/edit—— 它们是【对当前这一层的动作】,不是更深的一层。
//              `/hr/employees/new` 读起来是"员工 · 新建",不是"人力 › 员工 › 新建"。
//
// 实测这条判据落在 188 条路由上得到:深度 1 → 45 条,2 → 119,3 → 22,4 → 1。
// **深的一共 23 条 —— 与 Tim 的 D4 和勘察文件 PART F/3b 的 22+1 逐条对上。**
//
// 【为什么要生成一份文件,而不是运行时扫目录】运行时拿到的是 `usePathname()`,
// 那是【填好了 id 的具体路径】(/finance/bank/statements/abc-123),从它身上
// 看不出哪一段是动态段 —— 也就分不清 `statements/[id]` 与 `statements/foo`。
// 判据必须建立在【路由模式】上,而路由模式只有文件系统知道。
//
// 【为什么不手写那 23 条】勘察文件 E2/4 记着 finance/Subnav 里两份清单漂移的
// 隐患,而一份手写的"深路由清单"是同一个形状:加一页深路由的人不会想到来改它,
// 于是那一页永远没有面包屑,并且【没有任何东西会说出来】。
// 所以:生成 + 进 `npm run build` 的比对。加一页深路由而忘了重跑,构建当场变红。
//
// 用法:node scripts/gen-deep-routes.mjs          比对(build 跑这个,不一致退 1)
//       node scripts/gen-deep-routes.mjs --write  重新生成
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const APP = join(ROOT, 'app')
const OUT = join(ROOT, 'lib/deepRoutes.generated.ts')
const WRITE = process.argv.includes('--write')

/** 叶子动作词:它们是对当前层的动作,不是更深的一层。 */
const LEAF_VERBS = new Set(['new', 'edit'])
const isDynamic = (s) => s.startsWith('[')
const isGroup = (s) => s.startsWith('(') && s.endsWith(')')

function routePatterns(dir, segs = [], out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        if (statSync(p).isDirectory()) routePatterns(p, [...segs, e], out)
        else if (e === 'page.tsx') out.push(segs)
    }
    return out
}

const rows = routePatterns(APP)
    .map((segs) => {
        const kept = segs.filter((s) => !isGroup(s))
        return {
            pattern: '/' + kept.join('/'),
            depth: kept.filter((s) => !isDynamic(s) && !LEAF_VERBS.has(s)).length,
        }
    })
    .sort((a, b) => a.pattern.localeCompare(b.pattern))

const deep = rows.filter((r) => r.depth >= 3)
const histogram = {}
for (const r of rows) histogram[r.depth] = (histogram[r.depth] ?? 0) + 1

// ── 面包屑要几个【段名】的文案 ────────────────────────────────────────────
// 一条深路由的面包屑 = 模块 › 注册表条目 › 剩下的段。前两截的文案来自注册表
// (它们已经有 navKey);**剩下的段没有,所以要 breadcrumb.<段> 这样一个键。**
//
// 【这份段名清单是算出来的,不是列出来的】做法:把 lib/modules.ts 的 FUNCTIONS
// 里那些 href 当作【已经有名字的前缀】,深路由减去最长的那个前缀,剩下什么就要
// 什么。于是加一条深路由、或者把某一段提成注册表条目,这份清单自动跟着变 ——
// 而 scripts/check-i18n.mjs 的 MANIFEST 从这里现读,两个语言少一句就构建变红。
// 【为什么读文本而不是 import】这是一个 .mjs,而 lib/modules.ts 是 TypeScript;
// 仓库里现成的做法(check-i18n 的 tsRegex)也是读文本 —— 沿用它,不另起一种。
const modulesSrc = readFileSync(join(ROOT, 'lib/modules.ts'), 'utf8')
const fnBlock = modulesSrc.slice(modulesSrc.indexOf('export const FUNCTIONS'))
const ENTRY_HREFS = [...fnBlock.matchAll(/href: '([^']+)'/g)].map((m) => m[1])
if (ENTRY_HREFS.length === 0) {
    console.log('✗ 从 lib/modules.ts 的 FUNCTIONS 里一条 href 都没解析出来 —— 解析器坏了,不是"没有条目"。')
    process.exit(1)
}
const segsOf = (p) => p.split('/').filter(Boolean)
/** 段级前缀匹配:/finance/bank 是 /finance/bank/statements 的前缀,/finance/ba 不是。 */
const isPrefix = (a, b) => a.length <= b.length && a.every((s, i) => s === b[i])
function trailingSegments(pattern) {
    const segs = segsOf(pattern)
    let best = []
    for (const h of ENTRY_HREFS) {
        const hs = segsOf(h)
        if (isPrefix(hs, segs) && hs.length > best.length) best = hs
    }
    return segs.slice(best.length).filter((s) => !isDynamic(s))
}
const BREADCRUMB_SEGMENTS = [...new Set(deep.flatMap((r) => trailingSegments(r.pattern)))].sort()

const body = `// ⚠️ 【生成文件,不要手改】由 scripts/gen-deep-routes.mjs 产出。
// 改了它 \`npm run build\` 会红。判据与理由写在那个脚本的抬头里。
//
// 本次生成时的实测:路由 ${rows.length} 条,深度分布 ${JSON.stringify(histogram)},
// 深(≥3)的 ${deep.length} 条 —— 这就是 Tim 的 D4 说的"23 条深路由"。
//
// 段是【路由模式】的段:动态段写成 [x],路由组已经去掉(它们不出现在 URL 里)。

/** 深路由的模式,升序。运行时把 usePathname() 按段匹配到其中一条。 */
export const DEEP_ROUTES: readonly string[] = [
${deep.map((r) => `    '${r.pattern}',`).join('\n')}
]

/** 生成时的深度分布 —— 让下一次 diff 一眼看得出是哪一档变了。 */
export const DEPTH_HISTOGRAM: Readonly<Record<string, number>> = ${JSON.stringify(histogram)}

/**
 * 面包屑里【注册表答不上来的那些段】。每一个要 messages/{en,zh}.ts 里一句
 * breadcrumb.<段>;少一句 \`npm run build\` 会红(check-i18n 的 MANIFEST 从这里现读)。
 */
export const BREADCRUMB_SEGMENTS = [${BREADCRUMB_SEGMENTS.map((s) => `'${s}'`).join(', ')}] as const
`

if (WRITE) {
    writeFileSync(OUT, body)
    console.log(`✓ 写入 ${deep.length} 条深路由 → lib/deepRoutes.generated.ts（分布 ${JSON.stringify(histogram)}）`)
    process.exit(0)
}

let current = ''
try {
    current = readFileSync(OUT, 'utf8')
} catch {
    console.log('')
    console.log('✗ lib/deepRoutes.generated.ts 不存在 —— 跑 `node scripts/gen-deep-routes.mjs --write`。')
    process.exit(1)
}
if (current !== body) {
    console.log('')
    console.log('✗ 深路由清单过期了 —— 有人加/删/改了路由,而面包屑的判据没有跟着重算。')
    console.log('  后果:新的深路由【没有面包屑】,而没有任何东西会说出来(勘察 E2/4 那个形状)。')
    console.log('  修法:node scripts/gen-deep-routes.mjs --write,然后把生成的文件一起提交。')
    process.exit(1)
}
console.log(`✓ 深路由:${rows.length} 条路由,深度 ≥3 的 ${deep.length} 条,与生成文件一致`)
