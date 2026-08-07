'use client'

// 现金流量表工具栏(与损益表同一形状、同一预设 —— 三张报表的期间控件必须一致):日期区间(显示生效值,含默认)+ 快捷预设(本月/上月/今年)。
// 改动只写进 URL searchParams,聚合在服务端 page.tsx 完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function CashflowToolbar({
    from,
    to,
    presets,
}: {
    from: string // 生效起始日(缺省时为服务端算好的默认值)
    to: string
    presets: { key: string; from: string; to: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

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
            <label className="text-sm text-gray-600">
                {t('listFilters.dateFrom')}{' '}
                <input
                    type="date"
                    value={from}
                    onChange={(e) => push(e.target.value, to)}
                    className="rounded border border-gray-300 bg-white px-3 py-2"
                />
            </label>
            <label className="text-sm text-gray-600">
                {t('listFilters.dateTo')}{' '}
                <input
                    type="date"
                    value={to}
                    onChange={(e) => push(from, e.target.value)}
                    className="rounded border border-gray-300 bg-white px-3 py-2"
                />
            </label>
            {presets.map((p) => (
                <button
                    key={p.key}
                    type="button"
                    onClick={() => push(p.from, p.to)}
                    className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                >
                    {t('finance.presets.' + p.key)}
                </button>
            ))}
        </div>
    )
}
