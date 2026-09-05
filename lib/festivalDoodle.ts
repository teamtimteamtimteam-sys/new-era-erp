// lib/festivalDoodle.ts
// ════════════════════════════════════════════════════════════════════════════
// UI-1b(2026-09-05)· 首页字标在节日窗口里换一张画
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【顶栏那个标记【永远不换】★★
// 换的只有【首页】那个大字标。顶栏左上角是 `evoltrya-os-black.svg`,黑白、
// 25.5px 高,一年三百六十五天不动 —— 理由在 docs/brand-tokens.md §3.1.2:
// 「Tim 排除了彩色字标,两条理由:球体的细线在 20–24px 上会糊成一团;
//   而一个彩色标记会与右边那两个圆按钮抢眼。」**那两条理由与节日无关,
//   所以节日也不构成例外。** 本文件被 app/page.tsx 一个地方引用,
//   而 TopNav.tsx 不 import 它 —— 那是这条保证的机械形式。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么是【另一张表】,不是 public_holidays 的一个开关】★★
// ════════════════════════════════════════════════════════════════════════════
//
// C-2 当时被要求"把假日表设计成两个消费方共用"。**那条指示是错的,Tim 已经推翻。**
//
// 23 个节日里只有 **10 个**是新加坡公共假期。共用一张表意味着:
// **谁为了让首页出现一张万圣节的画而加了一行,就同时把那天变成了非工作日** ——
// 于是每一个人的年假计算、每一张考勤表、每一次 `is_business_day()` 判断
// (它还是 FX 回溯那条规矩的判据!)全都跟着变。
//
// > **一个公共假期是一件【工作日事实】;一张节日画是【装饰】。它们不该共用一行。**
//
// C-2 的 `holiday_key` 与 `is_in_lieu` 【留着】—— 跨年份稳定的身份本来就有用,
// 一点没浪费。两张表各自表达自己的事实:某个节日碰巧也是公共假期,
// 那是一次巧合,**两边各记各的,不交叉引用**。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【窗口是【算好存进去的日期】,不是一条规则】★★
// ════════════════════════════════════════════════════════════════════════════
//
// Tim 的三条特例(圣诞提前 3 天、一直到元旦【前一天】;元旦【当天】起 3 天;
// 农历新年提前 3 天、整窗 7 天;其余一律"前一天 + 当天")**本身就不规则**,
// 而下一个节日可能又要一条它自己的。**存规则要写代码,存日期只要改一行。**
// 算一次、写进去、在报告里把表印出来给 Tim 自己核 —— 那正是本刀做的。
//
// ★【两处【首尾相接】,那是相邻,不是重叠】★
//   圣诞 12-31 结束 → 元旦 01-01 开始;耶稣受难日 03-26 结束 → 复活节 03-27 开始。
//   **中间没有一天是平日字标。** 记在这里,免得那两天被当成 bug 报上来。
//
// ★★【将来真的重叠了怎么办 —— 判据在这里,不去问 Tim】★★
//   这是一个设计细节,不是一个需要他裁的决定。规则:
//     **① 窗口【短】的赢 · ② 同长则【晚开始】的赢 · ③ 再同则 holiday_key 升序。**
//   为什么"短的赢":一个 2 天的窗口是一次【具体】的纪念,一个 10 天的窗口
//   (圣诞)是一段【气氛】。把具体的那个盖在气氛上面,是人会做的选择。
//   ②③ 只为消除歧义而存在 —— **判据必须给出唯一答案,否则同一天两次刷新
//   会出现两张不同的画,而那读起来像坏了。**
//   同一段话写进 docs/information-architecture.md §20。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { businessToday } from '@/lib/format'

/** 产物路径的唯一拼法。**代码里没有文件名映射表** —— 约定就是 key + .webp。 */
export function doodleSrc(holidayKey: string): string {
    return `/brand/festivals/${holidayKey}.webp`
}

export type Doodle = { holidayKey: string; nameEn: string; nameZh: string; src: string }

/**
 * 【今天(新加坡的今天)该画哪张】。**没有窗口盖住今天就返回 null** ——
 * 那是绝大多数日子的正常状态,不是一次失败。
 *
 * 日期口径与问候语同一个时钟:`businessToday()`(lib/format.ts:84),
 * 它自己那一段抬头记着 `toISOString().slice(0,10)` 在新加坡凌晨会早一天。
 * **一张节日画早一天出现,正好就是把"前一天"整段错位。**
 */
export async function getTodaysDoodle(): Promise<Doodle | null> {
    const supabase = await createClient()
    const today = businessToday()

    const rows = mustRows(
        await supabase
            .from('festival_doodles')
            .select('holiday_key, name_en, name_zh, window_start, window_end')
            .eq('is_active', true)
            .lte('window_start', today)
            .gte('window_end', today),
        'festival_doodles'
    ) as { holiday_key: string; name_en: string; name_zh: string; window_start: string; window_end: string }[]

    if (rows.length === 0) return null

    // 【重叠的判据在这里,而不是在 SQL 的 ORDER BY 里】—— 它是一条要被读到的
    // 规则(见抬头),写成三行 TypeScript 比写成一句 ORDER BY 更容易读对。
    const winner = rows.reduce((best, r) => {
        const len = (d: { window_start: string; window_end: string }) =>
            Date.parse(d.window_end) - Date.parse(d.window_start)
        if (len(r) !== len(best)) return len(r) < len(best) ? r : best //     ① 短的赢
        if (r.window_start !== best.window_start) //                          ② 晚开始的赢
            return r.window_start > best.window_start ? r : best
        return r.holiday_key < best.holiday_key ? r : best //                 ③ key 升序
    })

    return {
        holidayKey: winner.holiday_key,
        nameEn: winner.name_en,
        nameZh: winner.name_zh,
        src: doodleSrc(winner.holiday_key),
    }
}
