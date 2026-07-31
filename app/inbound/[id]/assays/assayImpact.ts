// app/inbound/[id]/assays/assayImpact.ts
// "如果应用会怎样"的影响计算 —— 普通模块(不是 server action),所以服务端页面与
// 服务端动作都能直接调用。
//
// 【镜像 reprice_inbound_batch】(见 db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql
// 的 B1):ratio = clamp(remaining/quantity, 0, 1);inventory = round(delta × ratio, 2);
// cost = delta − inventory。
// 之所以要在应用之外再算一遍:DB 只在【提交那一刻】算这些数,而预览发生在提交之前,
// 系统里没有 dry-run 入口(加一个就是 schema 改动)。真正入账的数字一律以
// apply_assay_result 的返回 / price_history 那一行为准 —— 这里只回答"如果应用会怎样"。
export type AssayImpact = {
    quantity: number
    current_unit_price: number | null
    new_unit_price: number
    unit_delta: number
    total_delta: number
    in_stock_ratio: number
    inventory_share: number
    cost_share: number
}

const round2 = (n: number) => Math.round(n * 100) / 100
const round4 = (n: number) => Math.round(n * 10000) / 10000

export function computeAssayImpact(
    quantity: number,
    remaining: number,
    currentPrice: number | null,
    newPrice: number
): AssayImpact {
    const ratio = quantity === 0 ? 1 : Math.min(1, Math.max(0, remaining / quantity))
    const totalDelta = round2(quantity * (newPrice - (currentPrice ?? 0)))
    const inventoryShare = round2(totalDelta * ratio)
    return {
        quantity,
        current_unit_price: currentPrice,
        new_unit_price: newPrice,
        unit_delta: round4(newPrice - (currentPrice ?? 0)),
        total_delta: totalDelta,
        in_stock_ratio: round4(ratio),
        inventory_share: inventoryShare,
        cost_share: round2(totalDelta - inventoryShare),
    }
}
