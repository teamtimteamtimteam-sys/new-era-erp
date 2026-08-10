// lib/format.ts
// 共享格式化助手。第一个是金额格式化 —— 运行详情(成本/分摊)后续也会复用这一份。
//
// ── 金额的两种写法,以及为什么【不带币种的那个要多写一个参数】(CCY-1)───────
//
// 无币种的写法本身是对的:一列同币种的数字,列头写了币种,不必每格重复。错的是
// 【无币种曾经是默认】—— formatMoney(n) 打起来最省事,于是 23 个屏幕的金额就那么
// 一路裸奔下去(docs/money-without-currency-inventory.md),包括同一块面板上半截
// USD、下半截本位币而毫无标记的化验影响块。
//
// 所以:formatAmount(n, ccy) 是【平常的那个】;要省掉币种,得说出它写在哪儿 ——
// 这句话写在调用点,读代码的人和改代码的人都躲不开。说不出来,就说明这里本来就
// 该用 formatAmount。第二个参数是必填的,所以漏标不再是"少打几个字",而是【类型错误】。
export type CcyStatedIn = string   // 币种写在哪儿的人话说明,例如 '列头 Amount ({ccy})'

// formatMoneyBare:两位小数 + 千分位、不带币种。
// FIN-0 前叫 formatUsd —— 它从来只管数字形状,不管币种;本位币换成 SGD 后名字不能再撒谎。
// null/undefined 返回空串,方便"未分摊/未填"直接留白。
export function formatMoneyBare(n: number | null | undefined, ccyStatedIn: CcyStatedIn): string {
    void ccyStatedIn   // 只为在调用点留下那句交代 —— 运行时不用它
    if (n === null || n === undefined) return ''
    return new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    }).format(n)
}

// formatAmount:带币种代码的金额(如 "1,234.56 SGD")—— 【平常用这个】。
// 币种随数据变化的地方(银行、发票、采购单)固然必须用它;本位币金额同样用它,
// 除非币种确实已经写在列头/行标签/面板抬头上,那时才改用 formatMoneyBare 并
// 在第二个参数里说明写在哪儿。null/undefined 返回 '—'。
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

// ── 业务时区(FIN-20/21)─────────────────────────────────────────────────────
// 服务器时间戳一律按【业务时区】展示,不按渲染进程碰巧继承的时区。
// 这些 toLocaleString 都在【服务端】跑(RSC 预格式化,避免水合不一致),而
// Node 的环境时区是部署细节:TZ=UTC 的进程把 13:50 SG 渲染成 "5:50:31 AM",
// 时间戳本身分毫不差 —— walk 里两块屏就是这么"显示成 UTC"的。
// 数据库侧的同一决定在 db/database-settings.sql(库级 GUC,gate 的 guc 行钉住);
// 这里是它的界面侧镜像 —— 两处必须同改,与 lib/currencyMap.ts 对
// bank_native_currency 的关系相同。真有第二辖区时,改显式参数,不改常量。
export const BUSINESS_TIMEZONE = 'Asia/Singapore'

// formatTimestamp:ISO 时间戳 → 业务时区的本地化字符串。
// null/undefined 返回 '—'(与 formatAmount 同约定)。
export function formatTimestamp(iso: string | null | undefined, locale: string): string {
    if (!iso) return '—'
    return new Date(iso).toLocaleString(locale, { timeZone: BUSINESS_TIMEZONE })
}
