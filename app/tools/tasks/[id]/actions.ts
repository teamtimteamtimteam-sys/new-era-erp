'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeTaskError } from '../taskErrorCodes'
import { STATUS_VALUES, PRIORITY_VALUES } from '../types'

// app/tools/tasks/[id]/actions.ts
// TASK-1b:步骤 / 参与者 / 类型迁移的服务端动作。
//
// 【每一处失败都走 localizeTaskError】。约束抛的 23503 对操作员是天书,
// 而一层嵌套与跨任务认父【就是】约束在管(见 taskErrorCodes.ts 的文件头)。
// 界面同时【不提供】做不到的手势,两层缺一不可。

type Result = { error: string } | { success: true }

const GAP = 1024 // 稀疏序号的步长,与 rebalance_task_nodes 一致

async function fail(message: string): Promise<Result> {
    return { error: await localizeTaskError(message) }
}

function done(path: string): Result {
    revalidatePath(path)
    return { success: true }
}

// ── 步骤 ────────────────────────────────────────────────────────────────────

export async function addNode(
    taskId: string,
    title: string,
    targetDate: string | null,
    parentId: string | null
): Promise<Result> {
    const t = await getTranslations()
    if (!title.trim()) return { error: t('tasks.errors.titleRequired') }

    const supabase = await createClient()
    // 追加在同级末尾。并列是允许的(sort_order 没有唯一约束),所以这里
    // 不必处理竞态 —— 两个人同时追加最坏是并列,显示按 created_at 断开。
    const q = supabase.from('task_nodes').select('sort_order').eq('task_id', taskId)
    const { data: sibs, error: readErr } = await (parentId === null
        ? q.is('parent_id', null)
        : q.eq('parent_id', parentId)
    ).order('sort_order', { ascending: false }).limit(1)
    if (readErr) return fail(readErr.message)

    const next = (sibs && sibs.length > 0 ? sibs[0].sort_order : 0) + GAP
    const { error } = await supabase.from('task_nodes').insert({
        task_id: taskId,
        parent_id: parentId,
        depth: parentId ? 1 : 0,
        title: title.trim(),
        target_date: targetDate || null,
        sort_order: next,
    } as never)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

export async function renameNode(taskId: string, nodeId: string, title: string): Promise<Result> {
    const t = await getTranslations()
    if (!title.trim()) return { error: t('tasks.errors.titleRequired') }
    const supabase = await createClient()
    const { error } = await supabase.from('task_nodes').update({ title: title.trim() }).eq('id', nodeId)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

export async function setNodeDate(taskId: string, nodeId: string, date: string | null): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('task_nodes').update({ target_date: date || null }).eq('id', nodeId)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

export async function setNodeDone(taskId: string, nodeId: string, isDone: boolean): Promise<Result> {
    const supabase = await createClient()
    // done_at / done_by 由 trg_task_nodes_touch 写 —— 一个事实一处陈述
    const { error } = await supabase.from('task_nodes').update({ done: isDone }).eq('id', nodeId)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

export async function removeNode(taskId: string, nodeId: string): Promise<Result> {
    const supabase = await createClient()
    // 有子步骤时按名拒绝(TASK_NODE_HAS_CHILDREN)—— 绝不 CASCADE
    const { error } = await supabase.from('task_nodes').delete().eq('id', nodeId)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

// 上/下移一格。【一次移动只写一行】—— 这是稀疏序号的全部用意,
// 也是变更记录里那一条能陈述【一个动作】而不是一串副作用的原因。
export async function moveNode(taskId: string, nodeId: string, dir: 'up' | 'down'): Promise<Result> {
    const supabase = await createClient()
    const { data: node, error: nErr } = await supabase
        .from('task_nodes').select('id, parent_id, sort_order, created_at').eq('id', nodeId).single()
    if (nErr) return fail(nErr.message)

    // 只在同一父级内移动;显示序与这里的排序一致(sort_order,再 created_at,再 id)
    const { data: full, error: fErr } = await supabase
        .from('task_nodes').select('id, parent_id, sort_order, created_at').eq('task_id', taskId)
    if (fErr) return fail(fErr.message)
    const siblings = (full ?? [])
        .filter((s) => s.parent_id === node.parent_id)
        .sort(
            (a, b) =>
                a.sort_order - b.sort_order ||
                String(a.created_at).localeCompare(String(b.created_at)) ||
                a.id.localeCompare(b.id)
        )

    const idx = siblings.findIndex((s) => s.id === nodeId)
    const target = dir === 'up' ? idx - 1 : idx + 1
    if (idx < 0 || target < 0 || target >= siblings.length) return { success: true } // 已在端点:什么都不做

    const neighbour = siblings[target]
    const beyond = dir === 'up' ? siblings[target - 1] : siblings[target + 1]
    let newOrder: number
    if (!beyond) {
        newOrder = dir === 'up' ? neighbour.sort_order - GAP : neighbour.sort_order + GAP
    } else {
        newOrder = Math.round((neighbour.sort_order + beyond.sort_order) / 2)
        if (newOrder === neighbour.sort_order || newOrder === beyond.sort_order) {
            // 间隙用光了:整段重排(它【一行历史都不写】,见函数注释),然后重来
            const { error: rErr } = await supabase.rpc('rebalance_task_nodes', {
                p_task_id: taskId,
                p_parent_id: node.parent_id,
            } as never)
            if (rErr) return fail(rErr.message)
            return moveNode(taskId, nodeId, dir)
        }
    }

    const { error } = await supabase.from('task_nodes').update({ sort_order: newOrder }).eq('id', nodeId)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

// ── 参与者 ──────────────────────────────────────────────────────────────────

export async function addParticipant(taskId: string, employeeId: string): Promise<Result> {
    const supabase = await createClient()
    const { data: me, error: meErr } = await supabase.rpc('current_user_employee')
    if (meErr) return fail(meErr.message)
    const { error } = await supabase
        .from('task_participants')
        .insert({ task_id: taskId, employee_id: employeeId, added_by: me } as never)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

// 移出别人 / 自己退出。【两者写的是不同的 change_type】,由触发器按
// removed_by 是不是本人来分 —— "她是自己退出的还是被拿掉的"正是记录该回答的问题。
export async function removeParticipant(taskId: string, participantId: string): Promise<Result> {
    const supabase = await createClient()
    const { data: me, error: meErr } = await supabase.rpc('current_user_employee')
    if (meErr) return fail(meErr.message)
    const { error } = await supabase
        .from('task_participants')
        .update({ removed_at: new Date().toISOString(), removed_by: me })
        .eq('id', participantId)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

// ── 类型迁移 ────────────────────────────────────────────────────────────────

export async function promoteToTeam(taskId: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('promote_task_to_team', { p_task_id: taskId } as never)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

export async function correctType(taskId: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_task_type', { p_task_id: taskId } as never)
    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

// ── 表头 ────────────────────────────────────────────────────────────────────
// TASK-1c-b:弹窗退休成【只建不改】之后,表头七个字段搬到详情页来。
//
// 【这里【故意】不收 task_type】。类型迁移只剩两扇具名的门
// (promote_task_to_team / correct_task_type),而它们在参与者面板上。
// 表头再收一次 task_type,就等于把刚刚拆掉的第二扇门又装回来 ——
// 而两扇门规矩不一致正是 1c-a 记进 known-issues 的那一类毛病。
export type HeaderInput = {
    title: string
    description: string | null
    status: string
    priority: string
    due_date: string | null
    reminder_at: string | null
    tags: string[]
}

export async function updateTaskHeader(taskId: string, input: HeaderInput): Promise<Result> {
    const t = await getTranslations()
    if (!input.title.trim()) return { error: t('tasks.errors.titleRequired') }
    if (!(STATUS_VALUES as readonly string[]).includes(input.status)) {
        return { error: t('tasks.errors.invalidStatus', { value: input.status }) }
    }
    if (!(PRIORITY_VALUES as readonly string[]).includes(input.priority)) {
        return { error: t('tasks.errors.invalidPriority', { value: input.priority }) }
    }

    const supabase = await createClient()
    const { error } = await supabase
        .from('tasks')
        .update({
            title: input.title.trim(),
            description: input.description?.trim() || null,
            status: input.status,
            priority: input.priority,
            due_date: input.due_date || null,
            reminder_at: input.reminder_at || null,
            tags: input.tags ?? [],
        })
        .eq('id', taskId)
        .is('deleted_at', null)

    if (error) return fail(error.message)
    return done(`/tools/tasks/${taskId}`)
}

// 软删。硬删由 trg_tasks_no_hard_delete 按名拒绝,这里走的是支持的那条路。
export async function softDeleteTask(taskId: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('tasks')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', taskId)
        .is('deleted_at', null)

    if (error) return fail(error.message)
    revalidatePath('/tools/tasks')
    return { success: true }
}
