'use client'

// app/settings/change-history/ChangeHistoryTable.tsx
// HISTORY-1 · 变更记录那张表。
// 「谁」与「字段」两格是【服务端渲染好的元素】(与 DeletedTable 同一个做法):
//   受限 / 留白 / 原样那三种状态的判断只有一处(fieldValue.tsx),客户端只负责摆位置。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ChangeRow = {
    key: string
    whenLabel: string
    whoCell: React.ReactNode
    table: string
    record: string
    opLabel: string
    fieldsCell: React.ReactNode
}

export default function ChangeHistoryTable({ rows, empty }: { rows: ChangeRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【改动】与【字段】—— 这一页存在的理由就是"改之前是什么"。
    const columns: Column<ChangeRow>[] = [
        { key: 'when', header: t('changeHistory.colTime'), className: 'whitespace-nowrap', render: (r) => r.whenLabel },
        { key: 'who', header: t('changeHistory.colActor'), render: (r) => r.whoCell },
        { key: 'table', header: t('changeHistory.colTable'), className: 'font-mono', render: (r) => r.table },
        { key: 'record', header: t('changeHistory.colRecord'), className: 'font-mono break-all', render: (r) => r.record },
        { key: 'op', header: t('changeHistory.colOperation'), priority: true, render: (r) => r.opLabel },
        { key: 'fields', header: t('changeHistory.colFields'), priority: true, render: (r) => r.fieldsCell },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty} />
}
