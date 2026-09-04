'use client'

// app/components/finance/SettlementHistoryTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 结算历史 —— AP 与 AR 【共用同一张表】
// ════════════════════════════════════════════════════════════════════════════
//
// ★【已冲销的付款【留在表里】,发灰加删除线 —— 转换前就是这样,没有被压平】★
// 它们不计入已结额(与 ap_open_items 口径一致),但把它们删掉会让"这张单为什么
// 还欠这么多"变成一个没有证据的断言。整行发灰走 CONV-4 §⑨-3 的 rowClassName;
// 删除线只加在【付款单号】与【金额】两格上 —— 状态徽章本身不该被划掉,
// 它正是在说"这一条被冲销了"。
//
// ★【为什么它住在 app/components/finance/,而不是各自的路由目录里】★
// /finance/payables/[batchId] 与 /finance/receivables/[saleId] 的结算历史表
// **逐列相同**:付款单 · 日期 · 冲销额 · 状态,同一批 i18n 键,同一条
// 「已冲销的行留下但不计入已结额」的规矩。这不是两张相似的表,是同一张。
//
// 【这不违反"第三次才建"那道坎 —— 那条坎管的是【设计一个新能力】】
// 本仓库的门槛(rowClassName 第 5 处才建、add-a-row 数到 4 处仍不建)拦的是
// **照着太少的例子去设计一个抽象**。这里没有任何设计:同一个组件、两个调用点,
// 而 app/components/finance/ 已经是这一族共用件的现成住址(FinanceAttachmentsPanel
// 就在隔壁,同样被这两页共用)。**把它抄两份才是要付账的那件事。**
//
// 【行数据在服务端压平】金额格式要 baseCurrency,只有服务端知道。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type SettlementRow = {
    id: string
    paymentCode: string
    paymentHref: string | null
    paymentDate: string
    allocatedText: string
    reversed: boolean
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
}

export default function SettlementHistoryTable({ rows }: { rows: readonly SettlementRow[] }) {
    const t = useTranslations()

    const columns: Column<SettlementRow>[] = [
        {
            key: 'payment',
            header: t('finance.colPayment'),
            // 身份列 —— 一条结算行的主语是"哪一笔付款"。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) =>
                r.isTotal ? (
                    r.paymentCode
                ) : r.paymentHref ? (
                    <Link
                        href={r.paymentHref}
                        className={
                            r.reversed
                                ? 'text-gray-400 hover:underline line-through'
                                : 'text-blue-600 hover:underline'
                        }
                    >
                        {r.paymentCode}
                    </Link>
                ) : (
                    '—'
                ),
        },
        {
            key: 'date',
            header: t('finance.paymentDate'),
            render: (r) => r.paymentDate,
        },
        {
            key: 'allocated',
            header: t('finance.colAllocated'),
            align: 'right',
            // ★ 这张表存在的理由:**这一笔结掉了多少**。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (r.reversed ? <span className="line-through">{r.allocatedText}</span> : r.allocatedText),
        },
        {
            key: 'status',
            header: t('finance.colStatus'),
            render: (r) =>
                r.isTotal ? (
                    ''
                ) : r.reversed ? (
                    <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-500">
                        {t('finance.reversedMark')}
                    </span>
                ) : (
                    <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                        {t('finance.status.posted')}
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
            rowClassName={(r) =>
                r.isTotal
                    ? 'font-bold bg-[color:var(--brand-muted)]'
                    : r.reversed
                      ? 'text-gray-400'
                      : undefined
            }
            empty={t('finance.noOpenItems')}
        />
    )
}
