'use client'

// app/stocktakes/[id]/review/ReviewDiffTable.tsx
// CONV-5 · 盘点复核的差异表。
// 【差异的正负要看得出来】盘盈绿、盘亏红 —— 那是过账前唯一要当场判断的事。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ReviewDiffRow = {
    key: string
    side: string
    batchId: string
    code: string
    material: string
    current: string
    counted: string
    deltaLabel: string
    deltaPositive: boolean
}

export default function ReviewDiffTable({ rows }: { rows: ReviewDiffRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【批次】与【差异】—— 批次是身份,而差异【就是】这张表存在的
    //   理由:它只列有差异的行,账面量与实盘量是推导出差异的两个中间量。
    const columns: Column<ReviewDiffRow>[] = [
        {
            key: 'batch', header: t('stocktakes.colBatch'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/${r.side}/${r.batchId}/edit`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'material', header: t('stocktakes.colMaterial'), render: (r) => r.material },
        { key: 'current', header: t('stocktakes.currentLabel'), render: (r) => r.current },
        { key: 'counted', header: t('stocktakes.countedLabel'), render: (r) => r.counted },
        {
            key: 'delta', header: t('stocktakes.deltaLabel'), priority: true,
            render: (r) => (
                <span className={'font-medium ' + (r.deltaPositive ? 'text-green-600' : 'text-red-600')}>
                    {r.deltaLabel}
                </span>
            ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} />
}
