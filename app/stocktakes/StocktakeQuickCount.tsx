'use client'

// app/stocktakes/StocktakeQuickCount.tsx
// 批次编辑页顶部的"盘点进行中"横幅:扫批次 QR 落到编辑页后,就地录入实点数,
// 免去到盘点单里找批次。走与 CountList 相同的 saveCount action。
import { useActionState } from 'react'
import { saveCount, type SaveCountState, type BatchSide } from './actions'
import { useTranslations } from '@/lib/i18n/client'

const initialState: SaveCountState = {}

export default function StocktakeQuickCount({
    stocktakeId,
    stocktakeCode,
    side,
    batchId,
    counted,
}: {
    stocktakeId: string
    stocktakeCode: string
    side: BatchSide
    batchId: string
    counted: number | null // 本批已录的实点数(预填;没有则空)
}) {
    const t = useTranslations()
    const action = saveCount.bind(null, stocktakeId, side, batchId)
    const [state, formAction, isPending] = useActionState(action, initialState)

    return (
        <div className="bg-amber-50 border border-amber-300 rounded p-3 mb-6">
            <p className="text-sm text-amber-900 mb-2">
                {t('stocktakes.scanBanner', { code: stocktakeCode })}
            </p>
            {state.error && <p className="text-red-600 text-sm mb-2">{state.error}</p>}
            <form action={formAction} className="flex items-stretch gap-2">
                <input
                    type="number"
                    name="qty"
                    required
                    step="any"
                    min="0"
                    inputMode="decimal"
                    defaultValue={counted ?? ''}
                    placeholder={t('stocktakes.qtyPlaceholder')}
                    className="flex-1 min-w-0 border border-gray-300 rounded px-3 py-3 text-base min-h-[48px] bg-white"
                />
                <button
                    type="submit"
                    disabled={isPending}
                    className="shrink-0 bg-blue-600 text-white text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('stocktakes.save')}
                </button>
                {state.ok && !isPending && (
                    <span className="flex items-center px-1 text-green-600" aria-hidden>
                        ✓
                    </span>
                )}
            </form>
        </div>
    )
}
