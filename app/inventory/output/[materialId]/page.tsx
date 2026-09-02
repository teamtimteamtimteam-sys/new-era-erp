// app/inventory/output/[materialId]/page.tsx
// 库存钻取:某物料的在库产出批次(未软删 + remaining_qty > 0),按 remaining_qty 降序。
// cut 5:成本估值(产出腿的 unit_cost_base)+ 市价估值(assay 含量 × 最新金属价)+ 库龄。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { STATE_OPTIONS, labelKeyForValue } from '@/app/inbound/options'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare, formatUnitCost } from '@/lib/format'
import { mustOne, mustRows } from '@/lib/db-helpers'
import {
    toneForBucket,
    AGING_TONE_CLASSES,
    latestPriceByMetal,
    marketValuePerKg,
} from '@/lib/valuation'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type Row = {
    id: string
    code: string
    quantity: number
    remaining_qty: number
    unit: string
    state: string
    output_date: string | null
    customers: { legal_name: string } | null
    // 反向 FK 嵌入是数组:一个批次至多一条产出腿;金属含量 0..n 条
    // WO-1c:一条产出腿指向它的加工单,加工单可能挂着一张工单 —— 出处那一行读的就是它
    // ★【FX-DISPLAY-1:读的是【遮蔽视图】,不是 processing_outputs 基表】★
    //   基表没有授给 authenticated,内嵌它会让【整条查询】42501 —— 见下面取数处。
    processing_outputs_masked: { unit_cost_base: number | null
        processing_runs: { id: string; work_order_id: string | null } | null }[]
    output_batch_metals: { metal: string; content_pct: number }[]
}

export default async function OutputDrillPage({
    params,
}: {
    params: Promise<{ materialId: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const { materialId } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const todayYmd = new Date().toISOString().slice(0, 10)

    const [matRes, batchesRes, settingsRes, pricesRes, ageRes] = await Promise.all([
        supabase.from('materials').select('name').eq('id', materialId).single(),
        supabase
            .from('output_batches')
            .select(
                // ★★【这一页此前对每一个用户都渲染成「没有库存」—— 而库里有 6 批】★★
                //   内嵌的是 processing_outputs 【基表】,它是遮蔽表、没有授给
                //   authenticated:整条查询对真实用户返回 403 / 42501
                //   「permission denied for table processing_outputs」。
                //   而下面取数写的是 `?? []` —— 于是错误被吞成空列表,
                //   页面平静地印出「没有库存」。**一个报了却不拦的判词不是闸**,
                //   这里连报都没报。实测:换成遮蔽视图后同一条查询 200,
                //   OUT-2026-0007 / OUT-2026-0187 的 unit_cost_base 正常带回。
                //   (它躲过了 check-masked-reads:那支检查认的是
                //    `.from('<表>')` 字面量,【看不见 select 串里的内嵌关系】。)
                'id, code, quantity, remaining_qty, unit, state, output_date, customers ( legal_name ), processing_outputs_masked ( unit_cost_base, processing_runs ( id, work_order_id ) ), output_batch_metals ( metal, content_pct )'
            )
            .eq('material_id', materialId)
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('remaining_qty', { ascending: false }),
        // 每金属的最新有效价(只取今天及以前,忽略预登的未来价)
        // METAL-2:房屋约定的那条序列(没有合同可继承指数时用它)
        supabase.from('pricing_settings').select('default_metal_index').eq('id', true).maybeSingle(),
        supabase
            .from('metal_prices')
            .select('metal, price_usd_per_tonne, price_date, price_index')
            .is('deleted_at', null)
            .lte('price_date', todayYmd),
        // INV-VAL-1(R4):库龄档【从 DB 取】—— aging_bucket 是唯一一处边界定义,
        // 屏幕不再自己划 30/90。天数一并带出来,免得两边各算一次。
        supabase
            .from('output_batch_valuation')
            .select('id, aging_days, aging_bucket')
            .eq('material_id', materialId)
            .gt('remaining_qty', 0),
    ])

    if (matRes.error || !matRes.data) {
        notFound()
    }

    // ★【`?? []` 是这次整页失效【没被任何人看见】的原因,所以它也一起改掉】★
    //   查询 403 时它把错误读成空集,页面平静地印出「没有库存」——
    //   AGENTS.md 的规矩是「查询失败必须失败」。mustRows 会抛,
    //   于是同样的故障下次是一个红框,不是一句安静的假话。
    //   (它也躲过了 check-error-swallowing —— 那支检查自己的结语写着
    //    「本检查看得见的那一类」,而 `as unknown as` 这层转换它看不见。)
    const rows = mustRows(batchesRes) as unknown as Row[]
    const priceByMetal = latestPriceByMetal(
        mustRows(pricesRes),
        mustOne(settingsRes, 'pricing_settings')?.default_metal_index ?? null
    )

    // 每行估值:成本 = 剩余 × 产出腿单位成本;市价 = 剩余 × 每公斤金属市价
    // WO-1c:这一页上出现的工单编号一次取回 —— 逐行去查会是 N+1。
    const woIds = Array.from(new Set(rows
        .map((r) => r.processing_outputs_masked?.[0]?.processing_runs?.work_order_id)
        .filter(Boolean))) as string[]
    const woCode = new Map<string, string>()
    if (woIds.length > 0) {
        const woRows = mustRows(
            await supabase.from('work_orders').select('id, code').in('id', woIds),
            'work_orders') as { id: string; code: string }[]
        woRows.forEach((w) => woCode.set(w.id, w.code))
    }

    const ageById = new Map<string, { aging_days: number | null; aging_bucket: string | null }>()
    for (const a of (ageRes.data as unknown as { id: string; aging_days: number | null; aging_bucket: string | null }[] | null) ?? []) {
        ageById.set(a.id, a)
    }

    const valued = rows.map((r) => {
        const unitCost = r.processing_outputs_masked[0]?.unit_cost_base ?? null
        const perKg = marketValuePerKg(r.output_batch_metals, priceByMetal)
        return {
            ...r,
            unitCost,
            costValue: unitCost !== null ? r.remaining_qty * unitCost : null,
            marketValue: perKg !== null ? r.remaining_qty * perKg : null,
            ageDays: ageById.get(r.id)?.aging_days ?? null,
            ageBucket: ageById.get(r.id)?.aging_bucket ?? null,
        }
    })

    const total = valued.reduce((s, r) => s + r.remaining_qty, 0)
    const totalCostValue = valued.reduce((s, r) => s + (r.costValue ?? 0), 0)
    const totalMarketValue = valued.reduce((s, r) => s + (r.marketValue ?? 0), 0)
    const noCostCount = valued.filter((r) => r.costValue === null).length
    const noMarketCount = valued.filter((r) => r.marketValue === null).length

    const stateLabel = (v: string) => {
        const k = labelKeyForValue(STATE_OPTIONS, v)
        return k ? t(k) : v
    }

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/inventory" className="text-blue-600 hover:underline text-sm">
                    {t('inventory.drill.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-4">
                {matRes.data.name} · {t('inventory.drill.title')}
            </h1>

            {/* 汇总行:剩余合计 + 成本价值 + 市价价值(+ 无成本/无市价批数) */}
            <p className="text-sm mb-3">
                <span className="text-gray-600 mr-1">{t('inventory.drill.sumLabel')}:</span>
                <span className="font-mono">{total}</span>
                <span className="mx-2 text-gray-300">·</span>
                <span className="text-gray-600 mr-1">{t('valuation.colCostValue')}:</span>
                <span className="font-mono">{formatMoneyBare(totalCostValue, '紧挨着的行标签「成本价值 (SGD)」')}</span>
                <span className="mx-2 text-gray-300">·</span>
                <span className="text-gray-600 mr-1">{t('valuation.colMarketValue')}:</span>
                {/* FX-DISPLAY-1:同一个缺陷的第二个消费方 —— 列头与这条合计行共用
                    valuation.colMarketValue,那个键现在写 (USD)。这个数从来就是 USD。 */}
                <span className="font-mono">{formatMoneyBare(totalMarketValue, '紧挨着的行标签「市价价值 (USD)」')}</span>
                {noCostCount > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('valuation.noCostCount', { n: noCostCount })}
                    </span>
                )}
                {noMarketCount > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('valuation.noMarketCount', { n: noMarketCount })}
                    </span>
                )}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colCustomer')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colQuantity')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colRemaining')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colState')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colOutputDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colUnitCost')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colCostValue')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colMarketValue')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colAge')}</th>
                        {/* WO-1c:这批货是照哪张计划做出来的 —— 出处是这套系统存在的理由,
                            而【没有计划】是一个正当的答案,所以它有名字,不是空白。 */}
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colWorkOrder')}</th>
                    </tr>
                </thead>
                <tbody>
                    {valued.map((r) => {
                        const tone = toneForBucket(r.ageBucket)
                        return (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link href={`/output/${r.id}/edit`} className="text-blue-600 hover:underline">
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.customers?.legal_name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.quantity} {r.unit}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.remaining_qty} {r.unit}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <span className="px-2 py-1 bg-gray-200 rounded text-xs">{stateLabel(r.state)}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.output_date ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.unitCost !== null ? `${formatUnitCost(r.unitCost)} /kg` : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.costValue !== null ? formatMoneyBare(r.costValue, '列头「成本价值 (SGD)」') : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.marketValue !== null ? formatMoneyBare(r.marketValue, '列头「市价价值 (USD)」') : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.ageDays !== null && tone !== null ? (
                                        <span className={'px-2 py-1 rounded text-xs ' + AGING_TONE_CLASSES[tone]}>
                                            {r.ageDays}
                                        </span>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                                {/* WO-1c:出处 —— 有工单就点得进去,没有就【说出来】 */}
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    {(() => {
                                        const woId = r.processing_outputs_masked?.[0]?.processing_runs?.work_order_id ?? null
                                        return woId
                                            ? <Link href={`/operation/orders/${woId}`}
                                                    className="text-blue-600 hover:underline">
                                                  {woCode.get(woId) ?? '—'}
                                              </Link>
                                            : <span className="text-gray-500 italic">{t('processing.noWorkOrder')}</span>
                                    })()}
                                </td>
                            </tr>
                        )
                    })}
                    {valued.length === 0 && (
                        <tr>
                            <td colSpan={11} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('inventory.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
