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

// formatUnitCost:单位成本,4 位小数(与 DB 存储精度一致);null/undefined 返回空串。
// ★【FX-DISPLAY-1:这行注释从前写着「(USD/kg)」,而它【不知道】币种】★
//   它和 formatMoneyBare 一样,只管数字形状 —— 八个调用点传进来的
//   unit_price / unit_cost_base 都是【本位币】(SGD),
//   estimated_unit_price 则跟着采购单自己的币种。
//   一个宣称币种的格式化函数,会让调用点省掉"这是什么币"这个问题,
//   而那正是本刀在 /inventory 上修的那个缺陷的成因。币种由调用点写在列头/行标签上。
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

// ★★【businessToday():业务时区的"今天"—— CONV-7 ② 被实测抓出来的一处】★★
//
// 【它防的是什么,照直记】CONV-7 ② 的财务 Overview 第一版写的是
//   `new Date().toISOString().slice(0, 10)`,拿它当 gl_control_reconciliation 的
//   as_of。**那是 UTC 的今天,不是新加坡的今天** —— 在 SGT 上午 8 点之前,
//   它比业务日期【早一天】。
//
// ★【后果不是差一天那么轻】★ 那支函数对【早于今天】的存货腿**按名拒绝回答**
//   (它的抬头写着:「照答会返回一个自信的 0.00」)。于是那一页在新加坡的每个
//   凌晨到早上八点之间,四条腿里有两条画成「答不上来」—— 而它们其实答得上来。
//   **实测就是这么发现的**:直接问库用的是 CURRENT_DATE(库在业务时区),
//   四条腿全部 reconciled;而浏览器里渲染出来的那一页 reconRefusals = 2。
//   **一个只在一天里某几个小时出现的错误,靠读代码是读不出来的。**
//
// 【为什么放在这里】BUSINESS_TIMEZONE 就在上面,而它已经是"界面侧那一份镜像"。
// 一个业务日期的来源应当和业务时区的来源在同一处,否则下一个人会再写一次
// toISOString().slice(0,10) —— 那正是这次写出来的东西。
export function businessToday(): string {
    // en-CA 给的正是 YYYY-MM-DD,不用自己拼 —— 自己拼就要处理补零。
    return new Intl.DateTimeFormat('en-CA', { timeZone: BUSINESS_TIMEZONE }).format(new Date())
}

// formatTimestamp:ISO 时间戳 → 业务时区的本地化字符串。
// null/undefined 返回 '—'(与 formatAmount 同约定)。
export function formatTimestamp(iso: string | null | undefined, locale: string): string {
    if (!iso) return '—'
    return new Date(iso).toLocaleString(locale, { timeZone: BUSINESS_TIMEZONE })
}
