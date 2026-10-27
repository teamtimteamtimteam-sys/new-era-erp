'use client'

// 采购单列表工具栏:order_date 区间 + 供应商 + 单据状态(端口自 InvoicesToolbar)。
// 改动只写进 URL searchParams,过滤在服务端完成。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { filteredListHref } from '@/lib/savedViews' // SYSTEM-MAP-1 D1:清空筛选 → 原始列表

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
        router.push(filteredListHref(pathname, params))
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
            {/* 筛选下拉 max-w-full:Tim 2026-10-26 TABLE-FEATURES-2 Q7 的例外(只限列表工具栏里的筛选下拉),docs/variant-c-spec.md §4.1d */}
            <select
                value={supplier}
                onChange={(e) => onChange('supplier', e.target.value)}
                className={`${CONTROL_SELECT} max-w-full`}
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
                className={CONTROL_SELECT}
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
