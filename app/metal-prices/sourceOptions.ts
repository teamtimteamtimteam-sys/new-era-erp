// app/metal-prices/sourceOptions.ts
// LME-1b:行情出处的选项来源。与 indexOptions.ts 同一条思路,但有一处关键不同 ——
// **这个集合是【封闭】的,而且它的边界写在数据库的 CHECK 里**
// (metal_prices_source_check),不是一张可以加行的字典表。
// 加一种出处 = 改那条 CHECK = 一支迁移;所以这里的字面量与库里那四个值
// 【必须一一对应】,fixture 91 的 B/E 两臂钉住它们。
//
// 【unknown 不在这个列表里,而这是本文件存在的主要理由】
// 它是一个【只能向后看】的状态:LME-1a 之前录入的行情没有人记过出处,
// 所以它们读作"来源未记录"。**新录入不许选它** —— 允许选,就等于把
// "这一列是空话"原样保留下来,只是换了个词。
// upsert_metal_prices 会按名拒(QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW);
// 表单干脆不提供它,于是那条拒绝在正常使用中永远不会被撞到。

/** 新录入可选的三种出处。顺序即下拉顺序。 */
export const NEW_QUOTE_SOURCES = ['published_index', 'broker_quote', 'internal_estimate'] as const
export type NewQuoteSource = (typeof NEW_QUOTE_SOURCES)[number]

/** 库里还存在、但不许新选的历史状态。 */
export const LEGACY_QUOTE_SOURCE = 'unknown'

/** 表单里"当天 / 延迟 / 未记录"的三态哨兵 —— 空串在 FormData 里与"没填"分不开。 */
export const DELAY_UNRECORDED = '__unrecorded__'
export const DELAY_SAME_DAY = 'same_day'
export const DELAY_DELAYED = 'delayed'

/** 任一出处值 → 文案键。认不出的值原样返回,不猜(它会显示成键本身,而那是可见的)。 */
export function sourceLabelKey(source: string | null | undefined): string {
    if (!source) return 'metalPrices.source.unknown'
    return 'metalPrices.source.' + source
}
