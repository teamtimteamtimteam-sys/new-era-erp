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
    canEditDictionaries = false,
}: {
    /** 已按权限过滤 —— 过滤在服务端做,这里只渲染 */
    modules: ModuleEntry[]
    canManagePermissions?: boolean
    // DICT-ADMIN:能编辑【任一张】字典就看得见那一项 —— 与 manage_permissions 无关。
    canEditDictionaries?: boolean
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
    // AUDEL-3:/deleted 与 /margin 一样【装不进 lib/modules.ts 的形状】—— 它跨七个
    // 模块,ModuleEntry.permission 是一个字符串,表达不了那个并集。而它与 /margin
    // 不同的是:它【不需要】表达。视图 deleted_records 每一行自带 permission,
    // 无权的种类整类缺席,所以这个链接对任何人点开都是一个正当答案 ——
    // 有模块的人看见他那些模块里被删的东西,一个模块都没有的人看见那句具名空状态。
    // 【为什么不按权限藏起来】要藏就得在这里写一个"任一模块"的谓词,那正是 OPS-15
    // 说的第二份定义;而藏错的代价(有人看不见一个他本可以看的审计入口)比
    // 露错的代价(一句"你看得见的范围里没有")大。/my-reviews 是同一条:
    // 它对非评估人也是空的,一样不藏。
    const SELF_ITEMS = [
        { href: '/my-reviews', key: 'nav.myReviews' },
        { href: '/deleted', key: 'nav.deleted' },
        { href: '/me', key: 'nav.me' },
    ]
    const moduleItems = modules.map((m) => ({ href: m.href, key: m.navKey }))
    // DICT-ADMIN:字典维护【另起一项】,不挂在「设置」那一项上。
    // 那一项的判据是 action.manage_permissions,而五张字典把门的是
    // module.materials.edit / module.inbound.edit —— 沿用它会造出一个
    // **物料编辑员永远看不见的页**,而"没有入口的页"这个仓库付过四次账。
    const items = [
        ...moduleItems,
        ...SELF_ITEMS,
        ...(canEditDictionaries ? [{ href: '/settings/dictionaries', key: 'nav.dictionaries' }] : []),
        ...(canManagePermissions ? [{ href: '/settings/permissions', key: 'nav.settings' }] : []),
    ]

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
