'use client'

// app/purchasing/orders/[id]/ExpectedDateControl.tsx
// CASHFLOW-1:给一期分期设【预计付款日】。
//
// ★【它必须【看得出】是一个估计,而不是一个事实】★
// 三件事在这里做到:① 它在【自己的一列】里,永远不写进合同约定的到期日;
// ② 它旁边写着保管人是谁 —— 一个没人拥有的估计会停止被维护;
// ③ 它用与到期日【不同的字重与颜色】(虚线下划线、琥珀色),
//    与预测页上 estimated 那一档是同一套视觉。
import { useState, useTransition } from 'react'
import { setExpectedDate } from '@/app/finance/cash-forecast/actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ExpectedDateControl({
    termId, purchaseOrderId, triggerEvent, expectedDate, ownerName, canEdit,
}: {
    termId: string
    purchaseOrderId: string
    triggerEvent: string
    expectedDate: string | null
    ownerName: string | null
    canEdit: boolean
}) {
    const t = useTranslations()
    const [value, setValue] = useState(expectedDate ?? '')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    // 【这一期已经有真日期 → 这里什么都不该出现】fixed_date 由表上的 CHECK 保证
    // 带着到期日,on_order 的日子是 PO 的下单日。在一个事实旁边放一个猜测,
    // 只会让人去挑 —— 服务端也按名拒(EXPECTED_DATE_NOT_APPLICABLE)。
    if (!ownerName) {
        return <span className="text-xs text-gray-400">{t('cashForecast.expectedDateNotApplicable')}</span>
    }

    return (
        <div className="text-xs">
            {canEdit ? (
                <input
                    type="date"
                    value={value}
                    disabled={pending}
                    onChange={(e) => {
                        setValue(e.target.value)
                        setError(null)
                        startTransition(async () => {
                            const r = await setExpectedDate(termId, e.target.value, purchaseOrderId)
                            if (r.error) setError(r.error)
                        })
                    }}
                    className="rounded border-b border-dashed border-amber-500 bg-transparent px-1 py-0.5 text-amber-900"
                />
            ) : value ? (
                <span className="border-b border-dashed border-amber-500 text-amber-900">{value}</span>
            ) : (
                <span className="text-gray-400">{t('cashForecast.expectedDateNone')}</span>
            )}
            <span className="block text-[11px] text-gray-500">
                {t('cashForecast.expectedDateOwner', { owner: ownerName })}
            </span>
            <span className="block text-[11px] text-gray-400">{t('cashForecast.expectedDateIsEstimate')}</span>
            {error && <span className="block text-[11px] text-red-700">{error}</span>}
        </div>
    )
}
