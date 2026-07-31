'use client'

// 采购单列表工具栏:order_date 区间 + 供应商 + 单据状态(端口自 InvoicesToolbar)。
// 改动只写进 URL searchParams,过滤在服务端完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const STATUSES = ['draft', 'confirmed', 'receiving', 'closed', 'cancelled'] as const

export default function OrdersToolbar({ suppliers }: { suppliers: { id: string; name: string }[] }) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const dateFrom = searchParams.get('date_from') ?? ''
    const dateTo = searchParams.get('date_to') ?? ''
    const supplier = searchParams.get('supplier') ?? ''
    const status = searchParams.get('status') ?? ''

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
                value={supplier}
                onChange={(e) => onChange('supplier', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('purchasing.filterAllSuppliers')}</option>
                {suppliers.map((s) => (
                    <option key={s.id} value={s.id}>
                        {s.name}
                    </option>
                ))}
            </select>
            <select
                value={status}
                onChange={(e) => onChange('status', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('expense.filterAllStatus')}</option>
                {STATUSES.map((s) => (
                    <option key={s} value={s}>
                        {t('purchasing.status.' + s)}
                    </option>
                ))}
            </select>
        </div>
    )
}
