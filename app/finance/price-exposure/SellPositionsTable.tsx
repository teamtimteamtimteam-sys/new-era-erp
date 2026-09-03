'use client'

// app/finance/price-exposure/SellPositionsTable.tsx
// CONV-4 · 卖方向浮动价头寸那张表 —— 这一页其余部分都是叙述性文字
// (说出它看不见什么),只有这一张是逐条记录的表。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type SellPositionRow = {
    key: string
    contractCode: string
    metal: string
    indexCode: string
    baseEvent: string
    qpMonths: number
    payablePct: number
    orderedQuantity: number
}

export default function SellPositionsTable({ rows }: { rows: SellPositionRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【合同】与【数量】—— 合同是身份,数量是这张表存在的理由
    //   (这一页问的是"敞口有多大")。
    const columns: Column<SellPositionRow>[] = [
        { key: 'contract', header: t('priceExposure.colContract'), priority: true, className: 'text-sm', render: (r) => r.contractCode },
        { key: 'metal', header: t('priceExposure.colMetal'), className: 'text-sm', render: (r) => r.metal },
        { key: 'index', header: t('priceExposure.colIndex'), className: 'text-sm', render: (r) => r.indexCode },
        { key: 'baseEvent', header: t('priceExposure.colBaseEvent'), className: 'text-sm', render: (r) => r.baseEvent },
        { key: 'qpMonths', header: t('priceExposure.colQpMonths'), align: 'right', className: 'text-sm', render: (r) => r.qpMonths },
        { key: 'payable', header: t('priceExposure.colPayable'), align: 'right', className: 'text-sm', render: (r) => r.payablePct },
        { key: 'quantity', header: t('priceExposure.colQuantity'), priority: true, align: 'right', className: 'text-sm', render: (r) => r.orderedQuantity },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
        />
    )
}
