'use client'

// 销售登记面板。仅在批次未软删且 remaining_qty > 0 时由页面渲染。
// cut 1:销售必须带价 —— 单价 + 币种(非 USD 附汇率)+ 可选客户,实时金额预览。
// 成功后服务端 revalidate 重取,remaining/state/时间线一起刷新;表单用 formKey 清空。
import { useActionState, useEffect, useState } from 'react'
import { recordSale, type SaleState } from './saleActions'
import { STATE_OPTIONS, labelKeyForValue } from '../../../inbound/options'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoney } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

const initialState: SaleState = {}

type CustomerOption = { id: string; code: string; legal_name: string }

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
    customers,
    batchCustomerId,
}: {
    batchId: string
    remainingQty: number
    unit: string
    state: string
    customers: CustomerOption[]
    batchCustomerId: string | null
}) {
    const t = useTranslations()
    const recordWithId = recordSale.bind(null, batchId)
    const [st, formAction, isPending] = useActionState(recordWithId, initialState)
    const [formKey, setFormKey] = useState(0)

    // 金额预览要读输入值 → 受控;成功后连同 formKey 一起复位
    const [quantity, setQuantity] = useState('')
    const [unitPrice, setUnitPrice] = useState('')
    const [currency, setCurrency] = useState('USD')

    // 成功后清空录入(重挂表单 + 复位受控值)
    useEffect(() => {
        if (st.success) {
            setFormKey((k) => k + 1)
            setQuantity('')
            setUnitPrice('')
            setCurrency('USD')
        }
    }, [st.success])

    const stateLabel = (v: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, v)
        return key ? t(key) : v
    }

    // 实时预览:qty × price = 原币金额;SGD 折算由 DB 按当日牌价定,预览不猜数
    const qtyN = Number(quantity)
    const priceN = Number(unitPrice)
    const previewValid =
        quantity !== '' && unitPrice !== '' && !Number.isNaN(qtyN) && !Number.isNaN(priceN) &&
        qtyN > 0 && priceN > 0
    const previewAmount = previewValid ? Math.round(qtyN * priceN * 100) / 100 : null

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

            <form key={formKey} action={formAction} className="space-y-3">
                <div className="flex flex-wrap gap-2 items-end">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('output.sale.quantity')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="quantity"
                            required
                            value={quantity}
                            onChange={setQuantity}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('output.sale.unitPrice')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="unit_price"
                            required
                            value={unitPrice}
                            onChange={setUnitPrice}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('output.sale.currency')}</label>
                        <select
                            name="currency"
                            value={currency}
                            onChange={(e) => setCurrency(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="USD">USD</option>
                            <option value="SGD">SGD</option>
                        </select>
                    </div>
                    {/* FIN-0:外币按销售日行方买入价(tt_buy)自动估值,当天没牌价直接拒 */}
                    {currency !== 'SGD' && (
                    <p className="text-xs text-gray-500 self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
                )}
                </div>

                <div className="flex flex-wrap gap-2 items-end">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('output.sale.customer')}</label>
                        <select
                            name="customer_id"
                            defaultValue={batchCustomerId ?? ''}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('output.form.selectCustomerOptional')}</option>
                            {customers.map((c) => (
                                <option key={c.id} value={c.id}>
                                    {c.code} - {c.legal_name}
                                </option>
                            ))}
                        </select>
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
                </div>

                {previewAmount !== null && (
                    <p className="text-sm text-gray-600">
                        {t('output.sale.amountPreview', { amount: formatMoney(previewAmount), ccy: currency })}
                    </p>
                )}
            </form>
        </section>
    )
}
