// app/components/NavLinks.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

// OPS-15:导航项不再在本文件里手写 —— 清单在 lib/modules.ts,
// 由服务端(TopNav)判过权限后作为 prop 传进来。两份清单分开写必然漂,
// 而这一份漂了的后果是【有人看见一个他进不去的入口】。
//
// 【NAV-REG-1 / R4:进不去的模块【照样画出来】,画成「受限」】(Tim 的裁定 D5)
// 在这之前 TopNav 传下来的是【过滤后】的清单,于是一个进不去的模块在导航条上
// 整个消失 —— 屏幕上"这个系统里没有物流这回事"与"物流你进不去"长得一模一样。
// 那正是 moduleGuard 抬头那条病(进不去的空 ≠ 真的空)在导航层的样子,只是它
// 藏得更深:那一层至少还有一张页面会说话,这一层【连一个可点的东西都没有】。
// 现在 modules 是【全部】模块,每个带 allowed;进不去的渲染成一个不可点的
// 「模块名 · 受限」。
//
// 【措辞沿用既有的那一套】common.restricted + dashboard.restrictedHint ——
// 与首页牌子上那两行逐字相同。同一个意思有第二套说法,就是下一次漂移的种子。

/** 一个导航项:标签 + 【这个人进不进得去】。allowed=false 不是"不渲染"。 */
type NavItem = { href: string; key: string; allowed: boolean }

export default function NavLinks({
    modules,
    deletedAllowed = false,
    canManagePermissions = false,
    canEditDictionaries = false,
    canBulkImport = false,
}: {
    /** 【全部】模块,每个带 allowed —— 判权限在服务端做,这里只渲染,包括渲染拒绝 */
    modules: NavItem[]
    /** AUDEL-3 的 /deleted:同样来自注册表(FN.deleted),不是本文件里的一个谓词 */
    deletedAllowed?: boolean
    canManagePermissions?: boolean
    // DICT-ADMIN:能编辑【任一张】字典就看得见那一项 —— 与 manage_permissions 无关。
    canEditDictionaries?: boolean
    // IMPORT-1:批量导入自己一个权限码 —— 与「设置」那一项的判据无关,
    // 理由与上面字典那一条逐字相同(沿用 manage_permissions 会造出一个够不到的页)。
    canBulkImport?: boolean
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
    // AUDEL-3:/deleted 跨七支、六个码。
    // 【NAV-REG-1:它现在装得进那个形状了】—— 从前这里写着"ModuleEntry.permission
    // 是一个字符串,表达不了那个并集",而 permission 现在是一个谓词,那个并集就是
    // FN.deleted.permission 的 any 那一半(六个码,取自视图每一行自带的 permission)。
    // 【旧的"不藏"论证已经被 R4 取消了前提】:那段话说"藏错的代价比露错的大",
    // 而 R4 之后【没有任何东西被藏起来】—— 进不去的项照样画出来,画成「受限」。
    // 于是两种代价都不用付:一个模块都没有的人看得见这个审计入口存在,并且看得见
    // 它对他关着,而不是点进去撞上一张分不清"你无权"与"没人删过东西"的空表。
    // /my-reviews 与 /me 仍然对【每一个】登录用户开放:它们的判据是行级的
    //(我是不是这一行的评估人 / 这是不是我自己的档案),不是任何模块权限。
    const SELF_ITEMS: NavItem[] = [
        { href: '/my-reviews', key: 'nav.myReviews', allowed: true },
        { href: '/deleted', key: 'nav.deleted', allowed: deletedAllowed },
        { href: '/me', key: 'nav.me', allowed: true },
    ]
    const moduleItems: NavItem[] = modules.map((m) => ({ href: m.href, key: m.key, allowed: m.allowed }))
    // DICT-ADMIN:字典维护【另起一项】,不挂在「设置」那一项上。
    // 那一项的判据是 action.manage_permissions,而五张字典把门的是
    // module.materials.edit / module.inbound.edit —— 沿用它会造出一个
    // **物料编辑员永远看不见的页**,而"没有入口的页"这个仓库付过四次账。
    // 【设置那三项仍然是"有就画、没有就不画"】—— 它们不是模块,R4 不管它们。
    // 而"三项设置全都挂在 .edit / action 码上,于是五个角色一项设置都看不见"
    // 是一个【权限设计问题】,Tim 已把它移出本刀,记在
    // docs/information-architecture-scoping.md 的待决清单里(开户前的权限那一刀)。
    const items: NavItem[] = [
        ...moduleItems,
        ...SELF_ITEMS,
        ...(canEditDictionaries ? [{ href: '/settings/dictionaries', key: 'nav.dictionaries', allowed: true }] : []),
        ...(canBulkImport ? [{ href: '/settings/import', key: 'nav.import', allowed: true }] : []),
        ...(canManagePermissions ? [{ href: '/settings/permissions', key: 'nav.settings', allowed: true }] : []),
    ]

    return (
        <nav className="flex gap-1 overflow-x-auto px-6 pb-2">
            {items.map((item) => {
                // 【进不去的项:具名的限制,不是缺席】(R4)
                // data-module-restricted:给按角色的可达性检查用的【机器标记】,
                // 与 moduleGuard 的 data-access-denied 同一条理由 —— 认文案字符串
                // 去分辨"受限项"漏过一次就是一次误报。
                if (!item.allowed) {
                    return (
                        <span
                            key={item.href}
                            data-module-restricted="1"
                            title={t('dashboard.restrictedHint')}
                            className="whitespace-nowrap rounded px-3 py-1 text-sm text-gray-400 cursor-default"
                        >
                            {t(item.key)} · {t('common.restricted')}
                        </span>
                    )
                }
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
