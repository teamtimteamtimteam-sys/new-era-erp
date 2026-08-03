// app/components/NavLinks.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const NAV_ITEMS = [
    { href: '/suppliers', key: 'nav.suppliers' },
    // 采购(采购单 / 付款条款模板)紧跟供应商 —— 采购单是"跟这家供应商谈成了什么"的存档
    { href: '/purchasing', key: 'nav.purchasing' },
    { href: '/customers', key: 'nav.customers' },
    { href: '/materials', key: 'nav.materials' },
    // 定价板块(公式 / 计价器 / 行情)。/metal-prices 的路由仍然有效,只是不再单独占一个
    // 顶级导航位 —— 入口收进定价首页与定价子导航,避免同一件事出现两个并列入口。
    { href: '/pricing', key: 'nav.pricing' },
    { href: '/inbound', key: 'nav.inbound' },
    { href: '/output', key: 'nav.output' },
    { href: '/processing', key: 'nav.processing' },
    { href: '/inventory', key: 'nav.inventory' },
    { href: '/stocktakes', key: 'nav.stocktakes' },
    { href: '/finance', key: 'nav.finance' },
    { href: '/tasks', key: 'nav.tasks' },
    { href: '/hr', key: 'nav.hr' },
]

export default function NavLinks({ canManagePermissions = false }: { canManagePermissions?: boolean }) {
    const pathname = usePathname()
    const t = useTranslations()

    // cut 3:设置(权限)是【新增的顶级导航项】,不挂在财务或人力资源底下 ——
    // 权限管理既不是记账也不是人事,它是系统管理。放进任何一个业务模块都会让
    // "谁能看见什么"看起来像那个模块的内务。
    // 没有 action.manage_permissions 的人【整个条目不渲染】(不是灰掉),
    // 而页面本身也会自己拒绝 —— 藏链接是体贴,不是安全边界。
    // /me 给【每一个】登录用户 —— 人人都有一份自己的档案,所以它不需要任何权限判断。
    // /my-reviews 同理是【/hr 的同级】:部门经理评下属靠的是"我是这一行的评估人"
    // 那条行级策略,不是任何 HR 模块权限 —— 挂在 /hr 底下等于对他们隐身。
    const SELF_ITEMS = [
        { href: '/my-reviews', key: 'nav.myReviews' },
        { href: '/me', key: 'nav.me' },
    ]
    const items = canManagePermissions
        ? [...NAV_ITEMS, ...SELF_ITEMS, { href: '/settings/permissions', key: 'nav.settings' }]
        : [...NAV_ITEMS, ...SELF_ITEMS]

    return (
        <nav className="flex gap-1 overflow-x-auto px-6 pb-2">
            {items.map((item) => {
                const active =
                    pathname === item.href || pathname.startsWith(item.href + '/')
                return (
                    <Link
                        key={item.href}
                        href={item.href}
                        className={
                            'whitespace-nowrap rounded px-3 py-1 text-sm ' +
                            (active
                                ? 'bg-gray-900 text-white'
                                : 'text-gray-600 hover:bg-gray-100 hover:text-gray-900')
                        }
                    >
                        {t(item.key)}
                    </Link>
                )
            })}
        </nav>
    )
}
