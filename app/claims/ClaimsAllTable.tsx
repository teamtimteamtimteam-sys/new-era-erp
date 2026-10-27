'use client'

// app/claims/ClaimsAllTable.tsx
// SYSTEM-MAP-1(Tim D2 · Q2):两种报销一张表。手机上留【种类】【单号】【状态】—— 单号是身份,种类决定它去哪儿批,状态是来看这一页要问的那件事。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { Refusal } from '@/app/components/ui/refusal'
import { xText, xDate, xMoney, xMasked } from '@/lib/export/cells'

export type ClaimsAllRow = {
    key: string
    kind: 'medical' | 'general'
    code: string
    /** 去处;null = 读者进不去那一页(缺 linkCode),单号照印、不画成链接 */
    href: string | null
    linkCode: string
    employee: string
    date: string
    dateRaw: string | null
    /** null = 受限(医疗金额要 data.view_health,本人的除外) */
    amount: number | null
    currency: string
    state: string
}

const money = (n: number) => n.toFixed(2)

export default function ClaimsAllTable({ rows, empty }: { rows: ClaimsAllRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const kindLabel = (r: ClaimsAllRow) => (r.kind === 'medical' ? t('claimsAll.kindMedical') : t('claimsAll.kindGeneral'))
    const columns: ExportableColumn<ClaimsAllRow>[] = [
        { key: 'kind', header: t('claimsAll.colKind'), priority: true, render: kindLabel, exportAs: (r) => xText(kindLabel(r)) },
        {
            key: 'code', header: t('claims.code'), priority: true, exportAs: (r) => xText(r.code),
            render: (r) => r.href
                ? <Link href={r.href} className="hover:underline app-link" data-claim-link={r.kind}>{r.code}</Link>
                : <span title={t('claimsAll.noLink', { code: r.linkCode })} data-claim-link="none">{r.code}</span>,
        },
        { key: 'employee', header: t('leave.employee'), render: (r) => r.employee, exportAs: (r) => xText(r.employee) },
        { key: 'date', header: t('claims.date'), render: (r) => r.date, exportAs: (r) => xDate(r.dateRaw) },
        {
            key: 'amount', header: t('claims.amount'), align: 'right',
            // TABLE-FEATURES-1 规矩 5:两种报销各有各的币种,又没有本位币那一列 —— 不可排
            sortable: false,
            exportAs: (r) => xMasked(r.amount, r.amount !== null, (v) => xMoney(v, r.currency)),
            render: (r) => (r.amount === null
                ? <Refusal>{t('common.restricted')}</Refusal>
                : `${money(r.amount)} ${r.currency}`),
        },
        { key: 'state', header: t('claims.state'), priority: true, render: (r) => r.state, exportAs: (r) => xText(r.state) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'claims-all', title: t('claimsAll.title') }}
        // 两张视图各读一次、在服务端合并 —— 在浏览器里排(读满 1,000 行时 DataTable 自己关掉并说出来)
        sorting={{ mode: 'client', coverage: 'complete' }} />
}
