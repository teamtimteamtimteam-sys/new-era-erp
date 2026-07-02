'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateMetalPrice, type UpdateMetalPriceState } from './actions'
import { METAL_OPTIONS } from '../../options'
import { useTranslations } from '@/lib/i18n/client'

const initialState: UpdateMetalPriceState = {}

type MetalPrice = {
    id: string
    metal: string
    price_usd_per_tonne: number
    price_date: string
    notes: string | null
}

export default function EditMetalPriceForm({ row }: { row: MetalPrice }) {
    const t = useTranslations()
    const updateWithId = updateMetalPrice.bind(null, row.id)
    const [state, formAction, isPending] = useActionState(updateWithId, initialState)

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 金属(必填,预选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.form.metal')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="metal"
                        required
                        defaultValue={row.metal}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>{t('metalPrices.form.selectMetal')}</option>
                        {METAL_OPTIONS.map((o) => (
                            <option key={o.value} value={o.value}>
                                {t(o.labelKey)}
                            </option>
                        ))}
                    </select>
                    {state.fieldErrors?.metal && (
                        <p className="text-red-600 text-xs mt-1">{state.fieldErrors.metal}</p>
                    )}
                </div>

                {/* 价格(必填,> 0)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.form.price')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="price_usd_per_tonne"
                        required
                        step="0.01"
                        min="0"
                        defaultValue={row.price_usd_per_tonne}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.price_usd_per_tonne && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.price_usd_per_tonne}
                        </p>
                    )}
                </div>

                {/* 价格日期(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.form.priceDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="price_date"
                        required
                        defaultValue={row.price_date}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.price_date && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.price_date}
                        </p>
                    )}
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('metalPrices.form.notes')}</label>
                    <textarea
                        name="notes"
                        rows={3}
                        defaultValue={row.notes ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 提交按钮 */}
                <div className="flex gap-3 pt-4">
                    <button
                        type="submit"
                        disabled={isPending}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                    <Link
                        href="/metal-prices"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
