'use client'

// app/finance/bank/statements/[id]/StatementLinesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 银行对账单的行表(8 列,本刀最宽的几张之一)
// ════════════════════════════════════════════════════════════════════════════
//
// ★【手机上留【摘要】与【金额】,而【行号】刻意不留 —— 这是一个判断】★
// 行号是这张表里唯一"看起来像身份"的东西,而它在这张单子之外没有任何意义:
// 没有人拿着「第 14 行」去找一笔钱。人认得出一笔银行流水靠的是
// **它写了什么 + 动了多少**。所以身份列取【摘要】,第二列取【金额】。
// 与 CONV-5 §⑩-13 的启发式(身份列 + 这张登记簿存在的理由)同一条。
//
// 【负数金额发红,而那不是 rowClassName】红只属于金额那一格 ——
// 整行发红会让「这是一笔支出」读成「这一行有问题」。
//
// 【行数据在服务端压平】match 的分录链接要跨两跳反查(bank_line_matches →
// journal_lines → journal_entries),那是服务端的活;过界的是 code + href。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'
import { xDate, xInt, xMoney, xText } from '@/lib/export/cells'

export type StatementLineRow = {
    id: string
    lineNo: string
    lineDate: string
    description: string
    reference: string
    amountText: string
    negative: boolean
    matchStatus: string
    matches: readonly { entryId: string; entryCode: string }[]
    ignoreReason: string
    /** TABLE-EXPORT-3b:导出写原始值(整数行号、真日期、数),不写格式化过的字。合计行这三样:null / null / Σ。 */
    lineNoRaw: number | null
    lineYmd: string | null
    amount: number
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
}

// ★ TABLE-EXPORT-3b:一对导出。合计行(Tim 2026-10-25 Q1)照屏幕作为最后一行导出:标签在【摘要】列,金额是 Σ,其余空。
//   金额:屏幕上格子里不写币种(formatAmount(v, null)),整张单子一个币种,写在表头上方的「银行账户」那一格里 ——
//   导出把这个币种带进格子(xMoney(v, ccy)),一个光秃秃的数离开这一页就丢了它。
export default function StatementLinesTable({ rows, statementCode, currency }: {
    rows: readonly StatementLineRow[]; statementCode: string; currency: string
}) {
    const t = useTranslations()

    const columns: ExportableColumn<StatementLineRow>[] = [
        {
            key: 'lineNo',
            header: t('bank.colLineNo'),
            className: 'text-sm text-gray-500',
            render: (r) => r.lineNo,
            exportAs: (r) => xInt(r.lineNoRaw),
        },
        {
            key: 'date',
            header: t('bank.colDate'),
            className: 'text-sm',
            render: (r) => r.lineDate,
            exportAs: (r) => xDate(r.lineYmd),
        },
        {
            key: 'description',
            header: t('bank.colDescription'),
            // ★ 身份列 —— 见抬头:人靠"它写了什么"认出一笔流水,不靠行号。
            priority: true,
            className: 'text-sm',
            render: (r) => r.description,
            exportAs: (r) => xText(r.description),
        },
        {
            key: 'reference',
            header: t('bank.colReference'),
            className: 'text-sm',
            render: (r) => r.reference,
            exportAs: (r) => xText(r.reference),
        },
        {
            key: 'amount',
            header: t('bank.colAmount'),
            align: 'right',
            // ★ 这张表存在的理由:**动了多少钱**。
            priority: true,
            className: 'text-sm',
            render: (r) => (r.negative ? <span className="text-red-600">{r.amountText}</span> : r.amountText),
            exportAs: (r) => xMoney(r.amount, currency),
        },
        {
            key: 'status',
            header: t('finance.colStatus'),
            render: (r) =>
                r.isTotal ? (
                    ''
                ) : (
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (r.matchStatus === 'matched'
                                ? 'bg-green-100 text-green-800'
                                : r.matchStatus === 'ignored'
                                  ? 'bg-gray-200 text-gray-600'
                                  : 'bg-amber-100 text-amber-800')
                        }
                    >
                        {t('bank.lineStatus.' + r.matchStatus)}
                    </span>
                ),
            exportAs: (r) => xText(r.isTotal ? null : t('bank.lineStatus.' + r.matchStatus)),
        },
        {
            key: 'matchedTo',
            header: t('bank.colMatchedTo'),
            className: 'text-sm',
            render: (r) =>
                r.matches.length === 0 ? (
                    r.isTotal ? '' : '—'
                ) : (
                    <span className="flex flex-wrap gap-2">
                        {r.matches.map((m) => (
                            <Link
                                key={m.entryId}
                                href={`/finance/journal/${m.entryId}`}
                                className="hover:underline app-link app-link-inline"
                            >
                                {m.entryCode}
                            </Link>
                        ))}
                    </span>
                ),
            // 一行可以配到几张分录 —— 单号以「; 」连成一格
            exportAs: (r) => xText(r.matches.length === 0 ? (r.isTotal ? null : '—') : r.matches.map((m) => m.entryCode).join('; ')),
        },
        {
            key: 'ignoreReason',
            header: t('bank.ignoreReason'),
            className: 'text-sm text-gray-600',
            render: (r) => r.ignoreReason,
            exportAs: (r) => xText(r.ignoreReason),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'font-bold bg-[color:var(--brand-muted)]' : undefined)}
            empty={t('bank.empty')}
            exportSpec={{
                name: 'finance-bank-statement-lines',
                title: t('bank.detailTitle'),
                aboutExtra: [[t('bank.colCode'), statementCode]],
            }}
        />
    )
}
