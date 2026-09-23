'use client'

// app/tools/tasks/TaskEditGate.tsx
// APR-4(Tim 的 Q8):任务页上每一个写控件的闸 —— 看得见、按不动、说得出原因(DBLOCK-1)。
//
// ★【两种原因,两句话,不合成一句】★
//   · needs_code  —— 缺 module.tasks.edit。这是一个管理员勾得出来的码,所以走
//     PermissionGate 的标准那句;内容类控件(表头 / 状态 / 步骤)还多一条路:
//     「或者这是你自己的私人任务」—— 那条路也不是管理员给的,所以用 alsoAllowedIf 说。
//   · not_on_task —— 他【持】那个码,只是不在这张团队任务上。说"缺 module.tasks.edit"
//     就是指着一项他早就有的权限(DBLOCK-CONFLATED-BOOLEANS)。这里说的是真原因。
// 判据本身不在这里:状态由 lib/taskAccess.ts 从数据库读来(can_write_task / can_edit_task)。
import * as React from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'
import type { TaskEditState } from '@/lib/taskAccess'

const TASKS_EDIT = 'module.tasks.edit'

export function TaskEditGate({
    state,
    ownTaskPath = false,
    children,
    inline = false,
}: {
    state: TaskEditState
    /** 这个控件是否也对"自己的私人任务"开放(内容类:是;升级 / 参与者:否)。 */
    ownTaskPath?: boolean
    children: React.ReactNode
    inline?: boolean
}) {
    const t = useTranslations()
    if (state === 'allowed') return <>{children}</>

    if (state === 'needs_code') {
        return (
            <PermissionGate
                code={TASKS_EDIT}
                allowed={false}
                inline={inline}
                alsoAllowedIf={
                    ownTaskPath
                        ? { label: t('tasks.access.ownTaskAlt'), why: t('tasks.access.ownTaskWhy') }
                        : undefined
                }
            >
                {children}
            </PermissionGate>
        )
    }

    // not_on_task:与 PermissionGate 同一套机制(fieldset disabled,留在无障碍树里),
    // 只是那句话不同 —— 它不指向任何权限码。
    return (
        <span
            data-slot="permission-gate"
            data-task-gate="not-on-task"
            className={inline ? 'inline-flex flex-row items-center gap-1.5' : 'inline-flex flex-col items-start gap-1.5'}
        >
            <fieldset disabled className="contents">
                {children}
            </fieldset>
            <Refusal why={t('tasks.access.notYoursWhy')} className="whitespace-normal text-left font-normal">
                {t('tasks.access.notYours')}
            </Refusal>
        </span>
    )
}
