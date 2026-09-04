'use client'

// app/finance/assets/[id]/CostEntriesTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-9(2026-09-04)· 一台设备的成本从哪几张单据来
// ════════════════════════════════════════════════════════════════════════════
//
// ★【已冲销的行留着但不算数】EQP-1b-iii:它退回了成本,而这一行是
//   "它曾经在这里"的痕迹。整行发灰加删除线走 rowClassName(CONV-4 §⑨-3),
//   与转换前逐字同形。
//
// ★【手机上留【单据】与【本位币金额】】★
// 身份是那张支出单(它可点、可追);而这张表存在的理由是"这台机器一共花了多少",
// 那个数是本位币那一列 —— 原币列是它的出处,进展开区。
//
// 【行数据在服务端压平】金额格式要 baseCurrency 与每行自己的 currency,
// 而"这一行是不是已冲销"要读嵌套的 expenses.status —— 都只有服务端知道。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { useTranslations } from '@/lib/i18n/client'

export type CostEntryRow = {
    id: string
    expenseCode: string
    expenseHref: string
    expenseDate: string
    amountCcyText: string
    amountBaseText: string
    reversed: boolean
}

export default function CostEntriesTable({ rows }: { rows: readonly CostEntryRow[] }) {
    const t = useTranslations()

    const columns: Column<CostEntryRow>[] = [
        {
            key: 'expense',
            header: t('assets.detail.colExpense'),
            // 身份列 —— 一行成本的主语是那张支出单。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (
                <Link href={r.expenseHref} className="text-blue-600 underline">
                    {r.expenseCode}
                </Link>
            ),
        },
        {
            key: 'date',
            header: t('assets.detail.colDate'),
            className: 'text-sm',
            render: (r) => r.expenseDate,
        },
        {
            key: 'amountCcy',
            header: t('assets.detail.colAmountCcy'),
            align: 'right',
            className: 'text-sm',
            render: (r) => r.amountCcyText,
        },
        {
            key: 'amountBase',
            header: t('assets.detail.colAmountBase'),
            align: 'right',
            // ★ 这张表存在的理由:这台机器一共花了多少(本位币)。
            priority: true,
            className: 'text-sm',
            render: (r) => r.amountBaseText,
        },
        {
            key: 'state',
            header: t('assets.detail.colState'),
            className: 'text-sm',
            render: (r) => (r.reversed ? t('assets.detail.entryReversed') : t('assets.detail.entryLive')),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            rowClassName={(r) => (r.reversed ? 'text-gray-400 line-through' : undefined)}
            empty={t('assets.detail.noCostEntries')}
        />
    )
}
