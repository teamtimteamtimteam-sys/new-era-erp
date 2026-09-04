import { getTranslations } from '@/lib/i18n/server'
import ActorName, { type ActorNameMap } from '@/app/components/ActorName'

// app/tools/tasks/[id]/ChangeHistory.tsx
// TASK-1b:【变更记录】。只读,倒序,形状照 MovementTimeline。
//
// 【这个模块里不出现「时间线」这个词】。在本仓库里「时间线」已经是
// MovementTimeline 那件东西 —— 库存流水的过去式流水账。一个词在一个模块里
// 指流水、在另一个模块里指日程轴,这个词就废了。所以:
//   * 过去的那一半叫【变更记录】(本文件);
//   * 将来的那一半是步骤行上的【计划日期】(NodeTree),没有轴、没有条、没有泳道。
//
// 私人任务不显示这一节 —— 一个人不需要一份关于自己的审计(详情页里判断)。

export type HistoryRow = {
    id: string
    change_type: string
    node_id: string | null
    changed_at: string
    // TASK-1c-d:【员工空间】的 actor(employees.id,自 TASK-1a 起就是这一种)
    changed_by: string | null
    old_title: string | null; new_title: string | null
    old_status: string | null; new_status: string | null
    old_priority: string | null; new_priority: string | null
    old_due_date: string | null; new_due_date: string | null
    old_node_title: string | null; new_node_title: string | null
    old_node_target_date: string | null; new_node_target_date: string | null
    old_node_done: boolean | null; new_node_done: boolean | null
    old_sort_order: number | null; new_sort_order: number | null
}

function pair(from: string | null | undefined, to: string | null | undefined) {
    if (from == null && to == null) return null
    return `${from ?? '—'} → ${to ?? '—'}`
}

export default async function ChangeHistory({
    rows, heading, empty, actorNames, actorLabel, unrecordedHint,
}: {
    rows: HistoryRow[]; heading: string; empty: string
    actorNames: ActorNameMap
    actorLabel: string
    /** 那一行【早于本模块开始记人】—— 具名状态的来由,不是一句猜测 */
    unrecordedHint: string
}) {
    const t = await getTranslations()

    const detail = (r: HistoryRow): string => {
        const bits = [
            pair(r.old_title, r.new_title),
            pair(r.old_status, r.new_status),
            pair(r.old_priority, r.new_priority),
            pair(r.old_due_date, r.new_due_date),
            pair(r.old_node_title, r.new_node_title),
            pair(r.old_node_target_date, r.new_node_target_date),
        ].filter(Boolean)
        if (r.old_node_done !== null || r.new_node_done !== null) {
            bits.push(r.new_node_done ? t('tasks.history.ticked') : t('tasks.history.unticked'))
        }
        if (r.old_sort_order !== null && r.new_sort_order !== null) {
            bits.push(pair(String(r.old_sort_order), String(r.new_sort_order)) as string)
        }
        return bits.join(' · ')
    }

    return (
        <section className="mt-8 border-t pt-6">
            <h2 className="mb-3 text-xl font-bold">{heading}</h2>
            {rows.length === 0 ? (
                <p className="text-sm text-gray-500">{empty}</p>
            ) : (
                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('tasks.history.colTime')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('tasks.history.colWhat')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('tasks.history.colDetail')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{actorLabel}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-3 py-1">{r.changed_at.slice(0, 16).replace('T', ' ')}</td>
                                    <td className="border border-gray-300 px-3 py-1">{t('tasks.history.type.' + r.change_type)}</td>
                                    <td className="border border-gray-300 px-3 py-1">{detail(r)}</td>
                                    {/* 【空绝不留空】:没有 changed_by 的那一行是本模块开始记人之前留下的,
                                        它要说出这件事,而不是留一格白 —— 白格会被读成"没有人做过这件事"。
                                        查不到的员工 id 也不留白,印具名状态 + 小字 id(AUDEL-2/3)。 */}
                                    <td className="border border-gray-300 px-3 py-1">
                                        <ActorName
                                            userId={r.changed_by}
                                            names={actorNames}
                                            space="employee"
                                            unrecordedHint={unrecordedHint}
                                        />
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </section>
    )
}
