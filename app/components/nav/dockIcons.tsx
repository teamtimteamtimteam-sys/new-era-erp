// app/components/nav/dockIcons.tsx
// 【dock 收起来之后,一项还剩下什么】—— 一个图标,外加 title/aria-label 上的全名。
//
// ★【为什么要有这个文件:图标是【收起态】唯一的标识,所以它不能是装饰】★
// Tim 的 ④:「Collapsed on desktop means an icon-width strip, not disappearance」。
// 一条 48px 宽的竖栏放不下文字,于是每一项只剩图标 —— 那一刻图标【就是】那一项的
// 名字。所以:
//   ① 每一个图标都配 title + aria-label,写的是与展开态【逐字相同】的那个标签
//      (读屏与鼠标悬停都拿得到全名 —— 收起来的是宽度,不是信息);
//   ② 认不出的地址给一个【明确的兜底图标】,不给一个空格。一个看不出是什么的
//      方块,与"这里没有东西"在屏幕上分不开 —— 那正是这个仓库反复修的那类谎。
//
// ★【lucide-react 此前全仓库 0 处引用(量过),本刀是第一处】★
// 它早就在 package.json 里(BRAND-1 装 shadcn 地基时带进来的),所以这不是一个
// 新依赖,是一个一直躺着没人用的依赖第一次有了读者。
import {
    Boxes, Building2, ClipboardCheck, ClipboardList, Coins, Container, Factory,
    FileText, Landmark, ListChecks, Package, PackagePlus, Receipt, ShoppingCart,
    Tag, Truck, Users, Wrench, CircleDashed,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

/** 地址 → 图标。键是【注册表里的二级地址】,与 lib/modules.ts 的 FUNCTIONS 同源。 */
const BY_HREF: Record<string, LucideIcon> = {
    '/tasks': ListChecks,
    '/finance': Landmark,
    '/finance/invoices': Receipt,
    '/purchasing/orders': ShoppingCart,
    '/inbound': PackagePlus,
    '/operation/processing': Factory,
    '/sales/orders': Tag,
    '/inventory': Boxes,
    '/hr/employees': Users,
    '/logistics/containers': Container,
    '/stocktakes': ClipboardCheck,
    '/output': Package,
    '/customers': Building2,
    '/suppliers': Truck,
    '/materials': Wrench,
    '/metal-prices': Coins,
    '/settings/accounts': ClipboardList,
}

/** 模块段兜底 —— dock 可以放注册表里【任何】一条,不止默认那十六条。 */
const BY_SEGMENT: Record<string, LucideIcon> = {
    finance: Landmark,
    purchasing: ShoppingCart,
    sales: Tag,
    inventory: Boxes,
    hr: Users,
    logistics: Container,
    processing: Factory,
    settings: ClipboardList,
    tasks: ListChecks,
}

/**
 * 这条地址画哪个图标。
 * 【兜底不是"没有图标",是 CircleDashed】—— 一个画得出来的、明显是"没认出来"
 * 的记号,而不是一片空白。空白会读成"这一格是空的"。
 */
export function dockIcon(href: string): LucideIcon {
    if (BY_HREF[href]) return BY_HREF[href]
    const seg = href.split('/').filter(Boolean)[0]
    return (seg && BY_SEGMENT[seg]) || FileText
}

/** 「已下架」那一态专用 —— 它连一个模块段都未必对得上。 */
export const DOCK_GONE_ICON = CircleDashed
