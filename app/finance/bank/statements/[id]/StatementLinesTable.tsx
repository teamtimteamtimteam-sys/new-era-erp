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
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

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
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
}

export default function StatementLinesTable({ rows }: { rows: readonly StatementLineRow[] }) {
    const t = useTranslations()

    const columns: Column<StatementLineRow>[] = [
        {
            key: 'lineNo',
            header: t('bank.colLineNo'),
            className: 'text-sm text-gray-500',
            render: (r) => r.lineNo,
        },
        {
            key: 'date',
            header: t('bank.colDate'),
            className: 'text-sm',
            render: (r) => r.lineDate,
        },
        {
            key: 'description',
            header: t('bank.colDescription'),
            // ★ 身份列 —— 见抬头:人靠"它写了什么"认出一笔流水,不靠行号。
            priority: true,
            className: 'text-sm',
            render: (r) => r.description,
        },
        {
            key: 'reference',
            header: t('bank.colReference'),
            className: 'text-sm font-mono',
            render: (r) => r.reference,
        },
        {
            key: 'amount',
            header: t('bank.colAmount'),
            align: 'right',
            // ★ 这张表存在的理由:**动了多少钱**。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (r.negative ? <span className="text-red-600">{r.amountText}</span> : r.amountText),
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
                                className="text-blue-600 hover:underline font-mono"
                            >
                                {m.entryCode}
                            </Link>
                        ))}
                    </span>
                ),
        },
        {
            key: 'ignoreReason',
            header: t('bank.ignoreReason'),
            className: 'text-sm text-gray-600',
            render: (r) => r.ignoreReason,
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
        />
    )
}
