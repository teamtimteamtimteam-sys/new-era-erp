// lib/valuation.ts
// 库存估值 + 库龄的共享助手(纯模块,服务端/客户端皆可用)。
//
// 库龄阈值目前是写死的常量(30/90 天),只做提示性上色;
// 危废贮存的合规期限(及告警)是 Phase 5 的事,届时再抽成可配置。
//
// 市价口径:金属价为 USD/吨,批次量按 kg 记(与 allocate_processing_costs 的假设一致),
// 故每公斤市价 = Σ(含量%/100 × 价格/1000)。

export type AgingTone = 'ok' | 'warn' | 'alert'

export const AGING_BANDS: { maxDays: number; tone: AgingTone }[] = [
    { maxDays: 30, tone: 'ok' },
    { maxDays: 90, tone: 'warn' },
    { maxDays: Infinity, tone: 'alert' },
]

// 库龄天数:baseDate(YYYY-MM-DD)到今天,UTC 日期差(避免时区把同一天算成 ±1)。
export function agingDays(baseDate: string | null): number | null {
    if (!baseDate) return null
    const base = Date.parse(baseDate) // 'YYYY-MM-DD' 按 UTC 午夜解析
    if (Number.isNaN(base)) return null
    const now = new Date()
    const todayUtc = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
    return Math.round((todayUtc - base) / 86_400_000)
}

export function agingTone(days: number | null): AgingTone | null {
    if (days === null) return null
    for (const band of AGING_BANDS) {
        if (days <= band.maxDays) return band.tone
    }
    return null // unreachable(最后一档 maxDays 为 Infinity)
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
