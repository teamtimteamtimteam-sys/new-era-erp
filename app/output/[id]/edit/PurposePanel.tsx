'use client'

// PROC-WIRE-1A:这一批是【可售库存】还是【下游工序的投料】。
//
// 【为什么它在这一页,而且【就在销售面板旁边】】拦住这笔销售的东西,必须
// 与那个按钮出现在同一屏上。**否则操作员看到的是一条拒绝,却看不到那条拒绝
// 的开关在哪** —— 那正是本仓库反复付账的"报告了却没有下一步"。
//
// 【它【不】说"这个东西不许卖"】那是另一条轴(形态 · material_forms.may_be_sold),
// 而且对正极片来说那句话是假的:正极片可售,它只是【这一批】已经许给了粉料线。
// 两句话必须在屏幕上也分得开,不只是在数据库里分得开。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { setOutputBatchPurpose } from './purposeActions'

export type BatchPurpose = {
    code: string; name_en: string; name_zh: string; is_saleable_stock: boolean
}
// PROC-WIRE-1B-ii(R3):可选的工序,给"它在等哪一道"用。
export type OperationType = { code: string; name_en: string; name_zh: string }

export default function PurposePanel({
    batchId, purposes, current, canEdit, locale, operations, awaiting,
}: {
    batchId: string
    purposes: BatchPurpose[]
    current: string
    canEdit: boolean
    locale: string
    operations: OperationType[]
    awaiting: string | null
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    const label = (p: BatchPurpose) => (locale === 'zh' ? p.name_zh : p.name_en)
    const currentPurpose = purposes.find((p) => p.code === current) ?? null
    const earmarked = currentPurpose ? !currentPurpose.is_saleable_stock : false

    function change(code: string) {
        if (code === current) return
        setError(null)
        startTransition(async () => {
            // 【切到可售库存时不带工序】门自己也会清,这里不多传一个会被忽略的值。
            const target = purposes.find((p) => p.code === code)
            const keep = target && !target.is_saleable_stock ? awaiting : null
            const r = await setOutputBatchPurpose(batchId, code, keep)
            if (r.error) setError(r.error)
        })
    }

    // PROC-WIRE-1B-ii(R3):只改"在等哪一道",用途不动。
    function changeAwaiting(code: string | null) {
        setError(null)
        startTransition(async () => {
            const r = await setOutputBatchPurpose(batchId, current, code)
            if (r.error) setError(r.error)
        })
    }

    return (
        <div className="mt-8 border rounded p-4">
            <h2 className="font-semibold mb-1">{t('output.purpose.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('output.purpose.why')}</p>

            {/* 【当前状态要一眼看得出来】被指定的批次不是可售库存,而那是一条
                会在结账那一刻才发作的事实 —— 让它在这里就发作。 */}
            <div className="mb-3">
                <span
                    className={
                        'inline-block px-2 py-0.5 rounded text-xs ' +
                        (earmarked
                            ? 'bg-amber-100 text-amber-800 border border-amber-300'
                            : 'bg-green-100 text-green-800 border border-green-300')
                    }
                >
                    {currentPurpose ? label(currentPurpose) : current}
                </span>
                {earmarked && (
                    <p className="text-xs text-amber-700 mt-2">
                        {t('output.purpose.earmarkedNote')}
                    </p>
                )}
            </div>

            {/* ★ PROC-WIRE-1B-ii(R3):在等哪一道工序 —— 只有被指定的批次才有这个问题。
                【空【不是】"不适用"】:还没排到具体工序的料仍然是在制品,
                所以这里写"还没决定",不写"—"。 */}
            {earmarked && (
                <div className="mb-3 border-t pt-3">
                    <p className="text-xs text-gray-600 mb-2">{t('output.purpose.awaitingWhy')}</p>
                    <div className="flex flex-wrap items-center gap-2">
                        <span className="text-sm">
                            {t('output.purpose.awaitingNow')}{' '}
                            {awaiting
                                ? <b>{(() => {
                                      const op = operations.find((o) => o.code === awaiting)
                                      return op ? (locale === 'zh' ? op.name_zh : op.name_en) : awaiting
                                  })()}</b>
                                : <span className="text-gray-500 italic">{t('output.purpose.awaitingUnset')}</span>}
                        </span>
                    </div>
                    {canEdit && (
                        <div className="mt-2 flex flex-wrap gap-2">
                            {operations.map((o) => (
                                <button key={o.code} type="button"
                                        disabled={isPending || o.code === awaiting}
                                        onClick={() => changeAwaiting(o.code)}
                                        className={
                                            'px-3 py-1.5 text-sm rounded border disabled:opacity-50 ' +
                                            (o.code === awaiting
                                                ? 'bg-gray-200 border-gray-300'
                                                : 'bg-white border-gray-300 hover:bg-gray-50')
                                        }>
                                    {locale === 'zh' ? o.name_zh : o.name_en}
                                </button>
                            ))}
                            {awaiting && (
                                <button type="button" disabled={isPending}
                                        onClick={() => changeAwaiting(null)}
                                        className="px-3 py-1.5 text-sm rounded border border-gray-300 bg-white hover:bg-gray-50 disabled:opacity-50">
                                    {t('output.purpose.awaitingClear')}
                                </button>
                            )}
                        </div>
                    )}
                </div>
            )}

            {canEdit ? (
                <div className="flex flex-wrap gap-2">
                    {purposes.map((p) => (
                        <button
                            key={p.code}
                            type="button"
                            disabled={isPending || p.code === current}
                            onClick={() => change(p.code)}
                            className={
                                'px-3 py-1.5 text-sm rounded border disabled:opacity-50 ' +
                                (p.code === current
                                    ? 'bg-gray-200 border-gray-300'
                                    : 'bg-white border-gray-300 hover:bg-gray-50')
                            }
                        >
                            {p.code === current
                                ? label(p)
                                : t('output.purpose.switchTo', { name: label(p) })}
                        </button>
                    ))}
                </div>
            ) : (
                <p className="text-xs text-gray-500">{t('output.purpose.noPermission')}</p>
            )}

            {error && (
                <div className="mt-3 bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm">
                    {error}
                </div>
            )}
        </div>
    )
}
