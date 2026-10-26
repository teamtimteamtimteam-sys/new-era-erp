// lib/datePresets.ts
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-2(Tim 2026-10-25 Q5 · 2026-10-26 Q6)· 日期快捷区间 —— 一份算术,11 张列表 + 损益表 + 现金流量表共用
// ════════════════════════════════════════════════════════════════════════════
// 裁定:本月 · 上月 · 本季度 · 今年;自然月与自然季度按【新加坡时间】;「今年」读配置的财年年末
//   (finance_settings.fy_end_month/day,经 fiscal_year_end_setting());每一个区间【到期末为止】(月末 · 季末 · 年末),与损益表原来一样。
// 【今天从哪来】调用方传进来 —— 服务端一律用 businessToday()(lib/format.ts,业务时区的今天)。
//   本文件只做纯算术,不碰时区、不碰 new Date() 的本地钟:同一个 today 进来,同一组区间出去。
// 【财年怎么算,与年结同一个定义】preview_close_financial_year.sql:37-70 —— Y 年的年末 = make_date(Y, m, LEAST(d, 那个月的最后一天));
//   今天所在的财年 = 第一个不早于今天的那个年末;它的开头 = 前一个年末的次日。
//   (2 月 29 日在平年落到 28 日;4 月 31 日落到 30 日 —— 与年结逐字同一条规矩。)
import { addDaysIso, daysInMonthOf } from '@/lib/dates'

export type DatePresetKey = 'thisMonth' | 'lastMonth' | 'thisQuarter' | 'thisYear'
export type DatePreset = { key: DatePresetKey; from: string; to: string }
export type FiscalYearEnd = { month: number; day: number }

const ymd = (y: number, m: number, d: number) => `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
const monthEnd = (y: number, m: number) => ymd(y, m, daysInMonthOf(y, m))
const fyEndIn = (y: number, fy: FiscalYearEnd) => ymd(y, fy.month, Math.min(fy.day, daysInMonthOf(y, fy.month)))

/** 今天所在的财年 [from, to]。 */
export function fiscalYearOf(today: string, fy: FiscalYearEnd): { from: string; to: string } {
    const y = Number(today.slice(0, 4))
    const end = fyEndIn(y, fy) >= today ? fyEndIn(y, fy) : fyEndIn(y + 1, fy)
    const prevEnd = fyEndIn(Number(end.slice(0, 4)) - 1, fy)
    return { from: addDaysIso(prevEnd, 1), to: end }
}

export function datePresets(today: string, fy: FiscalYearEnd): DatePreset[] {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) throw new Error(`DATE_PRESETS_BAD_TODAY|${today}`)
    const y = Number(today.slice(0, 4)), m = Number(today.slice(5, 7))
    const ly = m === 1 ? y - 1 : y, lm = m === 1 ? 12 : m - 1
    const q0 = Math.floor((m - 1) / 3) * 3 + 1
    return [
        { key: 'thisMonth', from: ymd(y, m, 1), to: monthEnd(y, m) },
        { key: 'lastMonth', from: ymd(ly, lm, 1), to: monthEnd(ly, lm) },
        { key: 'thisQuarter', from: ymd(y, q0, 1), to: monthEnd(y, q0 + 2) },
        { key: 'thisYear', ...fiscalYearOf(today, fy) },
    ]
}
