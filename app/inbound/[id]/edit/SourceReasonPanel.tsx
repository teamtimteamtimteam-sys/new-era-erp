'use client'

// RECV-SOURCE-1:来源面板 —— 这张收货【从哪来】,以及事后补说明的那扇门(3e)。
//
// ★【四种状态必须长得不一样,而"未说明"永远不是空白】★(R4)
//   · 对着采购行           → 蓝,一句陈述(理由可另加 —— 对着单又附送样品是现实)
//   · 有理由(收货当场给) → 灰,理由 + 说明
//   · 有理由(事后补的)   → 绿,理由 + 说明 + 【什么时候补的】(谁补的记录在行上)
//   · 两者皆无             → 琥珀【未说明】—— 8 张早于本刀的收货就是这个样子,
//                            按 R4 不回填;Tim 哪天知道答案,从这里补,门会盖章。

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { explainSource } from './sourceReasonActions'
import type { SourceReasonOption } from '@/app/inbound/sourceReasonQuery'

export default function SourceReasonPanel({
    batchId, hasPoLine, poLabel, reasonCode, reasonNote, recordedAt, reasons, canEdit,
}: {
    batchId: string
    hasPoLine: boolean
    // 采购单号(有权限时),或 null(没权限时面板给一句通用陈述)
    poLabel: string | null
    reasonCode: string | null
    reasonNote: string | null
    recordedAt: string | null
    reasons: SourceReasonOption[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [sel, setSel] = useState(reasonCode ?? '')
    const [note, setNote] = useState(reasonNote ?? '')
    const [error, setError] = useState<string | null>(null)
    const [saving, setSaving] = useState(false)
    const [editing, setEditing] = useState(false)

    const reasonLabel = reasons.find((r) => r.code === reasonCode)?.label ?? reasonCode
    const selNeedsNote = reasons.find((r) => r.code === sel)?.requiresExplanation ?? false

    const state =
        reasonCode !== null
            ? (recordedAt !== null ? 'explainedLater' : 'explainedAtIntake')
            : hasPoLine ? 'fromPo' : 'unexplained'
    const tone =
        state === 'unexplained' ? 'bg-amber-50 border-amber-300 text-amber-900'
        : state === 'fromPo' ? 'bg-blue-50 border-blue-300 text-blue-900'
        : state === 'explainedLater' ? 'bg-green-50 border-green-300 text-green-900'
        : 'bg-gray-50 border-gray-300 text-gray-800'

    async function onSave() {
        setSaving(true); setError(null)
        const res = await explainSource(batchId, sel, note)
        setSaving(false)
        if (res.error) { setError(res.error); return }
        setEditing(false)
        router.refresh()
    }

    const showForm = canEdit && (state === 'unexplained' || editing)

    return (
        <div className="mb-8">
            <h2 className="text-sm font-medium text-gray-700 mb-2">{t('inbound.source.panelTitle')}</h2>
            <div className="border border-gray-300 rounded p-3 max-w-2xl">
                <p className={'text-sm mb-2 px-2 py-1 rounded border ' + tone}>
                    {state === 'fromPo'
                        ? (poLabel
                            ? t('inbound.source.stateFromPo', { po: poLabel })
                            : t('inbound.source.stateFromPoNoView'))
                        : state === 'explainedLater'
                          ? t('inbound.source.stateExplainedLater', { reason: reasonLabel ?? '', at: recordedAt ?? '' })
                          : state === 'explainedAtIntake'
                            ? t('inbound.source.stateExplainedAtIntake', { reason: reasonLabel ?? '' })
                            : t('inbound.source.stateUnexplained')}
                </p>
                {reasonNote && !showForm && (
                    <p className="text-xs text-gray-600 mb-2">{t('inbound.source.noteField')}: {reasonNote}</p>
                )}
                {/* R4 的下半句:未说明的留着、看得出来,补答案的门在这里 */}
                {state === 'unexplained' && (
                    <p className="text-xs text-gray-600 mb-2">{t('inbound.source.whyUnexplained')}</p>
                )}

                {showForm && (
                    <div className="space-y-2">
                        <select
                            value={sel}
                            onChange={(e) => setSel(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded text-sm"
                        >
                            <option value="">{t('inbound.source.select')}</option>
                            {reasons.map((r) => (
                                <option key={r.code} value={r.code}>{r.label}</option>
                            ))}
                        </select>
                        {selNeedsNote && (
                            <textarea
                                value={note}
                                onChange={(e) => setNote(e.target.value)}
                                rows={2}
                                placeholder={t('inbound.source.notePlaceholder')}
                                className="w-full border border-gray-300 px-3 py-2 rounded text-sm"
                            />
                        )}
                        {error && <p className="text-red-600 text-xs">{error}</p>}
                        <button
                            type="button"
                            onClick={onSave}
                            disabled={saving || sel === '' || (selNeedsNote && note.trim() === '')}
                            className="px-3 py-1.5 bg-blue-600 text-white rounded text-sm disabled:opacity-50"
                        >
                            {saving ? t('common.saving') : t('inbound.source.explainSave')}
                        </button>
                    </div>
                )}
                {canEdit && !showForm && state !== 'fromPo' && (
                    <button
                        type="button"
                        onClick={() => setEditing(true)}
                        className="text-xs text-blue-600 underline"
                    >
                        {t('inbound.source.reExplain')}
                    </button>
                )}
            </div>
        </div>
    )
}
