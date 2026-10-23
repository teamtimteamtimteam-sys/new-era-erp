'use client'

// app/safety/inspections/InspectionTables.tsx
// MES-7b-2 · 巡检那一页的两张表:清单(到期与否)与巡检。手机上留【代号 / 编号】与【到期 / 结果】—— 前者是身份,后者是这一页要人动手的那一格。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xInt, xTime, xBool } from '@/lib/export/cells'

export type TemplateRow = {
    id: string; code: string; name: string; area: string; frequency: string; items: number; lastRun: string; due: string; dueFlag: boolean; active: boolean
    /** TABLE-EXPORT-2b-1:最近一次巡检的原始 ISO;null = 从未巡检 */
    lastRunAt: string | null
}
export type RunRow = {
    id: string; code: string; checklist: string; inspected: string; inspector: string; counts: string; findings: string; openFindings: boolean
    corrected: string | null
    /** TABLE-EXPORT-2b-1:巡检时刻的原始 ISO */
    inspectedAt: string
}

export function TemplatesTable({ rows, empty }: { rows: TemplateRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<TemplateRow>[] = [
        { key: 'code', header: t('safety.inspections.colTemplate'), priority: true, exportAs: (r) => xText(r.code),
          render: (r) => <Link href={`/safety/inspections/templates/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'name', header: t('safety.inspections.colName'), render: (r) => r.name, exportAs: (r) => xText(r.name) },
        { key: 'area', header: t('safety.inspections.colArea'), render: (r) => r.area, exportAs: (r) => xText(r.area) },
        { key: 'frequency', header: t('safety.inspections.colFrequency'), render: (r) => r.frequency, exportAs: (r) => xText(r.frequency) },
        { key: 'items', header: t('safety.inspections.colItems'), render: (r) => String(r.items), exportAs: (r) => xInt(r.items) },
        { key: 'last', header: t('safety.inspections.colLastRun'), render: (r) => r.lastRun, exportAs: (r) => xTime(r.lastRunAt) },
        { key: 'due', header: t('safety.inspections.colDue'), priority: true, exportAs: (r) => xText(r.due),
          render: (r) => <span className={`px-2 py-1 rounded text-xs ${r.dueFlag ? 'bg-amber-100' : 'bg-gray-100'}`} data-flag={r.dueFlag ? 'due' : undefined}>{r.due}</span> },
        { key: 'active', header: t('safety.inspections.colActive'), render: (r) => (r.active ? t('common.yes') : t('common.no')), exportAs: (r) => xBool(r.active, t('common.yes'), t('common.no')) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'safety-inspection-templates', title: t('safety.inspections.templatesTitle') }} />
}

// TABLE-EXPORT-2b-1:这张表也挂在清单详情页上(那里只列这一份清单的巡检)—— 导出名与标题由调用方给
export function RunsTable({ rows, empty, exportName = 'safety-inspection-runs', exportTitle, serverRows }: {
    rows: RunRow[]; empty: React.ReactNode; exportName?: string; exportTitle?: string
    /** TABLE-EXPORT-2b-1:/safety/inspections 只画最近 200 次 —— 导出走这条路由取全 */
    serverRows?: string
}) {
    const t = useTranslations()
    const columns: ExportableColumn<RunRow>[] = [
        { key: 'code', header: t('safety.inspections.colRun'), priority: true, exportAs: (r) => xText(r.code),
          render: (r) => <Link href={`/safety/inspections/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'checklist', header: t('safety.inspections.colChecklist'), render: (r) => r.checklist, exportAs: (r) => xText(r.checklist) },
        { key: 'inspected', header: t('safety.inspections.colInspected'), render: (r) => r.inspected, exportAs: (r) => xTime(r.inspectedAt) },
        { key: 'inspector', header: t('safety.inspections.colInspector'), render: (r) => r.inspector, exportAs: (r) => xText(r.inspector) },
        { key: 'counts', header: t('safety.inspections.colResults'), priority: true, render: (r) => r.counts, exportAs: (r) => xText(r.counts) },
        { key: 'findings', header: t('safety.inspections.colFindings'), exportAs: (r) => xText(r.findings === '—' ? null : r.findings),
          render: (r) => <span className={r.openFindings ? 'text-amber-800' : undefined}>{r.findings}</span> },
        { key: 'corrected', header: t('safety.inspections.colCorrected'), render: (r) => r.corrected ?? '—', exportAs: (r) => xText(r.corrected) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: exportName, title: exportTitle ?? t('safety.inspections.runsTitle'), serverRows }} />
}
