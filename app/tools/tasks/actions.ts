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
import { refuseFromCoded, refuseNothingChanged, type ActionOutcome } from '@/lib/action-refusal'

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
export async function updateTaskStatus(id: string, newStatus: string): Promise<ActionOutcome> {
    // ★★【ALERT-1:invalidStatus 在这条路上是【丁类】—— 界面产生不出它】★★
    //   看板的那三列【就是】STATUS_VALUES 渲染出来的(TaskBoard.tsx:333),
    //   所以一次拖放只可能落在合法值上。把「无效的状态:xxx」写给人看,是在
    //   报告一个界面已经拦住了的状态 —— Tim 在 ALERT-1 闸上裁定它该走。
    //
    //   ★【走的是那句【话】,不是那道【闸】】★ 这里是服务端动作,也就是信任边界:
    //     绕开界面直接调它的人照样要被挡住。所以判据留着,只是不再假装自己是
    //     一句【给人看的拒绝】—— 走到这里就是调用方坏了,那是缺陷,不是拒绝。
    //   ☞ 同一个消息键在 :25(新建/编辑那条表单路)【仍然是给人看的】,
    //     那一条本刀没有动:一张表单确实可能带着过期或被改过的值回来。
    if (!(STATUS_VALUES as readonly string[]).includes(newStatus)) {
        throw new Error(`updateTaskStatus: 不在 STATUS_VALUES 里的状态 ${newStatus}`)
    }

    const supabase = await createClient()
    const { data, error } = await supabase
        .from('tasks')
        .update({ status: newStatus })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不动
        // ★ ALERT-1:见 app/materials/actions.ts 的注释。tasks 这一处的策略是
        //   `USING (can_edit_task(id)) WITH CHECK (can_edit_task(id))` —— 行级判据,
        //   所以【看得见但改不动】是常态(实测:一个真账号有 module.tasks.edit,
        //   却对某一张任务 rows=0 raised=NONE)。
        .select('id')

    if (error) return await refuseFromCoded(error.message, localizeTaskError)

    // ★ 零行落地 = 状态没有变。**这一处后果最重**:看板已经把卡片挪过去了,
    //   而报告成功会让它【留在数据库拒绝的那一列里】—— 屏幕主动说了一句假话。
    //   回滚由 TaskBoard 负责(它现在的判据是「没确认落地就回滚」)。
    if (!data || data.length === 0) {
        return await refuseNothingChanged('module.tasks.edit')
    }

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
