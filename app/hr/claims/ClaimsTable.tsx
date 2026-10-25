'use client'

// app/hr/claims/ClaimsTable.tsx
// CONV-5 · 医疗报销登记簿那张表。
// settlement_state 来自 medical_claim_status —— 它从【已过账的付款】推导"钱到底
// 付了没有",而不是相信报销单自己的状态列。这里只画它,不重算它。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate, xMoney, xMasked } from '@/lib/export/cells'
import { Refusal } from '@/app/components/ui/refusal'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

export type ClaimRow = {
    claimId: string
    code: string
    employeeLabel: string
    claimDate: string
    /** TABLE-EXPORT-1:导出用的原始日历日;null = 没有日期。 */
    claimDateRaw: string | null
    /** U1-A(UNBLOCK-1 Q8):不持 data.view_health 的人(本人的除外)是 null */
    amountSgd: string | null
    /** TABLE-EXPORT-1:导出用的原始金额(一个数,不是「12.00 SGD」);受限时同样是 null。 */
    amountSgdRaw: number | string | null
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

export default function ClaimsTable({ rows, empty, exportUrl, sort, shown, total }: {
    rows: ClaimRow[]; empty: React.ReactNode; exportUrl: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(claimsRows.ts 的 CLAIMS_SORT) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【单号】与【状态】—— 单号是身份,而状态是这张登记簿存在的理由:
    //   它回答"这笔钱到底付了没有",那是读者打开这一页要问的那一件事。
    const columns: ExportableColumn<ClaimRow>[] = [
        {
            key: 'code', sortable: true, header: t('claims.code'), priority: true, className: 'text-xs',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/hr/claims/${r.claimId}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'employee', header: t('leave.employee'), render: (r) => r.employeeLabel, exportAs: (r) => xText(r.employeeLabel) },
        { key: 'date', sortable: true, header: t('claims.date'), render: (r) => r.claimDate, exportAs: (r) => xDate(r.claimDateRaw) },
        {
            key: 'amount', sortable: true, header: t('claims.amount'), align: 'right',
            // TABLE-EXPORT-1 Q3(健康一族,data.view_health):与屏幕同一条判据 —— amountSgd 为 null 就是「受限」
            //   币种:屏幕上这一格写着「… SGD」(列本身就叫 amount_sgd),导出跟着写同一个。
            exportAs: (r) => xMasked(r.amountSgdRaw, r.amountSgd !== null, (v) => xMoney(v, 'SGD')),
            render: (r) => (r.amountSgd === null ? <Refusal>{t('common.restricted')}</Refusal> : `${r.amountSgd} SGD`),
        },
        {
            key: 'state', sortable: true, header: t('claims.state'), priority: true,
            exportAs: (r) => xText(t(`claims.state_${r.settlementState}`)),
            render: (r) => (
                <span className={`rounded px-2 py-0.5 text-xs ${CLS[r.settlementState ?? ''] ?? ''}`}>
                    {t(`claims.state_${r.settlementState}`)}
                </span>
            ),
        },
        { key: 'expense', sortable: true, header: t('claims.expense'), className: 'text-xs', render: (r) => r.expenseCode, exportAs: (r) => xText(r.expenseCode) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.claimId}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'hr-medical-claims', title: t('hr.subnav.claims'), serverRows: exportUrl }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
        />
    )
}
