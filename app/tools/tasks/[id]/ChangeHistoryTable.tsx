'use client'

// app/tools/tasks/[id]/ChangeHistoryTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 变更记录的表体
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【「操作人」那一格是一个【服务端渲染好的元素】过界的 —— CONV-5 §⑩-6 办法 ②】★★
// `<ActorName>` 是一个 **async 服务端组件**:它认识四种状态(查得到的名字 /
// 本模块开始记人之前的那一行 / 查不到的 id / 空),其中两种要画具名的琥珀色状态。
// 把这套判断在客户端重写一遍,正是这个仓库付过三次账的「殖民地」错误。
// 所以 ChangeHistory(服务端)把每一行的 <ActorName/> **渲染成元素**塞进行数据,
// 这个客户端组件只负责把它画出来 —— 过界的是 ReactNode,不是函数、不是判据。
//
// ★【手机上留【什么时候】与【改了什么】】★
// 一份变更记录被打开的问题是「这张任务什么时候被谁改成了现在这样」,
// 而扫读时先要定位的是**时刻**;「改了什么」是同一行里紧跟着的答案。
// 明细(逐字段 旧 → 新)与操作人进展开区 —— 它们是选中某一行之后的第二个问题。
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ChangeHistoryTableRow = {
    id: string
    when: string
    what: string
    detail: string
    /** ★ 服务端渲染好的 <ActorName/> —— 见抬头。 */
    actor: React.ReactNode
}

export default function ChangeHistoryTable({
    rows,
    colTime,
    colWhat,
    colDetail,
    actorLabel,
    empty,
}: {
    rows: readonly ChangeHistoryTableRow[]
    colTime: string
    colWhat: string
    colDetail: string
    actorLabel: string
    empty: string
}) {
    const columns: Column<ChangeHistoryTableRow>[] = [
        {
            key: 'when',
            header: colTime,
            // ★ 身份列 —— 一条变更的主语是它发生的那一刻。
            priority: true,
            className: 'whitespace-nowrap',
            render: (r) => r.when,
        },
        {
            key: 'what',
            header: colWhat,
            // ★ 这份记录存在的理由:改的是哪一件事。
            priority: true,
            render: (r) => r.what,
        },
        { key: 'detail', header: colDetail, render: (r) => r.detail },
        {
            key: 'actor',
            header: actorLabel,
            // 【空绝不留空】:那套判断住在服务端的 <ActorName/> 里,这里只是画它。
            render: (r) => r.actor,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
