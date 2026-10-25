'use client'

// app/operation/orders/WorkOrdersTable.tsx
// CONV-5 · 工单列表那张表。
// 【完成度是【读】出来的,不是存下来的】那一列由服务端从 work_order_fulfilment
// 汇总好再传进来 —— 工单表里刻意没有"完成度"这种字段,列描述符也不该重算它。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate } from '@/lib/export/cells'

export type WorkOrderRow = {
    id: string
    code: string
    statusLabel: string
    /** null = 没排期。空是一个答案,不画成一个日期。 */
    scheduledLabel: string | null
    /** null = 没有可算的完成度(没有计划投入) */
    progressLabel: string | null
    /** TABLE-FEATURES-1 Q9:排序用的完成度(投了 ÷ 计划);没有可算的完成度时是 null(排在最后)。 */
    progressRatio: number | null
    unplannedMaterials: number
    notes: string
    /** TABLE-EXPORT-1:导出用的原始值 —— 排期 `YYYY-MM-DD`(没排期是 null)、备注(没写是 null,屏幕上那个「—」不是一个词)。 */
    scheduledDate: string | null
    notesText: string | null
}

export default function WorkOrdersTable({ rows, empty }: { rows: WorkOrderRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【工单号】与【完成度】—— 工单号是身份,完成度是这一页作为
    //   "计划这一侧的入口"存在的理由(还差多少没投)。排期与备注进展开区。
    const columns: ExportableColumn<WorkOrderRow>[] = [
        {
            key: 'code', header: t('processing.wo.colCode'), priority: true, className: 'text-sm', exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/operation/orders/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', header: t('processing.wo.colStatus'), exportAs: (r) => xText(r.statusLabel),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        {
            key: 'scheduled', header: t('processing.wo.colScheduled'),
            exportAs: (r) => (r.scheduledDate ? xDate(r.scheduledDate) : xText(t('processing.wo.noSchedule'))),
            // 【没排期就说"没排期",不画成一个日期】空是一个答案
            render: (r) =>
                r.scheduledLabel ?? <span className="text-gray-500 italic">{t('processing.wo.noSchedule')}</span>,
        },
        {
            key: 'progress', header: t('processing.wo.colProgress'), priority: true, align: 'right',
            className: 'text-sm', sortValue: (r) => r.progressRatio,
            // 一格两样(投了 / 计划 · 计划外物料几种)—— 导出同一句,一格文字
            exportAs: (r) => xText([r.progressLabel,
                r.unplannedMaterials > 0 ? t('processing.wo.unplannedMaterials', { n: String(r.unplannedMaterials) }) : null]
                .filter(Boolean).join(' · ') || null),
            render: (r) => (
                <>
                    {r.progressLabel ?? <span className="text-gray-500">—</span>}
                    {r.unplannedMaterials > 0 && (
                        <span className="ml-2 text-xs text-amber-700">
                            {t('processing.wo.unplannedMaterials', { n: String(r.unplannedMaterials) })}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'notes', header: t('processing.wo.colNotes'), className: 'text-sm text-gray-600', render: (r) => r.notes, exportAs: (r) => xText(r.notesText) },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
                   exportSpec={{ name: 'operation-work-orders', title: t('processing.wo.listTitle') }}
                   // TABLE-FEATURES-1 Q9:一次读取拿到全体 —— 在浏览器里排
                   sorting={{ mode: 'client', coverage: 'complete' }} />
    )
}
