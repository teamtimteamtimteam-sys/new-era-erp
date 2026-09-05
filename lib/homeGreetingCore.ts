// lib/homeGreetingCore.ts
// ════════════════════════════════════════════════════════════════════════════
// UI-1b · 问候语的【纯核】—— 零 import,所以它可以被断言
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【这个文件为什么与 lib/homeGreeting.ts 分开】★★
// 它一个 import 都没有。**那不是洁癖,那是这两支函数【能不能被证明】的前提。**
//
//   · `slotFor` 要在【三个不同的进程 TZ】下跑同一句断言
//     (scripts/assert-home-greeting.mjs 用 TZ=UTC / America/Los_Angeles /
//      Asia/Singapore 各跑一遍)。
//   · 而 `lib/homeGreeting.ts` import 了 `next/headers` 与 `@/lib/supabase/server`
//     —— 前者要一个请求上下文,后者要打包器解析 `@/` 别名。
//     **一个断言脚本 import 不动它。**
//
// 所以纯的那一半住在这里,取数那一半住在隔壁 import 它。
// 决策全文与"为什么时区是参数不是默认值"写在 lib/homeGreeting.ts 抬头,
// 不在这里重复一遍 —— 同一段理由抄两份,迟早各改一次。

/** 六个时段。字面量与 db/tables/home_greetings.sql 的 CHECK 闭集逐字相同。 */
export const GREETING_SLOTS = [
    'early_morning',
    'morning',
    'midday',
    'afternoon',
    'evening',
    'late_night',
] as const
export type GreetingSlot = (typeof GREETING_SLOTS)[number]

/** 上一句记在这个 cookie 里。见抬头【四】—— 它不是 httpOnly,理由写在那里。 */
export const GREETING_COOKIE = 'evo_home_greeting'

/**
 * 【这个瞬间,在这个时区里,落在哪个时段】—— 纯函数,两个入参都显式。
 *
 * ★ 时区是【参数】不是默认值,这一点是承重的 ★:它让这支函数可以在任意
 *   进程 TZ 下被断言(见抬头【一】)。调用方永远传 BUSINESS_TIMEZONE。
 *
 * 边界逐字照 Tim 给的六段(闭区间,分钟粒度):
 *   06:00–08:59 早 · 09:00–11:29 上午 · 11:30–13:29 午 ·
 *   13:30–17:29 下午 · 17:30–21:59 晚 · 22:00–05:59 深夜
 */
export function slotFor(instant: Date, timeZone: string): GreetingSlot {
    // hourCycle h23 —— 不这么写的话 en-US 会给出 12 小时制,午夜是 "24"(h24)
    // 或者 "12 AM",两者都要再解析一次。h23 直接给 00–23。
    const parts = new Intl.DateTimeFormat('en-GB', {
        timeZone,
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23',
    }).formatToParts(instant)
    const hour = Number(parts.find((p) => p.type === 'hour')?.value)
    const minute = Number(parts.find((p) => p.type === 'minute')?.value)
    // 【一次缺席不许被渲染成一个答案】—— 解析不出来就抛,不悄悄当成午夜。
    if (!Number.isFinite(hour) || !Number.isFinite(minute)) {
        throw new Error(`slotFor:解析不出 ${timeZone} 的时分(${JSON.stringify(parts)})`)
    }
    const m = hour * 60 + minute
    if (m >= 360 && m <= 539) return 'early_morning' // 06:00–08:59
    if (m >= 540 && m <= 689) return 'morning' //        09:00–11:29
    if (m >= 690 && m <= 809) return 'midday' //         11:30–13:29
    if (m >= 810 && m <= 1049) return 'afternoon' //     13:30–17:29
    if (m >= 1050 && m <= 1319) return 'evening' //      17:30–21:59
    return 'late_night' //                               22:00–05:59(含跨零点那一段)
}

export type GreetingLine = { id: string; line_en: string }

/**
 * 【从候选里挑一句,排除上一句】—— 纯函数,随机源显式传入,所以断言得了。
 *
 * @param lines  这个时段的全部句子(已按 id 稳定排序)
 * @param prevId 上一次渲染的那一句;null = cookie 不在,不排除
 * @param roll   [0,1) 的随机数。**显式传进来**,否则这支函数没法被断言 ——
 *               与 slotFor 把 tz 显式化是同一个理由。
 */
export function pickGreeting(
    lines: readonly GreetingLine[],
    prevId: string | null,
    roll: number
): GreetingLine | null {
    if (lines.length === 0) return null
    // 【只剩一句时不能排除它】—— 排除到空集就成了"这个时段没有问候语",
    // 而那是一处缺席被渲染成了一个答案。宁可重样,不可空白。
    const pool = lines.length > 1 ? lines.filter((l) => l.id !== prevId) : lines
    const candidates = pool.length > 0 ? pool : lines
    const i = Math.min(candidates.length - 1, Math.floor(roll * candidates.length))
    return candidates[i]
}
