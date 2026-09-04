'use client'

// app/finance/ledger/[account]/LedgerRowsTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 科目明细的行表 —— 一个报表数字背后的那些分录行
// ════════════════════════════════════════════════════════════════════════════
//
// ★【手机上留【分录号】与【金额】】★
// 这一页是从报表上的一个数字点进来的,读者带着一个问题:**这个数是由哪些分录
// 凑出来的**。所以身份列是分录号(它可点、可追),第二列是金额(那个被追问的数)。
// 日期/来源/对方科目/摘要进展开区 —— 它们回答的是"这一笔是怎么回事",
// 而那是读者【选中某一行之后】才问的第二个问题。
//
// ★【被冲销的原分录留在表里,而且【必须】留】★
// 见 db/functions/journal_activity_lines.sql 的抬头:那段推导刻意不过滤 status。
// 所以这里给它一枚琥珀色的小标,免得读的人以为是重复行 —— 标住在【分录号】
// 那一格里,也就是手机上留下来的那一列,不会掉进展开区。
//
// 【行数据在服务端压平】locale(对方科目名取 zh 还是 en)、来源链接的解析
// (resolveSourceHrefs)、本位币金额格式 —— 全部只有服务端知道(CONV-1 §①)。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type LedgerTableRow = {
    id: string
    entryDate: string
    entryCode: string
    entryHref: string | null
    reversed: boolean
    sourceLabel: string
    sourceHref: string | null
    /** 对方科目,已在服务端按 locale 取好名字。 */
    counterparts: readonly { code: string; name: string }[]
    memo: string
    amountText: string
    negative: boolean
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
}

export default function LedgerRowsTable({
    rows,
    amountHeader,
    empty,
}: {
    rows: readonly LedgerTableRow[]
    /** 金额({ccy}) —— 本位币由服务端插好。 */
    amountHeader: string
    empty: string
}) {
    const t = useTranslations()

    const columns: Column<LedgerTableRow>[] = [
        {
            key: 'date',
            header: t('finance.colDate'),
            className: 'whitespace-nowrap',
            render: (r) => r.entryDate,
        },
        {
            key: 'entry',
            header: t('finance.ledgerColEntry'),
            // ★ 身份列 —— 这一页存在的意义就是从数字追到分录。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) =>
                r.isTotal ? (
                    <span className="font-sans">{r.entryCode}</span>
                ) : (
                    <>
                        {r.entryHref ? (
                            <Link href={r.entryHref} className="text-blue-600 hover:underline">
                                {r.entryCode}
                            </Link>
                        ) : (
                            r.entryCode
                        )}
                        {r.reversed && (
                            <span className="ml-2 text-xs text-amber-700 font-sans">
                                {t('finance.ledgerReversed')}
                            </span>
                        )}
                    </>
                ),
        },
        {
            key: 'source',
            header: t('finance.colSource'),
            className: 'text-sm',
            render: (r) =>
                r.sourceHref ? (
                    <Link href={r.sourceHref} className="text-blue-600 hover:underline">
                        {r.sourceLabel}
                    </Link>
                ) : (
                    r.sourceLabel
                ),
        },
        {
            key: 'counterpart',
            header: t('finance.ledgerColCounterpart'),
            className: 'text-sm',
            render: (r) =>
                r.counterparts.length === 0
                    ? r.isTotal
                        ? ''
                        : '—'
                    : r.counterparts.map((c) => (
                          <span key={c.code} className="mr-2 whitespace-nowrap">
                              <span className="font-mono">{c.code}</span> {c.name}
                          </span>
                      )),
        },
        {
            key: 'memo',
            header: t('finance.colMemo'),
            className: 'text-sm text-gray-600',
            render: (r) => r.memo,
        },
        {
            key: 'amount',
            header: amountHeader,
            align: 'right',
            // ★ 被追问的那个数。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (r.negative ? <span className="text-red-600">{r.amountText}</span> : r.amountText),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.isTotal ? 'font-bold bg-[color:var(--brand-muted)]' : undefined)}
            empty={empty}
        />
    )
}
