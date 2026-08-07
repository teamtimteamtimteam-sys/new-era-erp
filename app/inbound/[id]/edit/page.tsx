import Link from 'next/link'
import { formatTimestamp } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditInboundForm from './EditInboundForm'
import PricingPanel, { type PriceHistoryRow } from './PricingPanel'
import PrepaymentPanel, { type PrepaymentApplicationRow } from './PrepaymentPanel'
import AssaySection, { type AssayRow } from './AssaySection'
import RepriceFromContentPanel from './RepriceFromContentPanel'
import MetalContentPanel from '@/app/components/metals/MetalContentPanel'
import { priceBatchHref } from '@/app/components/metals/priceBatchHref'
import type { MetalContentRow } from '@/app/components/metals/metalContentTypes'
import { saveInboundMetal, deleteInboundMetal } from '@/app/components/metals/metalContentActions'
import MovementTimeline from '@/app/components/inventory/MovementTimeline'
import type { MovementRow } from '@/app/components/inventory/movementTypes'
import StocktakeQuickCount from '@/app/stocktakes/StocktakeQuickCount'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { canViewPrices } from '@/lib/permissions'
import { maskedRows, maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

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

export default async function EditInboundPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [batchRes, materialsRes, suppliersRes, metalsRes, movementsRes, stocktakeRes, priceHistoryRes] = await Promise.all([
        supabase
            .from('inbound_batches_masked')
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
            .from('suppliers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('inbound_batch_metals')
            .select('metal, content_pct, updated_at')
            .eq('inbound_batch_id', id)
            .order('metal'),
        supabase
            .from('inventory_movements')
            .select('id, movement_type, qty_delta, business_date, notes, occurred_at, run_id, processing_runs ( id, code )')
            .eq('inbound_batch_id', id)
            .order('occurred_at', { ascending: false }),
        // 进行中的盘点(最新一张):有则在顶部渲染"扫码即点"横幅
        supabase
            .from('stocktakes')
            .select('id, code')
            .eq('status', 'open')
            .is('deleted_at', null)
            .order('created_at', { ascending: false })
            .limit(1),
        // 价格历史(计价面板,cut 1)
        supabase
            .from('price_history_masked')
            .select('id, old_unit_price, new_unit_price, currency, original_price, fx_rate, rate_as_of, rate_type, notes, created_at')
            .eq('inbound_batch_id', id)
            .order('created_at', { ascending: false }),
    ])

    if (batchRes.error || !batchRes.data) {
        notFound()
    }

    if (materialsRes.error || suppliersRes.error) {
        const err = materialsRes.error ?? suppliersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('inbound.editTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // cut 2b:改读遮蔽视图(select('*') 会碰到被收回的 unit_price)。
    // 只有 unit_price 会被遮蔽,其余列恢复基表类型。
    const batch = maskedExcept<Tables<'inbound_batches'>, 'unit_price'>(batchRes.data)

    // 化验(cut 5b):本批次的化验单(新到旧)+ 会生效的定价公式
    // (解析顺序与 apply_assay_result 一致:批次 → 采购单明细行)
    const [assayRes, poLineFormulaRes] = await Promise.all([
        supabase
            .from('assay_results')
            .select('id, code, assay_date, lab_name, is_final, applied_at')
            .eq('inbound_batch_id', id)
            .is('deleted_at', null)
            .order('assay_date', { ascending: false })
            .order('code', { ascending: false }),
        batch.purchase_order_line_id
            ? supabase
                  .from('purchase_order_lines')
                  .select('pricing_formula_id')
                  .eq('id', batch.purchase_order_line_id)
                  .single()
            : Promise.resolve({ data: null, error: null }),
    ])
    const assayRows = (mustRows(assayRes)) as AssayRow[]
    const resolvedFormulaId: string | null =
        batch.pricing_formula_id ?? poLineFormulaRes.data?.pricing_formula_id ?? null

    // FIN-27:这批货按哪一份【承诺条款】结算 —— 解析次序与 resolve_pricing_commitment
    // 一致(批次自己的 → 它那条采购行的)。有公式引用却没有副本的批次,结算会点名
    // 拒(PRICING_TERMS_NOT_COMMITTED);那不是要瞒着操作员到按下按钮才说的事,
    // 所以这里就说,并且不渲染一个注定被拒的按钮。
    const commitmentRes = await supabase
        .from('pricing_term_commitments')
        .select('id, source_formula_code, committed_at, inbound_batch_id, purchase_order_line_id')
        .or(
            [
                `inbound_batch_id.eq.${id}`,
                batch.purchase_order_line_id
                    ? `purchase_order_line_id.eq.${batch.purchase_order_line_id}`
                    : null,
            ]
                .filter(Boolean)
                .join(',')
        )
    const commitmentRows = mustRows(commitmentRes)
    const commitment =
        commitmentRows.find((c) => c.inbound_batch_id === id) ??
        commitmentRows.find((c) => c.purchase_order_line_id === batch.purchase_order_line_id) ??
        null

    // 关联采购单(cut 4c):头部链接 + 行下单量;抵扣预付的资格/建议额与已抵扣记录
    let poHeader: { po_id: string; po_code: string; ordered_qty: number | null; unit: string } | null = null
    let applicable: {
        purchase_order_id: string
        po_code: string
        batch_ap_open_base: number
        po_unapplied_prepayment_base: number
        applicable_base: number
    } | null = null
    let prepaymentHistory: PrepaymentApplicationRow[] = []
    if (batch.purchase_order_id) {
        const [poRes, lineRes, applicableRes, historyRes] = await Promise.all([
            supabase.from('purchase_orders').select('id, code').eq('id', batch.purchase_order_id).single(),
            batch.purchase_order_line_id
                ? supabase
                      .from('purchase_order_lines')
                      .select('quantity, unit')
                      .eq('id', batch.purchase_order_line_id)
                      .single()
                : Promise.resolve({ data: null, error: null }),
            // 资格与建议额【只从视图读】—— 与 apply_prepayment 同一口径
            supabase
                .from('po_prepayment_applicable')
                .select('purchase_order_id, po_code, batch_ap_open_base, po_unapplied_prepayment_base, applicable_base')
                .eq('inbound_batch_id', id)
                .maybeSingle(),
            supabase
                .from('prepayment_applications_masked')
                .select('id, amount_base, created_at, journal_entry_id, journal_entries(id, code)')
                .eq('inbound_batch_id', id)
                .order('created_at', { ascending: false }),
        ])
        if (poRes.data) {
            poHeader = {
                po_id: poRes.data.id,
                po_code: poRes.data.code,
                ordered_qty: lineRes.data?.quantity ?? null,
                unit: lineRes.data?.unit ?? batch.unit,
            }
        }
        // 视图列在生成类型里全可空;行进视图即非空(WHERE 已保证),此处锁死
        applicable = (applicableRes.data ?? null) as typeof applicable
        prepaymentHistory = (
            (historyRes.data as unknown as {
                id: string
                amount_base: number
                created_at: string
                journal_entries: { id: string; code: string } | null
            }[] | null) ?? []
        ).map((h) => ({
            id: h.id,
            amount_base: h.amount_base,
            created_at_display: formatTimestamp(h.created_at, dateLocale),
            journal_id: h.journal_entries?.id ?? null,
            journal_code: h.journal_entries?.code ?? null,
        }))
    }

    // 本批在进行中盘点里的已录实点数(有则预填横幅)
    const openStocktake = stocktakeRes.data?.[0] ?? null
    let stocktakeCounted: number | null = null
    if (openStocktake) {
        const { data: countLine } = await supabase
            .from('stocktake_lines')
            .select('counted_qty')
            .eq('stocktake_id', openStocktake.id)
            .eq('inbound_batch_id', id)
            .maybeSingle()
        stocktakeCounted = countLine?.counted_qty ?? null
    }

    // 价格历史行:服务端预格式化 created_at
    const showPrices = await canViewPrices()
    const priceHistoryRows: PriceHistoryRow[] = maskedRows<
        Tables<'price_history'>,
        'old_unit_price' | 'new_unit_price' | 'original_price' | 'fx_rate'
    >(mustRows(priceHistoryRes)).map((h) => ({
        id: h.id,
        old_unit_price: h.old_unit_price,
        new_unit_price: h.new_unit_price,
        currency: h.currency,
        original_price: h.original_price,
        fx_rate: h.fx_rate,
        // FIN-21:牌价取自哪一天、哪一侧。定价日(SG 日历)用来判断要不要标"取自":
        // PostgREST 现按业务时区吐 +08:00 偏移,slice(0,10) 即 SG 日期。
        rate_as_of: h.rate_as_of,
        rate_type: h.rate_type,
        priced_date: h.created_at?.slice(0, 10) ?? null,
        notes: h.notes,
        created_at_display: formatTimestamp(h.created_at, dateLocale),
    }))

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

    return (
        <div className="p-4 sm:p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/inbound"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-xl sm:text-2xl font-bold mb-2">{t('inbound.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {batch.status}
                </span>
                {/* 定价状态(cut 5b):暂定价 = 还没按正式化验重算过 */}
                <span
                    className={
                        'ml-2 px-2 py-0.5 rounded text-xs ' +
                        (batch.pricing_status === 'final'
                            ? 'bg-green-100 text-green-800'
                            : batch.pricing_status === 'provisional'
                              ? 'bg-amber-100 text-amber-800'
                              : 'bg-gray-200 text-gray-600')
                    }
                >
                    {t('assay.pricingStatus.' + batch.pricing_status)}
                </span>
                <a
                    href={`/inbound/${batch.id}/label`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="ml-3 text-blue-600 hover:underline"
                >
                    {t('batchLabel.print')}
                </a>
                {poHeader && (
                    <span className="ml-3">
                        {t('inbound.againstPo')}:{' '}
                        <Link
                            href={`/purchasing/orders/${poHeader.po_id}`}
                            className="text-blue-600 hover:underline font-mono"
                        >
                            {poHeader.po_code}
                        </Link>
                        {poHeader.ordered_qty !== null && (
                            <span className="text-gray-500">
                                {' '}({t('inbound.poLineOrdered', { qty: poHeader.ordered_qty, unit: poHeader.unit })})
                            </span>
                        )}
                    </span>
                )}
            </p>

            {openStocktake && (
                <StocktakeQuickCount
                    stocktakeId={openStocktake.id}
                    stocktakeCode={openStocktake.code}
                    side="inbound"
                    batchId={batch.id}
                    counted={stocktakeCounted}
                />
            )}

            <EditInboundForm
                batch={batch}
                materials={mustRows(materialsRes)}
                suppliers={mustRows(suppliersRes)}
            />

            <MetalContentPanel
                rows={metalRows}
                saveAction={saveInboundMetal.bind(null, id)}
                deleteAction={deleteInboundMetal.bind(null, id)}
                priceHref={priceBatchHref(batch.quantity, metalRows)}
                note={t('assay.metalsFromAssay')}
            />

            {/* 化验(cut 5b):含量从哪来 → 化验 → 价格往哪去,顺序读下来是一条线 */}
            <AssaySection batchId={batch.id} rows={assayRows} />

            <PricingPanel
                baseCurrency={baseCurrency}
                        canViewPrices={showPrices}
                        batchId={batch.id}
                unitPrice={batch.unit_price}
                history={priceHistoryRows}
                extraAction={
                    commitment ? (
                        <RepriceFromContentPanel batchId={batch.id} />
                    ) : resolvedFormulaId ? (
                        /* 有公式、没有副本 = FIN-27 之前留下的引用。不回填猜测的条款,
                           也不摆一个服务端保证会拒的按钮 —— 说清楚,指出手工定价这条路。 */
                        <p className="mb-4 text-sm text-amber-700 border border-amber-300 bg-amber-50 rounded px-3 py-2">
                            {t('assay.termsNotCommitted')}
                        </p>
                    ) : null
                }
            />

            {/* 抵扣预付(cut 4c):可抵扣 or 有历史时才渲染 */}
            <PrepaymentPanel batchId={batch.id} applicable={applicable} history={prepaymentHistory} />

            <MovementTimeline rows={movementRows} unit={batch.unit} />
        </div>
    )
}
