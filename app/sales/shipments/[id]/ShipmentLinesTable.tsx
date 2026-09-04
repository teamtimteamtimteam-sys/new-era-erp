'use client'

// app/sales/shipments/[id]/ShipmentLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一张发货单的行
// ════════════════════════════════════════════════════════════════════════════
//
// ★【手机上留【物料】与【数量】,行号刻意不留】★
// 与 /finance/bank/statements/[id] 的判断同一条:行号在这张单子之外没有意义,
// 而人认得出一条发货行靠的是**发了什么、发了多少**。
//
// 【库位那一列有它自己的一句话】它记的是【发货当刻货在哪】,不是预留行的库位
// (那个会随整桶转移改写)。两者日后可以不同 —— 所以它是一列真数据,
// 不是一个可以从别处推出来的显示值。它进展开区,但它没有被删掉。
//
// 【行数据在服务端压平】三层嵌套(output_batches → materials / storage_locations
// / sales_order_lines)在服务端摊平成字符串,一个 Map 都不过界(CONV-1 §①)。
import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type ShipmentLineRow = {
    id: string
    lineNo: string
    materialCode: string
    materialName: string
    batchCode: string
    locationCode: string
    locationName: string
    qtyText: string
}

export default function ShipmentLinesTable({ rows }: { rows: readonly ShipmentLineRow[] }) {
    const t = useTranslations()

    const columns: Column<ShipmentLineRow>[] = [
        {
            key: 'lineNo',
            header: t('sales.shipDetail.colLineNo'),
            className: 'font-mono',
            render: (r) => r.lineNo,
        },
        {
            key: 'material',
            header: t('sales.shipDetail.colMaterial'),
            // ★ 身份列 —— 一条发货行的主语是"发的是什么货"。
            priority: true,
            render: (r) =>
                r.materialCode ? (
                    <>
                        <span className="font-mono">{r.materialCode}</span> {r.materialName}
                    </>
                ) : (
                    '—'
                ),
        },
        {
            key: 'batch',
            header: t('sales.shipDetail.colBatch'),
            className: 'font-mono',
            render: (r) => r.batchCode,
        },
        {
            key: 'location',
            header: t('sales.shipDetail.colLocation'),
            render: (r) =>
                r.locationCode ? (
                    <>
                        <span className="font-mono">{r.locationCode}</span> {r.locationName}
                    </>
                ) : (
                    '—'
                ),
        },
        {
            key: 'qty',
            header: t('sales.shipDetail.colQty'),
            align: 'right',
            // ★ 这张表存在的理由:发了多少。
            priority: true,
            className: 'font-mono',
            render: (r) => r.qtyText,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            // 具名的空状态 —— 一张没有行的发货单在结构上不该存在,所以这句话
            // 本身就是一个信号,不是"暂无数据"。
            empty={t('sales.shipDetail.noLines')}
        />
    )
}
