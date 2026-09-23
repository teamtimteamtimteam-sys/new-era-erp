// lib/taskAccess.ts
// APR-4(Tim 的 Q8):屏幕上"能不能改这张任务"的【唯一】入口。
//
// ★【它不自己判】★ 判据只有一份,在数据库:
//   · may_write  = can_write_task(id)  —— 内容:表头 / 状态 / 步骤 / 软删,含"自己的私人任务"例外;
//   · may_manage = can_edit_task(id)   —— 升级为团队任务 / 参与者,只有完整编辑人。
// 两列都由 task_board_rows 吐出来,守卫(trg_tasks_guard_write 等)与写策略调的是同一对函数。
// 在这里再用权限码拼一遍"是不是归属人 / 在不在任务上",就是同一条规则的第二份实现 ——
// 本仓库为"两份实现写下那天一致、之后悄悄分开"付过的账,见 AGENTS.md 的预览规则。
//
// ★【为什么还要知道持不持 module.tasks.edit】★ 只为了说对【原因】:
//   被挡住的人若不持那个码,该说"缺 module.tasks.edit(或者这是你自己的私人任务)";
//   若他持码,原因是"你不在这张任务上" —— 那不是管理员给得了的东西,
//   说成缺码就是 DBLOCK-CONFLATED-BOOLEANS 点名的"说错原因比不说原因更坏"。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

export const TASKS_EDIT = 'module.tasks.edit'

/** allowed:按得动;needs_code:缺 module.tasks.edit;not_on_task:持码,但不在这张任务上 / 不是归属人。 */
export type TaskEditState = 'allowed' | 'needs_code' | 'not_on_task'

export type TaskAccess = { write: TaskEditState; manage: TaskEditState }

function stateOf(allowed: boolean | null, holdsEditCode: boolean): TaskEditState {
    if (allowed === true) return 'allowed'
    return holdsEditCode ? 'not_on_task' : 'needs_code'
}

/** 一批任务的访问状态,按 id。读不到的 id 不在结果里 —— 调用方拿不到就当 needs_code/not_on_task 处理。 */
export async function loadTaskAccess(
    supabase: SupabaseClient<Database>,
    ids: string[],
    holdsEditCode: boolean
): Promise<Map<string, TaskAccess>> {
    const out = new Map<string, TaskAccess>()
    if (ids.length === 0) return out
    const rows = mustRows(
        await supabase.from('task_board_rows').select('id, may_write, may_manage').in('id', ids),
        'task_board_rows (may_write / may_manage)'
    )
    for (const r of rows) {
        if (!r.id) continue
        out.set(r.id, {
            write: stateOf(r.may_write, holdsEditCode),
            manage: stateOf(r.may_manage, holdsEditCode),
        })
    }
    return out
}

export const NO_ACCESS = (holdsEditCode: boolean): TaskAccess => ({
    write: stateOf(false, holdsEditCode),
    manage: stateOf(false, holdsEditCode),
})
