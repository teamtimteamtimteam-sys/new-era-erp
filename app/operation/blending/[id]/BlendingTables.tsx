'use client'

// MES-5b-3:配料计划页上的三张表 —— 目标与预测 · 候选批次(含量、实际与差)· 混出来那一批的化验对着目标。
//   所有的数都由服务端从视图里取好、压平成字(blending_plan_prediction / _line_metals / _execution / _outcome);这里不算任何东西。
//   「受限」与「没量过」是两句不同的话,与 0 也不同 —— 三者在这里各有各的字(lib/permissions.ts 存在的理由)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type TargetRow = {
    metal: string; bounds: string; source: string
    predicted: string; predictedTone: 'ok' | 'flag' | 'muted'
    measured: string; sources: string; flag: string
}
export type LineRow = {
    id: string; batchCode: string; batchHref: string | null; kind: string
    planned: string; content: string; contentMuted: boolean; actual: string; difference: string; differenceNegative: boolean
}
export type OutcomeRow = { metal: string; bounds: string; assay: string; content: string; verdict: string; verdictTone: 'ok' | 'flag' | 'muted' }

const TONE = { ok: 'text-green-700', flag: 'text-amber-700 font-medium', muted: 'text-[color:var(--brand-muted-text)] italic' }

export function TargetsTable({ rows }: { rows: TargetRow[] }) {
    const t = useTranslations()
    const columns: Column<TargetRow>[] = [
        { key: 'metal', header: t('blending.colMetal'), priority: true, render: (r) => r.metal },
        { key: 'bounds', header: t('blending.colBounds'), render: (r) => r.bounds },
        { key: 'source', header: t('blending.colTargetSource'), render: (r) => r.source },
        { key: 'predicted', header: t('blending.colPredicted'), priority: true, align: 'right',
          render: (r) => <span className={TONE[r.predictedTone]}>{r.predicted}</span> },
        { key: 'measured', header: t('blending.colMeasured'), render: (r) => r.measured },
        { key: 'sources', header: t('blending.colSources'), render: (r) => r.sources },
        { key: 'flag', header: t('blending.colFlag'), priority: true, render: (r) => r.flag },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty={t('blending.noTargets')} />
}

export function LinesTable({ rows }: { rows: LineRow[] }) {
    const t = useTranslations()
    const columns: Column<LineRow>[] = [
        { key: 'batch', header: t('blending.colBatch'), priority: true,
          render: (r) => r.batchHref ? <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link> : r.batchCode },
        { key: 'kind', header: t('blending.colKind'), render: (r) => r.kind },
        { key: 'planned', header: t('blending.colPlannedKg'), priority: true, align: 'right', render: (r) => r.planned },
        { key: 'content', header: t('blending.colContent'),
          render: (r) => <span className={r.contentMuted ? TONE.muted : ''}>{r.content}</span> },
        { key: 'actual', header: t('blending.colActualKg'), align: 'right', render: (r) => r.actual },
        { key: 'difference', header: t('blending.colDifference'), align: 'right',
          render: (r) => <span className={r.differenceNegative ? 'text-amber-700' : ''}>{r.difference}</span> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={t('blending.noLines')} />
}

export function OutcomeTable({ rows }: { rows: OutcomeRow[] }) {
    const t = useTranslations()
    const columns: Column<OutcomeRow>[] = [
        { key: 'metal', header: t('blending.colMetal'), priority: true, render: (r) => r.metal },
        { key: 'bounds', header: t('blending.colBounds'), render: (r) => r.bounds },
        { key: 'assay', header: t('blending.colAssay'), render: (r) => r.assay },
        { key: 'content', header: t('blending.colAssayContent'), align: 'right', render: (r) => r.content },
        { key: 'verdict', header: t('blending.colVerdict'), priority: true,
          render: (r) => <span className={TONE[r.verdictTone]}>{r.verdict}</span> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty={t('blending.noTargets')} />
}
