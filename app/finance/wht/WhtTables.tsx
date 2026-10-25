'use client'

// app/finance/wht/WhtTables.tsx
// CONV-4 · 这一页三张只读账簿(欠缴月度 / 汇缴登记簿 / 法定税率参照),
// 都是同一页面上的表,放进一个客户端文件而不是三个 —— 没有任何一张会被
// 别的页面复用,拆成三个文件只是多出两次触碰,不买来任何东西。

import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate } from '@/lib/export/cells'
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
    const columns: ExportableColumn<LiabilityRow>[] = [
        { key: 'month', header: t('wht.colMonth'), priority: true, render: (r) => formatMonth(r.periodMonth, locale),
            // 月份不是一个日子:导出写成原始的 YYYY-MM(从原始日期截,不从显示用的字截)
            exportAs: (r) => xText(r.periodMonth.slice(0, 7)) },
        {
            key: 'withheld', header: t('wht.colWithheld'), align: 'right',
            render: (r) => formatAmount(r.withheldBase, r.baseCurrency),
            exportAs: (r) => xMoney(r.withheldBase, r.baseCurrency),
        },
        {
            key: 'remitted', header: t('wht.colRemitted'), align: 'right',
            render: (r) => formatAmount(r.remittedBase, r.baseCurrency),
            exportAs: (r) => xMoney(r.remittedBase, r.baseCurrency),
        },
        {
            key: 'unremitted', header: t('wht.colUnremitted'), priority: true, align: 'right', className: 'font-semibold',
            render: (r) => formatAmount(r.unremittedBase, r.baseCurrency),
            exportAs: (r) => xMoney(r.unremittedBase, r.baseCurrency),
        },
        {
            key: 'due', header: t('wht.colDue'), className: 'text-xs',
            // 一个真日期;「逾期 / 还有 N 天」由这个日子与今天推得出,不写进日期格(TABLE-EXPORT-1 同一个处置)
            exportAs: (r) => xDate(r.dueDate),
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

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.periodMonth} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'wht-liability', title: t('wht.liabilityHeading') }}
        // TABLE-FEATURES-1 Q9:欠缴月度一次读全(wht_liability_by_month 不翻页)—— 在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
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
    const columns: ExportableColumn<RemittanceRow>[] = [
        { key: 'code', header: t('wht.colCode'), priority: true, render: (r) => r.code, exportAs: (r) => xText(r.code) },
        { key: 'month', header: t('wht.colMonth'), render: (r) => formatMonth(r.periodMonth, locale), exportAs: (r) => xText(r.periodMonth.slice(0, 7)) },
        { key: 'remittedOn', header: t('wht.colRemittedOn'), className: 'text-xs', render: (r) => r.remittedOn, exportAs: (r) => xDate(r.remittedOn) },
        {
            key: 'amount', header: t('wht.colAmount'), priority: true, align: 'right',
            render: (r) => formatAmount(r.amountBase, r.baseCurrency),
            exportAs: (r) => xMoney(r.amountBase, r.baseCurrency),
        },
        { key: 'ref', header: t('wht.colIrasRef'), className: 'text-xs', render: (r) => r.filedReference, exportAs: (r) => xText(r.filedReference) },
        {
            key: 'action', header: t('wht.colStatus'),
            // 状态这一格:已冲销 / 冲销申请在等(带单号);否则屏幕上是一颗钮 —— 那不是数据,导出空着
            exportAs: (r) => xText(r.reversed ? t('wht.reversed')
                : r.openRequestId ? t('wht.reversalRequested', { code: r.openRequestCode ?? '' })
                : null),
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

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'wht-remittances', title: t('wht.remittancesHeading') }}
        // TABLE-FEATURES-1 Q9:汇缴登记簿一次读全(wht_remittances 不翻页)—— 在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
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
    const columns: ExportableColumn<WhtRateRow>[] = [
        { key: 'nature', header: t('wht.colNature'), priority: true, render: (r) => r.name, exportAs: (r) => xText(r.name) },
        {
            key: 'rate', header: t('wht.colRate'), priority: true, className: 'text-xs',
            // TABLE-FEATURES-1 Q9:一格是几段税率的文字 —— 按它排没有意义,不可排
            sortable: false,
            // 几段税率各有生效区间 —— 写成屏幕上那几行文字,以「; 」分开,日期取原始的
            exportAs: (r) => xText(r.rates.map((rt) => `${Number(rt.rate_pct)}% · ${rt.effective_from} → ${rt.effective_to ?? '—'}`).join('; ')),
            render: (r) => r.rates.map((rt) => (
                <div key={formatDate(rt.effective_from, locale)}>
                    {Number(rt.rate_pct)}% · {formatDate(rt.effective_from, locale)} → {formatDate(rt.effective_to, locale) ?? '—'}
                </div>
            )),
        },
        { key: 'statute', header: t('wht.colStatute'), className: 'text-xs text-gray-600', render: (r) => r.statuteRef, exportAs: (r) => xText(r.statuteRef) },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.code} phone={{ mode: 'columns' }}
        exportSpec={{ name: 'wht-rates', title: t('wht.ratesHeading') }}
        // TABLE-FEATURES-1 Q9:法定税率参照一次读全 —— 在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
}
