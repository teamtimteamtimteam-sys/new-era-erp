'use client'

// 化验录入表单 + 实时影响预览。
//
// 金属表以【批次当前已录含量】为起点 —— 化验多半是对既有数字的更正,小改远比重敲省事。
// 含量或日期一变就(防抖后)重算一次预览:调服务端动作走 calculate_metal_price,
// 把完整明细摊开,再给出"如果应用"的对比 —— 当前单价 / 新单价 / 每公斤差额 /
// 总调整额,以及会怎样拆进存货与销售成本。客户端不做任何算术。
//
// 两个提交按钮:仅记录 / 记录并应用。后者失败时【记录仍然保留】(见 actions.ts)。
import { useActionState, useEffect, useState } from 'react'
import Link from 'next/link'
import type { DictOption } from '@/app/components/dictionaries/dictionaryQuery'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '@/app/metal-prices/options'
import AssayImpactPreview from '../AssayImpactPreview'
import {
    submitAssay,
    previewAssayPrice,
    type SubmitAssayState,
    type PreviewState,
} from '../actions'

const initialState: SubmitAssayState = {}

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export default function AssayForm({
    labOptions,
    substanceOptions,
    batch,
    formula,
    currentMetals,
    baseCurrency,
}: {
    // PROC-5:实验室字典(值 + 已翻好的名字),由页面读好传进来
    labOptions: DictOption[]
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    batch: {
        id: string
        code: string
        quantity: number
        unit: string
        unit_price: number | null
        pricing_status: string
    }
    formula: { id: string; code: string; name: string } | null
    currentMetals: Record<string, string>
    // ASY-3:影响块用它标出自己的货币(面板在那里换单位)
    baseCurrency: string
}) {
    const t = useTranslations()
    const bound = submitAssay.bind(null, batch.id)
    const [state, formAction, isPending] = useActionState(bound, initialState)

    const [assayDate, setAssayDate] = useState(todayIsoLocal())
    const [metals, setMetals] = useState<Record<string, string>>(currentMetals)
    const [preview, setPreview] = useState<PreviewState>({})
    const [previewing, setPreviewing] = useState(false)

    // 含量/日期变化 → 防抖重算预览。setState 都发生在异步回调里,不在 effect 主体中。
    const metalsKey = JSON.stringify(metals)
    useEffect(() => {
        if (!formula) return
        let cancelled = false
        const timer = setTimeout(() => {
            setPreviewing(true)
            previewAssayPrice({
                batchId: batch.id,
                metals: JSON.parse(metalsKey),
                referenceDate: assayDate,
            })
                .then((res) => {
                    if (!cancelled) {
                        setPreview(res)
                        setPreviewing(false)
                    }
                })
                .catch(() => {
                    if (!cancelled) setPreviewing(false)
                })
        }, 400)
        return () => {
            cancelled = true
            clearTimeout(timer)
        }
    }, [batch.id, formula, metalsKey, assayDate])

    const res = preview.result
    const impact = preview.impact
    const negative = res?.negative_value === true || (res ? res.unit_price_usd_per_kg <= 0 : false)

    // ASY-1:【预览报错 = 应用一定会失败】—— 试算与提交现在走同一段算术、同一批闸
    // (承诺条款、汇率、期间锁/年结),所以预览的红横幅就是提交的拒绝。既然如此,
    // "记录并应用"不该再摆成主按钮:不提供服务端保证会拒的控件。理由横幅已经在
    // 屏幕上说清了,这里只让按钮跟着它走 —— 不另写一句话。
    // 【警告不是拒绝】净值 ≤ 0(negative)照旧可应用:含量要落地,只是不定价。
    const applyBlocked = !!preview.error

    return (
        <form action={formAction} className="space-y-6">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

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
                        value={assayDate}
                        onChange={(e) => setAssayDate(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('assay.labName')}</label>
                    {/* PROC-5:实验室 —— 字典下拉,不再是自由文本框。
                        【留空仍然合法】那是"没有人记过是哪家出的"(线上 3 行就是这样),
                        而不是"我们自己做的" —— 后者若要成为一个可记录的事实,
                        它是字典里的一行,不是一个空值的含义。 */}
                    <select name="lab_name" defaultValue=""
                            className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="">{t('assay.labUnknown')}</option>
                        {labOptions.filter((o) => o.isActive).map((o) => (
                            <option key={o.value} value={o.value}>{o.label}</option>
                        ))}
                    </select>
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

            {/* ── 金属表(留空 = 没测,整行忽略)── */}
            <div>
                <h2 className="text-lg font-semibold mb-2">{t('assay.title')}</h2>
                <table className="w-full border-collapse border border-gray-300 max-w-md">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.colMetal')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.colContent')}</th>
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
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            {/* ── 实时预览 ── */}
            {!formula ? (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded text-sm">
                    {t('assay.noFormula')}
                </div>
            ) : (
                <section className="border-t pt-6">
                    <div className="flex items-center gap-3 mb-3">
                        <h2 className="text-xl font-bold">{t('assay.impactPreview')}</h2>
                        {previewing && <span className="text-sm text-gray-400">{t('common.saving')}</span>}
                    </div>

                    {preview.error && (
                        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                            {preview.error}
                        </div>
                    )}

                    {negative && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                            {t('assay.negativeValue')}
                        </div>
                    )}

                    {/* impact 可能没有(净值 ≤ 0 时 DB 不给试算)—— 计价明细照常显示 */}
                    {res && <AssayImpactPreview res={res} impact={impact} baseCurrency={baseCurrency} />}
                </section>
            )}

            {/* ── 提交 ── */}
            <div className="flex flex-wrap gap-3 pt-2 border-t">
                {/* 应用被拦时,"仅记录"接过主按钮 —— 它此刻【是】那条可走的路:
                    化验单是实验室出的客观事实,先落库,定价等条款/汇率/期间理顺再说。 */}
                <button
                    type="submit"
                    name="intent"
                    value="record"
                    disabled={isPending}
                    className={
                        applyBlocked
                            ? 'bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400'
                            : 'border border-gray-300 px-4 py-2 rounded hover:bg-gray-50 disabled:text-gray-400'
                    }
                >
                    {t('assay.saveOnly')}
                </button>
                <button
                    type="submit"
                    name="intent"
                    value="record_apply"
                    disabled={isPending || applyBlocked}
                    className={
                        applyBlocked
                            ? 'border border-gray-300 px-4 py-2 rounded disabled:text-gray-400'
                            : 'bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400'
                    }
                >
                    {isPending ? t('common.saving') : t('assay.saveAndApply')}
                </button>
                <Link
                    href={`/inbound/${batch.id}/edit`}
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
