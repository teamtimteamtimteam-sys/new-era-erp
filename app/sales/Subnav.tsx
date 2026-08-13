'use client'

// app/sales/Subnav.tsx
// 销售模块的子导航。样式与活动态判定端口自 app/finance/Subnav.tsx
// (最长前缀:/sales/orders/new 亮 orders)。
//
// 【一个数组,顺序就是显示顺序】—— 不重复 finance 那份"清单写两遍"的毛病
// (那两个数组已经漂开过)。
//
// 【没有按权限过滤,而这是一个【前提】,不是遗漏】本模块下每一项都挂在
// module.sales.view 上 —— 顶层 NavLinks 已经按它过滤过,能看见"销售"这个入口
// 的人,这里每一项都进得去。所以逐项过滤在这里是多余的一份判断。
// 【将来若有一项挂了别的权限码,这个前提当场失效】:那时必须像 NavLinks 那样
// 由服务端按权限过滤后传进来,否则会有人看见一个自己打不开的入口。
// 改这个文件之前先回来读这一段(与 app/inventory/Subnav.tsx 同一条)。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [{ href: '/sales/orders', key: 'sales.subnav.orders' }]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()
    return (
        <nav className="flex gap-1 overflow-x-auto border-b border-gray-200 px-6 pb-2 pt-1">
            {ITEMS.map((item) => {
                const active = pathname === item.href || pathname.startsWith(item.href + '/')
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
