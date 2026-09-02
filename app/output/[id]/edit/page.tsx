import Link from 'next/link'
import { formatTimestamp, formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { canViewPrices, can } from '@/lib/permissions'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditOutputForm from './EditOutputForm'
import MetalContentPanel from '@/app/components/metals/MetalContentPanel'
import { priceBatchHref } from '@/app/components/metals/priceBatchHref'
import type { MetalContentRow } from '@/app/components/metals/metalContentTypes'
import { saveOutputMetal, deleteOutputMetal } from '@/app/components/metals/metalContentActions'
import MovementTimeline from '@/app/components/inventory/MovementTimeline'
import BatchAuditTrail from '@/app/components/audit/BatchAuditTrail'
import { loadBatchAuditTrail } from '@/app/components/audit/auditTrailQuery'
import StockStatusPanel from '@/app/components/inventory/StockStatusPanel'
import type { MovementRow } from '@/app/components/inventory/movementTypes'
import SalePanel, { type CreditRow } from './SalePanel'
import PurposePanel, { type BatchPurpose, type OperationType } from './PurposePanel'
import SafetyStatePanel, { type SafetyState } from './SafetyStatePanel'
import OutputAssaySection from './OutputAssaySection'
import TraceabilitySection, { type IssueRow } from './TraceabilitySection'
import { fetchTraceability } from '@/app/output/traceabilityShared'
import StocktakeQuickCount from '@/app/stocktakes/StocktakeQuickCount'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD, FN } from '@/lib/modules'
import { loadSubstanceLabels, toOptions } from '@/app/pricing/metal-prices/substanceQuery'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type MovementFetchRow = {
    id: string
    movement_type: string
    qty_delta: number
    stock_status: string
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
    // SAL-B6:销售面板要在【录入之前】说出限额/敞口/余额。整段挂在
    // module.customers.view 后面 —— 无权时拿不到行,面板渲染「受限」而不是 0
    // (0 在信用面板上读作"没有限额、余额充足",是这个管控最危险的失败)。
    const canSeeCredit = await can('module.customers.view')
    // PROC-WIRE-1A:设定/释放【工序投料】指定要的是【工序】权限,不是销售权限 ——
    // 把一批货许给产线是一个工序决定。门里那条 require_permission 与这里同一个码。
    const canSetPurpose = await can('module.processing.edit')
    // PROC-WIRE-1B-ii(R1 / M4):记安全状态是【产出/收货的人看见了什么】,
    // 所以它挂 module.output.edit —— 与 output_batch_safety_states 的写策略同一个码,
    // 而【不是】工序权限:把一批货许给产线是工序决定,看见它鼓包了不是。
    const canEditSafety = await can('module.output.edit')
    const t = await getTranslations()
    const locale = await getLocale()

    // PROC-4:物质清单从 substances 那张字典读 —— 【连停用的一起读】,
    // 因为这一页要把历史含量行里的码翻成名字,而停用不该让历史数据变成光秃秃的 code。
    const substanceOptions = toOptions(await loadSubstanceLabels(supabase))
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
            // PROC-1b:含量带出处 —— 化验来源嵌出单据号,行上要看得见是谁说的数
            .select('metal, content_pct, updated_at, content_source, source_assay:assay_results!output_batch_metals_source_assay_id_fkey ( id, code )')
            .eq('output_batch_id', id)
            .order('metal'),
        supabase
            .from('inventory_movements')
            .select('id, movement_type, qty_delta, stock_status, business_date, notes, occurred_at, run_id, processing_runs ( id, code )')
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
    // 【失败必须失败】查询炸了不能变成"零行" —— 零行在这里的含义是"无权",
    // 面板会据此渲染「受限」,于是一次真正的查询错误会被伪装成一个合理的权限答复。
    // 无权的人本来就拿不到行(视图的谓词),两者必须分得开。
    const creditRes = await supabase
        .from('customer_credit_status')
        .select('customer_id, code, credit_limit_base, credit_hold, exposure_base, headroom_base, sales_blocked')

    // PROC-WIRE-1A:用途字典 —— 只取在用的,停用的不该再被指派上去(与门里同一条)。
    const purposesRes = await supabase
        .from('output_batch_purposes')
        .select('code, name_en, name_zh, is_saleable_stock')
        .eq('is_active', true)
        .order('sort_order')

    // PROC-WIRE-1B-ii(R3):可选的工序 —— "它在等哪一道"。只取在用的(与门里同一条)。
    const operationsRes = await supabase
        .from('operation_types')
        .select('code, name_en, name_zh')
        .eq('is_active', true)
        .order('sort_order')

    // PROC-WIRE-1B-ii(R1 / M4):安全状态字典 + 这一批身上已经记了哪些。
    // 【字典取全部,不只取在用的】守卫【不读】is_active —— 已经记下来的事实不因
    // 字典停用而改变(inbound_safety_states 的列注),所以已挂上的那些必须画得出来。
    const safetyDictRes = await supabase
        .from('inbound_safety_states')
        .select('code, name_en, name_zh, may_be_fed')
        .order('sort_order')
    const safetyHeldRes = await supabase
        .from('output_batch_safety_states')
        .select('safety_state_code')
        .eq('output_batch_id', id)

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

    // 金属含量行:服务端预格式化 updated_at,避免客户端水合不一致。
    // PROC-1b:出处列 —— 化验(单据号,可点)/ 手工 / 出处未知,三种状态各自可辨。
    // 产出侧 content_source NOT NULL,'unknown' 分支在这里走不到,写着是因为
    // 这个 map 的形状与进料侧同构,而进料侧真的有 NULL(PROC-1 之前的行)。
    type MetalFetchRow = {
        metal: string
        content_pct: number
        updated_at: string
        content_source: string | null
        source_assay: { id: string; code: string } | null
    }
    const metalRows: MetalContentRow[] = ((mustRows(metalsRes)) as unknown as MetalFetchRow[]).map((m) => ({
        metal: m.metal,
        content_pct: m.content_pct,
        updated_at_display: formatTimestamp(m.updated_at, dateLocale),
        source_kind: m.content_source === 'assay' ? 'assay' : m.content_source === 'manual' ? 'manual' : 'unknown',
        source_label:
            m.content_source === 'assay'
                ? m.source_assay?.code ?? t('metalContent.sourceAssay')
                : m.content_source === 'manual'
                    ? t('metalContent.sourceManual')
                    : t('metalContent.sourceUnknown'),
        source_href:
            m.content_source === 'assay' && m.source_assay
                ? `/output/${id}/assays/${m.source_assay.id}`
                : null,
    }))

    // IOD-1:可售 = available 桶之和;暂扣单列。问库(stock_by_status),页面不算账。
    const stockSplitRes = await supabase
        .from('stock_by_status')
        .select('stock_status, qty')
        .eq('output_batch_id', id)
    const stockSplit = mustRows(stockSplitRes, 'stock_by_status') as unknown as { stock_status: string; qty: number }[]

    // ── AUD-2:可追溯报告 ────────────────────────────────────────────────
    // 【具名拒绝原样带下去,不吞成空】NOTHING_TO_REPORT 是一个答案,
    // 而屏幕要把那句话说出来 —— 一张空表与"这批料没有可讲的来历"不是一回事。
    const traceReport = await fetchTraceability(supabase, batch.id)
    // 【失败必须失败】签发档列表不 `?? []`:读不出来会渲染成"从未签发",
    // 而那正是这一块最不能撒的谎(客户手里可能已经有一份)。
    const traceIssues = mustRows(
        await supabase
            .from('traceability_report_issues')
            .select('code, version, issued_at, sha256')
            .eq('output_batch_id', batch.id)
            .order('version', { ascending: false }),
        'traceability_report_issues'
    ) as unknown as IssueRow[]
    const saleAvailable = stockSplit.filter((r) => r.stock_status === 'available').reduce((a, r) => a + Number(r.qty), 0)
    const saleHeld = stockSplit.filter((r) => r.stock_status === 'on_hold').reduce((a, r) => a + Number(r.qty), 0)
    // SO-2:第三个桶。【必须单列】—— 少说一个数,屏幕上就会出现"可用 0、暂扣 0,
    // 可是卖不掉",而真正的答案是"它许给了某张订单"。服务端的拒绝
    // (IOD_SALE_EXCEEDS_AVAILABLE)也带着这个数,两边说的是同一句话。
    const saleCommitted = stockSplit.filter((r) => r.stock_status === 'committed').reduce((a, r) => a + Number(r.qty), 0)

    // 化验单(新到旧)—— 面板摆在金属含量旁边:化验是含量的出处,不是另一件事
    const assaysRes = await supabase
        .from('assay_results')
        .select('id, code, assay_date, lab_name, is_final, applied_at')
        .eq('output_batch_id', id)
        .is('deleted_at', null)
        .order('assay_date', { ascending: false })
        .order('code', { ascending: false })

    // 库存流水行:服务端预格式化 occurred_at
    const movementRows: MovementRow[] = ((movementsRes.data as unknown as MovementFetchRow[] | null) ?? []).map((m) => ({
        id: m.id,
        movement_type: m.movement_type,
        qty_delta: m.qty_delta,
        stock_status: m.stock_status,
        business_date: m.business_date,
        notes: m.notes,
        occurred_at_display: formatTimestamp(m.occurred_at, dateLocale),
        run: m.processing_runs,
    }))

    // AUDIT-1:跨模块审计轨迹。读【外层】视图 batch_audit_trail ——
    // 判据在那一层,内层 batch_audit_trail_all 不授权给任何人(AUD-1 的拆法)。
    const auditRows = await loadBatchAuditTrail('output', id)

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
                options={substanceOptions}
                rows={metalRows}
                saveAction={saveOutputMetal.bind(null, id)}
                deleteAction={deleteOutputMetal.bind(null, id)}
                priceHref={priceBatchHref(batch.quantity, metalRows)}
                note={t('assay.metalsFromAssay')}
            />

            {/* 化验(PROC-1b):含量的出处就摆在含量旁边 */}
            <OutputAssaySection batchId={batch.id} rows={mustRows(assaysRes)} />

            {/* ── 客户审计报告(AUD-2)────────────────────────────────────
                摆在化验之后:含量从哪来 → 这批料从哪来、怎么做的 → 发给客户的那份纸。 */}
            <TraceabilitySection
                batchId={batch.id}
                report={traceReport}
                issues={traceIssues}
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
                            {/* 【地址来自注册表】NAV-REG-1:这一条是【上下文交叉引用】,
                                不是产出模块名下的入口 —— 措辞("查看全部批次毛利")
                                是这一处的话,所以标签不从注册表取。
                                【可见性已经是同一个谓词】本块只在 marginRow 存在时渲染,
                                而 batch_margin 自己的 SQL 谓词就是 FN.margin.permission
                                (data.view_prices AND (finance OR processing))——
                                也就是说这个链接出现的条件与注册表判据同源,只是由
                                数据库那一侧执行。写死的 /margin 换成 FN.margin.href,
                                地址就再也不会与注册表分家。 */}
                            <Link href={FN.margin.href} className="text-blue-600 hover:underline">
                                {t('output.margin.allBatches')}
                            </Link>
                        </p>
                    </div>
                )}
            </section>

            {/* PROC-WIRE-1A:【这批是干什么用的】摆在销售面板正上方 ——
                拦住这笔销售的开关,必须与那个按钮在同一屏上。 */}
            <PurposePanel
                batchId={batch.id}
                purposes={mustRows(purposesRes) as BatchPurpose[]}
                current={batch.purpose_code}
                canEdit={canSetPurpose}
                locale={locale}
                operations={mustRows(operationsRes) as OperationType[]}
                awaiting={batch.awaiting_operation_type_code ?? null}
            />

            {/* ★ PROC-WIRE-1B-ii(R1 / M4):自产的料要回答与买来的料同一个安全问题。
                【这块屏必须存在】那道火闸的 HINT 写着"到【产出 → 打开这一批 →
                安全状态】那一块把它记上" —— 没有这块屏,那句提示就是一句假话。 */}
            <SafetyStatePanel
                batchId={batch.id}
                dictionary={mustRows(safetyDictRes) as SafetyState[]}
                current={(mustRows(safetyHeldRes) as { safety_state_code: string }[])
                    .map((r) => r.safety_state_code)}
                canEdit={canEditSafety}
                locale={locale}
            />

            {batch.remaining_qty > 0 ? (
                <SalePanel
                baseCurrency={baseCurrency}
                    canSeeCredit={canSeeCredit}
                    credit={mustRows(creditRes) as CreditRow[]}
                    batchId={batch.id}
                    remainingQty={batch.remaining_qty}
                    availableQty={saleAvailable}
                    heldQty={saleHeld}
                    committedQty={saleCommitted}
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

            {/* STK-1:库存分布(库位 × 状态)与暂扣/释放 —— 摆在流水【上面】,
                因为看批次的人先问「现在有多少可动」,再去看「它是怎么变成这样的」 */}
            <StockStatusPanel outputBatchId={id} unit={batch.unit} />

            <MovementTimeline rows={movementRows} unit={batch.unit} />

            {/* AUDIT-1:跨模块审计轨迹。它与上面的流水不是一件事 ——
                流水只答库存那一段,这一条把收货、加工、成本、销售、分录
                串成【一条】时间线,并把跟不动的每一跳画在行里。 */}
            <BatchAuditTrail rows={auditRows} />
        </div>
    )
}
