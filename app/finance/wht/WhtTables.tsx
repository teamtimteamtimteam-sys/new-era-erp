'use client'

// app/finance/wht/WhtTables.tsx
// CONV-4 · 这一页三张只读账簿(欠缴月度 / 汇缴登记簿 / 法定税率参照),
// 都是同一页面上的表,放进一个客户端文件而不是三个 —— 没有任何一张会被
// 别的页面复用,拆成三个文件只是多出两次触碰,不买来任何东西。

import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { formatDate, formatMonth } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'
import Link from 'next/link'
import { RequestWhtReversalButton } from './WhtControls'

export type LiabilityRow = {
    periodMonth: string
    withheldBase: number
    remittedBase: number
    unremittedBase: number
    dueDate: string
    isOverdue: boolean
    daysUntilDue: number
    baseCurrency: string
}

export function WhtLiabilityTable({ rows, empty }: { rows: LiabilityRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const locale = useLocale()

    // ★ 手机上留【月份】与【未汇缴】—— 未汇缴是这张表存在的理由(还欠多少)。
    const columns: Column<LiabilityRow>[] = [
        { key: 'month', header: t('wht.colMonth'), priority: true, render: (r) => formatMonth(r.periodMonth, locale) },
        {
            key: 'withheld', header: t('wht.colWithheld'), align: 'right',
            render: (r) => formatAmount(r.withheldBase, r.baseCurrency),
        },
        {
            key: 'remitted', header: t('wht.colRemitted'), align: 'right',
            render: (r) => formatAmount(r.remittedBase, r.baseCurrency),
        },
        {
            key: 'unremitted', header: t('wht.colUnremitted'), priority: true, align: 'right', className: 'font-semibold',
            render: (r) => formatAmount(r.unremittedBase, r.baseCurrency),
        },
        {
            key: 'due', header: t('wht.colDue'), className: 'text-xs',
            render: (r) => (
                <>
                    <span>{r.dueDate}</span>
                    {r.unremittedBase > 0 && (
                        r.isOverdue
                            ? <span className="ml-2 text-red-700 font-semibold">{t('wht.overdue')}</span>
                            : <span className="ml-2 text-gray-600">{t('wht.dueIn', { n: String(r.daysUntilDue) })}</span>
                    )}
                </>
            ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.periodMonth} phone={{ mode: 'columns' }} empty={empty} />
}

export type RemittanceRow = {
    id: string
    code: string
    periodMonth: string
    remittedOn: string
    amountBase: number
    baseCurrency: string
    filedReference: string
    /** PAY-REQ-1 · Batch B:它的分录已被冲销(这一行从"已汇"里掉出来了) */
    reversed: boolean
    /** 未了结的冲销申请(有就给链接,不再给钮) */
    openRequestId: string | null
    openRequestCode: string | null
}

export function WhtRemittancesTable({ rows, empty, canEdit }: { rows: RemittanceRow[]; empty: React.ReactNode; canEdit: boolean }) {
    const t = useTranslations()
    const locale = useLocale()

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张登记簿存在的理由。
    const columns: Column<RemittanceRow>[] = [
        { key: 'code', header: t('wht.colCode'), priority: true, render: (r) => r.code },
        { key: 'month', header: t('wht.colMonth'), render: (r) => formatMonth(r.periodMonth, locale) },
        { key: 'remittedOn', header: t('wht.colRemittedOn'), className: 'text-xs', render: (r) => r.remittedOn },
        {
            key: 'amount', header: t('wht.colAmount'), priority: true, align: 'right',
            render: (r) => formatAmount(r.amountBase, r.baseCurrency),
        },
        { key: 'ref', header: t('wht.colIrasRef'), className: 'text-xs', render: (r) => r.filedReference },
        {
            key: 'action', header: t('wht.colStatus'),
            render: (r) => r.reversed ? (
                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-700">{t('wht.reversed')}</span>
            ) : r.openRequestId ? (
                <Link href={`/finance/payment-requests/${r.openRequestId}`} className="hover:underline app-link app-link-inline">
                    {t('wht.reversalRequested', { code: r.openRequestCode ?? '' })}
                </Link>
            ) : (
                <RequestWhtReversalButton remittanceId={r.id} code={r.code} canEdit={canEdit} />
            ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}

export type WhtRateRow = {
    code: string
    name: string
    statuteRef: string
    rates: { rate_pct: number; effective_from: string; effective_to: string | null }[]
}

export function WhtRatesTable({ rows }: { rows: WhtRateRow[] }) {
    const locale = useLocale()
    const t = useTranslations()

    // ★ 手机上留【类别】与【税率】—— 类别是身份,税率是这张参照表存在的理由。
    const columns: Column<WhtRateRow>[] = [
        { key: 'nature', header: t('wht.colNature'), priority: true, render: (r) => r.name },
        {
            key: 'rate', header: t('wht.colRate'), priority: true, className: 'text-xs',
            render: (r) => r.rates.map((rt) => (
                <div key={formatDate(rt.effective_from, locale)}>
                    {Number(rt.rate_pct)}% · {formatDate(rt.effective_from, locale)} → {formatDate(rt.effective_to, locale) ?? '—'}
                </div>
            )),
        },
        { key: 'statute', header: t('wht.colStatute'), className: 'text-xs text-gray-600', render: (r) => r.statuteRef },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.code} phone={{ mode: 'columns' }} />
}
