'use client'

// app/output/OutputTable.tsx
// CONV-5 · 产出批次那张表。
// ★ Q7:排序仍是服务端的(sorting.mode='server')。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteButton from './DeleteButton'
import { Button } from '@/app/components/ui/button'

export type OutputTableRow = {
    id: string
    code: string
    materialName: string
    customerName: string
    quantity: string
    remaining: string
    outputDate: string
    stateLabel: string
    /**
     * PROC-WIRE-1A:被指定为下游工序投料的批次【不是可售库存】。
     * 它与销售状态是两条轴,所以是【另一个】角标,不是同一个角标的第四种颜色 ——
     * 一批货可以既"库存中"又"已许给产线"。null = 没有这条轴上的标记。
     */
    purposeTag: string | null
    status: string
    createdLabel: string
}

export default function OutputTable({
    rows, empty, sort, dir, filterQuery, shown, total,
}: {
    rows: OutputTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    filterQuery: Record<string, string>
    shown: number
    total: number
}) {
    const t = useTranslations()

    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/output?${params.toString()}`
    }

    // ★ 手机上留【批次号】与【可用余量】—— 批次号是身份,而余量是这张登记簿
    //   被打开的理由(还能卖/还能投多少)。总量是余量的来源,进展开区。
    const columns: Column<OutputTableRow>[] = [
        {
            key: 'code', header: t('output.colCode'), priority: true, sortable: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/output/${r.id}/edit`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'material', header: t('output.colMaterial'), render: (r) => r.materialName },
        { key: 'customer', header: t('output.colCustomer'), render: (r) => r.customerName },
        { key: 'quantity', header: t('output.colQuantity'), sortable: true, render: (r) => r.quantity },
        { key: 'remaining_qty', header: t('output.colRemaining'), priority: true, sortable: true, render: (r) => r.remaining },
        { key: 'output_date', header: t('output.colOutputDate'), sortable: true, render: (r) => r.outputDate },
        {
            key: 'state', header: t('output.colState'),
            render: (r) => (
                <>
                    <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.stateLabel}</span>
                    {r.purposeTag && (
                        <span className="ml-1 px-2 py-1 bg-amber-100 text-amber-800 border border-amber-300 rounded text-xs">
                            {r.purposeTag}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'status', header: t('output.colStatus'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.status}</span>,
        },
        {
            key: 'created_at', header: t('output.colCreated'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
        },
        { key: 'actions', header: t('output.colActions'), render: (r) => <DeleteButton id={r.id} code={r.code} /> },
        {
            key: 'label', header: t('batchLabel.col'),
            render: (r) => (
                <Button asChild variant="link" size="inline">
                    <a href={`/output/${r.id}/label`} target="_blank" rel="noopener noreferrer">
                        {t('batchLabel.col')}
                    </a>
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
            empty={empty}
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
        />
    )
}
