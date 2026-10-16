'use client'

// app/safety/inspections/InspectionTables.tsx
// MES-7b-2 · 巡检那一页的两张表:清单(到期与否)与巡检。手机上留【代号 / 编号】与【到期 / 结果】—— 前者是身份,后者是这一页要人动手的那一格。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type TemplateRow = {
    id: string; code: string; name: string; area: string; frequency: string; items: number; lastRun: string; due: string; dueFlag: boolean; active: boolean
}
export type RunRow = {
    id: string; code: string; checklist: string; inspected: string; inspector: string; counts: string; findings: string; openFindings: boolean
    corrected: string | null
}

export function TemplatesTable({ rows, empty }: { rows: TemplateRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<TemplateRow>[] = [
        { key: 'code', header: t('safety.inspections.colTemplate'), priority: true,
          render: (r) => <Link href={`/safety/inspections/templates/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'name', header: t('safety.inspections.colName'), render: (r) => r.name },
        { key: 'area', header: t('safety.inspections.colArea'), render: (r) => r.area },
        { key: 'frequency', header: t('safety.inspections.colFrequency'), render: (r) => r.frequency },
        { key: 'items', header: t('safety.inspections.colItems'), render: (r) => String(r.items) },
        { key: 'last', header: t('safety.inspections.colLastRun'), render: (r) => r.lastRun },
        { key: 'due', header: t('safety.inspections.colDue'), priority: true,
          render: (r) => <span className={`px-2 py-1 rounded text-xs ${r.dueFlag ? 'bg-amber-100' : 'bg-gray-100'}`} data-flag={r.dueFlag ? 'due' : undefined}>{r.due}</span> },
        { key: 'active', header: t('safety.inspections.colActive'), render: (r) => (r.active ? t('common.yes') : t('common.no')) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}

export function RunsTable({ rows, empty }: { rows: RunRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<RunRow>[] = [
        { key: 'code', header: t('safety.inspections.colRun'), priority: true,
          render: (r) => <Link href={`/safety/inspections/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'checklist', header: t('safety.inspections.colChecklist'), render: (r) => r.checklist },
        { key: 'inspected', header: t('safety.inspections.colInspected'), render: (r) => r.inspected },
        { key: 'inspector', header: t('safety.inspections.colInspector'), render: (r) => r.inspector },
        { key: 'counts', header: t('safety.inspections.colResults'), priority: true, render: (r) => r.counts },
        { key: 'findings', header: t('safety.inspections.colFindings'),
          render: (r) => <span className={r.openFindings ? 'text-amber-800' : undefined}>{r.findings}</span> },
        { key: 'corrected', header: t('safety.inspections.colCorrected'), render: (r) => r.corrected ?? '—' },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
