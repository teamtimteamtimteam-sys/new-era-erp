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
 * 这条路径【声明的全部属主模块】。仍然返回一组 —— 那是注册表里写着的事实。
 * ★ 但它【不再】是"该亮哪个"的答案 ★:那个问题只有一个答案,见 activeModuleForPath。
 */
export function moduleIdsForPath(pathname: string): string[] {
    return [...(entryForPath(pathname)?.modules ?? [])]
}

// ════════════════════════════════════════════════════════════════════════════
// ★★【NAV-CLEANUP-1 ⑤(2026-09-03):「我在哪个模块」只有【一个】答案】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 【被推翻的是什么 —— 记在这里,不做一次静默的编辑】
//   IA-BUILD-1 在 ModuleBar 里写下过一句刻意的判断:
//     「一个功能可以同属几个模块,所以高亮的可以是【两个】…… 挑一个就是撒谎。」
//   那句话在【描述数据】时是对的:/inbound 确实同属采购、库存、运营三个模块。
//   ★ 2026-09-03,Tim 走了部署系统之后推翻了它 ★:从采购点进收货,采购【和】库存
//   同时亮;库存报表一次点亮销售、财务、库存三个。**"我在哪"读起来因此没有答案。**
//   高亮回答的不是"这一页属于谁",而是"我现在站在哪" —— 后者只能有一个答案。
//
// ★【而"挑第一个"是【错的】,这是 Tim 当场抓到的一处缺陷】★
//   /inbound 的 modules[0] 是【采购】,而运营是 Tim 特意加的第三个属主
//   ——「车间需要知道什么料到了」。**operations 这个角色进不去采购。**
//   按 D5,进不去的模块仍然渲染,只是写着「· 受限」。
//   于是"永远亮 modules[0]"会在【正是为他加的那一页上】,把高亮打在一个
//   他被挡在外面的模块上。
//
// 【所以规则是:声明顺序里【这个读者进得去的】第一个属主。】
//   modules[0] 他进得去 → 就是它;进不去 → 顺着声明顺序往下找第一个进得去的。
//   一个都进不去 → **那是一个矛盾**(他既然打开了这一页,就至少有一个属主
//   模块因为这一条而变得可进),所以【报出来,不要静默地不亮】。
//
// 【为什么没有"进入上下文"这种东西】—— Tim 的 Q1,已裁定。
//   记住"你是从哪个菜单点进来的"在点击路径上是对的,而在【输入网址、dock 快捷方式、
//   别处来的链接、刷新、浏览器后退】上全是陈旧的。那等于给"我在哪"造第二个真源,
//   而这个仓库为"同一条规则两份实现"付过账(见 lib/modules.ts 抬头 §一)。
//   **一个确定的、可能不是你来路的答案,好过一个有时正确、有时陈旧的答案。**
//
// 【这一份是【唯一】的一份】ModuleBar 的高亮与 breadcrumbTrail 的第一截都调它。
//   从前面包屑自己写 `entry.modules[0]` —— 那是同一个谓词的第二份实现,
//   而它带着同一个缺陷。两份必然漂开,所以现在只有这一份。
// ════════════════════════════════════════════════════════════════════════════

/** 「我在哪个一级模块」的答案。id 为 null 表示【矛盾】,调用方必须报出来。 */
export type ActiveModule =
    | { id: string; usedFallback: boolean }
    | { id: null; contradiction: true }

/**
 * @param canEnter 这个读者进不进得去某个模块。**由调用方提供** ——
 *   ModuleBar 有服务端算好的 `allowed`,面包屑从 layout 拿同一份。
 *   这样这支函数自己不碰权限,却仍然只有一份判据。
 */
export function activeModuleForPath(
    pathname: string,
    canEnter: (moduleId: string) => boolean,
): ActiveModule {
    const owners = moduleIdsForPath(pathname)
    if (owners.length === 0) return { id: null, contradiction: true }
    for (let i = 0; i < owners.length; i++) {
        if (canEnter(owners[i])) return { id: owners[i], usedFallback: i > 0 }
    }
    // 打开了这一页,却一个属主模块都进不去 —— 见上面那一段。
    return { id: null, contradiction: true }
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
export function breadcrumbTrail(
    pathname: string,
    canEnter: (moduleId: string) => boolean,
): Crumb[] {
    const pattern = deepRoutePattern(pathname)
    if (!pattern) return []
    const entry = entryForPath(pathname)
    if (!entry) return []
    // ★ NAV-CLEANUP-1 ⑤:第一截【也】走那一份解析器。★
    //   从前这里写的是 `entry.modules[0]` —— 与 ModuleBar 各写一遍同一个谓词,
    //   而且带着同一个缺陷(会指向一个读者进不去的模块)。现在两处同源。
    const active = activeModuleForPath(pathname, canEnter)
    if (active.id === null) return []
    const mod = MODULES.find((m) => m.id === active.id)
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
