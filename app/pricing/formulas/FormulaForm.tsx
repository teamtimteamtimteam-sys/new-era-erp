'use client'

// 定价公式表单(新建/编辑共用)。计价基准选 average 时才出现天数;
// 适用对象三选一,选中哪个才出现对应下拉。
// 下方计价比例表:七个金属各一行,【留空 = 该金属不计价】(保存时删除旧行)。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { METAL_OPTIONS } from '@/app/metal-prices/options'
import type { FormulaState } from './actions'

const initialState: FormulaState = {}

export type PartyOption = { id: string; name: string }

export type FormulaDefaults = {
    name: string
    direction: string
    price_basis: string
    average_days: string
    treatment_charge_usd_per_tonne: string
    flat_discount_pct: string
    supplier_id: string | null
    customer_id: string | null
    notes: string
    is_active: boolean
    payables: Record<string, string>
}

export const EMPTY_FORMULA: FormulaDefaults = {
    name: '',
    direction: 'both',
    price_basis: 'spot',
    average_days: '',
    treatment_charge_usd_per_tonne: '',
    flat_discount_pct: '',
    supplier_id: null,
    customer_id: null,
    notes: '',
    is_active: true,
    payables: {},
}

export default function FormulaForm({
    action,
    defaults,
    suppliers,
    customers,
}: {
    action: (state: FormulaState, formData: FormData) => Promise<FormulaState>
    defaults: FormulaDefaults
    suppliers: PartyOption[]
    customers: PartyOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(action, initialState)

    const [basis, setBasis] = useState(defaults.price_basis)
    const [mode, setMode] = useState<'generic' | 'supplier' | 'customer'>(
        defaults.supplier_id ? 'supplier' : defaults.customer_id ? 'customer' : 'generic'
    )
    const [averageDays, setAverageDays] = useState(defaults.average_days)
    const [treatment, setTreatment] = useState(defaults.treatment_charge_usd_per_tonne)
    const [discount, setDiscount] = useState(defaults.flat_discount_pct)
    const [payables, setPayables] = useState<Record<string, string>>(defaults.payables)

    const err = (k: string) => state.fieldErrors?.[k]

    return (
        <form action={formAction} className="space-y-5 max-w-3xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[18rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('pricing.form.name')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        required
                        defaultValue={defaults.name}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {err('name') && <p className="text-red-600 text-sm mt-1">{err('name')}</p>}
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.direction')}</label>
                    <select
                        name="direction"
                        defaultValue={defaults.direction}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="both">{t('pricing.direction.both')}</option>
                        <option value="purchase">{t('pricing.direction.purchase')}</option>
                        <option value="sale">{t('pricing.direction.sale')}</option>
                    </select>
                </div>
            </div>

            {/* 计价基准:average 才出天数 */}
            <div className="flex flex-wrap items-end gap-4">
                <div>
                    <span className="block text-sm font-medium mb-1">{t('pricing.form.basis')}</span>
                    <label className="mr-4 text-sm">
                        <input
                            type="radio"
                            name="price_basis"
                            value="spot"
                            checked={basis === 'spot'}
                            onChange={() => setBasis('spot')}
                            className="mr-1"
                        />
                        {t('pricing.form.basisSpot')}
                    </label>
                    <label className="text-sm">
                        <input
                            type="radio"
                            name="price_basis"
                            value="average"
                            checked={basis === 'average'}
                            onChange={() => setBasis('average')}
                            className="mr-1"
                        />
                        {t('pricing.form.basisAverage')}
                    </label>
                </div>
                {basis === 'average' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('pricing.form.averageDays')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="average_days"
                            value={averageDays}
                            onChange={setAverageDays}
                            className="w-24 border border-gray-300 px-3 py-2 rounded"
                        />
                        {err('average_days') && (
                            <p className="text-red-600 text-sm mt-1">{err('average_days')}</p>
                        )}
                    </div>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.treatment')}</label>
                    <DecimalInput
                        name="treatment_charge_usd_per_tonne"
                        value={treatment}
                        onChange={setTreatment}
                        className="w-40 border border-gray-300 px-3 py-2 rounded"
                    />
                    {err('treatment_charge_usd_per_tonne') && (
                        <p className="text-red-600 text-sm mt-1">{err('treatment_charge_usd_per_tonne')}</p>
                    )}
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.discount')}</label>
                    <DecimalInput
                        name="flat_discount_pct"
                        value={discount}
                        onChange={setDiscount}
                        className="w-32 border border-gray-300 px-3 py-2 rounded"
                    />
                    {err('flat_discount_pct') && (
                        <p className="text-red-600 text-sm mt-1">{err('flat_discount_pct')}</p>
                    )}
                </div>
            </div>

            {/* 适用对象 */}
            <div className="flex flex-wrap items-end gap-4">
                <div>
                    <span className="block text-sm font-medium mb-1">{t('pricing.form.counterpartyMode')}</span>
                    <input type="hidden" name="counterparty_mode" value={mode} />
                    <label className="mr-4 text-sm">
                        <input
                            type="radio"
                            checked={mode === 'generic'}
                            onChange={() => setMode('generic')}
                            className="mr-1"
                        />
                        {t('pricing.form.modeGeneric')}
                    </label>
                    <label className="mr-4 text-sm">
                        <input
                            type="radio"
                            checked={mode === 'supplier'}
                            onChange={() => setMode('supplier')}
                            className="mr-1"
                        />
                        {t('pricing.form.modeSupplier')}
                    </label>
                    <label className="text-sm">
                        <input
                            type="radio"
                            checked={mode === 'customer'}
                            onChange={() => setMode('customer')}
                            className="mr-1"
                        />
                        {t('pricing.form.modeCustomer')}
                    </label>
                </div>
                {mode === 'supplier' && (
                    <div className="flex-1 min-w-[16rem]">
                        <select
                            name="supplier_id"
                            defaultValue={defaults.supplier_id ?? ''}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('finance.selectCounterparty')}</option>
                            {suppliers.map((s) => (
                                <option key={s.id} value={s.id}>
                                    {s.name}
                                </option>
                            ))}
                        </select>
                        {err('supplier_id') && <p className="text-red-600 text-sm mt-1">{err('supplier_id')}</p>}
                    </div>
                )}
                {mode === 'customer' && (
                    <div className="flex-1 min-w-[16rem]">
                        <select
                            name="customer_id"
                            defaultValue={defaults.customer_id ?? ''}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('finance.selectCounterparty')}</option>
                            {customers.map((c) => (
                                <option key={c.id} value={c.id}>
                                    {c.name}
                                </option>
                            ))}
                        </select>
                        {err('customer_id') && <p className="text-red-600 text-sm mt-1">{err('customer_id')}</p>}
                    </div>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                <label className="text-sm">
                    <input
                        type="checkbox"
                        name="is_active"
                        defaultChecked={defaults.is_active}
                        className="mr-2"
                    />
                    {t('pricing.form.active')}
                </label>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        defaultValue={defaults.notes}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 计价比例 */}
            <div>
                <h2 className="text-lg font-semibold mb-1">{t('pricing.form.payableTitle')}</h2>
                <p className="text-sm text-gray-500 mb-3">{t('pricing.payableBlankHint')}</p>
                <table className="w-full border-collapse border border-gray-300 max-w-md">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.form.colMetal')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.form.colPayable')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {METAL_OPTIONS.map((opt) => (
                            <tr key={opt.value}>
                                <td className="border border-gray-300 px-4 py-2">
                                    {t(opt.labelKey)}
                                    <span className="text-gray-400 font-mono text-xs ml-2">{opt.value}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <input type="hidden" name="payable_metal" value={opt.value} />
                                    <DecimalInput
                                        name="payable_pct"
                                        value={payables[opt.value] ?? ''}
                                        onChange={(raw) =>
                                            setPayables((p) => ({ ...p, [opt.value]: raw }))
                                        }
                                        className="w-28 border border-gray-300 px-3 py-2 rounded"
                                    />
                                    {err('payable_' + opt.value) && (
                                        <p className="text-red-600 text-sm mt-1">{err('payable_' + opt.value)}</p>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('pricing.form.submit')}
                </button>
                <Link href="/pricing/formulas" className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
