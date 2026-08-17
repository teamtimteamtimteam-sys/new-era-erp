// app/components/ActorName.tsx
// AUDEL-3:把一个登录账号 uuid 渲染成【一个人】—— 一份实现,所有显示"谁做的"
// 的地方共用。
//
// 【为什么它必须只有一处】Tim 的验收里看到过一个裸 uuid。那不是一次笔误:
// /stocktakes/[id] 与新的"已删除记录"页各自写一遍"取不到名字就退回 uuid",
// 两处迟早给出两种答案 —— 而这一族要回答的正是"谁为这件事负责"。
// 所以取名与兜底都在这里,调用方只传 id 和一张已经查好的名字表。
//
// ── 三种状态,三句不同的话 ────────────────────────────────────────────────
//   ① 查得到员工          → 印姓名;
//   ② 有账号、但没关联员工 → 印【具名状态】「该账号未关联员工档案」,
//      并把 id 作为小字附在后面。**绝不裸印 uuid** —— 一串 uuid 对读的人
//      不是一个答案,而它看起来像一个答案;
//   ③ 根本没有记过是谁    → 印「未记录」,并说明是哪一段历史造成的。
//      **绝不留空、绝不猜**(FIN-26):线上 16 行已删记录里有 14 行属于这一类,
//      它们是 AUDEL-1b 之前删的,当时系统没有记过人。留空会被读成
//      "没有人做过这件事",而真相是"当时没有人记下来"。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'

export type ActorNameMap = Map<string, string>

/** 一次把一批 uuid 的姓名查回来 —— 逐行查会是 N 次往返。 */
export async function loadActorNames(
    supabase: SupabaseClient<Database>,
    ids: (string | null | undefined)[]
): Promise<ActorNameMap> {
    const unique = [...new Set(ids.filter((x): x is string => !!x))]
    const map: ActorNameMap = new Map()
    if (unique.length === 0) return map
    // 【失败必须失败】用 mustRows,不用 `?? []` —— 读不到名字表时每一行都会退化成
    // 「该账号未关联员工档案」,而那是一句【断言】,不是一次读取失败该说的话。
    const rows = mustRows(
        await supabase.from('employees').select('user_id, legal_name').in('user_id', unique),
        'employees actor names'
    )
    for (const r of rows) {
        if (r.user_id) map.set(r.user_id, r.legal_name)
    }
    return map
}

export default async function ActorName({
    userId,
    names,
    /** 没有记过人时那句话的来由(例如"这条记录早于 AUDEL-1b") */
    unrecordedHint,
}: {
    userId: string | null | undefined
    names: ActorNameMap
    unrecordedHint?: string
}) {
    const t = await getTranslations()

    // ③ 根本没记过
    if (!userId) {
        return (
            <span className="text-gray-500">
                {t('actor.unrecorded')}
                {unrecordedHint && (
                    <span className="ml-1 text-xs text-gray-400">({unrecordedHint})</span>
                )}
            </span>
        )
    }

    // ① 查得到
    const name = names.get(userId)
    if (name) return <span>{name}</span>

    // ② 有账号、没档案 —— 具名状态 + 小字 id
    return (
        <span className="text-gray-600">
            {t('actor.noEmployeeRecord')}
            <span className="ml-1 text-xs text-gray-400 font-mono">{userId.slice(0, 8)}…</span>
        </span>
    )
}
