'use client'

// app/finance/gst/GstPeriodsTable.tsx
// CONV-4 · 申报期间登记簿。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText } from '@/lib/export/cells'

export type GstPeriodRow = {
    id: string
    code: string
    isCorrection: boolean
    window: string
    filed: boolean
    /** APR-10:四种状态 —— 等批准与已批准是申报申请带来的两格 */
    statusKey: 'open' | 'awaiting' | 'approved' | 'filed'
    filedOn: string | null
    filedReference: string | null
    /** TABLE-EXPORT-2a:申报日的原始日历日 */
    filedOnRaw: string | null
}

export default function GstPeriodsTable({ rows }: { rows: GstPeriodRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【期间】与【状态】—— 期间是身份,状态是这张登记簿存在的理由。
    const columns: ExportableColumn<GstPeriodRow>[] = [
        {
            key: 'period', header: t('gst.period'), priority: true,
            exportAs: (r) => xText(r.isCorrection ? `${r.code} (${t('gst.isCorrection')})` : r.code),
            render: (r) => (
                <>
                    <Link href={`/finance/gst/${r.id}`} className="hover:underline app-link">{r.code}</Link>
                    {r.isCorrection && <span className="ml-2 text-xs text-amber-800">{t('gst.isCorrection')}</span>}
                </>
            ),
        },
        // 期间窗口是一段日期,不是一个日子 —— 写成由原始日期拼出的文字(TABLE-EXPORT-1 同一个处置)
        { key: 'window', header: t('gst.window'), className: 'text-xs', render: (r) => r.window, exportAs: (r) => xText(r.window) },
        {
            key: 'status', header: t('gst.status'), priority: true,
            render: (r) => t('gstFiling.periodStatus.' + r.statusKey),
            exportAs: (r) => xText(t('gstFiling.periodStatus.' + r.statusKey)),
        },
        {
            key: 'filing', header: t('gst.filing'), className: 'text-xs',
            // 一格里是「申报日 · 申报号」两样 —— 照屏幕写成文字,日期取原始的 YYYY-MM-DD
            exportAs: (r) => xText(r.filed
                ? `${r.filedOnRaw ?? ''}${r.filedReference ? ` · ${r.filedReference}` : ''}`.trim()
                : t('gst.notFiledYet')),
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
            exportSpec={{ name: 'gst-periods', title: t('gst.periods') }}
        />
    )
}
