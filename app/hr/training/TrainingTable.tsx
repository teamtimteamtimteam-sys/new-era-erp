'use client'

// app/hr/training/TrainingTable.tsx
// CONV-5 · 培训记录登记簿那张表。
// 【到期状态在服务端算好】expired / soon 是拿"今天"和 90 天档口比出来的,
// 那两个日期只有服务端知道得准 —— 客户端只画它算完的结果(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteTrainingButton from './DeleteTrainingButton'
import { Button } from '@/app/components/ui/button'

export type TrainingRow = {
    id: string
    employeeId: string | null
    employeeCode: string | null
    employeeName: string | null
    trainingName: string
    categoryLabel: string
    completedDate: string
    expiryDate: string | null
    expiryState: 'expired' | 'soon' | 'none'
    provider: string
    certificateRef: string
}

export default function TrainingTable({ rows, empty }: { rows: TrainingRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【员工】与【到期日】—— 员工是身份,而到期日是这张登记簿存在的
    //   理由:证书过期意味着这个人暂时不能上那道工序(见 page.tsx 抬头)。
    const columns: Column<TrainingRow>[] = [
        {
            key: 'employee', header: t('hr.colEmployee'), priority: true, className: 'text-sm',
            render: (r) =>
                r.employeeId ? (
                    <Link href={`/hr/employees/${r.employeeId}`} className="text-blue-600 hover:underline">
                        <span className="font-mono text-xs text-gray-500 mr-2">{r.employeeCode}</span>
                        {r.employeeName}
                    </Link>
                ) : (
                    '—'
                ),
        },
        { key: 'name', header: t('hr.colTrainingName'), render: (r) => r.trainingName },
        { key: 'category', header: t('hr.colCategory'), className: 'text-sm', render: (r) => r.categoryLabel },
        { key: 'completed', header: t('hr.colCompletedDate'), className: 'text-sm', render: (r) => r.completedDate },
        {
            key: 'expiry', header: t('hr.colExpiryDate'), priority: true,
            className: 'text-sm whitespace-nowrap',
            render: (r) => (
                <>
                    {r.expiryDate ?? '—'}
                    {r.expiryState === 'expired' && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-red-100 text-red-800">
                            {t('hr.severity.expired')}
                        </span>
                    )}
                    {r.expiryState === 'soon' && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                            {t('hr.expiringSoon')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'provider', header: t('hr.colProvider'), className: 'text-sm', render: (r) => r.provider },
        { key: 'cert', header: t('hr.colCertificateRef'), className: 'text-sm font-mono', render: (r) => r.certificateRef },
        {
            key: 'actions', header: t('metalPrices.colActions'), className: 'text-sm whitespace-nowrap',
            render: (r) => (
                <>
                    <Button asChild variant="link" size="inline" className="mr-3">
                        <Link href={`/hr/training/${r.id}/edit`}>
                            {t('purchasing.editLink')}
                        </Link>
                    </Button>
                    <DeleteTrainingButton id={r.id} name={r.trainingName} />
                </>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
