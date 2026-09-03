'use client'

// app/inventory/reports/violations/ViolationsTables.tsx
// CONV-5 · 分类违规报表的两种表。
// 【三段,而只有第一段是违规】—— 这条判据由 page.tsx 的分段与计数承担,
// 这里只提供两种表的画法:真违规(4 列,整行红)与未决定(3 列)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ViolationRow = {
    key: string
    locationCode: string
    materialCode: string
    classCode: string
    qty: string
}

export type UndecidedTableRow = {
    key: string
    code: string
    name: string
    other: string
    qty: string
}

export function ViolationsTable({ rows, empty }: { rows: ViolationRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【库位】与【物料】—— 一条违规就是"这个物料不该待在这个库位",
    //   身份是这两者【合起来】,少任何一个这一行都读不成话。
    const columns: Column<ViolationRow>[] = [
        { key: 'location', header: t('reports.colLocation'), priority: true, className: 'font-mono text-xs', render: (r) => r.locationCode },
        { key: 'material', header: t('reports.colMaterial'), priority: true, className: 'font-mono text-xs', render: (r) => r.materialCode },
        { key: 'class', header: t('reports.colClass'), render: (r) => r.classCode },
        { key: 'qty', header: t('reports.colQty'), align: 'right', render: (r) => r.qty },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            empty={empty}
            rowClassName={() => 'bg-red-50'}
        />
    )
}

export function UndecidedTable({
    rows, colA, colB, qtyLabel,
}: { rows: UndecidedTableRow[]; colA: string; colB: string; qtyLabel: string }) {
    // ★ 3 列表:手机上留【第一列】与【数量】—— 第一列是这一段的主语
    //   (未配置段是库位,未分类段是物料),数量是它值得被列出来的理由。
    const columns: Column<UndecidedTableRow>[] = [
        {
            key: 'a', header: colA, priority: true,
            render: (r) => (
                <>
                    <span className="font-mono text-xs">{r.code}</span> {r.name}
                </>
            ),
        },
        { key: 'b', header: colB, render: (r) => r.other },
        { key: 'qty', header: qtyLabel, priority: true, align: 'right', render: (r) => r.qty },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} />
}
