// app/components/nav/types.ts
// 外壳三个客户端组件共用的 prop 形状。
// 【为什么单独一个文件】ModuleBar / Dock 是 'use client',判权限要读库所以在服务端做完
// 再传下来 —— 两侧都要 import 这些类型,而它们不能挂在任何一个带 'use client' 的文件上。

/** 一个可导航的条目 + 【这个人进不进得去】。allowed=false 不是"不渲染"(D5)。 */
export type NavEntry = { href: string; key: string; allowed: boolean }

/** 一个一级模块:名字 + 可进性 + 二级;财务额外带第三级分组。 */
export type NavModule = {
    id: string
    key: string
    /** 【推导】出来的:名下有没有任何一条二级进得去。见 lib/moduleAccess.ts。 */
    allowed: boolean
    entries: NavEntry[]
    /** 只有财务非空。空 = 这个模块只有两级。 */
    groups: { key: string; entries: NavEntry[] }[]
}

/** dock 上的一项。三态见 lib/dock.ts 的 DockItem。 */
export type DockEntry = { href: string; key: string | null; state: 'open' | 'restricted' | 'gone' }
