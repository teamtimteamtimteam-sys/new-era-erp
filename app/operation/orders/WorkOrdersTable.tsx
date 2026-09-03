'use client'

// app/operation/orders/WorkOrdersTable.tsx
// CONV-5 · 工单列表那张表。
// 【完成度是【读】出来的,不是存下来的】那一列由服务端从 work_order_fulfilment
// 汇总好再传进来 —— 工单表里刻意没有"完成度"这种字段,列描述符也不该重算它。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type WorkOrderRow = {
    id: string
    code: string
    statusLabel: string
    /** null = 没排期。空是一个答案,不画成一个日期。 */
    scheduledLabel: string | null
    /** null = 没有可算的完成度(没有计划投入) */
    progressLabel: string | null
    unplannedMaterials: number
    notes: string
}

export default function WorkOrdersTable({ rows, empty }: { rows: WorkOrderRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【工单号】与【完成度】—— 工单号是身份,完成度是这一页作为
    //   "计划这一侧的入口"存在的理由(还差多少没投)。排期与备注进展开区。
    const columns: Column<WorkOrderRow>[] = [
        {
            key: 'code', header: t('processing.wo.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/operation/orders/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', header: t('processing.wo.colStatus'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        {
            key: 'scheduled', header: t('processing.wo.colScheduled'),
            // 【没排期就说"没排期",不画成一个日期】空是一个答案
            render: (r) =>
                r.scheduledLabel ?? <span className="text-gray-500 italic">{t('processing.wo.noSchedule')}</span>,
        },
        {
            key: 'progress', header: t('processing.wo.colProgress'), priority: true, align: 'right',
            className: 'font-mono text-sm',
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
        { key: 'notes', header: t('processing.wo.colNotes'), className: 'text-sm text-gray-600', render: (r) => r.notes },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
