'use client'

// app/hr/payroll/PayrollPeriodsTable.tsx
// CONV-5 · 薪资期间登记簿那张表。
// 【注意】同目录下的 PayrollGrid 是【可编辑网格】(CONV-2 的模板),它只挂在
// /hr/payroll/new 与 /[id]/edit —— 不在这一页上。CONV-3 §⑧-10 把它记成了
// 这一页的东西,本刀按 import 核实后更正:这一页是纯只读账簿。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type PayrollPeriodRow = {
    id: string
    code: string
    periodMonth: string
    paymentDate: string
    currency: string
    grossTotal: number
    netPayTotal: number
    lineCount: number
    status: string
    journalEntryId: string | null
    journalCode: string
}

export default function PayrollPeriodsTable({ rows, empty }: { rows: PayrollPeriodRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【期间】与【实发合计】—— 期间是身份,实发合计是这张登记簿
    //   存在的理由(这个月到底付出去多少)。应发与人数进展开区。
    const columns: Column<PayrollPeriodRow>[] = [
        {
            key: 'period', header: t('hr.colPeriod'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <>
                    <Link href={`/hr/payroll/${r.id}`} className="text-blue-600 hover:underline">
                        {r.periodMonth?.slice(0, 7)}
                    </Link>
                    <span className="text-gray-400 ml-2 text-xs">{r.code}</span>
                </>
            ),
        },
        { key: 'paymentDate', header: t('hr.colPaymentDate'), render: (r) => r.paymentDate },
        { key: 'currency', header: t('hr.colCurrency'), render: (r) => r.currency },
        {
            key: 'gross', header: t('hr.colGrossTotal'), align: 'right', className: 'font-mono text-sm',
            render: (r) => formatMoneyBare(r.grossTotal, '同行「币种」列(hr.colCurrency)'),
        },
        {
            key: 'net', header: t('hr.colNetTotal'), priority: true, align: 'right',
            className: 'font-mono text-sm font-medium',
            render: (r) => formatMoneyBare(r.netPayTotal, '同行「币种」列(hr.colCurrency)'),
        },
        { key: 'lines', header: t('hr.colLineCount'), align: 'right', className: 'font-mono text-sm', render: (r) => r.lineCount },
        {
            key: 'status', header: t('hr.colStatus'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.status === 'posted' ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')}>
                    {t('hr.payrollStatus.' + r.status)}
                </span>
            ),
        },
        {
            key: 'journal', header: t('assay.journalLink'), className: 'text-sm',
            render: (r) =>
                r.journalEntryId ? (
                    <Link href={`/finance/journal/${r.journalEntryId}`} className="text-blue-600 hover:underline font-mono">
                        {r.journalCode}
                    </Link>
                ) : (
                    '—'
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
        />
    )
}
