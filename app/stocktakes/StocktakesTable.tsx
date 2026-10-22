'use client'

// app/stocktakes/StocktakesTable.tsx
// CONV-5 · 盘点单登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'

export type StocktakeRow = {
    id: string
    code: string
    statusLabel: string
    startedLabel: string
    /** null = 还没过账。 */
    postedLabel: string | null
    notes: string
    /** TABLE-EXPORT-1:导出用的原始时刻(Excel 里是真日期,按新加坡时间;posted null = 还没过账)。 */
    startedAt: string
    postedAt: string | null
}

export default function StocktakesTable({ rows, empty, exportHref }: {
    rows: StocktakeRow[]
    empty: React.ReactNode
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(这一页分页,表手里只有一页)。 */
    exportHref: string
}) {
    const t = useTranslations()

    // ★ 手机上留【盘点单号】与【状态】—— 单号是身份,状态回答"这一次盘完了没有、
    //   过账了没有",那是打开这份清单要问的那一件事。
    const columns: ExportableColumn<StocktakeRow>[] = [
        {
            key: 'code', header: t('stocktakes.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/stocktakes/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', header: t('stocktakes.colStatus'), priority: true,
            exportAs: (r) => xText(r.statusLabel),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        { key: 'started', header: t('stocktakes.colStarted'), render: (r) => r.startedLabel, exportAs: (r) => xTime(r.startedAt) },
        { key: 'posted', header: t('stocktakes.colPosted'), render: (r) => r.postedLabel ?? '—', exportAs: (r) => xTime(r.postedAt) },
        { key: 'notes', header: t('stocktakes.colNotes'), render: (r) => r.notes, exportAs: (r) => xText(r.notes) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'stocktakes', title: t('stocktakes.listTitle'), serverRows: exportHref }}
        />
    )
}
