'use client'

// 产出化验录入表单。进料侧 AssayForm 是形状的出处,砍掉的是算价预览 ——
// 产出化验不定价。留下的"应用会怎样"是两件事,都在提交【之前】说:
//   * 含量会【整体替换】当前数(化验没报的金属行会消失)—— 对照当前值就在
//     每行旁边(它是录入起点),外加一行明说替换语义;
//   * 过期后果 —— 服务端问库得来(preview_apply_output_assay),这里只显示。
// 两个提交按钮:仅记录 / 记录并应用。后者失败时【记录仍然保留】(见 actions.ts)。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '@/app/metal-prices/options'
import { submitOutputAssay, type SubmitOutputAssayState } from '../actions'

const initialState: SubmitOutputAssayState = {}

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export default function OutputAssayForm({
    substanceOptions,
    batchId,
    currentMetals,
    impact,
}: {
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    batchId: string
    currentMetals: Record<string, string>
    // 服务端问库得来的应用后果;null = 试算失败(不挡记录,后果标注"未知")
    impact: {
        producing_run_code: string | null
        producing_run_allocated_at: string | null
        producing_run_basis: string | null
        will_flag_stale: boolean
    } | null
}) {
    const t = useTranslations()
    const bound = submitOutputAssay.bind(null, batchId)
    const [state, formAction, isPending] = useActionState(bound, initialState)
    const [metals, setMetals] = useState<Record<string, string>>(currentMetals)

    const hasCurrent = Object.keys(currentMetals).length > 0

    return (
        <form action={formAction} className="space-y-6">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {/* 产出化验不定价 —— 与进料侧最大的区别,先说出来,免得有人等一个
                不会出现的价格预览 */}
            <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2">
                {t('assay.output.noPricing')}
            </p>

            {/* ── 单据字段 ── */}
            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('assay.assayDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="assay_date"
                        required
                        max={todayIsoLocal()}
                        defaultValue={todayIsoLocal()}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('assay.labName')}</label>
                    <input type="text" name="lab_name" className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('assay.certificateRef')}</label>
                    <input type="text" name="certificate_ref" className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div className="flex-1 min-w-[10rem]">
                    <label className="block text-sm font-medium mb-1">{t('assay.sampleRef')}</label>
                    <input type="text" name="sample_ref" className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
            </div>

            <div className="flex flex-wrap gap-4 items-start">
                <div>
                    <label className="flex items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name="is_final" defaultChecked />
                        {t('assay.isFinal')}
                    </label>
                    <p className="text-xs text-gray-500 mt-1">{t('assay.isFinalHint')}</p>
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('assay.notes')}</label>
                    <input type="text" name="notes" className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
            </div>

            {/* ── 金属表(留空 = 没测,整行忽略;当前值在旁边作对照)── */}
            <div>
                <h2 className="text-lg font-semibold mb-2">{t('assay.title')}</h2>
                {hasCurrent && (
                    <p className="text-xs text-amber-800 mb-2">{t('assay.output.replacesAll')}</p>
                )}
                <table className="w-full border-collapse border border-gray-300 max-w-xl">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.colMetal')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.colContent')}</th>
                            {hasCurrent && (
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.output.colCurrent')}</th>
                            )}
                        </tr>
                    </thead>
                    <tbody>
                        {substanceOptions.filter((s) => s.isActive).map((opt) => (
                            <tr key={opt.value}>
                                <td className="border border-gray-300 px-4 py-2">
                                    {t(opt.labelKey)}
                                    <span className="text-gray-400 font-mono text-xs ml-2">{opt.value}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <input type="hidden" name="assay_metal" value={opt.value} />
                                    <DecimalInput
                                        name="assay_content"
                                        value={metals[opt.value] ?? ''}
                                        onChange={(raw) => setMetals((m) => ({ ...m, [opt.value]: raw }))}
                                        className="w-28 border border-gray-300 px-3 py-2 rounded"
                                    />
                                </td>
                                {hasCurrent && (
                                    <td className="border border-gray-300 px-4 py-2 text-sm text-gray-500 font-mono">
                                        {currentMetals[opt.value] !== undefined
                                            ? `${currentMetals[opt.value]}%`
                                            : '—'}
                                    </td>
                                )}
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            {/* ── 应用的后果(服务端问库;试算失败不挡记录,但要说"后果未知")── */}
            {impact === null ? (
                <p className="text-sm text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {t('assay.output.impactUnavailable')}
                </p>
            ) : impact.will_flag_stale ? (
                <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {t('assay.output.staleWarning', { run: impact.producing_run_code ?? '?' })}
                </p>
            ) : impact.producing_run_code ? (
                <p className="text-sm text-gray-600">
                    {t('assay.output.noStaleEffect', { run: impact.producing_run_code })}
                </p>
            ) : null}

            {/* ── 提交 ── */}
            <div className="flex flex-wrap gap-3 pt-2 border-t">
                <button
                    type="submit"
                    name="intent"
                    value="record"
                    disabled={isPending}
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50 disabled:text-gray-400"
                >
                    {t('assay.saveOnly')}
                </button>
                <button
                    type="submit"
                    name="intent"
                    value="record_apply"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('assay.saveAndApply')}
                </button>
                <Link
                    href={`/output/${batchId}/edit`}
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
