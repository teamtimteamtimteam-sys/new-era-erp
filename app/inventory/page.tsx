// app/inventory/page.tsx
// 库存与物料平衡(只读,JS 聚合)
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
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { UNIT_OPTIONS, labelKeyForValue } from '@/app/materials/options'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { latestPriceByMetal, marketValuePerKg } from '@/lib/valuation'
import { maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustCount, mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getBaseCurrency } from '@/lib/currency'

// PROC-1:种类从 material_kinds 嵌进来,不再是物料上的一列自由文本
type MaterialEmbed = { name: string; material_kinds: { name_en: string; name_zh: string } | null } | null

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type InboundStockRow = {
    material_id: string
    remaining_qty: number
    unit: string
    // INV-VAL-1:到岸成本。没有 data.view_prices 时视图把它遮蔽成 null,
    // 而 unpriced 【不】遮蔽 —— "有没有价"是事实,不是价。
    landed_unit_cost: number | null
    unpriced: boolean
}

type OutputStockRow = {
    id: string
    material_id: string
    remaining_qty: number
    unit: string
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
    // CCY-1:估值合计条的三个标签(原料库存价值/成品成本价值/成品市价价值)【不带币种】,
    // 而下面表格的列头带 —— 合计条自己把币种写出来,不去借一个没说过话的抬头。
    const baseCurrency = await getBaseCurrency()

    const todayYmd = new Date().toISOString().slice(0, 10)

    const [inboundRes, outputRes, runsRes, legsRes, metalsRes, settingsRes, pricesRes, unpricedRes, materialsRes] = await Promise.all([
        // INV-VAL-1:估值读取器。【视图没有外键,所以物料名不能内嵌】——
        // 单独取一份 materials 再在 JS 里对起来,而不是为了内嵌退回旧口径。
        supabase
            .from('inbound_batch_valuation')
            .select('material_id, remaining_qty, unit, landed_unit_cost, unpriced')
            .gt('remaining_qty', 0),
        // ★★【FIX-2a:这一页对 warehouse 的四条腿里有三条是空的】★★
        //   守卫是 module.inventory.view(warehouse / sales / procurement / finance
        //   都持有),而这三张分别挂 output.view / processing.view / output.view。
        //   后果不是"少一栏":物料平衡的投入、产出、损耗全是 0,于是屏幕上
        //   写着【什么都没有加工过】;成品成本与市值也是 0.00。
        //   ★ 而这一页【自己已经有】具名受限的渲染(下面 pricesRestricted,
        //     INV-VAL-1 写的)—— 它此前拿不到行去驱动。
        //   物料名不再内嵌:下面本来就单独取了一份 materials,用它对起来。
        supabase
            .from('output_batch_lookup')
            .select('id, material_id, remaining_qty, unit')
            .is('deleted_at', null)
            .gt('remaining_qty', 0),
        supabase
            .from('processing_run_lookup')
            .select('total_input, total_output, loss_qty')
            .is('deleted_at', null),
        // 产出腿:批次 → 单位成本(一个批次至多一条产出腿)
        supabase
            .from('processing_output_lookup')
            .select('output_batch_id, unit_cost_base'),
        // 金属含量(assay):批次 → 各金属含量
        supabase
            .from('output_batch_metal_lookup')
            .select('output_batch_id, metal, content_pct'),
        // 每金属的最新有效价(只取今天及以前,忽略预登的未来价)
        // METAL-2:房屋约定的那条序列(没有合同可继承指数时用它)
        supabase.from('pricing_settings').select('default_metal_index').eq('id', true).maybeSingle(),
        supabase
            .from('metal_prices')
            .select('metal, price_usd_per_tonne, price_date, price_index')
            .is('deleted_at', null)
            .lte('price_date', todayYmd),
        // 未计价的在册进料批次数(与进料列表页同口径的提示徽标)
        // INV-VAL-1:未计价的判据跟着口径一起换 —— 一张没有采购价、
        // 却挂着已资本化加工成本的批次【不是】未计价的。
        supabase
            .from('inbound_batch_valuation')
            .select('id', { count: 'exact', head: true })
            .eq('unpriced', true),
        // INV-VAL-1:物料名与种类 —— 估值视图没有外键,内嵌不了,单独取。
        supabase
            // FIX-2a:种类名在 material_lookup 上是【摊平的两列】,不是内嵌 ——
            // 视图没有外键,嵌不了(本页 §INV-VAL-1 那条注释说的就是这件事)。
            .from('material_lookup')
            .select('id, name, kind_name_en, kind_name_zh')
            .is('deleted_at', null),
    ])

    if (inboundRes.error || outputRes.error || runsRes.error || legsRes.error || metalsRes.error || pricesRes.error || materialsRes.error) {
        const err =
            inboundRes.error ?? outputRes.error ?? runsRes.error ??
            legsRes.error ?? metalsRes.error ?? pricesRes.error ?? materialsRes.error
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('inventory.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inventory.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const inbound = (inboundRes.data as unknown as InboundStockRow[] | null) ?? []
    // 物料 id → 名称/种类。进料侧改读估值视图之后,内嵌没了,这张表补上。
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
    const output = (outputRes.data as unknown as OutputStockRow[] | null) ?? []
    const runs = mustRows(runsRes)

    // 批次 → 单位成本 / 金属含量;金属 → 最新价
    const legCostByBatch = new Map<string, number>()
    // unit_cost_base 会被遮蔽(没有 data.view_prices 时为 null);其余列不会。
    for (const leg of maskedRows<Tables<'processing_outputs'>, 'unit_cost_base'>(
        mustRows(legsRes) as unknown as Tables<'processing_outputs'>[]
    )) {
        if (leg.unit_cost_base !== null) legCostByBatch.set(leg.output_batch_id, leg.unit_cost_base)
    }
    const metalsByBatch = new Map<string, { metal: string; content_pct: number }[]>()
    for (const m of mustRows(metalsRes) as unknown as
        { output_batch_id: string; metal: string; content_pct: number }[]) {
        const list = metalsByBatch.get(m.output_batch_id)
        if (list) list.push(m)
        else metalsByBatch.set(m.output_batch_id, [m])
    }
    const priceByMetal = latestPriceByMetal(
        mustRows(pricesRes),
        mustOne(settingsRes, 'pricing_settings')?.default_metal_index ?? null
    )

    // 按 material_id 聚合
    const rowsByMaterial = new Map<string, InventoryRow>()

    function ensureRow(
        materialId: string,
        embed: MaterialEmbed,
        unit: string
    ): InventoryRow {
        const existing = rowsByMaterial.get(materialId)
        if (existing) {
            if (existing.unit !== MIXED_UNIT && existing.unit !== unit) {
                existing.unit = MIXED_UNIT
            }
            return existing
        }
        const fresh: InventoryRow = {
            material_id: materialId,
            name: embed?.name ?? null,
            kindLabel: embed?.material_kinds
                ? (locale === 'zh' ? embed.material_kinds.name_zh : embed.material_kinds.name_en)
                : null,
            unit,
            inboundStock: 0,
            outputStock: 0,
            pricedQty: 0,
            stockValue: null,
            costValue: null,
            marketValue: null,
        }
        rowsByMaterial.set(materialId, fresh)
        return fresh
    }

    for (const b of inbound) {
        const row = ensureRow(b.material_id, materialById.get(b.material_id) ?? null, b.unit)
        row.inboundStock += b.remaining_qty
        // 【计价与否用 unpriced,金额用 landed_unit_cost】两者【不是同一个判据】:
        // 没有 data.view_prices 的读者拿到 landed_unit_cost = null 而 unpriced = false,
        // 那是"你看不到",不是"这批货没有价"。把它们混成一个判据,
        // 受限读者会看到一个少算了的合计 —— 本仓库为这个形状付过三次账。
        if (!b.unpriced) row.pricedQty += b.remaining_qty
        if (b.landed_unit_cost !== null) {
            row.stockValue = (row.stockValue ?? 0) + b.remaining_qty * b.landed_unit_cost
        }
    }
    for (const b of output) {
        const row = ensureRow(b.material_id, materialById.get(b.material_id) ?? null, b.unit)
        row.outputStock += b.remaining_qty

        const unitCost = legCostByBatch.get(b.id)
        if (unitCost !== undefined) {
            row.costValue = (row.costValue ?? 0) + b.remaining_qty * unitCost
        }
        const perKg = marketValuePerKg(metalsByBatch.get(b.id) ?? [], priceByMetal)
        if (perKg !== null) {
            row.marketValue = (row.marketValue ?? 0) + b.remaining_qty * perKg
        }
    }

    const rows = Array.from(rowsByMaterial.values())
    rows.sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '', 'zh-CN'))

    // 估值合计(三个口径分开:原料按单价、成品按成本、成品按市价)
    // ★★【读不到价的人必须拿到【具名受限】,不是一个自信的 SGD 0.00】★★
    // 【这是本刀顺手修掉的一个【线上正在错】的渲染,不是新功能】
    //   operations 与 warehouse 有 module.inventory.view、没有 data.view_prices,
    //   于是每一行的 stockValue 都是 null,而 `?? 0` 把整条合计条变成
    //   "原料库存价值 SGD 0.00" —— 一个会被抄进决策的数字,而真相是
    //   "这个数没有对你显示"。INV-VAL-1 在 RPT-1 上按裁定渲染具名受限,
    //   同一批用户在这张姊妹屏上却看到 0.00,那正是这条裁定要消灭的不一致。
    // 【判据是【有货、有价、但读不到】,不是"合计为零"】—— 一个真的空仓库
    //   应当照常显示 0.00,那是一句真话。
    // 判据:存在一张【有价】的批次(unpriced = false),而它的到岸成本读出来是 null
    // —— 那只可能是遮蔽。两个字段被同一条权限管着(data.view_prices),
    // 所以这一个信号同时说明了产成品那两列也读不到。
    const pricesRestricted = inbound.some((b) => !b.unpriced && b.landed_unit_cost === null)
    const totalInboundValue = rows.reduce((s, r) => s + (r.stockValue ?? 0), 0)
    const totalCostValue = rows.reduce((s, r) => s + (r.costValue ?? 0), 0)
    const totalMarketValue = rows.reduce((s, r) => s + (r.marketValue ?? 0), 0)

    // 物料平衡合计
    const balInput = runs.reduce((s, r) => s + (r.total_input ?? 0), 0)
    const balOutput = runs.reduce((s, r) => s + (r.total_output ?? 0), 0)
    const balLoss = runs.reduce((s, r) => s + (r.loss_qty ?? 0), 0)
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
                    <h1 className="text-2xl font-bold">{t('inventory.listTitle')}</h1>
                    <p className="text-sm text-gray-500 mt-1">{t('inventory.ledgerNote')}</p>
                </div>
                {/* LOC-1:库位主数据的入口。【本页是它唯一的入口】—— /inventory/locations
                    是动态路由之外的一条静态路由,但可达性走查只断言"打得开却走不到"
                    的静态路由集合,新加一条没有入口的页面会被它抓到;这一行就是那个
                    入口,而且它落在读者已经持有的模块里(两者同为 module.inventory)。 */}
                <Link
                    href="/inventory/locations"
                    className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm whitespace-nowrap"
                >
                    {t('locations.listTitle')}
                </Link>
            </div>

            {/* 物料平衡 */}
            <section>
                <h2 className="text-lg font-semibold mb-2">{t('inventory.balanceSectionHeader')}</h2>
                <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm">
                    <div>
                        <span className="text-gray-600">{t('inventory.balTotalInput')}</span>{' '}
                        <span className="font-medium">{balInput}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('inventory.balTotalOutput')}</span>{' '}
                        <span className="font-medium">{balOutput}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('inventory.balTotalLoss')}</span>{' '}
                        <span className="font-medium">{balLoss}</span>
                        {lossRate && (
                            <span className="text-gray-500"> ({lossRate}%)</span>
                        )}
                    </div>
                    <div>
                        <span className="text-gray-600">{t('inventory.balRunCount')}</span>{' '}
                        <span className="font-medium">{runs.length}</span>
                    </div>
                </div>
            </section>

            {/* 当前库存 */}
            <section>
                <h2 className="text-lg font-semibold mb-2">{t('inventory.stockSectionHeader')}</h2>

                {/* 估值合计条 */}
                <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm mb-3">
                    <div>
                        <span className="text-gray-600">{t('valuation.totalInboundValue')}:</span>{' '}
                        <span className="font-medium font-mono">
                            {pricesRestricted
                                ? <span className="text-gray-400">{t('valuation.priceRestricted')}</span>
                                : formatAmount(totalInboundValue, baseCurrency)}
                        </span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('valuation.totalCostValue')}:</span>{' '}
                        <span className="font-medium font-mono">
                            {pricesRestricted
                                ? <span className="text-gray-400">{t('valuation.priceRestricted')}</span>
                                : formatAmount(totalCostValue, baseCurrency)}
                        </span>
                    </div>
                    {/* ════════════════════════════════════════════════════════════
                        ★【币种分界 —— 这一格与左边两格【不是同一个币种,也不是同一类数】】★
                        FX-DISPLAY-1(2026-08-31)修的就是这里。从前它写的是
                        `formatAmount(totalMarketValue, baseCurrency)` —— 把一个
                        **USD** 数字贴上 **SGD**,而且是【运行时从 currencies.is_base
                        取出来贴上去的】,所以它读起来比一个写死的标签更像是权威结论。
                        实测:线上这个数是 1,870.00 USD,当时印成 "1,870.00 SGD"。
                        它就摆在两个【真 SGD】合计旁边,三个数看起来可以相加 —— 不能。
                        现在:币种写进标签(valuation.totalMarketValue 带 (USD)),
                        数字用 formatMoneyBare 裸印,并用一条竖线把它与账面数分开。
                        【不折算】线上唯一的 USD 中间价是 2026-07-31,超出 4 天回溯上限,
                        fx_rate_asof('USD', 今天, 'mid') 返回零行 —— 折不出来就不折,
                        而不是拿一个过期的汇率编一个 SGD 数出来。
                        ════════════════════════════════════════════════════════════ */}
                    <div className="border-l border-gray-300 pl-8">
                        <span className="text-gray-600">{t('valuation.totalMarketValue')}:</span>{' '}
                        <span className="font-medium font-mono">
                            {formatMoneyBare(totalMarketValue, '同一格的标签「成品市价价值 (USD)」')}
                        </span>
                        <p className="text-xs text-gray-500 mt-1 max-w-md">{t('valuation.marketValueNote')}</p>
                    </div>
                    {(mustCount(unpricedRes)) > 0 && (
                        <div className="text-gray-400">
                            {t('inbound.unpricedBadge', { n: mustCount(unpricedRes) })}
                        </div>
                    )}
                </div>

                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colMaterial')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colCategory')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colInboundStock')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colAvgPrice')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colStockValue')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colOutputStock')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colCostValue')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colMarketValue')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colUnit')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.material_id}>
                                <td className="border border-gray-300 px-4 py-2">{r.name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{categoryLabel(r.kindLabel)}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.inboundStock > 0 ? (
                                        <Link
                                            href={`/inventory/inbound/${r.material_id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.inboundStock}
                                        </Link>
                                    ) : (
                                        r.inboundStock
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.pricedQty > 0 && r.stockValue !== null
                                        ? formatMoneyBare(r.stockValue / r.pricedQty, '列头「加权均价 (SGD)」')
                                        : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.stockValue !== null ? formatMoneyBare(r.stockValue, '列头「库存价值 (SGD)」') : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.outputStock > 0 ? (
                                        <Link
                                            href={`/inventory/output/${r.material_id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.outputStock}
                                        </Link>
                                    ) : (
                                        r.outputStock
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.costValue !== null ? formatMoneyBare(r.costValue, '列头「成本价值 (SGD)」') : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.marketValue !== null ? formatMoneyBare(r.marketValue, '列头「市价价值 (USD)」') : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{unitLabel(r.unit)}</td>
                            </tr>
                        ))}
                        {rows.length === 0 && (
                            <tr>
                                <td
                                    colSpan={9}
                                    className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                >
                                    {t('inventory.emptyState')}
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
                <p className="text-xs text-gray-500 mt-2">
                    {t('inventory.footerNote')}
                </p>
            </section>
        </div>
        </>
    )
}
