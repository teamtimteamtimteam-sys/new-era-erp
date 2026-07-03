'use client'

// 销售登记面板。仅在批次未软删且 remaining_qty > 0 时由页面渲染。
// 成功后服务端 revalidate 重取,remaining/state/时间线一起刷新;表单用 formKey 清空。
import { useActionState, useEffect, useState } from 'react'
import { recordSale, type SaleState } from './saleActions'
import { STATE_OPTIONS, labelKeyForValue } from '../../../inbound/options'
import { useTranslations } from '@/lib/i18n/client'

const initialState: SaleState = {}

function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function SalePanel({
    batchId,
    remainingQty,
    unit,
    state,
}: {
    batchId: string
    remainingQty: number
    unit: string
    state: string
}) {
    const t = useTranslations()
    const recordWithId = recordSale.bind(null, batchId)
    const [st, formAction, isPending] = useActionState(recordWithId, initialState)
    const [formKey, setFormKey] = useState(0)

    // 成功后清空录入(重挂表单)
    useEffect(() => {
        if (st.success) setFormKey((k) => k + 1)
    }, [st.success])

    const stateLabel = (v: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, v)
        return key ? t(key) : v
    }

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('output.sale.title')}</h2>

            <div className="bg-gray-50 rounded p-4 mb-4 flex flex-wrap gap-8 text-sm">
                <div>
                    <span className="text-gray-600 mr-1">{t('output.sale.remainingLabel')}:</span>
                    <span className="font-medium font-mono">{remainingQty} {unit}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('output.sale.stateLabel')}:</span>
                    <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">{stateLabel(state)}</span>
                </div>
            </div>

            {st.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {st.error}
                </div>
            )}

            <form key={formKey} action={formAction} className="flex flex-wrap gap-2 items-end">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('output.sale.quantity')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="quantity"
                        step="any"
                        min="0"
                        required
                        className="w-32 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.sale.saleDate')}</label>
                    <input
                        type="date"
                        name="sale_date"
                        defaultValue={todayIsoLocal()}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[8rem]">
                    <label className="block text-sm font-medium mb-1">{t('output.sale.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {t('output.sale.button')}
                </button>
            </form>
        </section>
    )
}
