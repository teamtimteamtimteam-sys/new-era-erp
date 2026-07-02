// lib/format.ts
// 共享格式化助手。第一个是金额格式化 —— 运行详情(成本/分摊)后续也会复用这一份。
//
// formatUsd:两位小数 + 千分位;【不带货币符号】(列头已标注 "USD",避免重复)。
// null/undefined 返回空串,方便"未分摊/未填"直接留白。
export function formatUsd(n: number | null | undefined): string {
    if (n === null || n === undefined) return ''
    return new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    }).format(n)
}

// formatUnitCost:单位成本(USD/kg),4 位小数(与 DB 存储精度一致);null/undefined 返回空串。
// 展示端自行补 " /kg" 后缀,null 时展示 "—"。
export function formatUnitCost(n: number | null | undefined): string {
    if (n === null || n === undefined) return ''
    return new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 4,
        maximumFractionDigits: 4,
    }).format(n)
}
