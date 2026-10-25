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
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xMoney, xRestricted, xText } from '@/lib/export/cells'
import { Refusal } from '@/app/components/ui/refusal'
import { useTranslations } from '@/lib/i18n/client'

export type LedgerTableRow = {
    id: string
    entryDate: string
    /** TABLE-EXPORT-3b:原始 YYYY-MM-DD(合计行 null),导出写真日期。 */
    entryYmd: string | null
    entryCode: string
    entryHref: string | null
    reversed: boolean
    sourceLabel: string
    sourceHref: string | null
    /** 对方科目,已在服务端按 locale 取好名字。 */
    counterparts: readonly { code: string; name: string }[]
    memo: string
    amountText: string
    /** TABLE-EXPORT-3b:原始金额(受限时 null),导出用。 */
    amount: number | null
    negative: boolean
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
    /** U1-A(UNBLOCK-1 Q1):工资分录那一行的金额对不持 data.view_pay 的人受限 —— 印「受限」,不印 0.00。合计不受限(它是发生额)。 */
    restricted?: boolean
}

export default function LedgerRowsTable({
    rows,
    amountHeader,
    empty,
    title,
    aboutExtra,
}: {
    rows: readonly LedgerTableRow[]
    /** TABLE-EXPORT-3b:导出的表名(页面标题)与 About 上多写的几行(科目、区间)。 */
    title: string
    aboutExtra: ReadonlyArray<[string, string]>
    /** 金额({ccy}) —— 本位币由服务端插好。 */
    amountHeader: string
    empty: string
}) {
    const t = useTranslations()

    // ★ TABLE-EXPORT-3b:一对导出。合计行(标签在【分录号】一列)排最后照屏幕导出;它不受限(account_ledger「合计不遮」)。
    const columns: ExportableColumn<LedgerTableRow>[] = [
        {
            key: 'date',
            header: t('finance.colDate'),
            className: 'whitespace-nowrap',
            render: (r) => r.entryDate,
            exportAs: (r) => xDate(r.entryYmd),
        },
        {
            key: 'entry',
            header: t('finance.ledgerColEntry'),
            // ★ 身份列 —— 这一页存在的意义就是从数字追到分录。
            priority: true,
            className: 'text-sm',
            render: (r) =>
                r.isTotal ? (
                    <span className="font-sans">{r.entryCode}</span>
                ) : (
                    <>
                        {r.entryHref ? (
                            <Link href={r.entryHref} className="hover:underline app-link">
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
            // 链接导出它的字;「已冲销」小标改变这一行的意思 → 接在分录号后面(FormulasTable 的 rowInactive 同形)
            exportAs: (r) => xText(r.reversed ? `${r.entryCode} (${t('table.export.rowReversed')})` : r.entryCode),
        },
        {
            key: 'source',
            header: t('finance.colSource'),
            className: 'text-sm',
            render: (r) =>
                r.sourceHref ? (
                    <Link href={r.sourceHref} className="hover:underline app-link">
                        {r.sourceLabel}
                    </Link>
                ) : (
                    r.sourceLabel
                ),
            exportAs: (r) => xText(r.isTotal ? null : r.sourceLabel),
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
                              <span>{c.code}</span> {c.name}
                          </span>
                      )),
            // 一格里可能有几个对方科目 → 「代码 名称」以 "; " 连起来
            exportAs: (r) => xText(r.counterparts.length === 0
                ? (r.isTotal ? null : '—')
                : r.counterparts.map((c) => `${c.code} ${c.name}`).join('; ')),
        },
        {
            key: 'memo',
            header: t('finance.colMemo'),
            className: 'text-sm text-gray-600',
            render: (r) => r.memo,
            exportAs: (r) => xText(r.isTotal ? null : r.memo),
        },
        {
            key: 'amount',
            header: amountHeader,
            align: 'right',
            // ★ 被追问的那个数。
            priority: true,
            className: 'text-sm',
            render: (r) =>
                r.restricted ? <Refusal>{t('common.restricted')}</Refusal>
                    : r.negative ? <span className="text-red-600">{r.amountText}</span> : r.amountText,
            // 表头带着本位币 → 光数字;受限与屏幕同一条判据(restricted)
            exportAs: (r) => (r.restricted ? xRestricted : xMoney(r.amount)),
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
            exportSpec={{ name: 'finance-account-ledger-lines', title, aboutExtra }}
        />
    )
}
