'use client'

// MES-5b-1(2026-10-08):物料平衡与得率两页共用的一张只读表 —— 服务端把每一格画成字符串(或一个链接 / 一个标记),
//   这里只负责摆。没有排序、没有筛选:行的先后由服务端定(线的固定顺序、工序的排序号),一个按字母排出来的平衡表读不通。
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type MassCell = string | { text: string; href?: string | null; tone?: 'flag' | 'muted' | 'notSet'; mark?: string }
export type MassRow = { key: string; cells: MassCell[]; emphasis?: boolean }
export type MassHeader = { label: string; priority?: boolean; align?: 'left' | 'right' }

function Cell({ c }: { c: MassCell }) {
    if (typeof c === 'string') return <>{c}</>
    const cls = c.tone === 'flag' ? 'text-red-700 font-medium'
        : c.tone === 'notSet' ? 'text-amber-700'
        : c.tone === 'muted' ? 'text-[color:var(--brand-muted-text)]' : ''
    const body = c.href ? <Link href={c.href} className="hover:underline app-link">{c.text}</Link> : c.text
    return <span className={cls} data-mark={c.mark}>{body}</span>
}

export default function MassTable({ headers, rows, empty, testId }: { headers: MassHeader[]; rows: MassRow[]; empty: string; testId?: string }) {
    function cell(i: number) {
        return function renderCell(r: MassRow) {
            return <span className={r.emphasis ? 'font-medium' : ''}><Cell c={r.cells[i] ?? ''} /></span>
        }
    }
    // 第一列永远是这一行【是什么】(项目 / 工序 / 单位 / 单号)—— 手机上它必须留下;其余列按调用方声明的 priority
    const columns: Column<MassRow>[] = [
        { key: 'c0', header: headers[0]?.label ?? '', priority: true, align: headers[0]?.align, render: cell(0) },
        ...headers.slice(1).map((h, j) => ({ key: `c${j + 1}`, header: h.label, priority: h.priority, align: h.align, render: cell(j + 1) })),
    ]
    return (
        <div data-mass-table={testId}>
            <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty} />
        </div>
    )
}
