'use client'

// 加工单列表工具栏:仅两个日期字段(process_date 区间)。URL 驱动,改动回到第 1 页。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function ProcessingToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const currentDateFrom = searchParams.get('date_from') ?? ''
    const currentDateTo = searchParams.get('date_to') ?? ''

    function buildHref(updates: Record<string, string | null>) {
        const params = new URLSearchParams(searchParams.toString())
        for (const [k, v] of Object.entries(updates)) {
            if (!v) params.delete(k)
            else params.set(k, v)
        }
        const qs = params.toString()
        return qs ? `${pathname}?${qs}` : pathname
    }

    function onFilterChange(key: string, value: string) {
        router.push(buildHref({ [key]: value || null, page: null }))
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <label className="flex items-center gap-1 text-sm text-gray-600">
                {t('listFilters.dateFrom')}
                <input
                    type="date"
                    value={currentDateFrom}
                    onChange={(e) => onFilterChange('date_from', e.target.value)}
                    className="rounded border border-gray-300 bg-white px-2 py-2"
                />
            </label>
            <label className="flex items-center gap-1 text-sm text-gray-600">
                {t('listFilters.dateTo')}
                <input
                    type="date"
                    value={currentDateTo}
                    onChange={(e) => onFilterChange('date_to', e.target.value)}
                    className="rounded border border-gray-300 bg-white px-2 py-2"
                />
            </label>
        </div>
    )
}
