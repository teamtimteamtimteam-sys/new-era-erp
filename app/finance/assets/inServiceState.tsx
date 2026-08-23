// FIX-1(B-D5):一台机器的【投用状态】怎么写在屏幕上 —— 一份实现,两处共用。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么需要它:一个过去时的标签配一个未来的日期,读起来是真的,而它不是】
// FIX-1 之前,详情页写「投用日:2027-01-01」,列表页也照直印那一天。
// 那一行读起来是"这台机器 2027-01-01 起在役" —— 而那一天【还没到】。
// Tim 填它是想说"这条线明年投产",而这一列装不下那个意思。
//
// 【三个具名状态,一个都不许是空白,也不许是过去时标签配未来日期】
//   1. 没投用,也没有计划   → 「尚未投用」
//   2. 计划在某天投用       → 「计划 2027-01-01 投用」  ← 将来时,而且带日期
//   3. 已投用              → 「2026-03-16 起在役」      ← 过去时,只在真的到了才用
// ════════════════════════════════════════════════════════════════════════════
export type InServiceShape = {
    in_service_date: string | null
    planned_in_service_date: string | null
}

/** 返回 i18n 键与参数 —— 由调用方 t() 出来,好让两处的句子永远是同一句。 */
export function inServiceState(a: InServiceShape): { key: string; params?: Record<string, string> } {
    if (a.in_service_date) {
        return { key: 'assets.inServiceSince', params: { 0: a.in_service_date } }
    }
    if (a.planned_in_service_date) {
        return { key: 'assets.plannedFor', params: { 0: a.planned_in_service_date } }
    }
    return { key: 'assets.notCommissioned' }
}
