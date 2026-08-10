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
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { METAL_OPTIONS } from '@/app/metal-prices/options'
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
    batch,
    formula,
    currentMetals,
}: {
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
                        {METAL_OPTIONS.map((opt) => (
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
                    {res && <AssayImpactPreview res={res} impact={impact} />}
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
