'use client'

// app/processing/Subnav.tsx
// 加工模块的子导航(WO-1c 新增)。样式与活动态判定端口自 app/sales/Subnav.tsx
// (最长前缀:/processing/orders/new 亮 orders)。
//
// 【顺序就是流程】工单是计划,加工单是实绩 —— 计划排在前面,与销售那份把报价
// 排在订单前面同一条理由。
//
// 【没有按权限过滤,而这是一个【前提】,不是遗漏】本模块下两项都挂在
// module.processing.view 上 —— 顶层 NavLinks 已经按它过滤过,能看见"加工"这个
// 入口的人,这里每一项都进得去。所以逐项过滤在这里是多余的一份判断。
// 【将来若有一项挂了别的权限码,这个前提当场失效】:那时必须像 NavLinks 那样
// 由服务端按权限过滤后传进来,否则会有人看见一个自己打不开的入口
// (与 app/sales/Subnav.tsx、app/inventory/Subnav.tsx 同一条)。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/processing/orders', key: 'processing.subnav.workOrders' },
    { href: '/processing', key: 'processing.subnav.runs' },
    // PROC-WIRE-1B-ii(R3):在制品 —— 什么在等哪一道工序。
    { href: '/processing/wip', key: 'processing.subnav.wip' },
    // PROC-SUPPORT-1(R4):交接班。挂在 module.processing.view 上,与上面三项同一个
    // 权限码 —— 所以上面那条"不逐项过滤"的前提仍然成立。
    { href: '/processing/handovers', key: 'processing.subnav.handovers' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()
    return (
        <nav className="flex gap-1 overflow-x-auto border-b border-gray-200 px-6 pb-2 pt-1">
            {ITEMS.map((item) => {
                // 【/processing 是另一项的前缀,所以它要精确匹配】否则站在
                // /processing/orders 上两项会同时亮。
                const active = item.href === '/processing'
                    ? pathname === '/processing' || pathname.startsWith('/processing/')
                        && !pathname.startsWith('/processing/orders')
                        && !pathname.startsWith('/processing/wip')
                        && !pathname.startsWith('/processing/handovers')
                    : pathname === item.href || pathname.startsWith(item.href + '/')
                return (
                    <Link key={item.href} href={item.href}
                          className={'px-3 py-1 rounded text-sm whitespace-nowrap ' +
                              (active ? 'bg-gray-900 text-white' : 'text-gray-600 hover:bg-gray-100')}>
                        {t(item.key)}
                    </Link>
                )
            })}
        </nav>
    )
}
