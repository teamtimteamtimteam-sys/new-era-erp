'use client'

// app/operation/blending/BlendingPlansTable.tsx
// MES-5b-3 · 配料计划列表那张表。手机上留【编号】与【状态】—— 编号是身份,状态是这一页的问题(哪几份在等放行、等执行)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type BlendingPlanRow = {
    id: string
    code: string
    statusLabel: string
    material: string
    createdLabel: string
    run: { id: string; code: string } | null
    notes: string
}

export default function BlendingPlansTable({ rows, empty }: { rows: BlendingPlanRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<BlendingPlanRow>[] = [
        {
            key: 'code', header: t('blending.colCode'), priority: true,
            render: (r) => <Link href={`/operation/blending/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'status', header: t('blending.colStatus'), priority: true,
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.statusLabel}</span>,
        },
        { key: 'material', header: t('blending.colOutputMaterial'), render: (r) => r.material },
        { key: 'created', header: t('blending.colCreated'), render: (r) => r.createdLabel },
        {
            key: 'run', header: t('blending.colRun'),
            render: (r) => r.run
                ? <Link href={`/operation/processing/${r.run.id}`} className="hover:underline app-link">{r.run.code}</Link>
                : <span className="text-gray-500">—</span>,
        },
        { key: 'notes', header: t('blending.colNotes'), className: 'text-gray-600', render: (r) => r.notes },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
