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
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
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

    // ════════════════════════════════════════════════════════════════════════
    // ★★★【ALERT-2d ④ · 一个操作数里裹着三类东西 —— 委托书点名的那一处】★★★
    // ════════════════════════════════════════════════════════════════════════
    //   原来是:`showForm = canEdit && (state === 'unexplained' || editing)`
    //             ~~~~~~~     ~~~~~~~~~~~~~~~~~~~~~~~~~~~   ~~~~~~~
    //             权限        记录状态(这张收货还没说明)   这一次会话的开合位
    //   而 `showForm` 又被下面 :117 那一行当成一个操作数用,于是那条布尔
    //   **一个操作数里就有三类东西** —— 它为假的时候,没有任何一句话说得清是哪一类。
    //
    //   拆开:`formOpen` 只装【记录状态 + 开合位】(两者都是"这块表单该不该展开"
    //   的答案,它们回答的是同一个问题);权限那一半交给 <PermissionGate>。
    //   ☞ 于是没有 module.inbound.edit 的人,在一张【未说明】的收货上
    //     看得见那张表单、按不动、并读得到该去要哪个码 ——
    //     此前他看到的是一个琥珀框和一片空白,而那张收货正等着有人来补答案。
    //   ☞ 这张表单里没有【取消】(只有保存),所以包住它不触 DBLOCK-1 的第一条边界。
    const formOpen = state === 'unexplained' || editing

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
                {reasonNote && !formOpen && (
                    <p className="text-xs text-gray-600 mb-2">{t('inbound.source.noteField')}: {reasonNote}</p>
                )}
                {/* R4 的下半句:未说明的留着、看得出来,补答案的门在这里 */}
                {state === 'unexplained' && (
                    <p className="text-xs text-gray-600 mb-2">{t('inbound.source.whyUnexplained')}</p>
                )}

                {formOpen && (
                    <PermissionGate code="module.inbound.edit" allowed={canEdit} className="flex w-full items-stretch">
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
                        <Button size="sm"
                            type="button"
                            onClick={onSave}
                            disabled={saving || sel === '' || (selNeedsNote && note.trim() === '')}>
                            {saving ? t('common.saving') : t('inbound.source.explainSave')}
                        </Button>
                    </div>
                    </PermissionGate>
                )}
                {/* ★ 同一次拆分的下半:`canEdit && !showForm && state !== 'fromPo'`。
                       `state !== 'fromPo'` 是记录状态(对着采购行的收货没有"重说"
                       这件事可做),留在条件里;权限那一半上闸。 */}
                {!formOpen && state !== 'fromPo' && (
                    <PermissionGate code="module.inbound.edit" allowed={canEdit} inline>
                        <Button
                            variant="link"
                            size="inline"
                            type="button"
                            onClick={() => setEditing(true)}
                            className="text-xs"
                        >
                            {t('inbound.source.reExplain')}
                        </Button>
                    </PermissionGate>
                )}
            </div>
        </div>
    )
}
