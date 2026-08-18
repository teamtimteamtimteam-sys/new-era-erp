// app/tasks/[id]/page.tsx
// TASK-1b:任务详情。步骤树、参与者、变更记录 —— 三样都只在这里,不在弹窗里。
//
// 【为什么是详情页而不是把弹窗做大】弹窗装不下一棵树 + 一份名单 + 一条记录,
// 而看板的拖拽是这个模块最好用的手势,不该被挤走。弹窗保留【表头】的快速编辑。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows, mustOne } from '@/lib/db-helpers'
import NodeTree, { type NodeRow } from './NodeTree'
import Participants, { type ParticipantRow, type AssignableRow } from './Participants'
import ChangeHistory, { type HistoryRow } from './ChangeHistory'

export default async function TaskDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.tasks)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const taskRes = await supabase
        .from('tasks')
        .select('id, code, title, description, status, priority, task_type, due_date, reminder_at, tags')
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    if (taskRes.error) throw new Error(taskRes.error.message)
    if (!taskRes.data) notFound()
    const task = taskRes.data

    // 【mustRows,不是 ?? []】读不到必须报错。Q11 定下"零步骤什么都不显示",
    // 所以一次失败的查询与一张没有步骤的任务在屏幕上会一模一样 —— 那正是
    // 吞错误最难被发现的地方。
    const nodes = mustRows<NodeRow>(
        await supabase
            .from('task_nodes')
            .select('id, parent_id, depth, title, target_date, done, sort_order, created_at')
            .eq('task_id', id)
            .order('sort_order', { ascending: true })
            .order('created_at', { ascending: true })
    )

    const isTeam = task.task_type === 'team'

    const participants = isTeam
        ? mustRows<ParticipantRow>(
              await supabase
                  .from('task_participant_directory')
                  .select('participant_id, employee_id, display_name, added_at, added_by_name, removed_at, left_voluntarily')
                  .eq('task_id', id)
                  .order('added_at', { ascending: true })
          )
        : []

    const assignable = isTeam
        ? mustRows<AssignableRow>(
              await supabase
                  .from('task_assignable_employees')
                  .select('employee_id, display_name, code')
                  .order('display_name', { ascending: true })
          )
        : []

    // 【私人任务不显示变更记录,而这是有意的不对称】一个人不需要一份关于自己的审计。
    // 若哪天这在屏幕上读起来不对,要重议的是"私人任务不留痕"这个决定本身,
    // 不是这里的显示方式。
    const history = isTeam
        ? mustRows<HistoryRow>(
              await supabase
                  .from('task_history')
                  .select('id, change_type, node_id, changed_at, old_title, new_title, old_status, new_status, old_priority, new_priority, old_due_date, new_due_date, old_node_title, new_node_title, old_node_target_date, new_node_target_date, old_node_done, new_node_done, old_sort_order, new_sort_order')
                  .eq('task_id', id)
                  .order('changed_at', { ascending: false })
          )
        : []

    const me = await supabase.rpc('current_user_employee')
    const myEmployeeId = (me.data as string | null) ?? null
    const iAmParticipant = participants.some((p) => !!myEmployeeId && p.employee_id === myEmployeeId && !p.removed_at)

    // 【选错类型的那扇门只在它开着的时候出现】——「有别人来过」之后就关上了,
    // 而关上之后类型是一段文字,不是一个下拉框:不提供做不到的手势。
    const everyoneEver = participants.filter((p) => p.employee_id !== myEmployeeId)
    const correctable = isTeam && participants.length <= 1 && everyoneEver.length === 0

    return (
        <div className="p-8">
            <div className="mb-2 text-sm">
                <Link href="/tasks" className="text-blue-700 hover:underline">
                    ← {t('tasks.pageTitle')}
                </Link>
            </div>
            <h1 className="mb-1 text-2xl font-bold">{task.title}</h1>
            <p className="mb-6 text-sm text-gray-500">
                {task.code} · {t('tasks.type.' + task.task_type)} · {t('tasks.status.' + task.status)} ·{' '}
                {t('tasks.priority.' + task.priority)}
                {task.due_date ? ` · ${t('tasks.form.dueDate')} ${task.due_date}` : ''}
            </p>

            {task.description ? <p className="mb-6 whitespace-pre-wrap text-sm">{task.description}</p> : null}

            <NodeTree
                taskId={task.id}
                nodes={nodes}
                labels={{
                    heading: t('tasks.nodes.heading'),
                    empty: t('tasks.nodes.empty'),
                    add: t('tasks.nodes.add'),
                    addSub: t('tasks.nodes.addSub'),
                    titlePlaceholder: t('tasks.nodes.titlePlaceholder'),
                    targetDate: t('tasks.nodes.targetDate'),
                    overdue: t('tasks.nodes.overdue'),
                    remove: t('tasks.nodes.remove'),
                    up: t('tasks.nodes.up'),
                    down: t('tasks.nodes.down'),
                    save: t('common.save'),
                    cancel: t('common.cancel'),
                    rename: t('tasks.nodes.rename'),
                }}
            />

            {isTeam ? (
                <Participants
                    taskId={task.id}
                    rows={participants}
                    assignable={assignable}
                    canEdit={iAmParticipant}
                    myEmployeeId={myEmployeeId}
                    correctable={correctable}
                    labels={{
                        heading: t('tasks.participants.heading'),
                        empty: t('tasks.participants.empty'),
                        add: t('tasks.participants.add'),
                        pick: t('tasks.participants.pick'),
                        left: t('tasks.participants.left'),
                        removed: t('tasks.participants.removed'),
                        removeOther: t('tasks.participants.removeOther'),
                        leave: t('tasks.participants.leave'),
                        addedBy: t('tasks.participants.addedBy'),
                        stillReads: t('tasks.participants.stillReads'),
                        correctType: t('tasks.participants.correctType'),
                        typeLocked: t('tasks.participants.typeLocked'),
                    }}
                />
            ) : (
                <PromotePanel taskId={task.id} />
            )}

            {isTeam ? (
                <ChangeHistory
                    rows={history}
                    heading={t('tasks.history.heading')}
                    empty={t('tasks.history.empty')}
                />
            ) : null}
        </div>
    )
}

// 私人任务:升级是一条【单向】的路,所以这里只有一个按钮,没有"改回私人"。
async function PromotePanel({ taskId }: { taskId: string }) {
    const t = await getTranslations()
    const Client = (await import('./Participants')).PromoteButton
    return (
        <section className="mt-8 border-t pt-6">
            <h2 className="mb-2 text-xl font-bold">{t('tasks.participants.heading')}</h2>
            <p className="mb-3 text-sm text-gray-600">{t('tasks.participants.personalHint')}</p>
            <Client taskId={taskId} label={t('tasks.participants.promote')} />
        </section>
    )
}
