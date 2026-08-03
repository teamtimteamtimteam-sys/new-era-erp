// lib/format.ts
// 共享格式化助手。第一个是金额格式化 —— 运行详情(成本/分摊)后续也会复用这一份。
//
// formatMoney:两位小数 + 千分位;【不带货币符号】(列头标注币种)。
// FIN-0 前叫 formatUsd —— 它从来只管数字形状,不管币种;本位币换成 SGD 后名字不能再撒谎。
// null/undefined 返回空串,方便"未分摊/未填"直接留白。
export function formatMoney(n: number | null | undefined): string {
    if (n === null || n === undefined) return ''
    return new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    }).format(n)
}

// formatAmount:带币种代码的金额(如 "1,234.56 SGD")。formatMoney 是【无币种】
// (不带符号,靠列头标注),但银行对账里 SGD 账户的金额绝不能被当成 USD 展示 ——
// 凡是币种随数据变化的地方用这个。null/undefined 返回 '—'。
export function formatAmount(n: number | null | undefined, ccy: string | null | undefined): string {
    if (n === null || n === undefined) return '—'
    const num = new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    }).format(n)
    return ccy ? `${num} ${ccy}` : num
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
