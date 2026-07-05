// app/stocktakes/delta.ts
// 盘点差异的数值助手。DB numeric 到 JS 变浮点,直接相减会出 1e-16 级噪声,
// 造成"假差异"(0.30000000000000004 ≠ 0)。统一四舍五入到 1e-6 —— 远超称重精度。

export function roundQty(n: number): number {
    return Math.round(n * 1e6) / 1e6
}

// 差异 = 实点 − 当前账面(正 = 盘盈,负 = 盘亏)
export function qtyDelta(counted: number, current: number): number {
    return roundQty(counted - current)
}

// 带符号显示:正数补 '+',其余原样(负号自带)
export function formatSigned(n: number): string {
    return n > 0 ? `+${n}` : String(n)
}
