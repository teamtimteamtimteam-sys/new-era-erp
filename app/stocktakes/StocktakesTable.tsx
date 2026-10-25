'use client'

// app/stocktakes/StocktakesTable.tsx
// CONV-5 · 盘点单登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

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

export default function StocktakesTable({ rows, empty, exportHref, sort, shown, total }: {
    rows: StocktakeRow[]
    empty: React.ReactNode
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(这一页分页,表手里只有一页)。 */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(stocktakeRows.ts 的 STOCKTAKE_SORT) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【盘点单号】与【状态】—— 单号是身份,状态回答"这一次盘完了没有、
    //   过账了没有",那是打开这份清单要问的那一件事。
    const columns: ExportableColumn<StocktakeRow>[] = [
        {
            key: 'code', sortable: true, header: t('stocktakes.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/stocktakes/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', sortable: true, header: t('stocktakes.colStatus'), priority: true,
            exportAs: (r) => xText(r.statusLabel),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        { key: 'started', sortable: true, header: t('stocktakes.colStarted'), render: (r) => r.startedLabel, exportAs: (r) => xTime(r.startedAt) },
        { key: 'posted', sortable: true, header: t('stocktakes.colPosted'), render: (r) => r.postedLabel ?? '—', exportAs: (r) => xTime(r.postedAt) },
        { key: 'notes', sortable: true, header: t('stocktakes.colNotes'), render: (r) => r.notes, exportAs: (r) => xText(r.notes) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'stocktakes', title: t('stocktakes.listTitle'), serverRows: exportHref }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
        />
    )
}
