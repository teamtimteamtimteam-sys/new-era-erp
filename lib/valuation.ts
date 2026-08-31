// lib/valuation.ts
// 库存估值 + 库龄的共享助手(纯模块,服务端/客户端皆可用)。
//
// ★【库龄档位的定义【不在这里】—— INV-VAL-1 把第二份定义删掉了】★
// 曾经这里有一份 AGING_BANDS(30 / 90 两档半),而库里另有一份 aging_bucket
// (0-30 / 31-60 / 61-90 / 90+,AGING-1 明写它被抽出来正是因为边界写了三遍)。
// 两份的边界【本来就不一样】:75 天的一批货在 DB 里是 b61_90,在这里是 warn。
// 没人报过这个 bug,因为这一份只用来上色 —— 而那正是第二份定义最能活得久的形态。
// 现在档位由 inbound_batch_valuation / output_batch_valuation 带出来(视图里调
// aging_bucket),本模块只把【档位映射成颜色】。映射是表现,不是边界:
// 改颜色改这里,改边界改 aging_bucket,两件事再也不会互相冒充。
//
// 市价口径:金属价为 USD/吨,批次量按 kg 记(与 allocate_processing_costs 的假设一致),
// 故每公斤市价 = Σ(含量%/100 × 价格/1000)。

export type AgingTone = 'ok' | 'warn' | 'alert'

// 【agingDays 也删了】INV-VAL-1:天数改由视图给(CURRENT_DATE - 基准日,
// 在库里算一次),于是这支 TS 实现没有调用方。**留着不调用的第二实现,
// 下一个人一定会调用它** —— 那正是上面那段说的 AGING_BANDS 的下场。

// 档位 → 颜色。【只做映射,不划边界】边界的唯一定义是 DB 的 aging_bucket。
// 档位算不出来(没有基准日期)时返回 null —— 调用方据此渲染 '—',
// 而不是一个"0 天"或"90 天以上"。两者都是假话,后者尤其是。
export function toneForBucket(bucket: string | null): AgingTone | null {
    switch (bucket) {
        case 'b0_30':    return 'ok'
        case 'b31_60':   return 'warn'
        case 'b61_90':   return 'warn'
        case 'b90_plus': return 'alert'
        default:         return null
    }
}

// 库龄 pill 的上色(两个钻取页共用,免得类名漂移)
export const AGING_TONE_CLASSES: Record<AgingTone, string> = {
    ok: 'bg-green-100 text-green-800',
    warn: 'bg-amber-100 text-amber-800',
    alert: 'bg-red-100 text-red-700',
}

// ---- 钻取行的估值字段 ----

// 进料批次:单价直接来自 inbound_batches.unit_price
export type InboundValuation = {
    unitPrice: number | null // USD/kg;null = 未计价
    batchValue: number | null // remaining × unitPrice;未计价为 null
    ageDays: number | null // 距 arrival_date;无日期为 null
}

// 产出批次:成本来自产出它的加工腿(processing_outputs.unit_cost_base,至多一条),
// 市价来自 assay 金属含量 × 最新金属价
export type OutputValuation = {
    unitCost: number | null // USD/kg;null = 从未分摊
    costValue: number | null // remaining × unitCost;无成本为 null
    marketValue: number | null // remaining × 每公斤市价;无已计价金属为 null
    ageDays: number | null // 距 output_date;无日期为 null
}

// 最新有效金属价:每个金属取 price_date 最大的一条(调用方已过滤 deleted_at / 未来日期)。
// 不依赖输入顺序,重复日期由 DB 唯一约束排除。
export function latestPriceByMetal(
    rows: { metal: string; price_usd_per_tonne: number; price_date: string; price_index?: string | null }[],
    // METAL-2:取【哪一条序列】的价。库存估值没有合同可以继承指数,所以调用方
    // 传的是 pricing_settings.default_metal_index —— 一个默认值在替一条缺席的
    // 条款站位,不是"这批货按某个指数结算了"。它还没卖。
    // null = 未标注指数的那条序列(既有 11 行所在的位置)。
    priceIndex: string | null = null
): Map<string, number> {
    const best = new Map<string, { price: number; date: string }>()
    for (const r of rows) {
        // 跨序列混着取"最新一条"会让估值在两个市场之间跳,而没有人说得出它用了哪个
        if ((r.price_index ?? null) !== priceIndex) continue
        const cur = best.get(r.metal)
        if (!cur || r.price_date > cur.date) {
            best.set(r.metal, { price: r.price_usd_per_tonne, date: r.price_date })
        }
    }
    return new Map(Array.from(best, ([metal, v]) => [metal, v.price]))
}

// 每公斤市价 = Σ(含量%/100 × USD/t ÷ 1000),只累计有价格的金属;
// 一个都没有 → null(展示成 '—',与"值为 0"区分开)。
export function marketValuePerKg(
    metals: { metal: string; content_pct: number }[],
    priceByMetal: Map<string, number>
): number | null {
    let sum = 0
    let priced = false
    for (const m of metals) {
        const price = priceByMetal.get(m.metal)
        if (price === undefined) continue
        priced = true
        sum += (m.content_pct / 100) * (price / 1000)
    }
    return priced ? sum : null
}
