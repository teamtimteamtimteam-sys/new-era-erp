'use client'

// WO-1c:改计划。draft 与 released 都改得动 —— 工单不像销售订单那样一确认就冻,
// 因为计划本来就会随现实调整(见 amend_work_order 的函数头)。
//
// 【地板在服务端】计划量改不到已经吃掉的量以下(WO_LINE_BELOW_CONSUMED)——
// 这里【不重算那个判据】,而是把服务端那句拒绝按名显示出来。页面自己算一遍,
// 就是给同一个规则留下第二处实现(AGENTS.md:一处推导,N 个消费者)。
// 每行下面显示的"已耗"来自 work_order_fulfilment,所以人在按之前就看得见地板在哪。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { amendWorkOrder } from '../actions'

export type AmendRow = {
    material_id: string; material_label: string
    planned_qty: number | null; consumed_qty: number
}

export default function AmendLinesControl({
    id, rows, editable, blockedReason,
}: {
    id: string; rows: AmendRow[]; editable: boolean; blockedReason: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')
    const [draft, setDraft] = useState<Record<string, string>>(
        Object.fromEntries(rows.filter((r) => r.planned_qty != null)
            .map((r) => [r.material_id, String(r.planned_qty)])))

    if (!editable) {
        return <p className="text-sm text-amber-700">{blockedReason}</p>
    }

    function submit() {
        setError('')
        const changed = rows
            .filter((r) => r.planned_qty != null)
            .filter((r) => String(r.planned_qty) !== (draft[r.material_id] ?? ''))
            .map((r) => ({
                material_id: r.material_id,
                // 空 = 删掉这一行(与服务端的约定一致:planned_qty 省略即删行)
                planned_qty: (draft[r.material_id] ?? '').trim() === '' ? null : Number(draft[r.material_id]),
            }))
        startTransition(async () => {
            const res = await amendWorkOrder({ id, reason, lines: changed })
            if (res?.error) { setError(res.error); return }
            setOpen(false); setReason(''); router.refresh()
        })
    }

    return (
        <div className="mt-3">
            {!open ? (
                <button type="button" onClick={() => setOpen(true)}
                        className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50">
                    {t('processing.wo.actions.amend')}
                </button>
            ) : (
                <div className="border border-gray-300 rounded p-3 space-y-2">
                    <p className="text-xs text-gray-500">{t('processing.wo.actions.amendWhy')}</p>
                    {error && <p className="text-sm text-red-600">{error}</p>}
                    {rows.filter((r) => r.planned_qty != null).map((r) => (
                        <div key={r.material_id} className="flex items-center gap-3 text-sm">
                            <span className="w-64">{r.material_label}</span>
                            <input type="number" step="any" min="0" value={draft[r.material_id] ?? ''}
                                   onChange={(e) => setDraft({ ...draft, [r.material_id]: e.target.value })}
                                   className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                            {/* 【地板画在旁边,但判据在服务端】 */}
                            <span className="text-xs text-gray-500">
                                {t('processing.wo.actions.floorHint', { qty: String(r.consumed_qty) })}
                            </span>
                        </div>
                    ))}
                    <div className="flex items-center gap-3">
                        <input type="text" value={reason} placeholder={t('processing.wo.actions.amendReasonPlaceholder')}
                               onChange={(e) => setReason(e.target.value)}
                               className="border border-gray-300 px-2 py-1 rounded text-sm w-72" />
                        <button type="button" onClick={submit}
                                disabled={isPending || reason.trim() === ''}
                                className="text-sm bg-blue-600 text-white px-3 py-1 rounded hover:bg-blue-700 disabled:bg-gray-400">
                            {isPending ? t('common.saving') : t('common.save')}
                        </button>
                        <button type="button" onClick={() => setOpen(false)}
                                className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">
                            {t('common.cancel')}
                        </button>
                    </div>
                    {reason.trim() === '' && (
                        <p className="text-xs text-amber-700">{t('processing.wo.actions.amendReasonRequired')}</p>
                    )}
                </div>
            )}
        </div>
    )
}
