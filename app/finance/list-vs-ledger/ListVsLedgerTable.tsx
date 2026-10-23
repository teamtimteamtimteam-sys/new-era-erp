'use client'

// app/finance/list-vs-ledger/ListVsLedgerTable.tsx
// AP-RECON-1 Batch B:清单 ↔ 总账那一边的勾稽表 —— 组件库的 DataTable,两列(名目 / 金额)。
//
// 【行数据在服务端压平】每一行的名目、链接、明细与金额文字都由 page.tsx 从
// list_ledger_reconciliation() 的返回值里取出来;这里一分钱都不算(预览要问数据库那条规矩)。
// 【手机上两列全留】名目与金额是一句话的两半,拆开哪一半都读不懂。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xMoney, xText } from '@/lib/export/cells'

export type ListVsLedgerRow = {
    id: string
    label: string
    href: string | null
    /** 名目下面的小字明细(残留逐单据、挂账逐笔)。 */
    details: string[]
    amountText: string
    /** TABLE-EXPORT-3a:导出写数,不写屏幕上那串字;NULL = 那一边答不上来,屏幕写「—」。 */
    amount: number | null
    /** 'strong' = 差那一行;'ok' / 'bad' = 未解释那一行是不是 0.00。 */
    tone: 'strong' | 'ok' | 'bad' | null
}

export default function ListVsLedgerTable({
    rows,
    lineHeader,
    amountHeader,
    exportName,
    exportTitle,
}: {
    rows: readonly ListVsLedgerRow[]
    lineHeader: string
    amountHeader: string
    /** TABLE-EXPORT-3a(Tim 2026-10-23 Q1):每一边一张表,各一对导出。 */
    exportName: string
    exportTitle: string
}) {
    // 名目下面那几行小字明细(残留逐单据、挂账逐笔)跟着名目进同一格,用「; 」隔开 —— 一格一个值,而它们是那个名目的说明。
    const columns: ExportableColumn<ListVsLedgerRow>[] = [
        {
            key: 'line',
            header: lineHeader,
            priority: true,
            render: (r) => (
                <div>
                    {r.href ? (
                        <Link href={r.href} className="hover:underline app-link">{r.label}</Link>
                    ) : (
                        r.label
                    )}
                    {r.details.length > 0 && (
                        <ul className="mt-1 space-y-1 text-xs text-gray-600">
                            {r.details.map((d, i) => <li key={i}>{d}</li>)}
                        </ul>
                    )}
                </div>
            ),
            exportAs: (r) => xText(r.details.length ? `${r.label}: ${r.details.join('; ')}` : r.label),
        },
        {
            key: 'amount',
            header: amountHeader,
            align: 'right',
            priority: true,
            className: 'tabular-nums',
            render: (r) => (
                <span className={r.tone === 'ok' ? 'text-green-800' : r.tone === 'bad' ? 'text-red-700' : undefined}
                      data-unexplained={r.tone === 'ok' || r.tone === 'bad' ? r.id : undefined}>
                    {r.amountText}
                </span>
            ),
            exportAs: (r) => (r.amount === null ? xText('—') : xMoney(r.amount)),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.tone ? 'font-semibold' : undefined)}
            exportSpec={{ name: exportName, title: exportTitle }}
        />
    )
}
