'use client'

// app/finance/self-approved/SelfApprovedTable.tsx
// APR-ROUTE-1(R2):自批记录那张表。行在服务端已经格式化好(时间、金额、种类名),
// 这里只负责摆放。
// ★ 手机上留【单据】与【决定人】—— 这张表回答的就是"谁批了谁的哪一张",
//   其余几栏进展开区。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xTime, xRestricted } from '@/lib/export/cells'
import { Refusal } from '@/app/components/ui/refusal'
import type { ListTotal } from '@/lib/listTotals'
import { totalsFooterRows } from '@/app/components/ui/list-totals'

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
    /** U1-B:一张医疗报销的金额对不持 data.view_health(又不是本人)的读者是受限 —— 印「受限」,不印 —。 */
    amountRestricted: boolean
    note: string
    /** U1-B:同一个判据下的说明(批准 / 驳回的理由)。受限 ≠ 空着。 */
    noteRestricted: boolean
    // TABLE-EXPORT-2a:导出读原始值
    decidedAtRaw: string
    amountCcy: number | null
    currency: string | null
}

export default function SelfApprovedTable({ rows, empty, totals }: {
    rows: SelfApprovedRow[]; empty: React.ReactNode
    /** TABLE-FEATURES-2(Tim Q1):库算的合计(list_totals_self_approved)—— 每个币种一行;有一笔看不见就是「受限」 */
    totals: ListTotal[]
}) {
    const t = useTranslations()
    const columns: ExportableColumn<SelfApprovedRow>[] = [
        { key: 'decidedAt', header: t('finance.selfApproved.colDecidedAt'), render: (r) => r.decidedAt, exportAs: (r) => xTime(r.decidedAtRaw) },
        {
            key: 'document', header: t('finance.selfApproved.colDocument'), priority: true,
            exportAs: (r) => xText(`${r.kind} · ${r.code}`),
            render: (r) => (
                <>
                    {r.kind} · {r.href ? <Link href={r.href} className="underline">{r.code}</Link> : r.code}
                </>
            ),
        },
        { key: 'decision', header: t('finance.selfApproved.colDecision'), render: (r) => r.decision, exportAs: (r) => xText(r.decision) },
        { key: 'decider', header: t('finance.selfApproved.colDecider'), priority: true, render: (r) => r.decider, exportAs: (r) => xText(r.decider) },
        { key: 'subject', header: t('finance.selfApproved.colSubject'), render: (r) => r.subject, exportAs: (r) => xText(r.subject) },
        // TABLE-FEATURES-1 Q9(规矩 5):各行币种不同,又没有本位币那一列 —— 不可排
        { key: 'amount', header: t('finance.selfApproved.colAmount'), align: 'right', sortable: false, render: (r) => (r.amountRestricted ? <Refusal>{t('common.restricted')}</Refusal> : r.amount),
            // 与屏幕同一个判据(amountRestricted,健康那一族):受限写「受限」,否则是带币种的数
            exportAs: (r) => (r.amountRestricted ? xRestricted : xMoney(r.amountCcy, r.currency)) },
        { key: 'note', header: t('finance.selfApproved.colNote'), render: (r) => (r.noteRestricted ? <Refusal>{t('common.restricted')}</Refusal> : r.note),
            exportAs: (r) => (r.noteRestricted ? xRestricted : xText(r.note)) },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.seq}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'self-approved-decisions', title: t('finance.selfApproved.title') }}
            // TABLE-FEATURES-1 Q9:self_approved_decisions 一次读全 —— 在浏览器里排
            sorting={{ mode: 'client', coverage: 'complete' }}
            footer={() => totalsFooterRows(totals, { amount: 'amount' }, t)}
        />
    )
}
