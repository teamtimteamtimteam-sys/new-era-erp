'use client'

// app/operation/blending/BlendingPlansTable.tsx
// MES-5b-3 · 配料计划列表那张表。手机上留【编号】与【状态】—— 编号是身份,状态是这一页的问题(哪几份在等放行、等执行)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'

export type BlendingPlanRow = {
    id: string
    code: string
    statusLabel: string
    material: string
    createdLabel: string
    /** TABLE-EXPORT-1:导出用的原始时刻(Excel 里是真日期,按新加坡时间)。 */
    createdAt: string
    run: { id: string; code: string } | null
    notes: string
    /** TABLE-EXPORT-1:导出用的原始值 —— 物料没查到 / 没写备注时是 null(屏幕上那个「—」不是一个词,导出留空)。 */
    materialText: string | null
    notesText: string | null
}

export default function BlendingPlansTable({ rows, empty }: { rows: BlendingPlanRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<BlendingPlanRow>[] = [
        {
            key: 'code', header: t('blending.colCode'), priority: true, exportAs: (r) => xText(r.code),
            render: (r) => <Link href={`/operation/blending/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'status', header: t('blending.colStatus'), priority: true, exportAs: (r) => xText(r.statusLabel),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        { key: 'material', header: t('blending.colOutputMaterial'), render: (r) => r.material, exportAs: (r) => xText(r.materialText) },
        { key: 'created', header: t('blending.colCreated'), render: (r) => r.createdLabel, exportAs: (r) => xTime(r.createdAt) },
        {
            key: 'run', header: t('blending.colRun'), exportAs: (r) => xText(r.run?.code ?? null),
            render: (r) => r.run
                ? <Link href={`/operation/processing/${r.run.id}`} className="hover:underline app-link">{r.run.code}</Link>
                : <span className="text-gray-500">—</span>,
        },
        { key: 'notes', header: t('blending.colNotes'), className: 'text-gray-600', render: (r) => r.notes, exportAs: (r) => xText(r.notesText) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
                      exportSpec={{ name: 'operation-blending-plans', title: t('blending.listTitle') }} />
}
