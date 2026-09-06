// app/output/[id]/assays/[assayId]/page.tsx
// 产出化验详情:单据抬头 + 金属表 +(未应用时)"应用会怎样"+ 应用/撤销动作。
// 进料侧 assays/[assayId] 是形状的出处;这里没有价格变动区 —— 产出化验不定价。
//
// "应用会怎样"整块【问库】(preview_apply_output_assay,与 apply_output_assay
// 同一串拒绝、同一条过期谓词 —— fixture 54 的 I 臂钉着),页面只显示:
//   * 含量对照:当前(带出处 —— 被顶掉的是谁说的数,要看得见)→ 化验后;
//     化验没报的金属行标【将移除】—— 应用是整体替换,不是逐行合并;
//   * 过期后果:产出它的加工单若按 metal_value 已分摊,应用会让拆分过期 ——
//     说在确认之前,不是事后。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatTimestamp } from '@/lib/format'
import { metalLabelKey } from '@/app/tools/pricing/metal-prices/options'
import { localizeAssayError } from '@/app/inbound/assayErrorCodes'
import { ApplyOutputAssayButton, UnapplyOutputAssayControl } from './OutputApplyControls'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type PreviewCurrentRow = {
    metal: string
    content_pct: number
    content_source: string | null
    source_assay_code: string | null
}
type ApplyPreview = {
    current_metals: PreviewCurrentRow[]
    assay_metals: { metal: string; content_pct: number }[] | null
    producing_run_id: string | null
    producing_run_code: string | null
    producing_run_allocated_at: string | null
    producing_run_basis: string | null
    will_flag_stale: boolean
}

export default async function OutputAssayDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string; assayId: string }>
    searchParams: Promise<{ apply_error?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const { id, assayId } = await params
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: assay, error } = await supabase
        .from('assay_results')
        .select('id, code, output_batch_id, assay_date, lab_name, weight_basis, moisture_pct, result_party, certificate_ref, sample_ref, is_final, notes, applied_at, superseded_by, created_at')
        .eq('id', assayId)
        .is('deleted_at', null)
        .single()

    // 契约:这条路由只认产出父,且必须是【这一批】的化验
    if (error || !assay || assay.output_batch_id !== id) {
        notFound()
    }

    const [batchRes, metalsRes, supersederRes, latestRes] = await Promise.all([
        supabase
            .from('output_batches')
            .select('id, code, quantity, unit')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('assay_result_metals')
            .select('metal, content_pct')
            .eq('assay_result_id', assayId)
            .order('metal'),
        assay.superseded_by
            ? supabase.from('assay_results').select('id, code').eq('id', assay.superseded_by).single()
            : Promise.resolve({ data: null, error: null }),
        // 该批次最近一次【已应用】的化验 —— 只有它才允许撤销(DB 也这么判)
        supabase
            .from('assay_results')
            .select('id')
            .eq('output_batch_id', id)
            .not('applied_at', 'is', null)
            .is('deleted_at', null)
            .order('applied_at', { ascending: false })
            .order('code', { ascending: false })
            .limit(1),
    ])

    const batch = batchRes.data
    if (!batch) notFound()

    const metals = mustRows(metalsRes)
    const isApplied = assay.applied_at !== null
    const isLatestApplied = isApplied && latestRes.data?.[0]?.id === assayId

    // ── 未应用:"应用会怎样"问库(与应用同一串拒绝;拒绝原样显示)──
    let preview: ApplyPreview | null = null
    let previewError: string | null = null
    if (!isApplied) {
        const { data: prevRaw, error: prevErr } = await supabase.rpc('preview_apply_output_assay', {
            p_output_batch_id: id,
            p_assay_result_id: assayId,
        })
        if (prevErr) {
            previewError = await localizeAssayError(prevErr.message)
        } else {
            preview = prevRaw as unknown as ApplyPreview
        }
    }

    const applyError = sp.apply_error ? await localizeAssayError(decodeURIComponent(sp.apply_error)) : null
    const metalLabel = (v: string) => {
        const key = metalLabelKey(v)
        return key ? t(key) : v
    }
    const sourceLabel = (r: PreviewCurrentRow) =>
        r.content_source === 'assay'
            ? r.source_assay_code ?? t('metalContent.sourceAssay')
            : r.content_source === 'manual'
                ? t('metalContent.sourceManual')
                : t('metalContent.sourceUnknown')

    // 对照表:当前 ∪ 化验后,按金属并集;化验没报的行【将移除】
    const previewRows = preview
        ? Array.from(
              new Set([
                  ...preview.current_metals.map((r) => r.metal),
                  ...(preview.assay_metals ?? []).map((r) => r.metal),
              ])
          )
              .sort()
              .map((metal) => ({
                  metal,
                  current: preview!.current_metals.find((r) => r.metal === metal) ?? null,
                  next: (preview!.assay_metals ?? []).find((r) => r.metal === metal) ?? null,
              }))
        : []

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <div className="mb-6">
                <Link href={`/output/${id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">
                {t('assay.detailTitle')}
                <span className="ml-3 font-mono text-base text-gray-500">{assay.code}</span>
            </h1>
            <p className="text-sm text-gray-600 mb-4">
                <Link href={`/output/${id}/edit`} className="text-blue-600 hover:underline font-mono">
                    {batch.code}
                </Link>
                <span className="mx-2">·</span>
                <span className="font-mono">
                    {batch.quantity} {batch.unit}
                </span>
            </p>

            {/* 记录成功但应用失败:化验单已经留下了,这里说明为什么含量没动 */}
            {applyError && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {applyError}
                </div>
            )}

            {/* 抬头 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('assay.colDate')}:</span>
                    <span>{assay.assay_date}</span>
                </div>
                {/* PROC-6:基准与出具方【总是显示】—— 它们是解读这些数字的前提,
                    不是可有可无的补充。历史化验单没有基准,那就照直说「没有记过」,
                    而不是让那一栏消失(消失读起来像"这件事不重要")。 */}
                <div>
                    <span className="text-gray-600 mr-1">{t('assay.weightBasis')}:</span>
                    <span>{assay.weight_basis
                        ? t('assay.basis_' + assay.weight_basis)
                        : <span className="text-amber-700">{t('assay.basisNotRecorded')}</span>}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('assay.resultParty')}:</span>
                    <span>{t('assay.party_' + assay.result_party)}</span>
                </div>
                {/* 【水分:没测过就写「没测过」,绝不写 0】
                    一个乘数的单位元是看不见的 —— 把没测过显示成 0,
                    读的人会拿它去推干重,而那个数看起来完全合理。 */}
                <div>
                    <span className="text-gray-600 mr-1">{t('assay.moisture')}:</span>
                    <span>{assay.moisture_pct === null || assay.moisture_pct === undefined
                        ? <span className="text-amber-700">{t('assay.moistureNotMeasured')}</span>
                        : <span className="font-mono">{assay.moisture_pct}%</span>}</span>
                </div>
                {assay.lab_name && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('assay.colLab')}:</span>
                        <span>{assay.lab_name}</span>
                    </div>
                )}
                {assay.certificate_ref && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('assay.colCertificate')}:</span>
                        <span className="font-mono">{assay.certificate_ref}</span>
                    </div>
                )}
                {assay.sample_ref && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('assay.colSample')}:</span>
                        <span className="font-mono">{assay.sample_ref}</span>
                    </div>
                )}
                <span
                    className={
                        'px-2 py-1 rounded text-xs ' +
                        (assay.is_final ? 'bg-gray-200 text-gray-700' : 'bg-amber-100 text-amber-800')
                    }
                >
                    {assay.is_final ? t('assay.kindFinal') : t('assay.kindPreliminary')}
                </span>
                <span
                    className={
                        'px-2 py-1 rounded text-xs ' +
                        (isApplied ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')
                    }
                >
                    {isApplied
                        ? `${t('assay.applied')} · ${formatTimestamp(assay.applied_at!, dateLocale)}`
                        : t('assay.notApplied')}
                </span>
                {supersederRes.data && (
                    <Link
                        href={`/output/${id}/assays/${supersederRes.data.id}`}
                        className="px-2 py-1 rounded text-xs bg-amber-100 text-amber-800 hover:underline"
                    >
                        {t('assay.supersededBy', { code: supersederRes.data.code })}
                    </Link>
                )}
            </div>

            {assay.notes && (
                <p className="text-sm text-gray-600 mb-4 whitespace-pre-line">
                    <span className="text-gray-500 mr-1">{t('assay.notes')}:</span>
                    {assay.notes}
                </p>
            )}

            {/* 金属表(单据本身说了什么)*/}
            <table className="w-full border-collapse border border-gray-300 max-w-md mb-6">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.colMetal')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('assay.colContent')}</th>
                    </tr>
                </thead>
                <tbody>
                    {metals.map((m) => (
                        <tr key={m.metal}>
                            <td className="border border-gray-300 px-4 py-2">
                                {metalLabel(m.metal)}
                                <span className="text-gray-400 font-mono text-xs ml-2">{m.metal}</span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {m.content_pct}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {/* 未应用:应用会怎样(问库)+ 立即应用 */}
            {!isApplied && (
                <section className="border-t pt-6 mb-6">
                    <h2 className="text-xl font-bold mb-3">{t('assay.output.applyPreviewTitle')}</h2>
                    {previewError && (
                        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                            {previewError}
                        </div>
                    )}
                    {preview && (
                        <>
                            <p className="text-sm text-gray-600 mb-3">{t('assay.output.replacesAll')}</p>
                            <div className="overflow-x-auto mb-4">
                                <table className="w-full border-collapse border border-gray-300 max-w-2xl text-sm">
                                    <thead className="bg-gray-100">
                                        <tr>
                                            <th className="border border-gray-300 px-3 py-2 text-left">{t('assay.colMetal')}</th>
                                            <th className="border border-gray-300 px-3 py-2 text-right">{t('assay.output.colCurrent')}</th>
                                            <th className="border border-gray-300 px-3 py-2 text-left">{t('metalContent.colSource')}</th>
                                            <th className="border border-gray-300 px-3 py-2 text-right">{t('assay.output.colAfter')}</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {previewRows.map((r) => (
                                            <tr key={r.metal}>
                                                <td className="border border-gray-300 px-3 py-2">
                                                    {metalLabel(r.metal)}
                                                    <span className="text-gray-400 font-mono text-xs ml-2">{r.metal}</span>
                                                </td>
                                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                                    {r.current ? `${r.current.content_pct}%` : '—'}
                                                </td>
                                                <td className="border border-gray-300 px-3 py-2">
                                                    {r.current ? (
                                                        <span
                                                            className={
                                                                'px-2 py-0.5 rounded text-xs ' +
                                                                (r.current.content_source === 'assay'
                                                                    ? 'bg-blue-100 text-blue-800 font-mono'
                                                                    : r.current.content_source === 'manual'
                                                                        ? 'bg-gray-200 text-gray-600'
                                                                        : 'bg-amber-100 text-amber-800')
                                                            }
                                                        >
                                                            {sourceLabel(r.current)}
                                                        </span>
                                                    ) : (
                                                        '—'
                                                    )}
                                                </td>
                                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                                    {r.next ? (
                                                        `${r.next.content_pct}%`
                                                    ) : (
                                                        // 化验没报这一行 —— 应用是整体替换,这行会消失。
                                                        // 被顶掉/移除的行必须看得见,不能被静默覆盖。
                                                        <span className="px-2 py-0.5 rounded text-xs bg-red-100 text-red-700">
                                                            {t('assay.output.willRemove')}
                                                        </span>
                                                    )}
                                                </td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </div>

                            {/* 过期后果:说在确认之前 */}
                            {preview.will_flag_stale ? (
                                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                                    {t('assay.output.staleWarning', { run: preview.producing_run_code ?? '?' })}
                                    {preview.producing_run_id && (
                                        <>
                                            {' '}
                                            <Link
                                                href={`/operation/processing/${preview.producing_run_id}`}
                                                className="text-blue-600 hover:underline font-mono"
                                            >
                                                {preview.producing_run_code}
                                            </Link>
                                        </>
                                    )}
                                </div>
                            ) : preview.producing_run_code ? (
                                <p className="text-sm text-gray-600 mb-4">
                                    {t('assay.output.noStaleEffect', { run: preview.producing_run_code })}
                                </p>
                            ) : null}
                        </>
                    )}
                    {/* 试算报错 = 应用一定会失败(同一串拒绝)。理由横幅在上面,按钮跟着走 */}
                    <ApplyOutputAssayButton assayId={assayId} batchId={id} blocked={!!previewError} />
                </section>
            )}

            {/* 最近一次已应用的化验可以撤销(不回含量 —— 控件里挂着提醒)*/}
            {isLatestApplied && (
                <section className="border-t pt-6">
                    <UnapplyOutputAssayControl assayId={assayId} batchId={id} subject={`${assay.code} · ${batch.code}`} />
                </section>
            )}
        </div>
    )
}
