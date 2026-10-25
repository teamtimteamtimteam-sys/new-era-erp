'use client'

// app/settings/import/ImportHistoryTable.tsx
// CONV-5 · 导入历史那张表。它是一份【日志】(页脚那句 historyIsALog 说的就是
// 这件事),所以行序就是导入序,这里不接管排序。
// TABLE-FEATURES-1(Tim 2026-10-25 Q9):默认仍是导入序;表头可以在数据库里换顺序(importRows.ts 的 IMPORT_SORT)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xInt, xTime, xRestricted } from '@/lib/export/cells'
import { Refusal } from '@/app/components/ui/refusal'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

export type ImportBatchRow = {
    id: string
    whenLabel: string
    tableLabel: string
    fileName: string
    rowCount: number
    codeRange: string
    /** AUDIT-TRAIL-1d-1(Q24):谁导入的 —— 按 ActorName 的规矩已经解析好的名字;null = 没记人或认不出 */
    whoName: string | null
    /** 记了人、而这个读者认不出(不持 module.hr.view)—— 画「受限」,不画「—」。
     *  TABLE-EXPORT-2b-1:是数据而不是一段 JSX —— 行要穿过导出的 JSON 路由。 */
    whoRestricted: boolean
    /** TABLE-EXPORT-2b-1:导入时刻的原始 ISO */
    importedAt: string
}

export default function ImportHistoryTable({ rows, empty, serverRows, sort, total }: {
    rows: ImportBatchRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-2b-1:页面只画最近 20 次 —— 导出走这条路由取全 */
    serverRows?: string
    /** TABLE-FEATURES-1 Q9:在数据库里排;total = 全部次数(只画最近 IMPORTS_SHOWN 次) */
    sort: ListSort; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【什么时候】与【哪张表】—— 时间是这份日志里一行的身份,
    //   而"导进了哪张表"是回头查它时唯一要先确定的事。文件名与编号区间进展开区。
    const columns: ExportableColumn<ImportBatchRow>[] = [
        { key: 'when', sortable: true, header: t('import.col.when'), priority: true, render: (r) => r.whenLabel, exportAs: (r) => xTime(r.importedAt) },
        { key: 'table', sortable: true, header: t('import.col.table'), priority: true, render: (r) => r.tableLabel, exportAs: (r) => xText(r.tableLabel) },
        { key: 'who', header: t('import.col.who'),
          render: (r) => r.whoName ?? (r.whoRestricted ? <Refusal>{t('common.restricted')}</Refusal> : '—'),
          exportAs: (r) => (r.whoName !== null ? xText(r.whoName) : r.whoRestricted ? xRestricted : xText(null)) },
        { key: 'file', sortable: true, header: t('import.col.file'), render: (r) => r.fileName, exportAs: (r) => xText(r.fileName) },
        { key: 'rows', sortable: true, header: t('import.col.rows'), align: 'right', render: (r) => r.rowCount, exportAs: (r) => xInt(r.rowCount) },
        { key: 'codeRange', header: t('import.col.codeRange'), className: 'text-xs', render: (r) => r.codeRange, exportAs: (r) => xText(r.codeRange) },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'import-history', title: t('import.history'), serverRows }}
        sorting={{ mode: 'server', coverage: { shown: rows.length, total }, active: sort, href: sortHref }} />
}
