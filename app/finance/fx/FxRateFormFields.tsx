'use client'

// 汇率表单字段(新增/编辑共用):币种(非 USD)、汇率、日期、备注。
// 语义提示:1 单位外币 = ? USD。
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
        rate_to_usd?: number
        rate_date?: string
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

            {/* 汇率(必填,> 0)*/}
            <div>
                <label className="block text-sm font-medium mb-1">
                    {t('finance.fxPage.form.rate')} <span className="text-red-600">*</span>
                </label>
                <input
                    type="number"
                    name="rate_to_usd"
                    required
                    step="any"
                    min="0"
                    defaultValue={defaults?.rate_to_usd ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
                {fieldErrors?.rate_to_usd && (
                    <p className="text-red-600 text-xs mt-1">{fieldErrors.rate_to_usd}</p>
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
