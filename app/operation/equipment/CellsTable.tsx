'use client'

// app/operation/equipment/CellsTable.tsx
// AUDIT-TRAIL-1b-1:设备页与交接班页的只读小表 —— 格子在服务端造好(字、链接、状态药丸),这里只交给 DataTable 排开。
// DataTable 的 render 是函数,过不了 RSC 边界;格子(ReactNode)过得了。所以列的定义在这里按键取格子,
// 与 HandoversTable 同一张 DataTable、同一种 390px 画法(phone: columns,priority 那几列留在手机上)。
import type { ReactNode } from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type CellRow = { id: string; cells: Record<string, ReactNode> }
export type CellColumn = { key: string; header: string; priority?: boolean; align?: 'left' | 'right' }

export default function CellsTable({ columns, rows, empty }: { columns: CellColumn[]; rows: CellRow[]; empty: ReactNode }) {
    // 第一列是这一行的身份(日期、机器、单号)—— 手机上它【永远】留下(check-datatable-phone:至少一列 priority);
    // 其余几列照调用方说的留或收
    const cols: Column<CellRow>[] = columns.map((c, i) => i === 0
        ? { key: c.key, header: c.header, priority: true, align: c.align, render: (r: CellRow) => r.cells[c.key] }
        : { key: c.key, header: c.header, priority: c.priority, align: c.align, render: (r: CellRow) => r.cells[c.key] })
    return <DataTable rows={rows} columns={cols} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
