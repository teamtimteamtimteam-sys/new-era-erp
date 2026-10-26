'use client'
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-2(Tim 2026-10-25 Q5)· 日期快捷区间的一排链接 —— 11 张列表与两张报表共用
// ════════════════════════════════════════════════════════════════════════════
// 区间由服务端算好传进来(lib/datePresetsServer.ts:新加坡的今天 + 财年年末),这里只把它们画成链接:
//   保留地址里别的筛选,写入起止两个参数,【去掉页码】(换了区间,第几页就没有意义了)。
//   两个参数一次写进去 —— 工具栏的 onChange 一次只写一个键,连按两下会丢掉前一个(survey-presets.md)。
// 当前地址正好是某个区间时,那一个画成当前态(aria-current)。
import Link from 'next/link'
import { usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import type { DatePreset } from '@/lib/datePresets'
import { cn } from '@/lib/utils'

export function DatePresetLinks({ presets, fromKey = 'date_from', toKey = 'date_to', pageKey = 'page', className }: {
    presets: readonly DatePreset[]
    fromKey?: string
    toKey?: string
    pageKey?: string
    className?: string
}) {
    const t = useTranslations()
    const pathname = usePathname()
    const sp = useSearchParams()
    const label = (k: DatePreset['key']) =>
        k === 'thisMonth' ? t('listFilters.presets.thisMonth')
        : k === 'lastMonth' ? t('listFilters.presets.lastMonth')
        : k === 'thisQuarter' ? t('listFilters.presets.thisQuarter')
        : t('listFilters.presets.thisYear')
    return (
        <nav aria-label={t('listFilters.presetsLabel')} data-slot="date-presets" className={cn('mb-3 flex flex-wrap items-center gap-2 text-sm', className)}>
            <span className="text-[color:var(--brand-muted-text)]">{t('listFilters.presetsLabel')}</span>
            {presets.map((p) => {
                const q = new URLSearchParams(sp.toString())
                q.set(fromKey, p.from)
                q.set(toKey, p.to)
                q.delete(pageKey)
                const active = sp.get(fromKey) === p.from && sp.get(toKey) === p.to
                return (
                    <Link
                        key={p.key}
                        href={`${pathname}?${q.toString()}`}
                        data-preset={p.key}
                        data-from={p.from}
                        data-to={p.to}
                        aria-current={active ? 'true' : undefined}
                        className={cn('rounded border px-2 py-1 app-link', active && 'font-bold')}
                    >
                        {label(p.key)}
                    </Link>
                )
            })}
        </nav>
    )
}
