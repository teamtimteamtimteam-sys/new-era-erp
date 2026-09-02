// lib/navTrail.ts
// 【从一条 URL 反查它在信息架构里的位置】—— 纯函数,没有任何 import 是服务端专属的,
// 所以顶栏(客户端)与面包屑(客户端)都能用,服务端也能用。
//
// 【NAV-REG-1 删掉过一个 moduleForPath,理由是它一个调用者都没有】。本刀重新需要
// 这件事,于是重新造 —— **并且这一次它有三个调用者**(顶栏活动态、面包屑、dock 的
// 归属)。那条规矩没变:有读者的东西才留下。
import { FUNCTIONS, MODULES, type FunctionEntry } from '@/lib/modules'
import { DEEP_ROUTES } from '@/lib/deepRoutes.generated'

const segsOf = (p: string): string[] => p.split('/').filter(Boolean)
const isDynamic = (s: string) => s.startsWith('[')

/** 段级前缀:/finance/bank 是 /finance/bank/statements 的前缀,/finance/ba 不是。 */
function isSegmentPrefix(prefix: string[], full: string[]): boolean {
    return prefix.length <= full.length && prefix.every((s, i) => s === full[i])
}

/** 具体路径能不能套进这个路由模式(动态段吃任何一段,段数必须相等)。 */
function matchesPattern(pathname: string, pattern: string): boolean {
    const a = segsOf(pathname)
    const b = segsOf(pattern)
    if (a.length !== b.length) return false
    return b.every((s, i) => isDynamic(s) || s === a[i])
}

/**
 * 这条路径是不是【深路由】—— 返回它匹配上的那个路由模式,不深就是 null。
 * 判据与那份清单都不在这里:见 scripts/gen-deep-routes.mjs 的抬头(Tim 的 D4)。
 * 【为什么要返回模式而不是布尔】面包屑要知道【哪几段是 id】,而一条填好了 id 的
 * 具体路径身上看不出来 —— 只有模式知道。
 */
export function deepRoutePattern(pathname: string): string | null {
    return DEEP_ROUTES.find((p) => matchesPattern(pathname, p)) ?? null
}

/** 这条路径落在哪一条二级条目下(最长前缀优先)。 */
export function entryForPath(pathname: string): FunctionEntry | null {
    const segs = segsOf(pathname)
    let best: FunctionEntry | null = null
    for (const f of FUNCTIONS) {
        const hs = segsOf(f.href)
        if (isSegmentPrefix(hs, segs) && (!best || hs.length > segsOf(best.href).length)) best = f
    }
    return best
}

/**
 * 这条路径【属于哪几个一级模块】。
 * 【返回一组而不是一个】—— 一个功能可以同属几个模块(NAV-REG-1 的全部内容),
 * 站在 /output 上,运营与库存【两个】都该亮。返回一个就得挑一个,而挑就是撒谎。
 */
export function moduleIdsForPath(pathname: string): string[] {
    return [...(entryForPath(pathname)?.modules ?? [])]
}

export type Crumb = {
    /** 文案键 */
    key: string
    /** 可点的话给地址;【最后一截与模块名不给】—— 当前页与一个不是链接的模块名 */
    href?: string
}

/**
 * 面包屑。**只有深路由才有**(Tim 的 D4),浅的返回空数组 ——
 * 在二级页面上,面包屑只会把顶栏已经高亮的东西再说一遍。
 *
 * 构造是机械的,三截拼起来:
 *   ① 模块名(不是链接 —— 模块在顶栏上是一个展开菜单的按钮,不是一个地址);
 *   ② 注册表里那条最长前缀的二级条目(它自带 navKey 与 href);
 *   ③ 剩下的段,每段一句 breadcrumb.<段>。**动态段整段跳过** ——
 *      与判定"深不深"时跳过 [id] 是【同一条理由】:一个 id 不是架构里的一层,
 *      它是同一层上的一行。
 */
export function breadcrumbTrail(pathname: string): Crumb[] {
    const pattern = deepRoutePattern(pathname)
    if (!pattern) return []
    const entry = entryForPath(pathname)
    if (!entry) return []
    const mod = MODULES.find((m) => m.id === entry.modules[0])
    if (!mod) return []

    const here = segsOf(pathname)
    const pat = segsOf(pattern)
    const consumed = segsOf(entry.href).length

    const crumbs: Crumb[] = [{ key: mod.navKey }, { key: entry.navKey, href: entry.href }]
    for (let i = consumed; i < pat.length; i++) {
        if (isDynamic(pat[i])) continue
        crumbs.push({ key: `breadcrumb.${pat[i]}`, href: '/' + here.slice(0, i + 1).join('/') })
    }
    // 最后一截是【当前页】,不给地址 —— 一个指向自己的链接是噪音。
    if (crumbs.length > 0) delete crumbs[crumbs.length - 1].href
    return crumbs
}
