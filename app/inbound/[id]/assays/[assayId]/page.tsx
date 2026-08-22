// app/inbound/[id]/assays/[assayId]/page.tsx
// 化验单详情:单据抬头 + 金属表 +(已应用时)由此产生的价格变动 /(未应用时)
// 应用前的影响预览 + 应用/撤销动作。
//
// 已应用的价格变动【从既有记录里读,不重算】—— price_history 那一行就是当时真正
// 发生的事(重算会因行情变动给出与当初不同的数字,那是误导)。关联分录靠
// created_at 精确匹配:apply_assay_result 在一个事务里同时写 price_history 与分录,
// 而 now() 在事务内是冻结的,两行的 created_at 逐微秒相等 —— 跨事务则不会相等。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoneyBare, formatUnitCost, formatTimestamp } from '@/lib/format'
import { metalLabelKey } from '@/app/metal-prices/options'
import { localizeAssayError } from '../../../assayErrorCodes'
import { ApplyNowButton, UnapplyControl } from './ApplyAssayControls'
import AssayImpactPreview from '../AssayImpactPreview'
import { repricePreview, type AssayImpact } from '../actions'
import type { CalcResult } from '@/app/pricing/calculator/actions'
import { canViewPrices } from '@/lib/permissions'
import { getBaseCurrency } from '@/lib/currency'
import { maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { MaskedValue } from '@/app/components/MaskedValue'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function AssayDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string; assayId: string }>
    searchParams: Promise<{ apply_error?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const { id, assayId } = await params
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    // ASY-3:本位币来自数据(currencies.is_base),不是常量 —— 影响块要说出
    // 自己是哪种货币,而面板上半截是行情口径的 USD。
    const baseCurrency = await getBaseCurrency()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: assay, error } = await supabase
        .from('assay_results')
        .select('id, code, inbound_batch_id, assay_date, lab_name, weight_basis, moisture_pct, result_party, certificate_ref, sample_ref, is_final, notes, applied_at, superseded_by, created_at')
        .eq('id', assayId)
        .is('deleted_at', null)
        .single()

    if (error || !assay || assay.inbound_batch_id !== id) {
        notFound()
    }

    const [batchRes, metalsRes, supersederRes, latestRes] = await Promise.all([
        supabase
            .from('inbound_batches_masked')
            .select('id, code, quantity, unit, remaining_qty, unit_price, pricing_status, pricing_formula_id, purchase_order_line_id')
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
            .eq('inbound_batch_id', id)
            .not('applied_at', 'is', null)
            .is('deleted_at', null)
            .order('applied_at', { ascending: false })
            .order('code', { ascending: false })
            .limit(1),
    ])

    const showPrices = await canViewPrices()
    const batch = maskedExcept<Tables<'inbound_batches'>, 'unit_price'>(batchRes.data)
    if (!batch) notFound()

    const metals = mustRows(metalsRes)
    const isApplied = assay.applied_at !== null
    const isLatestApplied = isApplied && latestRes.data?.[0]?.id === assayId

    // ── 已应用:把当时真正发生的价格变动读出来 ──
    let priceChange:
        // cut 2b:没有 data.view_prices 时 old/next 回来是 null,delta 因此也算不出来。
        | { old: number | null; next: number | null; delta: number | null; when: string; journalId: string | null; journalCode: string | null }
        | null = null
    if (isApplied) {
        const { data: ph } = await supabase
            .from('price_history_masked')
            .select('old_unit_price, new_unit_price, created_at')
            .eq('inbound_batch_id', id)
            .eq('notes', `Assay ${assay.code} applied`)
            .order('created_at', { ascending: false })
            .limit(1)
        // 遮蔽的是价格列;created_at 恢复基表类型。
        const row = ph?.[0]
            ? maskedExcept<Tables<'price_history'>, 'old_unit_price' | 'new_unit_price'>(ph[0])
            : undefined
        if (row) {
            // 同一事务写下的分录:created_at 与 price_history 行逐微秒相等(见文件头)
            const { data: je } = await supabase
                .from('journal_entries')
                .select('id, code')
                .eq('source_type', 'purchase')
                .eq('source_id', id)
                .eq('created_at', row.created_at)
                .limit(1)
            priceChange = {
                old: row.old_unit_price,
                next: row.new_unit_price,
                delta:
                    row.new_unit_price === null
                        ? null
                        : Math.round(Number(batch.quantity) * (Number(row.new_unit_price) - Number(row.old_unit_price ?? 0)) * 100) / 100,
                when: formatTimestamp(row.created_at, dateLocale),
                journalId: je?.[0]?.id ?? null,
                journalCode: je?.[0]?.code ?? null,
            }
        }
    }

    // ── 未应用:算一份"如果应用"的预览。化验含量是定死的,服务端一次算好即可
    //    (录入页那边含量在动,才需要防抖的实时预览)──
    let preview: { result: CalcResult; impact?: AssayImpact } | null = null
    let previewError: string | null = null
    if (!isApplied && metals.length > 0) {
        // FIN-27:承诺解析 + 算价 + 拆账试算全在 preview_assay_price 里 ——
        // 与 apply_assay_result 逐字同构,所以这一页展示的数就是按下"应用"会落的数。
        // 有公式引用却没有承诺副本时它点名拒,错误照原样显示给操作员。
        const { data: row, error: calcErr } = await supabase.rpc('preview_assay_price', {
            p_inbound_batch_id: id,
            p_metals: metals.map((m) => ({ metal: m.metal, content_pct: m.content_pct })),
            p_reference_date: assay.assay_date,
        })
        if (calcErr) {
            previewError = await localizeAssayError(calcErr.message)
        } else {
            const parsed = row as unknown as { calc: CalcResult | null; impact: unknown }
            if (parsed?.calc) {
                preview = {
                    result: parsed.calc,
                    // 拆分交给 DB 试算(与真正入账的那套算术是同一份)
                    impact: await repricePreview(supabase, id, Number(parsed.calc.unit_price_usd_per_kg)),
                }
            }
        }
    }

    const applyError = sp.apply_error ? await localizeAssayError(decodeURIComponent(sp.apply_error)) : null
    const metalLabel = (v: string) => {
        const key = metalLabelKey(v)
        return key ? t(key) : v
    }

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <div className="mb-6">
                <Link href={`/inbound/${id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">
                {t('assay.detailTitle')}
                <span className="ml-3 font-mono text-base text-gray-500">{assay.code}</span>
            </h1>
            <p className="text-sm text-gray-600 mb-4">
                <Link href={`/inbound/${id}/edit`} className="text-blue-600 hover:underline font-mono">
                    {batch.code}
                </Link>
                <span className="mx-2">·</span>
                <span className="font-mono">
                    {batch.quantity} {batch.unit}
                </span>
            </p>

            {/* 记录成功但应用失败:化验单已经留下了,这里说明为什么价格没动 */}
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
                        href={`/inbound/${id}/assays/${supersederRes.data.id}`}
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

            {/* 金属表 */}
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

            {/* 已应用:由此产生的价格变动(读记录,不重算)*/}
            {isApplied && priceChange && (
                <section className="border-t pt-6 mb-6">
                    <h2 className="text-xl font-bold mb-3">{t('assay.priceChangeTitle')}</h2>
                    <div className="bg-gray-50 rounded p-4 text-sm max-w-md space-y-1">
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('assay.currentPrice', { ccy: baseCurrency })}</span>
                            <span className="font-mono">
                                <MaskedValue value={priceChange.old === null ? null : formatUnitCost(priceChange.old)} canView={showPrices} fallback="—" />
                            </span>
                        </div>
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('assay.newPrice', { ccy: baseCurrency })}</span>
                            <span className="font-mono font-medium"><MaskedValue value={priceChange.next === null || priceChange.next === undefined ? null : formatUnitCost(priceChange.next)} canView={showPrices} /></span>
                        </div>
                        <div className="flex justify-between border-t pt-1 font-bold">
                            <span>{t('assay.totalDelta', { ccy: baseCurrency })}</span>
                            <span className="font-mono">{formatMoneyBare(priceChange.delta, '同行左侧的行标签「调整总额({ccy})」—— ccy 就是本位币')}</span>
                        </div>
                        <div className="flex justify-between text-gray-500">
                            <span>{t('inbound.pricing.colWhen')}</span>
                            <span>{priceChange.when}</span>
                        </div>
                        {priceChange.journalId && (
                            <div className="flex justify-between">
                                <span className="text-gray-600">{t('assay.journalLink')}</span>
                                <Link
                                    href={`/finance/journal/${priceChange.journalId}`}
                                    className="text-blue-600 hover:underline font-mono"
                                >
                                    {priceChange.journalCode}
                                </Link>
                            </div>
                        )}
                    </div>
                </section>
            )}

            {/* 未应用:影响预览 + 立即应用 */}
            {!isApplied && (
                <section className="border-t pt-6 mb-6">
                    <h2 className="text-xl font-bold mb-3">{t('assay.impactPreview')}</h2>
                    {previewError && (
                        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                            {previewError}
                        </div>
                    )}
                    {preview ? (
                        <AssayImpactPreview res={preview.result} impact={preview.impact} baseCurrency={baseCurrency} />
                    ) : (
                        <p className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded text-sm">
                            {t('assay.noFormula')}
                        </p>
                    )}
                    {/* ASY-1:预览报错 = 应用一定会失败(试算与提交同一段算术、同一批闸)。
                        理由横幅就在上面,按钮跟着它走 —— 不提供服务端保证会拒的控件。 */}
                    <div className="mt-4">
                        <ApplyNowButton assayId={assayId} batchId={id} blocked={!!previewError} />
                    </div>
                </section>
            )}

            {/* 最近一次已应用的化验可以撤销(不回价 —— 控件里挂着提醒)*/}
            {isLatestApplied && (
                <section className="border-t pt-6">
                    <UnapplyControl assayId={assayId} batchId={id} />
                </section>
            )}
        </div>
    )
}
