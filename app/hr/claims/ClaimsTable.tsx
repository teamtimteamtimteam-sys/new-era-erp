'use client'

// app/hr/claims/ClaimsTable.tsx
// CONV-5 · 医疗报销登记簿那张表。
// settlement_state 来自 medical_claim_status —— 它从【已过账的付款】推导"钱到底
// 付了没有",而不是相信报销单自己的状态列。这里只画它,不重算它。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ClaimRow = {
    claimId: string
    code: string
    employeeLabel: string
    claimDate: string
    amountSgd: string
    settlementState: string
    expenseCode: string
}

const CLS: Record<string, string> = {
    submitted: 'bg-amber-100 text-amber-800',
    approved: 'bg-blue-100 text-blue-800',
    rejected: 'bg-red-100 text-red-800',
    expense_raised: 'bg-purple-100 text-purple-800',
    awaiting_payment_run: 'bg-blue-100 text-blue-800',
    part_paid: 'bg-purple-100 text-purple-800',
    paid: 'bg-green-100 text-green-800',
}

export default function ClaimsTable({ rows, empty }: { rows: ClaimRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【状态】—— 单号是身份,而状态是这张登记簿存在的理由:
    //   它回答"这笔钱到底付了没有",那是读者打开这一页要问的那一件事。
    const columns: Column<ClaimRow>[] = [
        {
            key: 'code', header: t('claims.code'), priority: true, className: 'font-mono text-xs',
            render: (r) => (
                <Link href={`/hr/claims/${r.claimId}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'employee', header: t('leave.employee'), render: (r) => r.employeeLabel },
        { key: 'date', header: t('claims.date'), render: (r) => r.claimDate },
        { key: 'amount', header: t('claims.amount'), align: 'right', className: 'font-mono', render: (r) => `${r.amountSgd} SGD` },
        {
            key: 'state', header: t('claims.state'), priority: true,
            render: (r) => (
                <span className={`rounded px-2 py-0.5 text-xs ${CLS[r.settlementState ?? ''] ?? ''}`}>
                    {t(`claims.state_${r.settlementState}`)}
                </span>
            ),
        },
        { key: 'expense', header: t('claims.expense'), className: 'font-mono text-xs', render: (r) => r.expenseCode },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.claimId}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
