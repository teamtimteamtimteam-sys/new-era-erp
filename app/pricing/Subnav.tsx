'use client'

// app/pricing/Subnav.tsx
// 定价板块内部子导航(公式 / 计价器 / 金属行情),样式端口自 finance/Subnav。
// 行情页仍住在 /metal-prices(未迁移,老链接照常可用),这里只是把它并进同一组入口。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/pricing/formulas', key: 'pricing.subnav.formulas' },
    { href: '/pricing/calculator', key: 'pricing.subnav.calculator' },
    { href: '/metal-prices', key: 'pricing.subnav.prices' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先;都不中则定价首页
    const activeHref =
        ITEMS.find((i) => pathname === i.href || pathname.startsWith(i.href + '/'))?.href ??
        '/pricing'

    const ordered = [{ href: '/pricing', key: 'pricing.hubTitle' }, ...ITEMS]

    return (
        <nav className="flex gap-1 overflow-x-auto mb-6">
            {ordered.map((item) => {
                const active = item.href === activeHref
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
