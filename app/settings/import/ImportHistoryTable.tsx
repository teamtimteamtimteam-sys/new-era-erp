'use client'

// app/settings/import/ImportHistoryTable.tsx
// CONV-5 · 导入历史那张表。它是一份【日志】(页脚那句 historyIsALog 说的就是
// 这件事),所以行序就是导入序,这里不接管排序。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ImportBatchRow = {
    id: string
    whenLabel: string
    tableLabel: string
    fileName: string
    rowCount: number
    codeRange: string
}

export default function ImportHistoryTable({ rows, empty }: { rows: ImportBatchRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【什么时候】与【哪张表】—— 时间是这份日志里一行的身份,
    //   而"导进了哪张表"是回头查它时唯一要先确定的事。文件名与编号区间进展开区。
    const columns: Column<ImportBatchRow>[] = [
        { key: 'when', header: t('import.col.when'), priority: true, render: (r) => r.whenLabel },
        { key: 'table', header: t('import.col.table'), priority: true, render: (r) => r.tableLabel },
        { key: 'file', header: t('import.col.file'), render: (r) => r.fileName },
        { key: 'rows', header: t('import.col.rows'), align: 'right', render: (r) => r.rowCount },
        { key: 'codeRange', header: t('import.col.codeRange'), className: 'font-mono text-xs', render: (r) => r.codeRange },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
