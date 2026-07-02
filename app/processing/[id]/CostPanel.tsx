'use client'

// 加工成本条目面板。只在【已提交】的加工单上渲染(页面决定)。
// 底部一个共用表单:editingId 为空 = 新增,非空 = 编辑该行(表单按 key 重挂载以带入默认值)。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { formatUsd } from '@/lib/format'
import { COST_TYPE_OPTIONS, costTypeLabelKey, type CostEntryRow } from './costTypes'
import { addCostEntry, updateCostEntry, softDeleteCostEntry } from './costActions'

export default function CostPanel({
    runId,
    entries,
}: {
    runId: string
    entries: CostEntryRow[]
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [editingId, setEditingId] = useState<string | null>(null)
    const [formKey, setFormKey] = useState(0) // 成功后 +1,重挂表单以清空

    const typeLabel = (v: string) => {
        const k = costTypeLabelKey(v)
        return k ? t(k) : v
    }

    const total = entries.reduce((s, e) => s + e.amount_usd, 0)
    const editing = editingId ? entries.find((e) => e.id === editingId) ?? null : null

    function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        setError(null)
        startTransition(async () => {
            const result = editingId
                ? await updateCostEntry(editingId, fd)
                : await addCostEntry(runId, fd)
            if (result?.error) {
                setError(result.error)
                return
            }
            setEditingId(null)
            setFormKey((k) => k + 1)
        })
    }

    function handleDelete(id: string) {
        if (!window.confirm(t('processing.cost.deleteConfirm'))) return
        setError(null)
        startTransition(async () => {
            const result = await softDeleteCostEntry(id)
            if (result?.error) setError(result.error)
            else if (editingId === id) setEditingId(null)
        })
    }

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('processing.cost.title')}</h2>

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            {entries.length > 0 && (
                <table className="w-full border-collapse border border-gray-300 mb-4">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.cost.colType')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.cost.colAmount')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.cost.colNotes')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.cost.colCreated')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.cost.colActions')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {entries.map((e) => (
                            <tr key={e.id} className={editingId === e.id ? 'bg-blue-50' : ''}>
                                <td className="border border-gray-300 px-4 py-2">
                                    {typeLabel(e.cost_type)}
                                    {e.is_estimate && (
                                        <span className="text-amber-600 text-xs ml-1">
                                            {t('processing.cost.estimateTag')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatUsd(e.amount_usd)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{e.notes ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                    {e.created_at_display}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 whitespace-nowrap">
                                    <button
                                        type="button"
                                        onClick={() => {
                                            setEditingId(e.id)
                                            setError(null)
                                        }}
                                        disabled={isPending}
                                        className="text-blue-600 text-sm hover:underline disabled:text-gray-400"
                                    >
                                        {t('processing.cost.edit')}
                                    </button>
                                    <span className="mx-2 text-gray-300">|</span>
                                    <button
                                        type="button"
                                        onClick={() => handleDelete(e.id)}
                                        disabled={isPending}
                                        className="text-red-600 text-sm hover:underline disabled:text-gray-400"
                                    >
                                        {t('common.delete')}
                                    </button>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* 合计 */}
            <p className="text-sm mb-4">
                <span className="text-gray-600 mr-1">{t('processing.cost.sumLabel')}:</span>
                <span className="font-mono">{formatUsd(total)}</span>
            </p>

            {/* 新增 / 编辑表单(共用) */}
            <h3 className="text-sm font-semibold mb-2">
                {editing ? t('processing.cost.editTitle') : t('processing.cost.addTitle')}
            </h3>
            <form
                key={editingId ?? `new-${formKey}`}
                onSubmit={handleSubmit}
                className="flex flex-wrap gap-2 items-start"
            >
                <select
                    name="cost_type"
                    required
                    defaultValue={editing?.cost_type ?? ''}
                    className="border border-gray-300 px-3 py-2 rounded"
                >
                    <option value="" disabled>{t('processing.cost.selectType')}</option>
                    {COST_TYPE_OPTIONS.map((o) => (
                        <option key={o.value} value={o.value}>
                            {t(o.labelKey)}
                        </option>
                    ))}
                </select>
                <input
                    type="number"
                    name="amount_usd"
                    step="0.01"
                    required
                    defaultValue={editing ? editing.amount_usd : ''}
                    placeholder={t('processing.cost.amountPlaceholder')}
                    className="w-32 border border-gray-300 px-3 py-2 rounded"
                />
                <label className="flex items-center gap-1 text-sm px-1 py-2">
                    <input
                        type="checkbox"
                        name="is_estimate"
                        defaultChecked={editing?.is_estimate ?? false}
                    />
                    {t('processing.cost.estimateLabel')}
                </label>
                <input
                    type="text"
                    name="notes"
                    defaultValue={editing?.notes ?? ''}
                    placeholder={t('processing.cost.notesPlaceholder')}
                    className="flex-1 min-w-[8rem] border border-gray-300 px-3 py-2 rounded"
                />
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {t('processing.cost.save')}
                </button>
                {editing && (
                    <button
                        type="button"
                        onClick={() => {
                            setEditingId(null)
                            setError(null)
                        }}
                        disabled={isPending}
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50 disabled:opacity-50"
                    >
                        {t('common.cancel')}
                    </button>
                )}
            </form>
        </section>
    )
}
