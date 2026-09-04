'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeTaskError } from './taskErrorCodes'
import type { InsertRow } from '@/lib/db-helpers'
import {
    TASK_COLUMNS,
    STATUS_VALUES,
    PRIORITY_VALUES,
    TASK_TYPE_VALUES,
    type TaskInput,
    type SaveResult,
    type DeleteResult,
} from './types'

type Translate = (key: string, params?: Record<string, string | number>) => string

// 校验枚举字段 + 标题非空;返回(已本地化的)错误信息或 null
function validateInput(input: TaskInput, t: Translate): string | null {
    if (!input.title || !input.title.trim()) {
        return t('tasks.errors.titleRequired')
    }
    if (!(STATUS_VALUES as readonly string[]).includes(input.status)) {
        return t('tasks.errors.invalidStatus', { value: input.status })
    }
    if (!(PRIORITY_VALUES as readonly string[]).includes(input.priority)) {
        return t('tasks.errors.invalidPriority', { value: input.priority })
    }
    if (!(TASK_TYPE_VALUES as readonly string[]).includes(input.task_type)) {
        return t('tasks.errors.invalidType', { value: input.task_type })
    }
    return null
}

// 把表单输入归一化成可写入的列(去空白、空串转 null)
function toRow(input: TaskInput) {
    return {
        title: input.title.trim(),
        description: input.description?.trim() || null,
        status: input.status,
        priority: input.priority,
        due_date: input.due_date || null,
        reminder_at: input.reminder_at || null,
        tags: input.tags ?? [],
        task_type: input.task_type,
    }
}

// 看板拖拽改状态(Step 1 已有,保留)
export async function updateTaskStatus(id: string, newStatus: string) {
    const t = await getTranslations()
    if (!(STATUS_VALUES as readonly string[]).includes(newStatus)) {
        return { error: t('tasks.errors.invalidStatus', { value: newStatus }) }
    }

    const supabase = await createClient()
    const { error } = await supabase
        .from('tasks')
        .update({ status: newStatus })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不动

    if (error) return { error: await localizeTaskError(error.message) }

    revalidatePath('/tools/tasks')
    return { success: true }
}

// 新建任务。code / owner_id / created_by / 时间戳 交给 DB 默认值与触发器
export async function createTask(input: TaskInput): Promise<SaveResult> {
    const t = await getTranslations()
    const invalid = validateInput(input, t)
    if (invalid) return { error: invalid }

    const supabase = await createClient()
    const { data, error } = await supabase
        .from('tasks')
        // code 由 BEFORE INSERT 触发器生成,故需 as InsertRow<'tasks'>
        .insert(toRow(input) as InsertRow<'tasks'>)
        .select(TASK_COLUMNS)
        .single()

    if (error) return { error: await localizeTaskError(error.message) }

    revalidatePath('/tools/tasks')
    return { success: true, task: data }
}

// 【updateTask / deleteTask 在 TASK-1c-b 删掉了】——它们的调用者(弹窗的编辑态)
// 退休了,而改任务与软删现在住在 app/tools/tasks/[id]/actions.ts 里。
// 留着它们不是"备用",是把刚拆掉的第二扇门原样放回去:两个写同一个事实的入口,
// 规矩迟早各自演化(1c-a 为账号关联那一处记过同样的账)。
