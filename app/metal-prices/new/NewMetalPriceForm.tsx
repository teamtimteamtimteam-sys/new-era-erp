'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createMetalPrice, type CreateMetalPriceState } from './actions'
import { METAL_OPTIONS } from '../options'
import { useTranslations } from '@/lib/i18n/client'
import AnomalyWarning from '../AnomalyWarning'
import IndexPicker from '../IndexPicker'
import type { MetalPriceIndex } from '../indexOptions'
import { ACK_FIELD, ackSignature } from '../anomaly'

const initialState: CreateMetalPriceState = {}

// 本地日期(YYYY-MM-DD),用作价格日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function NewMetalPriceForm({
    indices,
    locale,
}: {
    indices: MetalPriceIndex[]
    locale: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createMetalPrice,
        initialState
    )

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/metal-prices"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('metalPrices.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 金属(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.form.metal')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="metal"
                        required
                        defaultValue=""
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
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.price_usd_per_tonne && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.price_usd_per_tonne}
                        </p>
                    )}
                </div>

                {/* METAL-2:这条报价来自哪个市场 —— 与"怎么来的"(source)是两个轴 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.form.priceIndex')}
                    </label>
                    <IndexPicker name="price_index" indices={indices} defaultValue={null} locale={locale} />
                    <p className="text-xs text-gray-500 mt-1">{t('metalPrices.form.priceIndexHint')}</p>
                </div>

                {/* 价格日期(必填,默认今天)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('metalPrices.form.priceDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="price_date"
                        required
                        defaultValue={todayIsoLocal()}
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
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* METAL-1:异常提示 —— 出现时这一次【没有保存】,确认钮才保存 */}
                {state.warnings && state.warnings.length > 0 && (
                    <>
                        <AnomalyWarning items={state.warnings} />
                        {/* 第二次提交带上确认位。表单里的值原样保留,人不用重敲 */}
                        <input type="hidden" name={ACK_FIELD} value={ackSignature(state.warnings)} />
                    </>
                )}

                {/* 提交按钮 */}
                <div className="flex gap-3 pt-4">
                    <button
                        type="submit"
                        disabled={isPending}
                        className={
                            'px-4 py-2 rounded text-white disabled:bg-gray-400 ' +
                            (state.warnings?.length
                                ? 'bg-amber-600 hover:bg-amber-700'
                                : 'bg-blue-600 hover:bg-blue-700')
                        }
                    >
                        {isPending
                            ? t('common.saving')
                            : state.warnings?.length
                              ? t('metalPrices.anomaly.confirm')
                              : t('common.save')}
                    </button>
                    <Link
                        href="/metal-prices"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
