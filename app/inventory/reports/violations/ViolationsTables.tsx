'use client'

// app/inventory/reports/violations/ViolationsTables.tsx
// CONV-5 · 分类违规报表的两种表。
// 【三段,而只有第一段是违规】—— 这条判据由 page.tsx 的分段与计数承担,
// 这里只提供两种表的画法:真违规(4 列,整行红)与未决定(3 列)。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum } from '@/lib/export/cells'

export type ViolationRow = {
    key: string
    locationCode: string
    materialCode: string
    classCode: string
    qty: string
    /** TABLE-EXPORT-1:导出用的原始数量。 */
    qtyRaw: number
}

export type UndecidedTableRow = {
    key: string
    code: string
    name: string
    other: string
    qty: string
    /** TABLE-EXPORT-1:导出用的原始数量(屏幕上是「12 kg」这串字)。 */
    qtyRaw: number
    /** TABLE-EXPORT-1:屏幕上跟在数量后面的单位(原样的码)—— 导出时一起写。 */
    unit: string
}

export function ViolationsTable({ rows, empty }: { rows: ViolationRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【库位】与【物料】—— 一条违规就是"这个物料不该待在这个库位",
    //   身份是这两者【合起来】,少任何一个这一行都读不成话。
    const columns: ExportableColumn<ViolationRow>[] = [
        { key: 'location', header: t('reports.colLocation'), priority: true, className: 'text-xs', render: (r) => r.locationCode, exportAs: (r) => xText(r.locationCode) },
        { key: 'material', header: t('reports.colMaterial'), priority: true, className: 'text-xs', render: (r) => r.materialCode, exportAs: (r) => xText(r.materialCode) },
        { key: 'class', header: t('reports.colClass'), render: (r) => r.classCode, exportAs: (r) => xText(r.classCode) },
        { key: 'qty', header: t('reports.colQty'), align: 'right', render: (r) => r.qty, exportAs: (r) => xNum(r.qtyRaw, 'qty') },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'class-violations', title: t('reports.violations.title') }}
            rowClassName={() => 'bg-red-50'}
        />
    )
}

export function UndecidedTable({
    rows, colA, colB, qtyLabel, exportName, exportTitle,
}: {
    rows: UndecidedTableRow[]; colA: string; colB: string; qtyLabel: string
    /** TABLE-EXPORT-1:同一个组件画两段(未配置库位 · 未分类物料),各自一个导出名与标题。 */
    exportName: string; exportTitle: string
}) {
    // ★ 3 列表:手机上留【第一列】与【数量】—— 第一列是这一段的主语
    //   (未配置段是库位,未分类段是物料),数量是它值得被列出来的理由。
    const columns: ExportableColumn<UndecidedTableRow>[] = [
        {
            key: 'a', header: colA, priority: true,
            exportAs: (r) => xText(`${r.code} ${r.name}`),
            render: (r) => (
                <>
                    <span className="text-xs">{r.code}</span> {r.name}
                </>
            ),
        },
        { key: 'b', header: colB, render: (r) => r.other, exportAs: (r) => xText(r.other) },
        { key: 'qty', header: qtyLabel, priority: true, align: 'right', render: (r) => r.qty, exportAs: (r) => xNum(r.qtyRaw, 'qty', r.unit) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            exportSpec={{ name: exportName, title: exportTitle }}
        />
    )
}
