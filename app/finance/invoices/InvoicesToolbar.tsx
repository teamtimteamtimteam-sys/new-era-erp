'use client'

// 发票列表工具栏:issue_date 区间 + 收款状态 + 单据状态(端口自 PaymentsToolbar)。
// 改动只写进 URL searchParams,过滤在服务端完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function InvoicesToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const dateFrom = searchParams.get('date_from') ?? ''
    const dateTo = searchParams.get('date_to') ?? ''
    const state = searchParams.get('state') ?? ''
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
                value={state}
                onChange={(e) => onChange('state', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('expense.filterAllStatus')}</option>
                <option value="unpaid">{t('invoice.paymentState.unpaid')}</option>
                <option value="partial">{t('invoice.paymentState.partial')}</option>
                <option value="paid">{t('invoice.paymentState.paid')}</option>
                <option value="overdue">{t('invoice.filterOverdue')}</option>
            </select>
            {/* 单据状态:默认只看已开具;作废的不在 invoice_status 视图里,服务端另查 */}
            <select
                value={status}
                onChange={(e) => onChange('status', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('invoice.status.issued')}</option>
                <option value="void">{t('invoice.status.void')}</option>
                <option value="all">{t('expense.filterAllStatus')}</option>
            </select>
        </div>
    )
}
