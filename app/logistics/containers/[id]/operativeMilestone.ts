// app/logistics/containers/[id]/operativeMilestone.ts
//
// CTN-OP:「同一种里程碑之内,哪一条算数」—— 这条规则在页面这一侧【只有这一份】。
//
// ════════════════════════════════════════════════════════════════════════════
// 规则(LOG-5d 定的):算数的是【最后被录入】的那一条 —— recorded_at DESC,
// 同刻则 id DESC 破平局。**不是 event_date 最晚的那一条**:里程碑只增不改,
// 更正的写法是再记一条,而一条把日期改【早】的更正在 event_date 排序下永远
// 排不到前面 —— 它一次都不会生效(线上 CTR-2026-0009 就是这么躺着的)。
//
// 【为什么要抽出来】在此之前,页面这一侧已经有两处各自实现过"哪一条算数":
//   · ContainerFreightPanel 的免柜期锚点(SQL 里排序 + limit 1);
//   · 里程碑时间轴上那个 ↺ 标记 —— 而它【算错了】:它按【列表当前的显示顺序】
//     取"第一次出现的那条"当原始行,而列表是按 event_date 排的,
//     于是 08-16 那条(最早录、日期最晚)被标成原始行、没有 ↺,
//     后录的更正反而被标成 ↺。**恰好把真相说反了**,而 Tim 就是这么读错的。
// 再写第三份就是第三个会漂开的答案。所以两处都改成调用这里。
//
// 【库里那一份仍然是另一份实现】db/views/operations_now.sql 的两支臂
// (free_time_expiring / container_no_arrival)在 SQL 里排同样的序 ——
// 那是 LOG-5b 就记下的已知重复(去掉它要一个库侧算子),两边注释互相点名。
// 本文件只保证【页面这一侧】不再有第三种说法。
// ════════════════════════════════════════════════════════════════════════════

export type MilestoneLike = {
    id: string
    milestone: string
    recorded_at: string
}

/**
 * 同一种里程碑里,谁排在前面就是谁算数。
 * recorded_at 降序;同刻则 id 降序 —— 与 db/views/operations_now.sql 里那两处
 * `ORDER BY m.recorded_at DESC, m.id DESC` 逐字对应。
 */
function laterWins(a: MilestoneLike, b: MilestoneLike): number {
    if (a.recorded_at !== b.recorded_at) return a.recorded_at < b.recorded_at ? 1 : -1
    // 【id 只用来破平局,不代表"更晚"】—— uuid 比大小没有时间含义,
    // 但它是确定的,而不确定比排错更坏。库里那一侧同理。
    return a.id < b.id ? 1 : -1
}

/** 某一种里程碑当前算数的那一条(没有则 null)。 */
export function operativeOf<T extends MilestoneLike>(rows: T[], milestone: string): T | null {
    const of = rows.filter((r) => r.milestone === milestone)
    if (of.length === 0) return null
    return [...of].sort(laterWins)[0]
}

/** 出现过的每一种里程碑,各自算数的那一条的 id。 */
export function operativeMilestoneIds(rows: MilestoneLike[]): Set<string> {
    const out = new Set<string>()
    for (const type of new Set(rows.map((r) => r.milestone))) {
        const op = operativeOf(rows, type)
        if (op) out.add(op.id)
    }
    return out
}
