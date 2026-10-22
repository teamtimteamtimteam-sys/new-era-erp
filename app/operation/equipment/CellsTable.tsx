'use client'

// app/operation/equipment/CellsTable.tsx
// AUDIT-TRAIL-1b-1:设备页与交接班页的只读小表 —— 格子在服务端造好(字、链接、状态药丸),这里只交给 DataTable 排开。
// DataTable 的 render 是函数,过不了 RSC 边界;格子(ReactNode)过得了。所以列的定义在这里按键取格子,
// 与 HandoversTable 同一张 DataTable、同一种 390px 画法(phone: columns,priority 那几列留在手机上)。
//
// TABLE-EXPORT-1(Tim 2026-10-22):格子是画好的 JSX,从里面抠不出一个数 —— 所以每一行另带一份
//   `exports`(同一组键,每一格是 lib/export/cells.ts 的带类型一格),由调用方从【原始值】造。
//   ExportCell 是纯对象,过得了 RSC 边界。缺一个键不是"空格",是一个错:导出当场按名拒绝。
import type { ReactNode } from 'react'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import type { ExportCell } from '@/lib/export/cells'

export type CellRow = { id: string; cells: Record<string, ReactNode>; exports: Record<string, ExportCell> }
export type CellColumn = {
    key: string; header: string; priority?: boolean; align?: 'left' | 'right'
    /** 画控件的那一列(按钮、勾选)—— 它不是数据,不导出;这一列不必在 exports 里有键。 */
    control?: boolean
}
/** 统一导出的名字与标题(RSC 边界上只能是纯数据,所以不收 TableExportSpec 的函数字段)。 */
export type CellsExport = { name: string; title: string }

export default function CellsTable({ columns, rows, empty, exportSpec }: {
    columns: CellColumn[]; rows: CellRow[]; empty: ReactNode; exportSpec: CellsExport
}) {
    // 第一列是这一行的身份(日期、机器、单号)—— 手机上它【永远】留下(check-datatable-phone:至少一列 priority);
    // 其余几列照调用方说的留或收
    const exportAs = (c: CellColumn) => c.control ? false as const : (r: CellRow): ExportCell => {
        const x = r.exports[c.key]
        if (!x) throw new Error(`EXPORT_CELL_MISSING|${exportSpec.name}|${c.key}`)
        return x
    }
    const cols: ExportableColumn<CellRow>[] = columns.map((c, i) => i === 0
        ? { key: c.key, header: c.header, priority: true, align: c.align, render: (r: CellRow) => r.cells[c.key], exportAs: exportAs(c) }
        : { key: c.key, header: c.header, priority: c.priority, align: c.align, render: (r: CellRow) => r.cells[c.key], exportAs: exportAs(c) })
    return <DataTable rows={rows} columns={cols} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
                      exportSpec={{ name: exportSpec.name, title: exportSpec.title }} />
}
