// lib/dock.ts
// 【dock 的纯逻辑】—— 默认值、上限、以及"存下来的地址"到"画得出的项"的翻译。
// 纯数据 + 纯函数,所以服务端与客户端都能 import(同 lib/modules.ts 的理由)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ dock 是【快捷层】,不是第二套导航(Tim 的 4d)★
// 它只能指向【注册表里已经有的】二级条目。scripts/check-dock.mjs 把这条钉死:
// 一个不在 FUNCTIONS 里的地址进不了默认清单,而人手加的那一侧由服务端动作校验。
// 【为什么这条要紧】一旦 dock 里能出现顶栏到不了的东西,它就成了第二个入口目录,
// 而"这个功能在哪"就有了两个答案 —— 那正是九模块方案要消灭的状态。
// ════════════════════════════════════════════════════════════════════════════
import { FUNCTIONS, allows } from '@/lib/modules'

/** dock 最多放几个。手机上是一条底栏,再多就换行成一堵墙。 */
export const DOCK_MAX = 8

/**
 * 【默认 dock 的候选,按优先级】—— Tim 的 4c:新同事第一次登录时 dock 不能是空的,
 * 因为"空的 dock"是一个没有人会发现的功能。
 *
 * ★【为什么按【权限】取前几条,而不是按【角色】查一张表】★
 * Tim 的原话是"按角色的合理默认"。这里落成"按权限",而两者在效果上是同一件事 ——
 * 权限【就是】角色带来的东西 —— 但按权限有两个好处,所以照直记下这处措辞差异:
 *   ① 一个人可以【同时持有几个角色】(user_roles 是多对多)。按角色取就得决定
 *      "两个角色的默认怎么合",而按权限根本不会遇到这个问题;
 *   ② 渲染顶栏时 getMyPermissions() 【已经】查过了(React cache),按权限取
 *      不需要在每一页的外壳里多打一次库。
 * 实测这份清单对 live 的九个角色都给得出非空的 dock —— 见 docs/information-architecture.md。
 *
 * 顺序取自 docs/exec-views-plan.md 的"每天做什么"草案与勘察 PART G/G1,
 * 排在前面的是【每天都要开】的那些。
 */
export const DOCK_DEFAULT_CANDIDATES: readonly string[] = [
    '/tasks',
    '/finance',
    '/purchasing/orders',
    '/inbound',
    '/processing',
    '/sales/orders',
    '/inventory',
    '/hr/employees',
    '/finance/invoices',
    '/logistics/containers',
    '/stocktakes',
    '/output',
    '/customers',
    '/suppliers',
    '/materials',
    // 【兜底的最后一条】它的判据是"任何登录用户"(metal_prices 读策略是 USING(true)),
    // 所以【任何人】至少拿得到一条 dock 项 —— 连一个零模块权限的人也不会看见空 dock。
    '/metal-prices',
]

/** dock 上的一项:地址 + 标签 + 【此刻】这个人进不进得去。 */
export type DockItem = {
    href: string
    /** 注册表里那条的 navKey;地址已经不在注册表里时为 null(见 allowed 的注释) */
    navKey: string | null
    /**
     * ★ 三态,不是两态(Tim 的 4b)★
     *   'open'      —— 可点;
     *   'restricted'—— 在注册表里,但这个人【现在】进不去 → 画成「· 受限」,不可点;
     *   'gone'      —— 这个地址【已经不在注册表里了】(某一刀删了那个功能)。
     * 后两者都必须与"这一项根本不在 dock 上"分得开 —— 那正是 4b 的全部内容。
     */
    state: 'open' | 'restricted' | 'gone'
}

/** 地址 → 注册表条目。dock 只认注册表里有的地址(4d)。 */
export function dockItemFor(href: string, perms: readonly string[]): DockItem {
    const fn = FUNCTIONS.find((f) => f.href === href)
    if (!fn) return { href, navKey: null, state: 'gone' }
    return {
        href,
        navKey: fn.navKey,
        state: allows(fn.permission, perms) ? 'open' : 'restricted',
    }
}

/** 这个人的默认 dock:候选里【他进得去】的前 DOCK_MAX 条。 */
export function defaultDock(perms: readonly string[]): string[] {
    return DOCK_DEFAULT_CANDIDATES.filter((href) => {
        const fn = FUNCTIONS.find((f) => f.href === href)
        return fn ? allows(fn.permission, perms) : false
    }).slice(0, DOCK_MAX)
}

/**
 * 存下来的地址 → 画得出的项。
 *
 * ★【三种状态各自的意思,不许合并】★
 *   stored === null   这个人【从来没有动过】dock  → 画默认(4c)
 *   stored === []     这个人【把它清空了】        → 就画空的,不要"好心"补回默认
 *   stored 非空        画这些
 * 中间那一种正是 user_dock 用"一行 + 一个数组"而不是"多行"的理由(见那张表的镜像)。
 */
export function resolveDock(stored: string[] | null, perms: readonly string[]): {
    items: DockItem[]
    /** 画的是默认吗 —— 界面据此决定要不要说一句"这是默认,你可以改" */
    isDefault: boolean
} {
    const hrefs = stored ?? defaultDock(perms)
    return { items: hrefs.map((h) => dockItemFor(h, perms)), isDefault: stored === null }
}
