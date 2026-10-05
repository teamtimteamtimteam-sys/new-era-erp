'use client'

// 分录列表工具栏:entry_date 日期区间(端口自 ProcessingToolbar 的日期段)。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { DatePicker } from '@/app/components/ui/date-picker'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function JournalToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const dateFrom = searchParams.get('date_from') ?? ''
    const dateTo = searchParams.get('date_to') ?? ''

    // 合并到当前 params:空值删除该键,保持 URL 干净;改筛选清回第 1 页
    function onChange(key: string, value: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (!value) params.delete(key)
        else params.set(key, value)
        params.delete('page')
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <label className="">
                {t('listFilters.dateFrom')}{' '}
                <DatePicker
                    value={dateFrom}
                    onChange={(v) => onChange('date_from', v)}
                />
            </label>
            <label className="">
                {t('listFilters.dateTo')}{' '}
                <DatePicker
                    value={dateTo}
                    onChange={(v) => onChange('date_to', v)}
                />
            </label>
        </div>
    )
}
