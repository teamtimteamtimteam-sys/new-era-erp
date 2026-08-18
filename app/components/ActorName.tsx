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
//   ④ 你看不到人事         → 印「受限」。
//
// 【④ 是 FIX-1 补上的,而它此前是一句谎话】employees 的 RLS 是
// has_permission('module.hr.view')(外加"自己那一行")。没有那个权限的读者
// 查回来的是【零行,不是错误】—— 于是 mustRows 一路放行,每一个 uuid 都落进
// 状态 ②「该账号未关联员工档案」。那是一句【断言】:它说的是"库里没这个人",
// 而真相是"你不能看"。这正是本仓库反复写的那一条 ——
// **一次权限答复不是一个空集**(mustRows / restRows / check-i18n 后缀同一条),
// 也正是 lib/permissions.ts 存在的全部理由:0.00 与「受限」不是一回事。
// 权限在 loadActorNames 里问一次(getMyPermissions 按请求缓存),随名字表一起
// 传下来,所以每一行不必各问一次。
// 注意 ①→④ 的先后:RLS 允许读【自己那一行】,所以一个无人事权限的人看自己
// 那条记录时名字是查得到的 —— 查得到就印名字,不要因为 restricted 就盖掉它。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'

/** 名字表 + 【这位读者能不能看人事】—— 两件事必须一起传,见抬头 ④。 */
export type ActorNameMap = { names: Map<string, string>; restricted: boolean }

/** 一次把一批 uuid 的姓名查回来 —— 逐行查会是 N 次往返。 */
export async function loadActorNames(
    supabase: SupabaseClient<Database>,
    ids: (string | null | undefined)[]
): Promise<ActorNameMap> {
    // 先问权限,再决定查不到时说什么(抬头 ④)。ids 为空时也要问 ——
    // 否则「这一页没有任何 actor」与「你看不到人事」会在别处被读成同一件事。
    const restricted = !(await can('module.hr.view'))
    const unique = [...new Set(ids.filter((x): x is string => !!x))]
    const map: ActorNameMap = { names: new Map(), restricted }
    if (unique.length === 0) return map
    // 【失败必须失败】用 mustRows,不用 `?? []` —— 读不到名字表时每一行都会退化成
    // 「该账号未关联员工档案」,而那是一句【断言】,不是一次读取失败该说的话。
    // 走【基表】而不是 employees_masked:基表的 RLS 额外放行"自己那一行"
    // (employees_masked 整张按 module.hr.view 判),所以一个没有人事权限的人
    // 至少认得出自己做的那件事。称呼名优先 —— 屏幕上要出现的是人怎么被叫。
    const rows = mustRows(
        await supabase.from('employees').select('user_id, legal_name, preferred_name').in('user_id', unique),
        'employees actor names'
    )
    for (const r of rows) {
        if (r.user_id) map.names.set(r.user_id, r.preferred_name || r.legal_name)
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

    // ① 查得到(包括无人事权限的人看【自己】那一行 —— RLS 放行,所以先查表)
    const name = names.names.get(userId)
    if (name) return <span>{name}</span>

    // ④ 看不到人事 —— 这是一句【权限答复】,不能说成"没有这个人"
    if (names.restricted) return <span className="text-gray-500">{t('common.restricted')}</span>

    // ② 有账号、没档案 —— 具名状态 + 小字 id
    return (
        <span className="text-gray-600">
            {t('actor.noEmployeeRecord')}
            <span className="ml-1 text-xs text-gray-400 font-mono">{userId.slice(0, 8)}…</span>
        </span>
    )
}
