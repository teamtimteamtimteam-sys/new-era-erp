'use client'

// app/finance/gst/GstPeriodsTable.tsx
// CONV-4 · 申报期间登记簿。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type GstPeriodRow = {
    id: string
    code: string
    isCorrection: boolean
    window: string
    filed: boolean
    filedOn: string | null
    filedReference: string | null
}

export default function GstPeriodsTable({ rows }: { rows: GstPeriodRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【期间】与【状态】—— 期间是身份,状态是这张登记簿存在的理由。
    const columns: Column<GstPeriodRow>[] = [
        {
            key: 'period', header: t('gst.period'), priority: true,
            render: (r) => (
                <>
                    <Link href={`/finance/gst/${r.id}`} className="text-blue-600 hover:underline font-mono">{r.code}</Link>
                    {r.isCorrection && <span className="ml-2 text-xs text-amber-800">{t('gst.isCorrection')}</span>}
                </>
            ),
        },
        { key: 'window', header: t('gst.window'), className: 'font-mono text-xs', render: (r) => r.window },
        {
            key: 'status', header: t('gst.status'), priority: true,
            render: (r) => (r.filed ? t('gst.statusFiled') : t('gst.statusOpen')),
        },
        {
            key: 'filing', header: t('gst.filing'), className: 'text-xs',
            render: (r) =>
                r.filed ? (
                    <>{r.filedOn} {r.filedReference ? `· ${r.filedReference}` : ''}</>
                ) : (
                    <span className="text-gray-500">{t('gst.notFiledYet')}</span>
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('gst.noPeriods')}
        />
    )
}
