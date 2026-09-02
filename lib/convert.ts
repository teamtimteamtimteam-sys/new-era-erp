// lib/convert.ts — 换算器用得上的【常数与纯算术】,以及每一个常数的出处。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【这个文件里【没有】湿基/干基换算,那是刻意的】★★
// 湿转干住在数据库里(`convert_weight_basis` / `convert_grade_basis`,
// TOOLS-1 从 sale_settlement_compute 提取)。**换算器调那两支,不在这里抄一遍。**
// 理由是 AGENTS.md 那条"一处实现,两个调用者":同一段算术写两遍,
// 在写下来那天一致,之后悄悄分开 —— 这个仓库为这个形状付过四次账。
// 而那一段算术【决定钱】(结算重量 × 含量 × 计价系数),抄错了就是钱错了。
//
// 【这里放的是另一类:没有"系统自己的定义"可以复用的那些】
// 每一条都写明它的出处,以及【它是不是这个系统的约定】—— 两者必须分得开。
// ════════════════════════════════════════════════════════════════════════════

/**
 * 一公吨 = 1000 公斤。
 *
 * 【它是不是系统自己的定义?——【是】,而且它在一条【算钱】的路径上】
 * `lib/valuation.ts:16` 写着「每公斤市价 = Σ(含量%/100 × 价格/1000)」,
 * 那个 `/1000` 就是本常数,把 `metal_prices.price_usd_per_tonne` 折成每公斤。
 * 所以这里【不是新发明一个约定】,是把系统已经在用的那个数写出名字。
 * (公吨/tonne 也叫 metric ton;它与美吨/英吨不是一回事,而本系统只用公吨。)
 */
export const KG_PER_TONNE = 1000

/**
 * 一磅 = 0.45359237 公斤(**精确值**,不是近似)。
 *
 * ★【出处:国际码磅协定(1959),SI 对常衡磅的定义 —— 【不是】本系统的约定】★
 * **实测:全仓库【没有】任何磅的换算**(搜过 pound / lb / 0.4535 / 2.2046 /
 * 453.59,零命中)。也就是说这里【没有系统自己的定义可以复用】,
 * 而 TOOLS-1 ④ 明确要求这种情况"照直说出来,而不是发明一个"。
 * 所以:这个数来自 SI,出处写在这里,而屏幕上也会把它印出来。
 * 【它今天没有任何业务路径依赖它】—— 换算器是它唯一的读者。
 */
export const KG_PER_POUND = 0.45359237

/**
 * 品位:1% = 10 000 克/吨。
 *
 * ★【它是【定义性的算术】,不是任何人的约定 —— 这一点要说清楚】★
 * 一吨 = 1 000 000 克;1% 的一吨 = 10 000 克。所以 1% ≡ 10 000 g/t 是恒等式,
 * 不是一个可以"选"的换算率。
 * **实测:全仓库没有任何 g/t 或 ppm 的换算**(搜过 g/t、gram…tonne、ppm、
 * 1000000、1e6,零命中)。系统内部一律用【百分比】记含量
 * (`assay_result_metals.content_pct`、`material_required_metals`),
 * 所以 g/t 这一档【只服务于读化验单的人】,系统自己不消费它。
 */
export const GRAMS_PER_TONNE_PER_PERCENT = 10_000

export type MassUnit = 'tonne' | 'kg' | 'pound'

/** 各单位换成公斤的系数 —— 上面三个常数的一张表,不是第四个定义。 */
const KG_PER: Record<MassUnit, number> = {
    tonne: KG_PER_TONNE,
    kg: 1,
    pound: KG_PER_POUND,
}

/**
 * 质量换算。**先折成公斤再折过去** —— 一个中枢单位,而不是 3×3 张系数表:
 * 九个系数里总有一个会与另外八个不自洽,而这里只有三个数可以错。
 *
 * **不 round。** 取几位是【显示】的事,由调用方决定并且要说出来 ——
 * 在算术里悄悄 round 会让"再换回去"对不上,而这是一个给人核对用的工具。
 */
export function convertMass(value: number, from: MassUnit, to: MassUnit): number {
    return (value * KG_PER[from]) / KG_PER[to]
}

/** 含量百分比 → 克/吨。 */
export function pctToGramsPerTonne(pct: number): number {
    return pct * GRAMS_PER_TONNE_PER_PERCENT
}

/** 克/吨 → 含量百分比。 */
export function gramsPerTonneToPct(gpt: number): number {
    return gpt / GRAMS_PER_TONNE_PER_PERCENT
}

/**
 * 结算那一侧的 round 位数。
 *
 * ★【出处:`sale_settlement_compute` 里那两处 `round(…, 4)`】★
 * TOOLS-1 ④ 要求"取整规则要有出处,不许自己发明一个" —— 这就是那个出处。
 * 结算重量与含金属量都按 4 位取整,所以换算器在【湿转干】那一档
 * 显示 4 位,与结算给出的数字对得上。
 * **另外两档(质量、品位)不属于结算路径**,它们没有这个出处,
 * 所以屏幕上按有效数字显示,并且明说"这一档不是结算口径"。
 */
export const SETTLEMENT_ROUND_DP = 4
