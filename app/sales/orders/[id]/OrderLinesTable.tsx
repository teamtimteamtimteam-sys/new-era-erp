'use client'

// app/sales/orders/[id]/OrderLinesTable.tsx
// ★ TABLE-CONVERT-3(2026-09-10):从 page.tsx 里搬出来的订单行表。
//   为什么必须是新文件,与 OpenItemsTable 抬头同一条(server→client 过不去函数)。
//
// 【这张表【没有】列选判断要搬】四列在 390px 上全部看得见,所以四列全部 priority。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xInt, xMoney, xNum, xText } from '@/lib/export/cells'

export type OrderLineRow = {
    lineNo: number
    /** `${code} — ${name}`,读不到物料时页面给的是 '—',与转换之前逐字相同。 */
    material: string
    quantity: number
    unitPrice: number
}

export default function OrderLinesTable({ rows, orderCode }: { rows: OrderLineRow[]
    /** TABLE-EXPORT-3b:导出的 About 表说明这份文件出自哪张订单 */
    orderCode: string }) {
    const t = useTranslations()

    // TABLE-EXPORT-3b:屏幕上数量与单价都是光秃秃的数(不写单位、不写币种)—— 导出同样光秃秃,列头说了算,不替屏幕添一列。
    const columns: ExportableColumn<OrderLineRow>[] = [
        // 列头是一个字面的 '#',转换之前就是 —— 它不是 i18n key,原样保留。
        { key: 'lineNo', header: '#', priority: true, render: (l) => l.lineNo, exportAs: (l) => xInt(l.lineNo) },
        { key: 'material', header: t('sales.colMaterial'), priority: true, render: (l) => l.material,
          exportAs: (l) => xText(l.material === '—' ? null : l.material) },
        { key: 'qty', header: t('sales.form.qty'), align: 'right', priority: true, render: (l) => l.quantity,
          exportAs: (l) => xNum(l.quantity, 'qty') },
        { key: 'unitPrice', header: t('sales.form.unitPrice'), align: 'right', priority: true, render: (l) => l.unitPrice,
          exportAs: (l) => xMoney(l.unitPrice) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(l) => String(l.lineNo)}
            phone={{ mode: 'columns' }}
            exportSpec={{ name: 'sales-order-lines', title: t('sales.form.lines'),
                          aboutExtra: [[t('sales.colCode'), orderCode]] }}
        />
    )
}
