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

export default function PurposePanel({
    batchId, purposes, current, canEdit, locale,
}: {
    batchId: string
    purposes: BatchPurpose[]
    current: string
    canEdit: boolean
    locale: string
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
            const r = await setOutputBatchPurpose(batchId, code)
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
