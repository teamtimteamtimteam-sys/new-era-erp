'use client'

// app/finance/self-approved/SelfApprovedTable.tsx
// APR-ROUTE-1(R2):自批记录那张表。行在服务端已经格式化好(时间、金额、种类名),
// 这里只负责摆放。
// ★ 手机上留【单据】与【决定人】—— 这张表回答的就是"谁批了谁的哪一张",
//   其余几栏进展开区。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type SelfApprovedRow = {
    seq: string
    decidedAt: string
    kind: string
    code: string
    href: string | null
    decision: string
    decider: string
    subject: string
    amount: string
    note: string
}

export default function SelfApprovedTable({ rows, empty }: { rows: SelfApprovedRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<SelfApprovedRow>[] = [
        { key: 'decidedAt', header: t('finance.selfApproved.colDecidedAt'), render: (r) => r.decidedAt },
        {
            key: 'document', header: t('finance.selfApproved.colDocument'), priority: true,
            render: (r) => (
                <>
                    {r.kind} · {r.href ? <Link href={r.href} className="underline">{r.code}</Link> : r.code}
                </>
            ),
        },
        { key: 'decision', header: t('finance.selfApproved.colDecision'), render: (r) => r.decision },
        { key: 'decider', header: t('finance.selfApproved.colDecider'), priority: true, render: (r) => r.decider },
        { key: 'subject', header: t('finance.selfApproved.colSubject'), render: (r) => r.subject },
        { key: 'amount', header: t('finance.selfApproved.colAmount'), align: 'right', render: (r) => r.amount },
        { key: 'note', header: t('finance.selfApproved.colNote'), render: (r) => r.note },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.seq}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
