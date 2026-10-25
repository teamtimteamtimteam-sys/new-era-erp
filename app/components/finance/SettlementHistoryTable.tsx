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
//
// ★ TABLE-EXPORT-3c(Tim 2026-10-25):一对导出,四个调用点共用这一对。
//   导出读【原始值】:日期 paymentDateRaw(YYYY-MM-DD)、金额 allocated + currency(屏幕上那一格写着币种,导出照样带上)。
//   发灰与删除线导不出去 ——「这一条被冲销了」只靠【状态】那一列的字说出来,所以状态列导出的是那枚徽章上的字,一个都不省。
//   合计行(Tim 3b Q1)照屏幕作为最后一行导出:标签在付款单那一列,日期与状态是空格。
//   标题与 About 那一行(单据号)由调用方给 —— 发票页这一块叫「收款情况」,另外三页叫「结算历史」。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'
import { xDate, xMoney, xText } from '@/lib/export/cells'

export type SettlementRow = {
    id: string
    paymentCode: string
    paymentHref: string | null
    paymentDate: string
    allocatedText: string
    /** TABLE-EXPORT-3c(Tim 2026-10-25):上面两串是格式化过的字;导出要日期本身(YYYY-MM-DD,合计行 null)与金额本身 + 它的币种。 */
    paymentDateRaw: string | null
    allocated: number
    currency: string
    reversed: boolean
    /** 合计行。见 CONV-4 §⑨-3 / CONV-8 §⑧。 */
    isTotal?: boolean
}

export default function SettlementHistoryTable({
    rows,
    exportTitle,
    record,
}: {
    rows: readonly SettlementRow[]
    /** TABLE-EXPORT-3c:导出的 About 表与工作表名 = 这一块在页面上的标题(界面语言)。 */
    exportTitle: string
    /** TABLE-EXPORT-3c:About 表多写的一行 —— [标签, 单据号],说明这份文件出自哪一张单据。 */
    record: [string, string]
}) {
    const t = useTranslations()

    const columns: ExportableColumn<SettlementRow>[] = [
        {
            key: 'payment',
            header: t('finance.colPayment'),
            // 身份列 —— 一条结算行的主语是"哪一笔付款"。
            priority: true,
            className: 'text-sm',
            render: (r) =>
                r.isTotal ? (
                    r.paymentCode
                ) : r.paymentHref ? (
                    <Link
                        href={r.paymentHref}
                        className={
                            r.reversed
                                ? 'text-gray-400 hover:underline line-through'
                                : 'app-link hover:underline'
                        }
                    >
                        {r.paymentCode}
                    </Link>
                ) : (
                    '—'
                ),
            exportAs: (r) => xText(r.paymentCode),
        },
        {
            key: 'date',
            header: t('finance.paymentDate'),
            render: (r) => r.paymentDate,
            exportAs: (r) => xDate(r.paymentDateRaw),
        },
        {
            key: 'allocated',
            header: t('finance.colAllocated'),
            align: 'right',
            // ★ 这张表存在的理由:**这一笔结掉了多少**。
            priority: true,
            className: 'text-sm',
            render: (r) => (r.reversed ? <span className="line-through">{r.allocatedText}</span> : r.allocatedText),
            // 已冲销的那一行照样导出它的金额(屏幕上是划掉的数,不是空)—— 它不计入合计,由状态列说明为什么
            exportAs: (r) => xMoney(r.allocated, r.currency),
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
            // 屏幕只用徽章 + 发灰说「已冲销」;导出把徽章上的字写成一格(合计行这一格屏幕上是空的,导出也空)
            exportAs: (r) =>
                xText(r.isTotal ? null : r.reversed ? t('finance.reversedMark') : t('finance.status.posted')),
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
            exportSpec={{ name: 'finance-settlement-history', title: exportTitle, aboutExtra: [record] }}
        />
    )
}
