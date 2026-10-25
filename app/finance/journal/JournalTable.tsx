'use client'

// app/finance/journal/JournalTable.tsx
// CONV-4 · 分录登记簿(总账)那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate, xMasked } from '@/lib/export/cells'
import { MaskedValue } from '@/app/components/MaskedValue'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

export type JournalRow = {
    id: string
    code: string
    entryDate: string
    /** TABLE-EXPORT-2a:分录日的原始日历日 */
    entryDateRaw: string
    memo: string | null
    sourceType: string | null
    sourceHref: string | null
    /** U1-A(UNBLOCK-1 Q1):工资分录对不持 data.view_pay 的人是 null —— 印「受限」,不印 0.00 */
    amount: number | null
    status: string
}

export default function JournalTable({ rows, empty, baseCurrency, exportHref, sort, shown, total }: {
    rows: JournalRow[]; empty: React.ReactNode; baseCurrency: string
    /** TABLE-EXPORT-2a:服务端分页 —— 清单导出向这条路由要全部匹配行(同一套筛选)。不是总账导出。 */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(journalRows.ts 的 JOURNAL_SORT) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()
    const sourceLabel = (v: string | null) => (v ? t('finance.source.' + v) : '—')

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张总账存在的理由。
    const columns: ExportableColumn<JournalRow>[] = [
        {
            key: 'code', sortable: true, header: t('finance.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/finance/journal/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', sortable: true, header: t('finance.colDate'), render: (r) => r.entryDate, exportAs: (r) => xDate(r.entryDateRaw) },
        { key: 'memo', sortable: true, header: t('finance.colMemo'), className: 'text-sm', render: (r) => r.memo ?? '—', exportAs: (r) => xText(r.memo) },
        {
            key: 'source', sortable: true, header: t('finance.colSource'), className: 'text-sm',
            // 来源【类型】那几个字;链接不是数据
            exportAs: (r) => xText(r.sourceType ? t('finance.source.' + r.sourceType) : null),
            render: (r) =>
                r.sourceHref ? (
                    <Link href={r.sourceHref} className="hover:underline app-link">
                        {sourceLabel(r.sourceType)}
                    </Link>
                ) : (
                    sourceLabel(r.sourceType)
                ),
        },
        {
            key: 'amount', header: t('finance.colAmount', { ccy: baseCurrency }), priority: true, align: 'right', className: 'text-sm',
            // 与 MaskedValue 同一条判据(U1-A,工资那一族):null = 受限;列头已带本位币,格子是一个光秃秃的数
            exportAs: (r) => xMasked(r.amount, r.amount !== null, (v) => xMoney(v)),
            render: (r) => (
                <MaskedValue value={r.amount} canView={r.amount !== null}
                             format={(v: number) => formatMoneyBare(v, '列头 金额 —— 已带本位币')} />
            ),
        },
        {
            key: 'status', sortable: true, header: t('finance.colStatus'),
            exportAs: (r) => xText(t('finance.status.' + r.status)),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.status === 'posted' ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-700')}>
                    {t('finance.status.' + r.status)}
                </span>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'journal-entries', title: t('finance.journalTitle'), serverRows: exportHref }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
        />
    )
}
