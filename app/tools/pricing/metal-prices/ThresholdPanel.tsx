'use client'

// METAL-1:阈值面板。人人看得见(阈值不是秘密,提示里就印着它),
// 有 module.pricing.edit 的人改得动。
//
// 【为什么把它摆在行情列表页上】改阈值的人就是录行情的人 —— 把这个数字放进
// /finance/settings 会让它归到另一批人名下,而他们不看这块屏。
import { useActionState } from 'react'
import { updateAnomalyThreshold, type ThresholdState } from './thresholdActions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

const initialState: ThresholdState = {}

export default function ThresholdPanel({
    thresholdPct,
    notes,
    canEdit,
}: {
    thresholdPct: number
    notes: string | null
    canEdit: boolean
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(updateAnomalyThreshold, initialState)

    return (
        <div className="border border-gray-300 rounded-lg p-4 mb-6 max-w-3xl">
            <p className="font-medium mb-1">{t('metalPrices.settings.title')}</p>
            <p className="text-sm text-gray-600 mb-3">{t('metalPrices.settings.hint')}</p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-3 text-sm">
                    {state.error}
                </div>
            )}
            {state.saved && (
                <div className="bg-green-50 border border-green-300 text-green-800 px-3 py-2 rounded mb-3 text-sm">
                    {t('metalPrices.settings.saved')}
                </div>
            )}

            {canEdit ? (
                <form action={formAction} className="flex flex-wrap items-end gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('metalPrices.settings.label')}
                        </label>
                        <input
                            type="number"
                            name="metal_price_change_warn_pct"
                            step="0.1"
                            min="0.1"
                            required
                            defaultValue={thresholdPct}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <Button
                        type="submit"
                        disabled={isPending}
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                </form>
            ) : (
                <p className="text-sm">
                    {t('metalPrices.settings.label')}:{' '}
                    <span className="font-mono">{thresholdPct}</span>
                </p>
            )}

            {/* 引导里那一行自带的说明 —— "这是默认值,不是决定"就写在数据里,
                而不是只写在某次提交的说明里 */}
            {notes && <p className="text-xs text-gray-500 mt-2">{notes}</p>}
        </div>
    )
}
