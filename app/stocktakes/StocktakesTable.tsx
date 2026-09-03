'use client'

// app/stocktakes/StocktakesTable.tsx
// CONV-5 · 盘点单登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type StocktakeRow = {
    id: string
    code: string
    statusLabel: string
    startedLabel: string
    /** null = 还没过账。 */
    postedLabel: string | null
    notes: string
}

export default function StocktakesTable({ rows, empty }: { rows: StocktakeRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【盘点单号】与【状态】—— 单号是身份,状态回答"这一次盘完了没有、
    //   过账了没有",那是打开这份清单要问的那一件事。
    const columns: Column<StocktakeRow>[] = [
        {
            key: 'code', header: t('stocktakes.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/stocktakes/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', header: t('stocktakes.colStatus'), priority: true,
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        { key: 'started', header: t('stocktakes.colStarted'), render: (r) => r.startedLabel },
        { key: 'posted', header: t('stocktakes.colPosted'), render: (r) => r.postedLabel ?? '—' },
        { key: 'notes', header: t('stocktakes.colNotes'), render: (r) => r.notes },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
