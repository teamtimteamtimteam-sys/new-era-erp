'use client'

// app/safety/environment/EnvironmentTable.tsx
// MES-7b-2 · 环境监测结果那张表。手机上留【参数】与【判定】—— 前者说是哪一个数,后者是这一页唯一会开出事故的那一格。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type EnvRow = {
    id: string; parameter: string; samplePoint: string; sampledOn: string; laboratory: string; report: string; value: string; limit: string
    judgement: string; judgementFlag: 'exceeds' | 'within' | 'not_judged'; incidentId: string | null; incidentCode: string | null
    note: string | null; canCorrect: boolean
}

export default function EnvironmentTable({ rows, empty, correctLabel }: { rows: EnvRow[]; empty: React.ReactNode; correctLabel: string | null }) {
    const t = useTranslations()
    const columns: Column<EnvRow>[] = [
        { key: 'parameter', header: t('safety.environment.colParameter'), priority: true, render: (r) => r.parameter },
        { key: 'point', header: t('safety.environment.colSamplePoint'), render: (r) => r.samplePoint },
        { key: 'sampled', header: t('safety.environment.colSampledOn'), render: (r) => r.sampledOn },
        { key: 'lab', header: t('safety.environment.colLaboratory'), render: (r) => `${r.laboratory} · ${r.report}` },
        { key: 'value', header: t('safety.environment.colValue'), align: 'right', render: (r) => r.value },
        { key: 'limit', header: t('safety.environment.colLimit'), render: (r) => r.limit },
        { key: 'judgement', header: t('safety.environment.colJudgement'), priority: true,
          render: (r) => <span className={`px-2 py-0.5 rounded text-xs ${r.judgementFlag === 'exceeds' ? 'bg-amber-100' : 'bg-gray-100'}`} data-judgement={r.judgementFlag}>{r.judgement}</span> },
        { key: 'incident', header: t('safety.environment.colIncident'),
          render: (r) => (r.incidentId ? <Link href={`/safety/incidents/${r.incidentId}`} className="app-link hover:underline">{r.incidentCode}</Link> : '—') },
        { key: 'note', header: t('safety.environment.colNote'),
          render: (r) => <>{r.note ?? ''}{r.canCorrect && correctLabel && <>{r.note ? ' · ' : ''}<Link href={`/safety/environment?corrects=${r.id}`} className="app-link hover:underline">{correctLabel}</Link></>}</> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
