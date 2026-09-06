'use client'

// app/finance/fx/FxRatesTable.tsx
// CONV-4 · 汇率牌价表 —— 排序留在服务端(这一页在 BASE-1 的 8 张已有排序名单里,
// Tim 的 Q7=A:行为一个字不变,DataTable 的 server 模式只换外观)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import type { FxSortCol } from './fxQuery'
import { Button } from '@/app/components/ui/button'

export type FxRateRow = {
    id: string
    currency: string
    rateType: string
    rateSgdPerUnit: number
    rateDate: string
    source: string
    notes: string | null
}

export default function FxRatesTable({
    rows, sort, dir, currency, shown, total,
}: {
    rows: FxRateRow[]
    sort: FxSortCol
    dir: 'asc' | 'desc'
    /** 排序链接要保留的筛选参数(不含 sort/dir/page)。 */
    currency: string
    shown: number
    total: number
}) {
    const t = useTranslations()

    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams()
        if (currency) params.set('currency', currency)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/finance/fx?${params.toString()}`
    }

    // ★ 手机上留【币种】与【牌价】—— 币种是身份,牌价是这张表存在的理由。
    const columns: Column<FxRateRow>[] = [
        {
            key: 'currency', header: t('finance.fxPage.colCurrency'), priority: true, sortable: true,
            className: 'font-mono text-sm', render: (r) => r.currency,
        },
        {
            key: 'rate_type', header: t('finance.fxPage.colType'), sortable: true, align: 'right',
            className: 'font-mono text-sm', render: (r) => t('finance.fxPage.rateType.' + r.rateType),
        },
        {
            key: 'rate_sgd_per_unit', header: t('finance.fxPage.colRate'), priority: true, sortable: true, align: 'right',
            className: 'font-mono', render: (r) => r.rateSgdPerUnit,
        },
        { key: 'rate_date', header: t('finance.fxPage.colRateDate'), sortable: true, render: (r) => r.rateDate },
        { key: 'source', header: t('finance.fxPage.colSource'), className: 'text-sm text-gray-600', render: (r) => r.source },
        { key: 'notes', header: t('finance.fxPage.colNotes'), className: 'text-sm', render: (r) => r.notes ?? '—' },
        {
            key: 'actions', header: t('finance.fxPage.colActions'),
            render: (r) => (
                <Button asChild variant="link" size="inline">
                    <Link href={`/finance/fx/${r.id}/edit`}>
                        {t('finance.fxPage.editAction')}
                    </Link>
                </Button>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('finance.fxPage.emptyState')}
            sorting={{
                mode: 'server',
                coverage: { shown, total },
                active: { key: sort, dir },
                href,
            }}
        />
    )
}
