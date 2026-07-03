'use client'

// 金属含量(化验)面板。进料/产出共用同一份;页面用 .bind 把 batchId 绑进 save/delete 动作,
// 所以面板本身从不接触 id。结构镜像 suppliers 的 AttachmentsPanel(mt-8 pt-8 border-t + 表格 + 录入行)。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import {
    type MetalContentRow,
    METAL_OPTIONS,
    metalLabelKey,
} from './metalContentTypes'

export default function MetalContentPanel({
    rows,
    saveAction,
    deleteAction,
}: {
    rows: MetalContentRow[]
    saveAction: (metal: string, contentPct: number) => Promise<{ error?: string }>
    deleteAction: (metal: string) => Promise<{ error?: string }>
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    // 录入行为受控(为了实时合计);成功后清空即可,无需 formKey。
    const [selectedMetal, setSelectedMetal] = useState('')
    const [pctInput, setPctInput] = useState('')

    const metalLabel = (value: string) => {
        const key = metalLabelKey(value)
        return key ? t(key) : value
    }

    // 已录入的金属集合:录入下拉里给它们加 "(已录)" 后缀提示;仍可选中 —— 选中并保存即覆盖(update)。
    const existing = new Set(rows.map((r) => r.metal))

    // 实时合计:已显示各行之和;若录入的金属已存在(覆盖),用录入值替换该行的旧值,得到"保存后"的合计。
    const displayedTotal = rows.reduce((sum, r) => sum + r.content_pct, 0)
    const pendingNum = Number(pctInput)
    const pendingValid = pctInput !== '' && !Number.isNaN(pendingNum) && pendingNum >= 0
    const replacedPct = selectedMetal
        ? rows.find((r) => r.metal === selectedMetal)?.content_pct ?? 0
        : 0
    const projectedTotal = pendingValid
        ? displayedTotal - replacedPct + pendingNum
        : displayedTotal
    const overHundred = projectedTotal > 100

    function handleSave() {
        if (!selectedMetal) {
            setError(t('metalContent.errInvalid'))
            return
        }
        const n = Number(pctInput)
        if (pctInput === '' || Number.isNaN(n) || n < 0 || n > 100) {
            setError(t('metalContent.errInvalid'))
            return
        }
        setError(null)
        startTransition(async () => {
            const result = await saveAction(selectedMetal, n)
            if (result?.error) {
                setError(result.error)
                return
            }
            // 成功:清空录入行(下拉回到占位、数字清空)
            setSelectedMetal('')
            setPctInput('')
        })
    }

    function handleDelete(metal: string) {
        if (!window.confirm(t('metalContent.deleteConfirm'))) return
        setError(null)
        startTransition(async () => {
            const result = await deleteAction(metal)
            if (result?.error) setError(result.error)
        })
    }

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('metalContent.title')}</h2>

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            {rows.length > 0 && (
                <div className="overflow-x-auto mb-4">
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colMetal')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colPct')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colUpdated')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colActions')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.metal}>
                                <td className="border border-gray-300 px-4 py-2">{metalLabel(r.metal)}</td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {r.content_pct.toFixed(2)}%
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                    {r.updated_at_display}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <button
                                        type="button"
                                        onClick={() => handleDelete(r.metal)}
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
                </div>
            )}

            {/* 合计行:实时反映"保存后"的百分比合计;>100 只警告不拦截 */}
            <p className="text-sm mb-4">
                <span className="text-gray-600 mr-1">{t('metalContent.totalLabel')}:</span>
                <span className={'font-mono ' + (overHundred ? 'text-red-600' : '')}>
                    {projectedTotal.toFixed(2)}%
                </span>
                {overHundred && (
                    <span className="text-red-600 ml-2">{t('metalContent.totalWarning')}</span>
                )}
            </p>

            {/* 录入 / 覆盖行 */}
            <div className="flex flex-wrap gap-2 items-start">
                <select
                    value={selectedMetal}
                    onChange={(e) => setSelectedMetal(e.target.value)}
                    className="border border-gray-300 px-3 py-2 rounded"
                >
                    <option value="" disabled>{t('metalContent.selectMetal')}</option>
                    {METAL_OPTIONS.map((o) => (
                        <option key={o.value} value={o.value}>
                            {t(o.labelKey)}
                            {existing.has(o.value) ? t('metalContent.alreadySet') : ''}
                        </option>
                    ))}
                </select>
                <input
                    type="number"
                    step="0.01"
                    min="0"
                    max="100"
                    placeholder={t('metalContent.pctPlaceholder')}
                    value={pctInput}
                    onChange={(e) => setPctInput(e.target.value)}
                    className="w-32 border border-gray-300 px-3 py-2 rounded"
                />
                <button
                    type="button"
                    onClick={handleSave}
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {t('metalContent.save')}
                </button>
            </div>
        </section>
    )
}
