'use client'

// app/stocktakes/CountList.tsx
// 盘点批次列表(已盘/未盘共用,mode 切换展示):点条目原地展开点数行,
// 保存走 saveCount(与批次页的 StocktakeQuickCount 同一个 action)。移动端大触控目标。
import { useEffect, useState, useActionState } from 'react'
import { saveCount, type SaveCountState, type BatchSide } from './actions'
import { formatSigned } from './delta'
import { useTranslations } from '@/lib/i18n/client'

export type CountItem = {
    side: BatchSide
    batchId: string
    code: string
    material: string
    remaining: number | null // 批次当前剩余(批次已删则 null)
    unit: string
    counted: number | null // 已录实点数(未盘为 null)
    book: number | null // 录数时的账面快照(未盘为 null)
    delta: number | null // 实点 − 当前剩余(服务端预计算;未盘/批次已删为 null)
    notes: string | null
}

const initialState: SaveCountState = {}

// 移动端触摸友好:大字号 + 约 48px 高的触控目标(端口自 receive/ReceiveForm)。
const fieldCls =
    'w-full border border-gray-300 rounded px-3 py-3 text-base min-h-[48px] bg-white'

// 展开的内联点数行:数量 + 备注 + 保存。保存成功后由父组件收起(数据经 revalidate 刷新)。
function CountRow({
    stocktakeId,
    item,
    onDone,
}: {
    stocktakeId: string
    item: CountItem
    onDone: () => void
}) {
    const t = useTranslations()
    const action = saveCount.bind(null, stocktakeId, item.side, item.batchId)
    const [state, formAction, isPending] = useActionState(action, initialState)

    useEffect(() => {
        if (state.ok) onDone()
    }, [state, onDone])

    return (
        <form action={formAction} className="space-y-3">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm">
                    {state.error}
                </div>
            )}
            <div className="flex items-stretch gap-2">
                <input
                    type="number"
                    name="qty"
                    required
                    step="any"
                    min="0"
                    inputMode="decimal"
                    defaultValue={item.counted ?? ''}
                    placeholder={t('stocktakes.qtyPlaceholder')}
                    className={fieldCls}
                    autoFocus
                />
                <span className="flex items-center px-3 text-base text-gray-600 bg-gray-100 border border-gray-300 rounded">
                    {item.unit}
                </span>
            </div>
            <input
                type="text"
                name="notes"
                defaultValue={item.notes ?? ''}
                placeholder={t('stocktakes.notesPlaceholder')}
                className={fieldCls}
            />
            <button
                type="submit"
                disabled={isPending}
                className="w-full bg-blue-600 text-white text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('common.saving') : t('stocktakes.save')}
            </button>
        </form>
    )
}

export default function CountList({
    stocktakeId,
    items,
    mode,
}: {
    stocktakeId: string
    items: CountItem[]
    mode: 'counted' | 'uncounted'
}) {
    const t = useTranslations()
    const [expandedKey, setExpandedKey] = useState<string | null>(null)

    return (
        <ul className="divide-y divide-gray-200 border border-gray-200 rounded mb-6">
            {items.map((item) => {
                const key = `${item.side}:${item.batchId}`
                const expanded = expandedKey === key
                return (
                    <li key={key}>
                        <button
                            type="button"
                            onClick={() => setExpandedKey(expanded ? null : key)}
                            className="w-full text-left px-3 py-3 min-h-[48px] hover:bg-gray-50"
                        >
                            <div className="flex items-center justify-between gap-3">
                                <div className="min-w-0">
                                    <span className="font-mono text-sm">{item.code}</span>
                                    <span className="ml-2 text-sm text-gray-600">{item.material}</span>
                                </div>
                                {mode === 'uncounted' ? (
                                    <span className="shrink-0 text-sm text-gray-600">
                                        {item.remaining ?? '—'} {item.unit}
                                    </span>
                                ) : (
                                    <span className="shrink-0 text-sm text-blue-600">
                                        {t('stocktakes.recount')}
                                    </span>
                                )}
                            </div>
                            {mode === 'counted' && (
                                <div className="mt-1 text-sm text-gray-600">
                                    {t('stocktakes.bookLabel')} {item.book ?? '—'} → {t('stocktakes.countedLabel')}{' '}
                                    {item.counted} {item.unit}
                                    {item.delta !== null && item.delta !== 0 && (
                                        <span
                                            className={
                                                'ml-2 font-medium ' +
                                                (item.delta > 0 ? 'text-green-600' : 'text-red-600')
                                            }
                                        >
                                            {formatSigned(item.delta)}
                                        </span>
                                    )}
                                </div>
                            )}
                        </button>
                        {expanded && (
                            <div className="px-3 pb-3">
                                <CountRow
                                    stocktakeId={stocktakeId}
                                    item={item}
                                    onDone={() => setExpandedKey(null)}
                                />
                            </div>
                        )}
                    </li>
                )
            })}
        </ul>
    )
}
