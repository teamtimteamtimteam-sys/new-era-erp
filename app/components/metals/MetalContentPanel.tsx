'use client'

// 金属含量(化验)面板。进料/产出共用同一份;页面用 .bind 把 batchId 绑进 save/delete 动作,
// 所以面板本身从不接触 id。结构镜像 suppliers 的 AttachmentsPanel(mt-8 pt-8 border-t + 表格 + 录入行)。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '../forms/DecimalInput'
import {
    type MetalContentRow,
    type MetalOption,
} from './metalContentTypes'

export default function MetalContentPanel({
    rows,
    options,
    saveAction,
    deleteAction,
    priceHref,
    note,
}: {
    rows: MetalContentRow[]
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来(值 + 已翻好的名字)。
    // 面板【不再】自己拿着一份清单 —— 那份清单曾经是第五个副本。
    options: MetalOption[]
    saveAction: (metal: string, contentPct: number) => Promise<{ error?: string }>
    deleteAction: (metal: string) => Promise<{ error?: string }>
    // 带着本批次数量与化验结果跳计价器(新标签页);页面在有化验行时才传。
    priceHref?: string
    // 灰字说明(进料侧 cut 5b 用来交代:含量现在由"应用化验结果"维护,
    // 手工编辑仍然保留给没有实验室结果的批次)。
    note?: string
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    // 录入行为受控(为了实时合计);成功后清空即可,无需 formKey。
    const [selectedMetal, setSelectedMetal] = useState('')
    const [pctInput, setPctInput] = useState('')

    // 【翻名字时【不】过滤 isActive】一条记着停用物质的历史行,必须照样显示它的名字。
    // 过滤了就会变成一个光秃秃的 code —— 那看起来像数据坏了,而不是像"不再可选"。
    const keyOf = new Map(options.map((o) => [o.value, o.labelKey]))
    const metalLabel = (value: string) => {
        const k = keyOf.get(value)
        return k ? t(k) : value
    }

    // 已录入的金属集合:录入下拉里给它们加 "(已录)" 后缀提示;仍可选中 —— 选中并保存即覆盖(update)。
    const existing = new Set(rows.map((r) => r.metal))

    // PROC-1b:出处列 —— 化验/手工/未知三种状态要看得见。页面传了才画
    // (标签已在服务端按语言格式化;手工覆盖一行化验值时,出处会当场翻成"手工")。
    const showSource = rows.some((r) => r.source_label)

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
            <div className="flex justify-between items-center mb-4">
                <h2 className="text-xl font-bold">{t('metalContent.title')}</h2>
                {priceHref && rows.length > 0 && (
                    <a
                        href={priceHref}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-blue-600 hover:underline text-sm"
                    >
                        {t('pricing.priceThisBatch')}
                    </a>
                )}
            </div>

            {note && <p className="text-xs text-gray-500 mb-3">{note}</p>}

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            {rows.length > 0 && (
                <div className="overflow-x-auto mb-4">
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colMetal')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colPct')}</th>
                            {showSource && (
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('metalContent.colSource')}</th>
                            )}
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
                                {showSource && (
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {r.source_kind === 'assay' && r.source_href ? (
                                            // 化验来源:标签就是单据号,点过去是那份化验
                                            <a href={r.source_href} className="px-2 py-0.5 rounded text-xs bg-blue-100 text-blue-800 hover:underline font-mono">
                                                {r.source_label}
                                            </a>
                                        ) : r.source_kind === 'unknown' ? (
                                            // 出处未知(PROC-1 之前录的行)—— 与"手工"是两回事,不能长得一样
                                            <span className="px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                                                {r.source_label}
                                            </span>
                                        ) : (
                                            <span className="px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-600">
                                                {r.source_label}
                                            </span>
                                        )}
                                    </td>
                                )}
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
                    {/* 【选单只列还能新选的】—— 停用的物质不出现在这里,
                        但上面那张表里它照样有名字。两个动词,两处不同的判断。 */}
                    {options.filter((o) => o.isActive).map((o) => (
                        <option key={o.value} value={o.value}>
                            {t(o.labelKey)}
                            {existing.has(o.value) ? t('metalContent.alreadySet') : ''}
                        </option>
                    ))}
                </select>
                {/* content_pct 在库里是无标度 numeric —— 微量贵金属化验值常到 3~4 位小数
                    (如 0.0035%),用 DecimalInput 不限位数;上下限由 handleSave 校验 */}
                <DecimalInput
                    placeholder={t('metalContent.pctPlaceholder')}
                    value={pctInput}
                    onChange={setPctInput}
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
