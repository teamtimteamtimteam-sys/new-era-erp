// lib/dateFilter.ts
// 列表页日期区间过滤的共享助手(进料/产出/加工列表复用)。
// 只接受 YYYY-MM-DD;非法/缺省当作"不过滤"。

export function isYmd(s: string): boolean {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return false
    return !Number.isNaN(Date.parse(s))
}

// 从原始 searchParams 解析日期区间,校验后返回(空串 = 不过滤)。
export function parseDateRange(sp: { date_from?: string; date_to?: string }): {
    dateFrom: string
    dateTo: string
} {
    const from = (sp.date_from ?? '').trim()
    const to = (sp.date_to ?? '').trim()
    return {
        dateFrom: isYmd(from) ? from : '',
        dateTo: isYmd(to) ? to : '',
    }
}
