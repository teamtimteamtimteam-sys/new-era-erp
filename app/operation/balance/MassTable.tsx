'use client'

// MES-5b-1(2026-10-08):物料平衡与得率两页共用的一张只读表 —— 服务端把每一格画成字符串(或一个链接 / 一个标记),
//   这里只负责摆。没有排序、没有筛选:行的先后由服务端定(线的固定顺序、工序的排序号),一个按字母排出来的平衡表读不通。
//
// TABLE-EXPORT-1(Tim 2026-10-22):格子是画好的字(fmtKg、fmtPct)—— 从里面抠出来的是【文字】,不是数。
//   所以每一行另带一份 `exports`(与 cells 同位、同长),由服务端从【原始值】造(xNum / xText / xRestricted);
//   ExportCell 是纯对象,过得了 RSC 边界。少一格不是"空格",是一个错:导出当场按名拒绝。
import Link from 'next/link'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import type { ExportCell } from '@/lib/export/cells'

export type MassCell = string | { text: string; href?: string | null; tone?: 'flag' | 'muted' | 'notSet'; mark?: string }
export type MassRow = { key: string; cells: MassCell[]; exports: ExportCell[]; emphasis?: boolean }
export type MassHeader = { label: string; priority?: boolean; align?: 'left' | 'right' }

function Cell({ c }: { c: MassCell }) {
    if (typeof c === 'string') return <>{c}</>
    const cls = c.tone === 'flag' ? 'text-red-700 font-medium'
        : c.tone === 'notSet' ? 'text-amber-700'
        : c.tone === 'muted' ? 'text-[color:var(--brand-muted-text)]' : ''
    const body = c.href ? <Link href={c.href} className="hover:underline app-link">{c.text}</Link> : c.text
    return <span className={cls} data-mark={c.mark}>{body}</span>
}

export default function MassTable({ headers, rows, empty, testId, exportSpec }: {
    headers: MassHeader[]; rows: MassRow[]; empty: string; testId?: string
    /** 统一导出的名字与标题(纯数据 —— 过 RSC 边界)。 */
    exportSpec: { name: string; title: string }
}) {
    function cell(i: number) {
        return function renderCell(r: MassRow) {
            return <span className={r.emphasis ? 'font-medium' : ''}><Cell c={r.cells[i] ?? ''} /></span>
        }
    }
    function exported(i: number) {
        return function exportCell(r: MassRow): ExportCell {
            const x = r.exports[i]
            if (!x) throw new Error(`EXPORT_CELL_MISSING|${exportSpec.name}|${i}`)
            return x
        }
    }
    // 第一列永远是这一行【是什么】(项目 / 工序 / 单位 / 单号)—— 手机上它必须留下;其余列按调用方声明的 priority
    const columns: ExportableColumn<MassRow>[] = [
        { key: 'c0', header: headers[0]?.label ?? '', priority: true, align: headers[0]?.align, render: cell(0), exportAs: exported(0) },
        ...headers.slice(1).map((h, j) => ({
            key: `c${j + 1}`, header: h.label, priority: h.priority, align: h.align, render: cell(j + 1), exportAs: exported(j + 1),
        })),
    ]
    return (
        <div data-mass-table={testId}>
            <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
                       exportSpec={{ name: exportSpec.name, title: exportSpec.title }} />
        </div>
    )
}
