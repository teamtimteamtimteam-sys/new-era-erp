'use client'

// app/inventory/reports/ledger/LedgerTable.tsx
// CONV-5 · 流水台账那张表。
// 行已经在服务端用 flatten() 压平,状态键也在服务端翻好 —— statusKey 与
// flatten 都是取数侧的知识,列描述符不该再认识它们(CONV-1 §① 通则)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xDate } from '@/lib/export/cells'

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
    /** TABLE-EXPORT-1:导出用的原始数量变动(带符号)。date 本来就是原始的 `YYYY-MM-DD`(空 = 屏幕上的「—」)。 */
    qtyDelta: number
}

export default function LedgerTable({ rows, empty, filters }: {
    rows: LedgerTableRow[]
    empty: React.ReactNode
    /**
     * TABLE-EXPORT-1:About 表的「筛选」那一栏。【默认 90 天】不在地址栏里(parseLedgerParams 补上的),
     * 所以不能让导出去读 URL —— 那样一份默认窗口的导出会自称「无筛选」。页面按生效的那一组参数给。
     */
    filters: ReadonlyArray<[string, string]>
}) {
    const t = useTranslations()

    // ★ 手机上留【批次】与【数量】—— 批次是这条流水的身份,数量是台账存在的
    //   理由(动了多少)。日期与库位是读到这一行之后才要问的,进展开区。
    const columns: ExportableColumn<LedgerTableRow>[] = [
        { key: 'date', header: t('reports.colDate'), render: (r) => r.date || '—', exportAs: (r) => xDate(r.date || null) },
        { key: 'batch', header: t('reports.colBatch'), priority: true, className: 'text-xs', render: (r) => r.batch, exportAs: (r) => xText(r.batch) },
        { key: 'material', header: t('reports.colMaterial'), render: (r) => r.material, exportAs: (r) => xText(r.material) },
        {
            key: 'location', header: t('reports.colLocation'),
            // 【未指定库位】是一个有名字的分组,导出里同样是那句话,不是空格
            exportAs: (r) => xText(r.hasLocation ? r.location : t('reports.unspecifiedLocation')),
            render: (r) =>
                r.hasLocation ? r.location : <span className="text-gray-400">{t('reports.unspecifiedLocation')}</span>,
        },
        { key: 'type', header: t('reports.colType'), render: (r) => r.type, exportAs: (r) => xText(r.type) },
        { key: 'status', header: t('reports.colStatus'), render: (r) => r.status, exportAs: (r) => xText(r.status) },
        { key: 'qty', header: t('reports.colQty'), priority: true, align: 'right', render: (r) => r.qty, exportAs: (r) => xNum(r.qtyDelta, 'qty') },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'stock-ledger', title: t('reports.ledger.title'), filters }}
        />
    )
}
