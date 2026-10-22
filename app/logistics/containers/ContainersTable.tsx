'use client'

// app/logistics/containers/ContainersTable.tsx
// CONV-5 · 集装箱名单那张表。
// 【单据那一栏:三种状态三句话,不折叠成一个数字】—— 那三句话在服务端算好
// 再传进来,列描述符不重新实现 lane_checklist_state 的判据。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xInt, xDate } from '@/lib/export/cells'

export type ContainerRow = {
    id: string
    code: string
    containerNumber: string
    laneLabel: string
    vessel: string
    departureDate: string
    /** TABLE-EXPORT-1:导出用的原始日历日(YYYY-MM-DD);null = 没填,屏幕上是「—」。 */
    departureDateRaw: string | null
    /** null = 没有里程碑。空是一个答案。 */
    milestoneLabel: string | null
    shipmentCount: string
    /** TABLE-EXPORT-1:导出用的原始件数。 */
    shipmentCountNum: number
    /** 单据栏三种状态之一的成品文案 + 它该用的颜色。 */
    docsLabel: string
    docsTone: 'warn' | 'muted' | 'plain' | 'none'
}

const TONE: Record<ContainerRow['docsTone'], string> = {
    warn: 'text-amber-900',
    muted: 'text-gray-600',
    none: 'text-gray-500',
    plain: '',
}

export default function ContainersTable({ rows, empty }: { rows: ContainerRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【箱号】与【最新里程碑】—— 箱号是身份;而这张名单被打开是为了
    //   知道"这只箱现在到哪了",里程碑就是那个答案。单据/件数进展开区。
    // TABLE-EXPORT-1:开航日是真日期,件数是整数;单据一格导出那三句话之一(与屏幕同一句)。
    const columns: ExportableColumn<ContainerRow>[] = [
        {
            key: 'code', header: t('logistics.colContainerCode'), priority: true,
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/logistics/containers/${r.id}`} className="hover:underline text-xs app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'number', header: t('logistics.colContainerNumber'), className: 'text-xs', render: (r) => r.containerNumber, exportAs: (r) => xText(r.containerNumber) },
        { key: 'lane', header: t('logistics.colLane'), render: (r) => r.laneLabel, exportAs: (r) => xText(r.laneLabel) },
        { key: 'vessel', header: t('logistics.colVessel'), render: (r) => r.vessel, exportAs: (r) => xText(r.vessel) },
        { key: 'departure', header: t('logistics.colDeparture'), render: (r) => r.departureDate, exportAs: (r) => xDate(r.departureDateRaw) },
        {
            key: 'milestone', header: t('logistics.colLatestMilestone'), priority: true,
            exportAs: (r) => xText(r.milestoneLabel),
            render: (r) => r.milestoneLabel ?? <span className="text-gray-500">—</span>,
        },
        { key: 'shipments', header: t('logistics.colShipments'), align: 'right', render: (r) => r.shipmentCount, exportAs: (r) => xInt(r.shipmentCountNum) },
        {
            key: 'docs', header: t('logistics.colDocuments'),
            exportAs: (r) => xText(r.docsLabel),
            render: (r) => <span className={TONE[r.docsTone]}>{r.docsLabel}</span>,
        },
    ]

    return (
        <DataTable
            rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
            exportSpec={{ name: 'logistics-containers', title: t('logistics.containersTitle') }}
        />
    )
}
