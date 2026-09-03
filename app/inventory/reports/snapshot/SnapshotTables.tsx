'use client'

// app/inventory/reports/snapshot/SnapshotTables.tsx
// CONV-5 · 库存快照的两张表:B 节(物料 × 库位 × 状态,按库位一段一张)与 C 节(库龄)。
//
// ★★【这一页的"分组"不是 CONV-4 §⑨-2 记的那个缺口】★★
// §⑨-2 记下的两种形状,都是【一张表里】夹着分组表头行与组内小计行
// (payables/receivables 按往来对象动态分组;balance-sheet/pnl/trial-balance
// 按科目类型固定三段 + 派生合计行)—— 那是 DataTable 的契约("一行 = 一条记录")
// 表达不了的东西。
// 这一页不是:它按库位切成【一段一个 <section>、每段一张完整的表】,表里没有
// 分组行、没有组内小计,唯一的合计是页顶那条【在所有表之外】的合计条。
// 也就是说它用今天的 DataTable 就画得出来,一个新口子都不需要。
// **所以本刀没有把它计入那 5 处缺口** —— 它是"分组"这个词底下的第三种排法,
// 而恰好是不需要建任何东西的那一种。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type SnapshotRow = {
    key: string
    materialCode: string
    materialName: string
    kindLabel: string
    statusLabel: string
    qty: string
    value: React.ReactNode
    uncosted: string
}

export type AgeingRow = {
    bucket: string
    bandLabel: string
    batches: number
    qty: string
    value: React.ReactNode
}

export function SnapshotGroupTable({ rows }: { rows: SnapshotRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【物料】与【数量】—— 物料是身份;数量而不是价值,因为这一页
    //   抬头写明它最主要的读者(operations / warehouse)【看不到价】:
    //   给他们留一列印着"受限"的格子,等于把小屏上两个名额之一浪费掉。
    const columns: Column<SnapshotRow>[] = [
        {
            key: 'material', header: t('reports.colMaterial'), priority: true,
            render: (r) => (
                <>
                    <span className="font-mono text-xs">{r.materialCode}</span> {r.materialName}
                </>
            ),
        },
        { key: 'kind', header: t('reports.colBatchKind'), render: (r) => r.kindLabel },
        { key: 'status', header: t('reports.colStatus'), render: (r) => r.statusLabel },
        { key: 'qty', header: t('reports.colQty'), priority: true, align: 'right', render: (r) => r.qty },
        { key: 'value', header: t('reports.colValue'), align: 'right', render: (r) => r.value },
        { key: 'uncosted', header: t('reports.colUncostedQty'), align: 'right', render: (r) => r.uncosted },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} />
}

export function AgeingTable({ rows }: { rows: AgeingRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【库龄档】与【数量】—— 同上,价值列对看不到价的人是"受限"。
    const columns: Column<AgeingRow>[] = [
        { key: 'band', header: t('reports.colAgeingBand'), priority: true, render: (r) => r.bandLabel },
        { key: 'batches', header: t('reports.colBatches'), align: 'right', render: (r) => r.batches },
        { key: 'qty', header: t('reports.colQty'), priority: true, align: 'right', render: (r) => r.qty },
        { key: 'value', header: t('reports.colValue'), align: 'right', render: (r) => r.value },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.bucket} phone={{ mode: 'columns' }} />
}
