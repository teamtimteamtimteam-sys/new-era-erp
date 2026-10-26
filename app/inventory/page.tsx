// app/inventory/page.tsx
// 库存与物料平衡(只读)
// TABLE-FEATURES-2(Tim 2026-10-26):台账的行与表尾合计都由库算 —— 行读 inventory_stock_by_material(),
//   表尾读 list_totals_inventory()(它加的正是前者的列)。从前的估值合计条(JS reduce 七份无序、无分页的整表读)删掉了:
//   「The existing ... inventory valuation bar [is] replaced by the new database totals.」
//   批次集合与每一列的规则写在 db/functions/inventory_stock_by_material.sql 抬头。
// INV-VAL-1(R1):原料估值口径由 unit_price 改为【到岸成本】
//   inbound_batch_landed_unit_cost = 采购价 + 运费 + 已资本化加工成本,
//   经 inbound_batch_valuation 视图读取(那支函数绕过价格遮蔽,不能直接授出去)。
//   与注销、盘点、gl_control_reconciliation 同一份定义 —— INV-VAL-0 的 M2
//   ("两个估值基准并存")就此关掉,而它今天为零、明天不为零:
//   第一张不被冲销的运费单过账的那一刻,旧口径会静默地与总账分开。
//   【实测:线上 16 张批次两个口径逐批相等,本次改动不改变任何一个现有数字。】
// 成品按产出腿成本 + 金属市价。
// 快照页,不做日期筛选(既定约定)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { compareForSort } from '@/lib/sortCollation'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { UNIT_OPTIONS, labelKeyForValue } from '@/app/materials/options'
import { formatMoneyBare } from '@/lib/format'
import { InventoryTable } from './InventoryTable'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { shapeListTotals } from '@/lib/listTotals'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getBaseCurrency } from '@/lib/currency'
import { Button } from '@/app/components/ui/button'
import { can } from '@/lib/permissions'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import WarehouseRequestsPanel, { type WarehouseRequestView } from './WarehouseRequestsPanel'
import RecentTrail from '@/app/components/trail/RecentTrail'

// PROC-1:种类从 material_kinds 嵌进来,不再是物料上的一列自由文本
type MaterialEmbed = { name: string; material_kinds: { name_en: string; name_zh: string } | null } | null

// TABLE-FEATURES-2:inventory_stock_by_material() 的一行(一种物料)。钱列 NULL 的意思见那支函数抬头 ——
//   没有一批计入,或者(stock / cost 两列)读者没有 data.view_prices。
type StockByMaterialRow = {
    material_id: string
    unit: string | null
    mixed_unit: boolean
    inbound_stock: number
    output_stock: number
    priced_qty: number
    stock_value: number | null
    cost_value: number | null
    market_value: number | null
}

type InventoryRow = {
    material_id: string
    name: string | null
    kindLabel: string | null
    unit: string
    inboundStock: number
    outputStock: number
    pricedQty: number // 已计价进料批次的剩余合计(加权均价分母)
    stockValue: number | null // Σ 剩余 × 单价;该物料无已计价批次为 null
    costValue: number | null // Σ 剩余 × 产出腿单位成本;无成本批次为 null
    marketValue: number | null // Σ 批次市价;无可市价批次为 null
}

// 混合单位的内部 sentinel(聚合逻辑用,显示时映射到 i18n)
const MIXED_UNIT = '⚠️混合'

export default async function InventoryPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    // APR-7 申请面板的金额用本位币标签
    const baseCurrency = await getBaseCurrency()

    // ── APR-7:等 CFO 批的注销 / 回滚 / 证书作废申请(页顶那一块)──────────────────────────
    //   读 warehouse_requests_visible():在等的全部 + 最近了结的十张;金额按 data.view_prices 给
    //   (NULL = 受限,画「受限」,不画 0.00)。snapshot 是提交时冻下来的那一组 —— CFO 读不到证书表。
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'
    const [canSeeFinance, canViewPrices, holdsWriteOff, holdsRollback, holdsCod, holdsCoa] = await Promise.all([
        can('module.finance.view'), can('data.view_prices'),
        can('action.batch_write_off'), can('action.processing_rollback'), can('action.issue_cod'), can('action.issue_coa')])
    type WrSnapshot = {
        batch_code?: string; run_code?: string; cod_code?: string; coa_code?: string; material_code?: string; material_name?: string
        supplier_name?: string; remaining_qty?: number; unit?: string; process_date?: string; locked_period?: boolean
        locked_before?: string | null; outputs?: string[]; inputs?: string[]; cods_voided?: string[]
    }
    const wrRows = mustRows(await supabase.rpc('warehouse_requests_visible', { p_recent: 10 })) as {
        id: string; kind: WarehouseRequestView['kind']; status: WarehouseRequestView['status']; label: string
        reason: string; snapshot: WrSnapshot | null; amount_base: number | null; created_at: string
        created_by_email: string | null; raised_by_me: boolean; decided_by_email: string | null
        decision_notes: string | null; withdraw_reason: string | null
    }[]
    const wrViews: WarehouseRequestView[] = wrRows.map((r) => {
        const s = r.snapshot ?? {}
        return {
            id: r.id, kind: r.kind, status: r.status, label: r.label,
            // MES-6b-2:作废分析证书那一种,主体是证书号(批号在快照里另有,但申请说的是那张证书)
            subjectCode: (r.kind === 'coa_void' ? s.coa_code : undefined) ?? s.batch_code ?? s.run_code ?? s.cod_code ?? '—',
            reason: r.reason,
            amountBase: r.amount_base,
            materialText: s.material_name ? `${s.material_code ?? ''} ${s.material_name}`.trim() : null,
            supplierText: s.supplier_name ?? null,
            quantityText: s.remaining_qty !== undefined && s.remaining_qty !== null ? `${s.remaining_qty} ${s.unit ?? ''}`.trim() : null,
            processDateText: s.process_date ? formatDate(s.process_date, dateLocale) : null,
            lockedPeriod: !!s.locked_period,
            outputs: s.outputs ?? [],
            inputs: s.inputs ?? [],
            codsVoided: r.kind === 'cod_void' || r.kind === 'coa_void' ? [] : (s.cods_voided ?? []),
            createdText: formatAuditStamp(r.created_at),
            raisedBy: r.created_by_email,
            raisedByMe: r.raised_by_me,
            decidedBy: r.decided_by_email,
            decisionNotes: r.decision_notes,
            withdrawReason: r.withdraw_reason,
        }
    })
    const wrLockedBefore = wrRows.map((r) => r.snapshot?.locked_before).find((d) => !!d) ?? null
    const wrKindCodes = [
        holdsWriteOff ? 'action.batch_write_off' : null,
        holdsRollback ? 'action.processing_rollback' : null,
        holdsCod ? 'action.issue_cod' : null,
        holdsCoa ? 'action.issue_coa' : null,
    ].filter((c): c is string => c !== null)

    const [stockRes, totalsRes, runsRes, unpricedRes, materialsRes] = await Promise.all([
        // TABLE-FEATURES-2:台账的行 —— 一种物料一行,库算(进料按到岸成本、产出按产出腿成本与金属市价)。
        //   从前这里是六次整表读再在 JS 里合并;FIX-2a / INV-VAL-1 那几条关于读哪张视图的理由
        //   现在住在那支函数里(它读的就是那几张视图,所以遮蔽与行谓词原样跟着走)。
        supabase.rpc('inventory_stock_by_material'),
        // 表尾合计:同一组行的列和(本位币两格、USD 一格),「受限」按 data.view_prices 判
        supabase.rpc('list_totals_inventory'),
        // MES-5b-1(Step 0 Q3 · Q12):平衡合计改读月度物料平衡的全期之和 —— 只算消耗型加工单(深度放电与拆去隔离是穿过去的质量,
        //   回滚的单与有一条腿单位不是 kg 的单不算)。此前把每一张没删的单的表头加起来,于是把放电穿过去的量也当成了消耗。
        //   "没有日期筛选"的约定不变:全期。外壳的门(加工 / 财务 / 库存查看任一)与 processing_run_lookup 给这几个数时同一组。
        supabase
            .from('processing_balance_monthly')
            .select('line, qty, runs')
            .eq('scope', 'plant'),
        // 未计价的在册进料批次数(与进料列表页同口径的提示徽标)
        // INV-VAL-1:未计价的判据跟着口径一起换 —— 一张没有采购价、
        // 却挂着已资本化加工成本的批次【不是】未计价的。
        supabase
            .from('inbound_batch_valuation')
            .select('id', { count: 'exact', head: true })
            .eq('unpriced', true),
        // INV-VAL-1:物料名与种类 —— 行里只有 material_id,单独取。
        supabase
            // FIX-2a:种类名在 material_lookup 上是【摊平的两列】,不是内嵌。
            .from('material_lookup')
            .select('id, name, kind_name_en, kind_name_zh')
            .is('deleted_at', null),
    ])

    if (stockRes.error || totalsRes.error || runsRes.error || materialsRes.error) {
        const err = stockRes.error ?? totalsRes.error ?? runsRes.error ?? materialsRes.error
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('inventory.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inventory.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(err, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    // 物料 id → 名称/种类。
    // ★ 物料被删了的批次在行里【照算】(名为「—」)—— 名称表过滤 deleted_at,估值不过滤;合计跟着行走
    //   (inventory_stock_by_material 抬头)。
    const materialById = new Map<string, MaterialEmbed>()
    // 视图列在生成类型里一律可空;行进了视图即非空 —— 取用处本地锁死(FIX-1 同一写法)。
    type MatLookupRow = { id: string; name: string; kind_name_en: string | null; kind_name_zh: string | null }
    for (const m of (materialsRes.data as unknown as MatLookupRow[] | null) ?? []) {
        materialById.set(m.id, {
            name: m.name,
            material_kinds:
                m.kind_name_en !== null && m.kind_name_zh !== null
                    ? { name_en: m.kind_name_en, name_zh: m.kind_name_zh }
                    : null,
        })
    }
    const runs = mustRows(runsRes)
    const totals = shapeListTotals(mustRows(totalsRes, 'inventory totals'))

    const rows: InventoryRow[] = (mustRows(stockRes, 'inventory stock') as unknown as StockByMaterialRow[]).map((r) => {
        const embed = materialById.get(r.material_id) ?? null
        return {
            material_id: r.material_id,
            name: embed?.name ?? null,
            kindLabel: embed?.material_kinds
                ? (locale === 'zh' ? embed.material_kinds.name_zh : embed.material_kinds.name_en)
                : null,
            unit: r.mixed_unit || r.unit === null ? MIXED_UNIT : r.unit,
            inboundStock: Number(r.inbound_stock),
            outputStock: Number(r.output_stock),
            pricedQty: Number(r.priced_qty),
            stockValue: r.stock_value === null ? null : Number(r.stock_value),
            costValue: r.cost_value === null ? null : Number(r.cost_value),
            marketValue: r.market_value === null ? null : Number(r.market_value),
        }
    })
    // ★ 这一页自己排自己的(初始顺序)—— 字序走 lib/sortCollation.ts 那条具名规矩(排序永远用英文字序,与界面语言无关)。
    rows.sort((a, b) => compareForSort(a.name ?? '', b.name ?? ''))

    // TABLE-EXPORT-1(Q3):均价 · 库存价值 · 成本价值三列被 data.view_prices 管着 —— 读不到时导出那一格写「受限」。
    //   从前由「有一张有价的进料批、而到岸成本读出来是 null」倒推,于是没有有价进料批时受限读者的导出是空格不是受限;
    //   现在直接读表尾的 restricted —— 库按 data.view_prices 判,受限时即使一行都没有也照样给出受限的那几行,
    //   所以导出与表尾是同一个判据、同一个答案,不在页面上再判一次。
    const pricesRestricted = totals.some((x) => x.restricted)

    // 物料平衡合计(MES-5b-1:月度平衡全厂那几条线的全期之和;损耗 = 有名字的损耗 + 余数)
    const lineSum = (line: string) => runs.filter((r) => r.line === line).reduce((s, r) => s + Number(r.qty ?? 0), 0)
    const balInput = lineSum('input')
    const balOutput = lineSum('output')
    const balLoss = lineSum('loss') + lineSum('remainder')
    const balRuns = runs.filter((r) => r.line === 'input').reduce((s, r) => s + Number(r.runs ?? 0), 0)
    const lossRate = balInput > 0 ? ((balLoss / balInput) * 100).toFixed(1) : null

    // PROC-1:种类的标签由 material_kinds 直接给出(字典,不是自由文本反查)。
    // 【没有种类】按名印出来,不印一根横杠 —— "没人决定过"与"没有种类"是两回事。
    const categoryLabel = (value: string | null) => value ?? t('materials.kindUndecided')

    // 单位:混合 sentinel → i18n;真实单位 → units.* 反查;未知值原样
    const unitLabel = (value: string) => {
        if (value === MIXED_UNIT) return t('inventory.mixedUnit')
        const key = labelKeyForValue(UNIT_OPTIONS, value)
        return key ? t(key) : value
    }

    return (
        <>
        <div className="p-8 space-y-6">
            <div className="flex justify-between items-start gap-4">
                <div>
                    <h1 className="">{t('inventory.listTitle')}</h1>
                    <p className="text-sm text-[color:var(--brand-muted-text)] mt-1">{t('inventory.ledgerNote')}</p>
                </div>
                {/* LOC-1:库位主数据的入口。【本页是它唯一的入口】—— /inventory/locations
                    是动态路由之外的一条静态路由,但可达性走查只断言"打得开却走不到"
                    的静态路由集合,新加一条没有入口的页面会被它抓到;这一行就是那个
                    入口,而且它落在读者已经持有的模块里(两者同为 module.inventory)。 */}
                <Button asChild variant="outline" className="whitespace-nowrap">
                    <Link
                        href="/inventory/locations"
                    >
                        {t('locations.listTitle')}
                    </Link>
                </Button>
            </div>

            {/* APR-7:等 CFO 批的注销 / 回滚 / 证书作废申请 */}
            <WarehouseRequestsPanel
                open={wrViews.filter((v) => v.status === 'submitted')}
                history={wrViews.filter((v) => v.status !== 'submitted')}
                canSeeFinance={canSeeFinance}
                canViewPrices={canViewPrices}
                kindCodesHeld={wrKindCodes}
                baseCurrency={baseCurrency}
                lockedBeforeText={wrLockedBefore ? formatDate(wrLockedBefore, dateLocale) : null}
            />
            {/* AUDIT-TRAIL-1b-1(Q12):这几张申请的审计记录 —— 谁提的、谁批的、何时;金额按 data.view_prices 给。
                读法与每一页底部同一支(record_trail),每一条带一栏 Record 链到申请的主体 */}
            <RecentTrail />

            {/* 物料平衡 */}
            <section>
                <h2 className="mb-2">{t('inventory.balanceSectionHeader')}</h2>
                <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm">
                    <div>
                        <span className="text-[color:var(--brand-muted-text)]">{t('inventory.balTotalInput')}</span>{' '}
                        <span className="font-medium">{balInput}</span>
                    </div>
                    <div>
                        <span className="text-[color:var(--brand-muted-text)]">{t('inventory.balTotalOutput')}</span>{' '}
                        <span className="font-medium">{balOutput}</span>
                    </div>
                    <div>
                        <span className="text-[color:var(--brand-muted-text)]">{t('inventory.balTotalLoss')}</span>{' '}
                        <span className="font-medium">{balLoss}</span>
                        {lossRate && (
                            <span className="text-[color:var(--brand-muted-text)]"> ({lossRate}%)</span>
                        )}
                    </div>
                    <div>
                        <span className="text-[color:var(--brand-muted-text)]">{t('inventory.balRunCount')}</span>{' '}
                        <span className="font-medium">{balRuns}</span>
                    </div>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1" data-balance-note>
                    {t('massBalance.inventoryNote')}{' '}
                    <Link href="/operation/balance" className="hover:underline app-link">{t('massBalance.inventoryLink')}</Link>
                </p>
            </section>

            {/* 当前库存 */}
            <section>
                <h2 className="mb-2">{t('inventory.stockSectionHeader')}</h2>

                {/* TABLE-FEATURES-2:估值合计条删掉了 —— 合计在表尾(库算,本位币一行、USD 一行)。
                    未计价徽标留下(它不是合计,是一句"有几批没有价");市价说明挪到表下。 */}
                {mustCount(unpricedRes) > 0 && (
                    <p className="text-sm text-gray-400 mb-2">
                        {t('inbound.unpricedBadge', { n: mustCount(unpricedRes) })}
                    </p>
                )}

                {/* ★ TABLE-CONVERT-4:换成 DataTable。
                    列、列头、每一格的字、以及 R-Q5 那条「数与单位并成一个值」全部原样;
                    手机档留下的仍然是 物料 · 进料库存 · 市价价值 三列。
                    ★ 那条「单位」列早就并进了数字里(TABLE-PHONE-1 / R-Q5,桌面 8 列),
                      本刀【没有再动它】。 */}
                <InventoryTable
                    rows={rows.map((r) => {
                        const unit = unitLabel(r.unit)
                        return {
                            materialId: r.material_id,
                            name: r.name ?? '—',
                            category: categoryLabel(r.kindLabel),
                            inboundStock: r.inboundStock,
                            outputStock: r.outputStock,
                            unit,
                            avgPriceText:
                                r.pricedQty > 0 && r.stockValue !== null
                                    ? formatMoneyBare(r.stockValue / r.pricedQty, '列头「加权均价 (SGD)」')
                                    : '—',
                            stockValueText:
                                r.stockValue !== null ? formatMoneyBare(r.stockValue, '列头「库存价值 (SGD)」') : '—',
                            costValueText:
                                r.costValue !== null ? formatMoneyBare(r.costValue, '列头「成本价值 (SGD)」') : '—',
                            marketValueText:
                                r.marketValue !== null ? formatMoneyBare(r.marketValue, '列头「市价价值 (USD)」') : '—',
                            // TABLE-EXPORT-1:同四个数的原始值(与上面四串字同一个判据,null 处同为「—」)
                            avgPrice: r.pricedQty > 0 && r.stockValue !== null ? r.stockValue / r.pricedQty : null,
                            stockValue: r.stockValue,
                            costValue: r.costValue,
                            marketValue: r.marketValue,
                        }
                    })}
                    pricesRestricted={pricesRestricted}
                    totals={totals}
                />
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">
                    {t('inventory.footerNote')}
                </p>
                {/* FX-DISPLAY-1:市价是 USD、不折算、不是账面数 —— 那句话从合计条搬到这里(表尾的 USD 一行就是它说的那个数) */}
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-2xl">
                    {t('valuation.marketValueFooterNote')}
                </p>
            </section>
        </div>
        </>
    )
}
