import Link from 'next/link'
import { formatTimestamp, formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { canViewPrices } from '@/lib/permissions'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditOutputForm from './EditOutputForm'
import MetalContentPanel from '@/app/components/metals/MetalContentPanel'
import { priceBatchHref } from '@/app/components/metals/priceBatchHref'
import type { MetalContentRow } from '@/app/components/metals/metalContentTypes'
import { saveOutputMetal, deleteOutputMetal } from '@/app/components/metals/metalContentActions'
import MovementTimeline from '@/app/components/inventory/MovementTimeline'
import type { MovementRow } from '@/app/components/inventory/movementTypes'
import SalePanel from './SalePanel'
import StocktakeQuickCount from '@/app/stocktakes/StocktakeQuickCount'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type MovementFetchRow = {
    id: string
    movement_type: string
    qty_delta: number
    business_date: string | null
    notes: string | null
    occurred_at: string
    processing_runs: { id: string; code: string } | null
}

export default async function EditOutputPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const showPrices = await canViewPrices()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [batchRes, materialsRes, customersRes, metalsRes, movementsRes, stocktakeRes] = await Promise.all([
        supabase
            .from('output_batches')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('customers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('output_batch_metals')
            .select('metal, content_pct, updated_at')
            .eq('output_batch_id', id)
            .order('metal'),
        supabase
            .from('inventory_movements')
            .select('id, movement_type, qty_delta, business_date, notes, occurred_at, run_id, processing_runs ( id, code )')
            .eq('output_batch_id', id)
            .order('occurred_at', { ascending: false }),
        // 进行中的盘点(最新一张):有则在顶部渲染"扫码即点"横幅
        supabase
            .from('stocktakes')
            .select('id, code')
            .eq('status', 'open')
            .is('deleted_at', null)
            .order('created_at', { ascending: false })
            .limit(1),
    ])

    // MAR-1:这一批的毛利。【问 batch_margin,不在页面上算】—— 三个限定词
    // (成本不完整 / 成本过期 / 与已过账 COGS 不同)必须跟着数字走,而不是缩在
    // 某处的一句说明。视图自己挂着 data.view_prices AND (finance OR processing):
    // 无权者拿到零行,页面据此渲染「受限」而不是 0 —— 这一页 operations 与
    // warehouse 都进得来,所以这条尤其要紧。没卖过就没有行(不是错误)。
    const marginRes = await supabase
        .from('batch_margin')
        .select('qty_sold, revenue_base, cost_current_base, margin_base, margin_pct, margin_status, cost_incomplete, is_stale, cogs_posted_base, cogs_differs')
        .eq('output_batch_id', id)
        .maybeSingle()
    const marginRow = (marginRes.data as {
        qty_sold: number; revenue_base: number; cost_current_base: number | null
        margin_base: number | null; margin_pct: number | null; margin_status: string
        cost_incomplete: boolean; is_stale: boolean
        cogs_posted_base: number | null; cogs_differs: boolean
    } | null) ?? null

    if (batchRes.error || !batchRes.data) {
        notFound()
    }

    if (materialsRes.error || customersRes.error) {
        const err = materialsRes.error ?? customersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('output.editTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('output.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const batch = batchRes.data

    // 本批在进行中盘点里的已录实点数(有则预填横幅)
    const openStocktake = stocktakeRes.data?.[0] ?? null
    let stocktakeCounted: number | null = null
    if (openStocktake) {
        const { data: countLine } = await supabase
            .from('stocktake_lines')
            .select('counted_qty')
            .eq('stocktake_id', openStocktake.id)
            .eq('output_batch_id', id)
            .maybeSingle()
        stocktakeCounted = countLine?.counted_qty ?? null
    }

    // 金属含量行:服务端预格式化 updated_at,避免客户端水合不一致
    const metalRows: MetalContentRow[] = (mustRows(metalsRes)).map((m) => ({
        metal: m.metal,
        content_pct: m.content_pct,
        updated_at_display: formatTimestamp(m.updated_at, dateLocale),
    }))

    // 库存流水行:服务端预格式化 occurred_at
    const movementRows: MovementRow[] = ((movementsRes.data as unknown as MovementFetchRow[] | null) ?? []).map((m) => ({
        id: m.id,
        movement_type: m.movement_type,
        qty_delta: m.qty_delta,
        business_date: m.business_date,
        notes: m.notes,
        occurred_at_display: formatTimestamp(m.occurred_at, dateLocale),
        run: m.processing_runs,
    }))

    // SAL-A:卖方可用的公式(方向 sale/both、启用)。走遮蔽视图 —— 没有
    // module.pricing.view 的读者拿到 0 行,面板于是只剩手填与现货预设,而不是报错。
    const { data: sellFormulaRows } = await supabase
        .from('pricing_formulas_masked')
        .select('id, code, name, direction, is_active')
        .in('direction', ['sale', 'both'])
        .eq('is_active', true)
        .is('deleted_at', null)
        .order('code')
    const sellFormulas = (sellFormulaRows ?? []).map((f) => ({ id: f.id as string, code: f.code as string, name: f.name as string }))

    return (
        <div className="p-4 sm:p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/output"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-xl sm:text-2xl font-bold mb-2">{t('output.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {batch.status}
                </span>
                <a
                    href={`/output/${batch.id}/label`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="ml-3 text-blue-600 hover:underline"
                >
                    {t('batchLabel.print')}
                </a>
            </p>

            {openStocktake && (
                <StocktakeQuickCount
                    stocktakeId={openStocktake.id}
                    stocktakeCode={openStocktake.code}
                    side="output"
                    batchId={batch.id}
                    counted={stocktakeCounted}
                />
            )}

            <EditOutputForm
                batch={batch}
                materials={mustRows(materialsRes)}
                customers={mustRows(customersRes)}
            />

            <MetalContentPanel
                rows={metalRows}
                saveAction={saveOutputMetal.bind(null, id)}
                deleteAction={deleteOutputMetal.bind(null, id)}
                priceHref={priceBatchHref(batch.quantity, metalRows)}
            />

            {/* ── 本批毛利(MAR-1)──────────────────────────────────────────
                "这批货挣了多少" 的答案摆在批次自己身上,而不是一条通往报表的链接:
                问题是在这里产生的。数字全部来自 batch_margin,页面不算账。 */}
            <section className="mt-8 pt-8 border-t">
                <h2 className="text-xl font-bold mb-3">{t('margin.title')}</h2>
                {!showPrices ? (
                    // 受限,不是零 —— operations 与 warehouse 都进得来这一页
                    <p className="text-sm text-gray-500">{t('common.restricted')}</p>
                ) : marginRow === null ? (
                    <p className="text-sm text-gray-500">{t('output.margin.notSold')}</p>
                ) : (
                    <div className="max-w-md space-y-1 text-sm">
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('margin.colRevenue')}</span>
                            <span className="font-mono">{formatAmount(marginRow.revenue_base, baseCurrency)}</span>
                        </div>
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('margin.colCost')}</span>
                            <span className="font-mono">
                                {marginRow.margin_status === 'ok'
                                    ? formatAmount(marginRow.cost_current_base, baseCurrency)
                                    : '—'}
                            </span>
                        </div>
                        <div className="flex justify-between border-t pt-1 font-bold">
                            <span>{t('margin.colMargin')}</span>
                            <span className="font-mono">
                                {/* 【绝不 0 成本化】算不出就留白,并说出是哪一种算不出 */}
                                {marginRow.margin_status === 'ok'
                                    ? `${formatAmount(marginRow.margin_base, baseCurrency)}${
                                          marginRow.margin_pct !== null ? ` · ${marginRow.margin_pct}%` : ''
                                      }`
                                    : '—'}
                            </span>
                        </div>
                        {marginRow.margin_status !== 'ok' && (
                            <p className="text-sm bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded mt-2">
                                {t('margin.statusHint.' + marginRow.margin_status)}
                            </p>
                        )}
                        {/* 三个限定词跟着数字走 */}
                        {marginRow.cost_incomplete && (
                            <p className="text-xs text-amber-800">{t('output.margin.costIncomplete')}</p>
                        )}
                        {marginRow.is_stale && (
                            <p className="text-xs text-amber-800">{t('output.margin.stale')}</p>
                        )}
                        {marginRow.cogs_differs && (
                            <p className="text-xs text-gray-600">
                                {t('output.margin.cogsDiffers', {
                                    posted: formatAmount(marginRow.cogs_posted_base, baseCurrency),
                                })}
                            </p>
                        )}
                        <p className="text-xs text-gray-500 pt-1">
                            <Link href="/margin" className="text-blue-600 hover:underline">
                                {t('output.margin.allBatches')}
                            </Link>
                        </p>
                    </div>
                )}
            </section>

            {batch.remaining_qty > 0 ? (
                <SalePanel
                baseCurrency={baseCurrency}
                    batchId={batch.id}
                    remainingQty={batch.remaining_qty}
                    unit={batch.unit}
                    state={batch.state}
                    customers={mustRows(customersRes)}
                    batchCustomerId={batch.customer_id}
                    formulas={sellFormulas}
                />
            ) : (
                <section className="mt-8 pt-8 border-t">
                    <h2 className="text-xl font-bold mb-4">{t('output.sale.title')}</h2>
                    <p className="text-sm text-gray-500">{t('output.sale.soldOut')}</p>
                </section>
            )}

            <MovementTimeline rows={movementRows} unit={batch.unit} />
        </div>
    )
}
