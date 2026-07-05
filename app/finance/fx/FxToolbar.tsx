'use client'

// 汇率列表工具栏:币种筛选下拉(全部 + 非 USD 币种,选项由服务端页面传入)。
// 端口自 MetalPricesToolbar。改动只写进 URL searchParams,过滤在服务端完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function FxToolbar({ currencies }: { currencies: string[] }) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const current = searchParams.get('currency') ?? ''

    function onFilterChange(value: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (!value) params.delete('currency')
        else params.set('currency', value)
        params.delete('page')
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <select
                value={current}
                onChange={(e) => onFilterChange(e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('finance.fxPage.allCurrencies')}</option>
                {currencies.map((c) => (
                    <option key={c} value={c}>
                        {c}
                    </option>
                ))}
            </select>
        </div>
    )
}
