'use client'

// app/inventory/reports/safety/SafetyTable.tsx
// CONV-5 · 安全库存总览那张表。
// 【低于阈值的行整行发琥珀】用的是 CONV-4 建的 rowClassName,不是页面自己
// 在每个 <td> 上重复一遍 class。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type SafetyRow = {
    materialId: string
    code: string
    name: string
    availableQty: string
    thresholdQty: string
    shortfall: string
    isBelow: boolean
}

export default function SafetyTable({ rows }: { rows: SafetyRow[] }) {
    const t = useTranslations()

    // ★ 4 列表:手机上留【物料】与【缺口】—— 物料是身份,缺口是这张报表存在的
    //   理由(要补多少)。可用量与阈值是推导出缺口的两个中间量,进展开区。
    const columns: Column<SafetyRow>[] = [
        {
            key: 'material', header: t('reports.colMaterial'), priority: true,
            render: (r) => (
                <>
                    <span className="font-mono text-xs">{r.code}</span> {r.name}
                </>
            ),
        },
        { key: 'available', header: t('reports.colAvailable'), align: 'right', render: (r) => r.availableQty },
        { key: 'threshold', header: t('reports.colThreshold'), align: 'right', render: (r) => r.thresholdQty },
        {
            key: 'shortfall', header: t('reports.colShortfall'), priority: true, align: 'right',
            className: 'font-medium', render: (r) => r.shortfall,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.materialId}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isBelow ? 'bg-amber-50' : undefined)}
        />
    )
}
