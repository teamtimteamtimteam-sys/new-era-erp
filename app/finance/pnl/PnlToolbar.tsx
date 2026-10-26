'use client'

// 损益表工具栏:日期区间(显示生效值,含默认)+ 快捷预设(本月/上月/本季度/今年 —— 区间由服务端按新加坡时间与财年年末算好,lib/datePresets.ts;TABLE-FEATURES-2 Q5)。
// 改动只写进 URL searchParams,聚合在服务端 page.tsx 完成。
import { DatePicker } from '@/app/components/ui/date-picker'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import type { DatePreset } from '@/lib/datePresets'

export default function PnlToolbar({
    from,
    to,
    presets,
}: {
    from: string // 生效起始日(缺省时为服务端算好的默认值)
    to: string
    presets: readonly DatePreset[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()
    // 与列表页那排快捷链接(app/components/ui/date-presets.tsx)同一组文案:listFilters.presets.*,逐个静态写出
    const presetLabel = (k: DatePreset['key']) =>
        k === 'thisMonth' ? t('listFilters.presets.thisMonth')
        : k === 'lastMonth' ? t('listFilters.presets.lastMonth')
        : k === 'thisQuarter' ? t('listFilters.presets.thisQuarter')
        : t('listFilters.presets.thisYear')

    function push(nextFrom: string, nextTo: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (nextFrom) params.set('date_from', nextFrom)
        else params.delete('date_from')
        if (nextTo) params.set('date_to', nextTo)
        else params.delete('date_to')
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <label className="">
                {t('listFilters.dateFrom')}{' '}
                <DatePicker
                    value={from}
                    onChange={(v) => push(v, to)}
                />
            </label>
            <label className="">
                {t('listFilters.dateTo')}{' '}
                <DatePicker
                    value={to}
                    onChange={(v) => push(from, v)}
                />
            </label>
            {presets.map((p) => (
                <Button
                    key={p.key}
                    type="button"
                    onClick={() => push(p.from, p.to)}
                    variant="secondary" size="default"
                >
                    {presetLabel(p.key)}
                </Button>
            ))}
        </div>
    )
}
