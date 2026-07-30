// app/components/metals/priceBatchHref.ts
// 由批次数量 + 已录化验行拼出计价器的预填链接(进料/产出两侧共用)。
// 普通模块,服务端页面调用后把结果作为 priceHref 传给 MetalContentPanel。
import type { MetalContentRow } from './metalContentTypes'

export function priceBatchHref(
    quantity: number | null | undefined,
    rows: Pick<MetalContentRow, 'metal' | 'content_pct'>[]
): string | undefined {
    if (!rows.length) return undefined
    const params = new URLSearchParams()
    if (quantity != null) params.set('quantity', String(quantity))
    for (const r of rows) params.set(r.metal, String(r.content_pct))
    return `/pricing/calculator?${params.toString()}`
}
