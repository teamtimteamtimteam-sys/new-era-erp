'use client'

// app/finance/SubnavClient.tsx
// 财务模块内部子导航的【渲染一半】。'use client' 是因为活动态要 usePathname;
// 判权限要读库,所以判断在 Subnav.tsx(服务端)做完再传进来。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ IA-BUILD-1:【这个文件里那两份手写清单没有了】★
// ════════════════════════════════════════════════════════════════════════════
// 它此前有 ITEMS(决定活动态的最长前缀匹配)与 ordered(决定实际画出来的顺序)
// 两个数组,文件自己写着"必须一起加"。勘察 E2/4 把它记成一处结构性隐患:
// **只加进 ITEMS 的条目【不会被渲染】—— 那就是一个真正的孤儿页,而且没有任何
// 门禁会响。**(实测当时还没有漂:ITEMS 30 条、ordered 31 条,差的是 /finance 自己。)
//
// 现在两份都没了:**条目、顺序、分组、判据全部来自 lib/modules.ts 的 FUNCTIONS**,
// 与顶栏画财务那一栏读的是【同一份】。那个隐患因此不是"今天没发作",是没有了。
//
// 【顺序与分组】数组顺序即显示顺序;第三级的六个组由 group 字段给,
// 组名与组的先后在 FINANCE_GROUPS 里(Tim 的 D1)。
// 【为什么这里画成一条平的滚动条,而不是分组的下拉】这是【页内】子导航,
// 顶栏那一份已经把三级层次画出来了;同一屏上第二个三级菜单是噪音。
// 分组信息在这里只用来【断行】,不画组名。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

/** 注册表派生的条目:标签、地址与判据都不是本文件的。 */
export type FunctionItem = { href: string; key: string; allowed: boolean }

export default function SubnavClient({ items }: { items: FunctionItem[] }) {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先:/finance/journal/new 亮 newEntry 而不是 journal。
    const activeHref = [...items]
        .sort((a, b) => b.href.length - a.href.length)
        .find((i) => pathname === i.href || pathname.startsWith(i.href + '/'))?.href

    return (
        <nav className="flex gap-1 overflow-x-auto mb-6">
            {items.map((item) => {
                // 【进不去的功能:具名的限制,不是缺席】—— 与顶栏同一条(D5),
                // 同一套措辞(common.restricted + dashboard.restrictedHint)。
                if (!item.allowed) {
                    return (
                        <span
                            key={item.href}
                            data-module-restricted="1"
                            title={t('dashboard.restrictedHint')}
                            className="whitespace-nowrap rounded px-3 py-1 text-sm text-[color:var(--brand-muted-text)] cursor-default"
                        >
                            {t(item.key)} · {t('common.restricted')}
                        </span>
                    )
                }
                const active = item.href === activeHref
                return (
                    <Link
                        key={item.href}
                        href={item.href}
                        className={
                            'whitespace-nowrap rounded px-3 py-1 text-sm ' +
                            (active
                                ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                        }
                    >
                        {t(item.key)}
                    </Link>
                )
            })}
        </nav>
    )
}
