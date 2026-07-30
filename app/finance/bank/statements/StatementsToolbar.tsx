'use client'

// 对账单列表工具栏:银行账户 + 状态筛选(端口自 PaymentsToolbar)。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function StatementsToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const account = searchParams.get('account') ?? ''
    const status = searchParams.get('status') ?? ''

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
            <select
                value={account}
                onChange={(e) => onChange('account', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('expense.filterAllAccounts')}</option>
                <option value="1010">{t('finance.bank.1010')}</option>
                <option value="1000">{t('finance.bank.1000')}</option>
            </select>
            <select
                value={status}
                onChange={(e) => onChange('status', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('expense.filterAllStatus')}</option>
                <option value="open">{t('bank.status.open')}</option>
                <option value="reconciled">{t('bank.status.reconciled')}</option>
            </select>
        </div>
    )
}
