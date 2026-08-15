// SO-4b:报价在应用这一侧的形状与共用零件。
//
// 【状态 → 文案键是一张静态表,不拼动态键】与 salesOrderTypes 的 SO_STATUS_KEY
// 逐字同一条理由:拼出来的键 check-i18n 的字面量收网看得见一半、看不见另一半,
// 而三次线上事故全住在动态键里。

export const QUOTE_STATUSES = ['draft', 'issued', 'declined', 'converted'] as const
export type QuoteStatus = (typeof QUOTE_STATUSES)[number]

export const QUOTE_STATUS_KEY: Record<string, string> = {
    draft: 'quotes.status.draft',
    issued: 'quotes.status.issued',
    declined: 'quotes.status.declined',
    converted: 'quotes.status.converted',
}
export const quoteStatusKey = (s: string) => QUOTE_STATUS_KEY[s] ?? 'quotes.status.unknown'
