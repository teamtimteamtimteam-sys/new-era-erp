'use client'

// app/inventory/reports/ledger/LedgerTable.tsx
// CONV-5 · 流水台账那张表。
// 行已经在服务端用 flatten() 压平,状态键也在服务端翻好 —— statusKey 与
// flatten 都是取数侧的知识,列描述符不该再认识它们(CONV-1 §① 通则)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type LedgerTableRow = {
    id: string
    date: string
    batch: string
    material: string
    location: string
    hasLocation: boolean
    type: string
    status: string
    qty: string
}

export default function LedgerTable({ rows, empty }: { rows: LedgerTableRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【批次】与【数量】—— 批次是这条流水的身份,数量是台账存在的
    //   理由(动了多少)。日期与库位是读到这一行之后才要问的,进展开区。
    const columns: Column<LedgerTableRow>[] = [
        { key: 'date', header: t('reports.colDate'), render: (r) => r.date || '—' },
        { key: 'batch', header: t('reports.colBatch'), priority: true, className: 'font-mono text-xs', render: (r) => r.batch },
        { key: 'material', header: t('reports.colMaterial'), render: (r) => r.material },
        {
            key: 'location', header: t('reports.colLocation'),
            render: (r) =>
                r.hasLocation ? r.location : <span className="text-gray-400">{t('reports.unspecifiedLocation')}</span>,
        },
        { key: 'type', header: t('reports.colType'), render: (r) => r.type },
        { key: 'status', header: t('reports.colStatus'), render: (r) => r.status },
        { key: 'qty', header: t('reports.colQty'), priority: true, align: 'right', render: (r) => r.qty },
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
