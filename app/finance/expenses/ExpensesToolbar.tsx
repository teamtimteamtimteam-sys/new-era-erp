'use client'

// 开支列表工具栏:expense_date 日期区间 + 付款状态 + 费用科目筛选
// (端口自 PaymentsToolbar)。改动只写进 URL searchParams,过滤在服务端完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function ExpensesToolbar({
    accounts,
}: {
    accounts: { code: string; name: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const dateFrom = searchParams.get('date_from') ?? ''
    const dateTo = searchParams.get('date_to') ?? ''
    const status = searchParams.get('status') ?? ''
    const account = searchParams.get('account') ?? ''

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
                value={status}
                onChange={(e) => onChange('status', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('expense.filterAllStatus')}</option>
                <option value="paid">{t('expense.status.paid')}</option>
                <option value="unpaid">{t('expense.status.unpaid')}</option>
            </select>
            <select
                value={account}
                onChange={(e) => onChange('account', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('expense.filterAllAccounts')}</option>
                {accounts.map((a) => (
                    <option key={a.code} value={a.code}>
                        {a.code} {a.name}
                    </option>
                ))}
            </select>
        </div>
    )
}
