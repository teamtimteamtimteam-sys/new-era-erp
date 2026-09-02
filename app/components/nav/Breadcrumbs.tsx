'use client'

// app/components/nav/Breadcrumbs.tsx
// 【面包屑,只在深路由上】—— Tim 的 D4。
//
// ★【"深"是算出来的,不是列出来的】★(IA-BUILD-1 的 3e)
// 判据与那份 23 条的清单都不在这个文件里:清单由 scripts/gen-deep-routes.mjs
// 从文件系统生成(判据写在它的抬头),`npm run build` 比对,过期就红。
// **为什么不手写那 23 条**:勘察 E2/4 记着 finance/Subnav 两份清单的漂移隐患 ——
// 一份手写的深路由清单是同一个形状,加一页的人不会想到来改它,于是那一页
// 永远没有面包屑,而没有任何东西会说出来。
//
// 在深度 ≤2 的 165 条路由上【什么都不画】:那里的面包屑只会把顶栏已经高亮的
// 东西再说一遍。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { breadcrumbTrail } from '@/lib/navTrail'

/**
 * @param openModuleIds 这个读者【进得去】的一级模块。★ 从服务端传下来 ★ ——
 *   面包屑的第一截必须与顶栏高亮是同一个答案(NAV-CLEANUP-1 ⑤),而那个答案
 *   要知道可进性。判据本身在 lib/navTrail.activeModuleForPath,两处共用一支。
 */
export default function Breadcrumbs({ openModuleIds }: { openModuleIds: string[] }) {
    const pathname = usePathname()
    const t = useTranslations()
    const open = new Set(openModuleIds)
    const trail = breadcrumbTrail(pathname, (id) => open.has(id))
    if (trail.length === 0) return null

    return (
        <nav
            aria-label={t('nav.breadcrumb')}
            data-breadcrumb="1"
            className="px-6 pt-3 text-xs text-[color:var(--brand-muted-glass)]"
        >
            <ol className="flex flex-wrap items-center gap-1">
                {trail.map((c, i) => (
                    <li key={`${c.key}-${i}`} className="flex items-center gap-1">
                        {i > 0 && (
                            <span aria-hidden className="text-[color:var(--brand-muted-glass)]">
                                ›
                            </span>
                        )}
                        {c.href ? (
                            <Link href={c.href} className="hover:text-[color:var(--brand-text)] hover:underline">
                                {t(c.key)}
                            </Link>
                        ) : (
                            /* 最后一截是当前页 —— 不是链接;第一截是模块名,它本来就不是地址。 */
                            <span aria-current={i === trail.length - 1 ? 'page' : undefined}>{t(c.key)}</span>
                        )}
                    </li>
                ))}
            </ol>
        </nav>
    )
}
