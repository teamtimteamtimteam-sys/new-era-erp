// app/components/NavLinks.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import type { ModuleEntry } from '@/lib/modules'

// OPS-15:导航项不再在本文件里手写 —— 与首页卡片共用 lib/modules.ts,
// 由服务端(TopNav)按权限过滤后作为 prop 传进来。两份清单分开写必然漂,
// 而这一份漂了的后果是【有人看见一个他进不去的入口】。

export default function NavLinks({
    modules,
    canManagePermissions = false,
}: {
    /** 已按权限过滤 —— 过滤在服务端做,这里只渲染 */
    modules: ModuleEntry[]
    canManagePermissions?: boolean
}) {
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
    const moduleItems = modules.map((m) => ({ href: m.href, key: m.navKey }))
    const items = canManagePermissions
        ? [...moduleItems, ...SELF_ITEMS, { href: '/settings/permissions', key: 'nav.settings' }]
        : [...moduleItems, ...SELF_ITEMS]

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
