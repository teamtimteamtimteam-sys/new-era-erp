'use client'

// MES-4b(2026-10-07,MES-4b Step 0 Q21 · Q25,Tim):交叉污染抽检的只读清单 —— 产出批页(这一批被抽过的)与 /operation/contamination(最近的)共用。
//   读的是 contamination_check_rows(带门的属主视图:加工或产出查看码;只持产出码的人读不到 processing_runs,所以单号由视图借过来)。
//   单号只在读者进得去加工单页时才是一个链接(runHref 为空就是纯文字)。只列当前的那一条(更正链末端);更正过的说出理由。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type CheckListRow = {
    id: number; runCode: string; runHref: string | null; date: string; shift: string; stream: string
    kind: 'sampled' | 'not_sampled'; batchCode: string | null; ratePct: number | null; warningPctAt: number | null
    above: boolean | null; sampledAt: string | null; notSampledReason: string | null; corrected: boolean; correctionReason: string | null
}

export default function ContaminationChecksList({ rows, emptyKey }: { rows: CheckListRow[]; emptyKey: string }) {
    const t = useTranslations()
    const columns: Column<CheckListRow>[] = [
        {
            key: 'run', header: t('contamination.colRun'), priority: true,
            render: (r) => (r.runHref ? <Link href={r.runHref} className="hover:underline app-link">{r.runCode}</Link> : r.runCode),
        },
        { key: 'shift', header: t('contamination.colShift'), render: (r) => `${r.date} · ${r.shift}` },
        { key: 'stream', header: t('contamination.colStream'), render: (r) => r.stream },
        {
            key: 'check', header: t('contamination.colCheck'), priority: true,
            render: (r) => (r.kind === 'sampled'
                ? t('contamination.rate', { rate: r.ratePct === null ? '—' : String(Number(r.ratePct.toFixed(4))), batch: r.batchCode ?? '' })
                : t('contamination.notSampledBecause', { reason: r.notSampledReason ?? '' })),
        },
        {
            key: 'flag', header: t('contamination.colWarning'),
            render: (r) => (r.kind !== 'sampled' ? '—'
                : r.above === true ? <span className="text-red-700 font-medium" data-flag="above">{t('contamination.above')} ({r.warningPctAt}%)</span>
                    : r.above === false ? `${t('contamination.within')} (${r.warningPctAt}%)`
                        : <span className="text-amber-700">{t('contamination.notJudged')}</span>),
        },
        { key: 'when', header: t('contamination.colSampledAt'), render: (r) => r.sampledAt ?? '—' },
        {
            key: 'correction', header: '', className: 'text-[color:var(--brand-muted-text)]',
            render: (r) => (r.corrected ? t('contamination.correctedBecause', { reason: r.correctionReason ?? '' }) : ''),
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t(emptyKey)} />
}
