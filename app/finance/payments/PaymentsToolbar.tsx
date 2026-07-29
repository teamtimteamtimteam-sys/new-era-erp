'use client'

// 收付款列表工具栏:payment_date 日期区间 + 方向筛选(端口自 JournalToolbar)。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function PaymentsToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const dateFrom = searchParams.get('date_from') ?? ''
    const dateTo = searchParams.get('date_to') ?? ''
    const direction = searchParams.get('direction') ?? ''

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
            <label className="text-sm text-gray-600">
                {t('listFilters.dateFrom')}{' '}
                <input
                    type="date"
                    value={dateFrom}
                    onChange={(e) => onChange('date_from', e.target.value)}
                    className="rounded border border-gray-300 bg-white px-3 py-2"
                />
            </label>
            <label className="text-sm text-gray-600">
                {t('listFilters.dateTo')}{' '}
                <input
                    type="date"
                    value={dateTo}
                    onChange={(e) => onChange('date_to', e.target.value)}
                    className="rounded border border-gray-300 bg-white px-3 py-2"
                />
            </label>
            <select
                value={direction}
                onChange={(e) => onChange('direction', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('finance.direction.all')}</option>
                <option value="in">{t('finance.direction.in')}</option>
                <option value="out">{t('finance.direction.out')}</option>
            </select>
        </div>
    )
}
