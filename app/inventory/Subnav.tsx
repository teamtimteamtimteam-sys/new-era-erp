'use client'

// app/inventory/Subnav.tsx
// 库存模块的子导航。样式与活动态判定端口自 app/finance/Subnav.tsx
// (最长前缀:/inventory/reports/ledger 亮 reports 而非 overview)。
//
// 【一个数组,顺序就是显示顺序】finance 那份把"有哪些项"和"按什么顺序显示"
// 写成了两个数组,于是它们已经漂开(cost-variance 与 company 在 ITEMS 里、
// 不在 ordered 里)。同一份清单写两遍必然漂,这里只写一遍。
//
// 【没有按权限过滤,而这是一个【前提】,不是遗漏】本模块下每一项都挂在
// module.inventory.view 上 —— 顶层 NavLinks 已经按它过滤过,能看见"库存"
// 这个入口的人,这三项都进得去。所以逐项过滤在这里是多余的一份判断。
// 【将来若有一项挂了别的权限码,这个前提当场失效】:那时必须像 NavLinks 那样
// 由服务端按权限过滤后传进来,否则会有人看见一个自己打不开的入口 ——
// 那正是 NavLinks 抬头写下的那条教训。改这个文件之前先回来读这一段。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/inventory', key: 'inventory.subnav.overview' },
    { href: '/inventory/locations', key: 'inventory.subnav.locations' },
    { href: '/inventory/reports', key: 'inventory.subnav.reports' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先 —— /inventory 是所有项的前缀,所以它必须最后判定
    const activeHref =
        ITEMS.filter((i) => i.href !== '/inventory').find(
            (i) => pathname === i.href || pathname.startsWith(i.href + '/')
        )?.href ?? '/inventory'

    return (
        <nav className="flex gap-1 overflow-x-auto border-b border-gray-200 px-6 pb-2 pt-1">
            {ITEMS.map((item) => (
                <Link
                    key={item.href}
                    href={item.href}
                    className={
                        'px-3 py-1 rounded text-sm whitespace-nowrap ' +
                        (activeHref === item.href
                            ? 'bg-gray-900 text-white'
                            : 'text-gray-600 hover:bg-gray-100')
                    }
                >
                    {t(item.key)}
                </Link>
            ))}
        </nav>
    )
}
