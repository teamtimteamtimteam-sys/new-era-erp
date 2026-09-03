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
// 【TASK-1c-d:② 分成了两句】。有些列记的是 employees.id 而不是登录账号
// (task_history.changed_by 就是这一种),那时「查不到」的意思是
// 【这份档案不在了】,而不是「这个账号没关联档案」—— 说错那一句会把读者
// 引向完全错误的排查方向。同一个组件、同一份名字表,由 space 参数决定说哪一句;
// **没有第二个取名器** —— 那正是本文件抬头那条理由。
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
import { Refusal } from '@/app/components/ui/refusal'

/** 名字表 + 【这位读者能不能看人事】—— 两件事必须一起传,见抬头 ④。 */
export type ActorNameMap = { names: Map<string, string>; restricted: boolean }

/** 一次把一批 uuid 的姓名查回来 —— 逐行查会是 N 次往返。 */
export async function loadActorNames(
    supabase: SupabaseClient<Database>,
    ids: (string | null | undefined)[],
    /**
     * 【员工空间的 actor】—— TASK-1c-d。有些列记的是 employees.id 而不是登录账号
     * (task_history.changed_by 自 TASK-1a 起就是这一种)。它们查的是同一张表、
     * 同一套兜底、同一份名字表,只是【认的那一列】不同 —— 所以扩这一个参数,
     * 而不是另写一个取名器:这个组件存在的全部理由就是"谁做的"只有一种答法。
     * 不传时行为与从前【一字不差】。
     */
    employeeIds: (string | null | undefined)[] = []
): Promise<ActorNameMap> {
    // 先问权限,再决定查不到时说什么(抬头 ④)。ids 为空时也要问 ——
    // 否则「这一页没有任何 actor」与「你看不到人事」会在别处被读成同一件事。
    const restricted = !(await can('module.hr.view'))
    const unique = [...new Set(ids.filter((x): x is string => !!x))]
    const uniqueEmp = [...new Set(employeeIds.filter((x): x is string => !!x))]
    const map: ActorNameMap = { names: new Map(), restricted }
    if (unique.length === 0 && uniqueEmp.length === 0) return map
    // 【失败必须失败】用 mustRows,不用 `?? []` —— 读不到名字表时每一行都会退化成
    // 「该账号未关联员工档案」,而那是一句【断言】,不是一次读取失败该说的话。
    // 走【基表】而不是 employees_masked:基表的 RLS 额外放行"自己那一行"
    // (employees_masked 整张按 module.hr.view 判),所以一个没有人事权限的人
    // 至少认得出自己做的那件事。称呼名优先 —— 屏幕上要出现的是人怎么被叫。
    if (unique.length > 0) {
        const rows = mustRows(
            await supabase.from('employees').select('user_id, legal_name, preferred_name').in('user_id', unique),
            'employees actor names'
        )
        for (const r of rows) {
            if (r.user_id) map.names.set(r.user_id, r.preferred_name || r.legal_name)
        }
    }
    // 员工空间的那一批:同一张表、同一份兜底,认的是 id 这一列。
    // 两个空间的 uuid 放进同一张表不会撞:它们来自不同的生成域,
    // 而调用方本来就知道自己传的是哪一种(见 ActorName 的 space)。
    if (uniqueEmp.length > 0) {
        const rows = mustRows(
            await supabase.from('employees').select('id, legal_name, preferred_name').in('id', uniqueEmp),
            'employees actor names (employee space)'
        )
        for (const r of rows) {
            if (r.id) map.names.set(r.id, r.preferred_name || r.legal_name)
        }
    }
    return map
}

export default async function ActorName({
    userId,
    names,
    /** 没有记过人时那句话的来由(例如"这条记录早于 AUDEL-1b") */
    unrecordedHint,
    /**
     * 这个 id 是哪一种(TASK-1c-d)。只影响【状态 ②】那句话:
     * 一个查不到的【登录账号】说的是"这个账号没关联员工档案";
     * 一个查不到的【员工 id】说的是"这份档案已经不在了" —— 两句不是一回事,
     * 而说错的那一句会把读者引向完全错误的排查方向。默认 'account',
     * 所以既有调用方一个字都不用改。
     */
    space = 'account',
}: {
    userId: string | null | undefined
    names: ActorNameMap
    unrecordedHint?: string
    space?: 'account' | 'employee'
}) {
    const t = await getTranslations()

    // ③ 根本没记过
    // ★【CONV-0 ①:这一句上了 <Refusal>,而那段小字【留在药丸外面】】★
    //   unrecordedHint 说的是「哪一段历史造成的」—— 它是**附在拒绝上的证据**,
    //   不是拒绝本身。塞进药丸里会得到一枚两种字号的药丸,而且会把一句
    //   【具体的、查得下去的】线索降格成那句通用答复的一部分。
    //   药丸负责"系统说得出口的那一句",小字负责"凭什么"。
    if (!userId) {
        return (
            <>
                <Refusal>{t('actor.unrecorded')}</Refusal>
                {unrecordedHint && (
                    <span className="ml-1 text-xs text-gray-400">({unrecordedHint})</span>
                )}
            </>
        )
    }

    // ① 查得到(包括无人事权限的人看【自己】那一行 —— RLS 放行,所以先查表)
    const name = names.names.get(userId)
    if (name) return <span>{name}</span>

    // ④ 看不到人事 —— 这是一句【权限答复】,不能说成"没有这个人"
    // CONV-0 ①:与 MaskedValue 那一句、与顶栏的「· 受限」从此是【同一种画法】。
    if (names.restricted) return <Refusal>{t('common.restricted')}</Refusal>

    // ② 查不到 —— 具名状态 + 小字 id。【绝不留空,也绝不裸印一串 uuid】(AUDEL-2/3)
    //
    // ★★【CONV-0 ①:这一支【刻意不上 <Refusal>】—— Tim 的裁定,理由要留下】★★
    //   ①③④ 说的都是【你】或【记录】的状态:受限 = 你不能看;未记录 = 没人填过。
    //   ② 说的是【数据】的状态:「该账号未关联员工档案」/「这份档案已经不在了」
    //   —— 那是一句关于库里有什么的**断言**,不是一次权限答复。
    //   把它画成拒绝药丸,等于教读者"数据缺口"和"权限墙"是同一件事,
    //   而这个仓库从 lib/permissions.ts 起、每一刀都在把这两件事分开。
    //   **统一不值这个价。**
    return (
        <span className="text-gray-600">
            {space === 'employee' ? t('actor.employeeGone') : t('actor.noEmployeeRecord')}
            <span className="ml-1 text-xs text-gray-400 font-mono">{userId.slice(0, 8)}…</span>
        </span>
    )
}
