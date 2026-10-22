'use client'

// app/finance/price-exposure/SellPositionsTable.tsx
// CONV-4 · 卖方向浮动价头寸那张表 —— 这一页其余部分都是叙述性文字
// (说出它看不见什么),只有这一张是逐条记录的表。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xInt } from '@/lib/export/cells'

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
    const columns: ExportableColumn<SellPositionRow>[] = [
        { key: 'contract', header: t('priceExposure.colContract'), priority: true, className: 'text-sm', render: (r) => r.contractCode, exportAs: (r) => xText(r.contractCode) },
        { key: 'metal', header: t('priceExposure.colMetal'), className: 'text-sm', render: (r) => r.metal, exportAs: (r) => xText(r.metal) },
        { key: 'index', header: t('priceExposure.colIndex'), className: 'text-sm', render: (r) => r.indexCode, exportAs: (r) => xText(r.indexCode) },
        { key: 'baseEvent', header: t('priceExposure.colBaseEvent'), className: 'text-sm', render: (r) => r.baseEvent, exportAs: (r) => xText(r.baseEvent) },
        { key: 'qpMonths', header: t('priceExposure.colQpMonths'), align: 'right', className: 'text-sm', render: (r) => r.qpMonths, exportAs: (r) => xInt(r.qpMonths) },
        { key: 'payable', header: t('priceExposure.colPayable'), align: 'right', className: 'text-sm', render: (r) => r.payablePct, exportAs: (r) => xNum(r.payablePct, 'pct') },
        { key: 'quantity', header: t('priceExposure.colQuantity'), priority: true, align: 'right', className: 'text-sm', render: (r) => r.orderedQuantity, exportAs: (r) => xNum(r.orderedQuantity, 'qty') },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            exportSpec={{ name: 'sell-price-positions', title: t('priceExposure.title') }}
        />
    )
}
