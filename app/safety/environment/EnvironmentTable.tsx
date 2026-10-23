'use client'

// app/safety/environment/EnvironmentTable.tsx
// MES-7b-2 · 环境监测结果那张表。手机上留【参数】与【判定】—— 前者说是哪一个数,后者是这一页唯一会开出事故的那一格。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xDate } from '@/lib/export/cells'

export type EnvRow = {
    id: string; parameter: string; samplePoint: string; sampledOn: string; laboratory: string; report: string; value: string; limit: string
    judgement: string; judgementFlag: 'exceeds' | 'within' | 'not_judged'; incidentId: string | null; incidentCode: string | null
    note: string | null; canCorrect: boolean
    /** TABLE-EXPORT-2b-1:采样日、测得值与单位的原始值 */
    sampledOnRaw: string; valueRaw: number; unit: string
}

export default function EnvironmentTable({ rows, empty, correctLabel }: { rows: EnvRow[]; empty: React.ReactNode; correctLabel: string | null }) {
    const t = useTranslations()
    const columns: ExportableColumn<EnvRow>[] = [
        { key: 'parameter', header: t('safety.environment.colParameter'), priority: true, render: (r) => r.parameter, exportAs: (r) => xText(r.parameter) },
        { key: 'point', header: t('safety.environment.colSamplePoint'), render: (r) => r.samplePoint, exportAs: (r) => xText(r.samplePoint) },
        { key: 'sampled', header: t('safety.environment.colSampledOn'), render: (r) => r.sampledOn, exportAs: (r) => xDate(r.sampledOnRaw) },
        { key: 'lab', header: t('safety.environment.colLaboratory'), render: (r) => `${r.laboratory} · ${r.report}`, exportAs: (r) => xText(`${r.laboratory} · ${r.report}`) },
        { key: 'value', header: t('safety.environment.colValue'), align: 'right', render: (r) => r.value, exportAs: (r) => xNum(r.valueRaw, 'qty', r.unit) },
        { key: 'limit', header: t('safety.environment.colLimit'), render: (r) => r.limit, exportAs: (r) => xText(r.limit) },
        { key: 'judgement', header: t('safety.environment.colJudgement'), priority: true, exportAs: (r) => xText(r.judgement),
          render: (r) => <span className={`px-2 py-0.5 rounded text-xs ${r.judgementFlag === 'exceeds' ? 'bg-amber-100' : 'bg-gray-100'}`} data-judgement={r.judgementFlag}>{r.judgement}</span> },
        { key: 'incident', header: t('safety.environment.colIncident'), exportAs: (r) => xText(r.incidentCode),
          render: (r) => (r.incidentId ? <Link href={`/safety/incidents/${r.incidentId}`} className="app-link hover:underline">{r.incidentCode}</Link> : '—') },
        // 「更正」链接是控件,不导出;只留那句备注
        { key: 'note', header: t('safety.environment.colNote'), exportAs: (r) => xText(r.note),
          render: (r) => <>{r.note ?? ''}{r.canCorrect && correctLabel && <>{r.note ? ' · ' : ''}<Link href={`/safety/environment?corrects=${r.id}`} className="app-link hover:underline">{correctLabel}</Link></>}</> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'safety-environment-results', title: t('safety.environment.resultsTitle'), serverRows: '/safety/environment/export' }} />
}
