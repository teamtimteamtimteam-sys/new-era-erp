'use client'

// 汇率表单字段(新增/编辑共用):币种(非 SGD)、日期、牌价方向、汇率、出处、备注。
// 语义:1 单位外币 = ? SGD(本位币)。牌价方向 tt_buy / tt_sell / mid 是三条各自的行,
// 银行买卖两价不同,方向由交易决定 —— 一天一个数不够,所以这里没有"一个汇率"这种字段。
import { useTranslations } from '@/lib/i18n/client'

export type FxFieldErrors = Record<string, string> | undefined

export default function FxRateFormFields({
    currencies,
    fieldErrors,
    defaults,
}: {
    currencies: string[]
    fieldErrors: FxFieldErrors
    defaults?: {
        currency?: string
        rate_type?: string
        rate_sgd_per_unit?: number
        rate_date?: string
        source?: string
        notes?: string | null
    }
}) {
    const t = useTranslations()

    return (
        <>
            {/* 币种(必填)*/}
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('finance.fxPage.form.currency')} <span className="text-red-600">*</span>
                </label>
                <select
                    name="currency"
                    required
                    defaultValue={defaults?.currency ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                >
                    <option value="" disabled>{t('finance.fxPage.form.selectCurrency')}</option>
                    {currencies.map((c) => (
                        <option key={c} value={c}>
                            {c}
                        </option>
                    ))}
                </select>
                {fieldErrors?.currency && (
                    <p className="text-red-600 text-xs mt-1">{fieldErrors.currency}</p>
                )}
            </div>

            {/* 牌价方向(必填)*/}
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('finance.fxPage.form.rateType')} <span className="text-red-600">*</span>
                </label>
                <select
                    name="rate_type"
                    required
                    defaultValue={defaults?.rate_type ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                >
                    <option value="" disabled>{t('finance.fxPage.form.selectRateType')}</option>
                    <option value="tt_buy">{t('finance.fxPage.rateType.tt_buy')}</option>
                    <option value="tt_sell">{t('finance.fxPage.rateType.tt_sell')}</option>
                    <option value="mid">{t('finance.fxPage.rateType.mid')}</option>
                </select>
                {fieldErrors?.rate_type && (
                    <p className="text-red-600 text-xs mt-1">{fieldErrors.rate_type}</p>
                )}
            </div>

            {/* 汇率(必填,> 0)*/}
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('finance.fxPage.form.rate')} <span className="text-red-600">*</span>
                </label>
                <input
                    type="number"
                    name="rate_sgd_per_unit"
                    required
                    step="any"
                    min="0"
                    defaultValue={defaults?.rate_sgd_per_unit ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
                {fieldErrors?.rate_sgd_per_unit && (
                    <p className="text-red-600 text-xs mt-1">{fieldErrors.rate_sgd_per_unit}</p>
                )}
            </div>

            {/* 汇率日期(必填)*/}
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('finance.fxPage.form.rateDate')} <span className="text-red-600">*</span>
                </label>
                <input
                    type="date"
                    name="rate_date"
                    required
                    defaultValue={defaults?.rate_date ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
                {fieldErrors?.rate_date && (
                    <p className="text-red-600 text-xs mt-1">{fieldErrors.rate_date}</p>
                )}
            </div>

            {/* 出处(默认 DBS)*/}
            <div>
                <label className="block text-sm font-medium mb-1">{t('finance.fxPage.form.source')}</label>
                <input
                    name="source"
                    defaultValue={defaults?.source ?? 'DBS'}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            </div>

            {/* 备注 */}
            <div>
                <label className="block text-sm font-medium mb-1">{t('finance.fxPage.form.notes')}</label>
                <textarea
                    name="notes"
                    rows={3}
                    defaultValue={defaults?.notes ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            </div>
        </>
    )
}
