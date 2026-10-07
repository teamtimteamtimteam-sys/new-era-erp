'use client'

// MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q24 · Q25,Tim):每一个(加工日, 班次, 流)抽过没有 —— 一格一行。
//   状态三种:抽过(checked)· 这一班没抽、写了理由(not_sampled)· 一条当前的抽检都没有(missing —— 提醒臂 contamination_check_missing 的同一格)。
//   最高污染率对着记录那一刻的警戒线;超过只标出来;线没给时"判不了"。点单号进那一炉(抽检记在那一页);只持产出码的人没有链接。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type GridRow = {
    key: string; date: string; shift: string; stream: string; state: 'checked' | 'not_sampled' | 'missing'
    maxRate: number | null; anyAbove: boolean | null; runCode: string; runHref: string | null; runCount: number
}

export default function ContaminationGrid({ rows }: { rows: GridRow[] }) {
    const t = useTranslations()
    const columns: Column<GridRow>[] = [
        { key: 'date', header: t('contamination.colDate'), priority: true, render: (r) => r.date },
        { key: 'shift', header: t('contamination.colShift'), render: (r) => r.shift },
        { key: 'stream', header: t('contamination.colStream'), priority: true, render: (r) => r.stream },
        {
            key: 'state', header: t('contamination.colState'), priority: true,
            render: (r) => (
                <span data-check-state={r.state}
                      className={r.state === 'missing' ? 'text-red-700 font-medium' : r.state === 'not_sampled' ? 'text-amber-700' : ''}>
                    {t('contamination.state.' + r.state)}
                </span>
            ),
        },
        {
            key: 'rate', header: t('contamination.colMaxRate'),
            render: (r) => (r.maxRate === null ? '—'
                : <>{String(Number(r.maxRate.toFixed(4)))}%{r.anyAbove === true
                    ? <span className="ml-2 text-red-700 font-medium" data-flag="above">{t('contamination.above')}</span>
                    : r.anyAbove === null ? <span className="ml-2 text-amber-700">{t('contamination.notJudged')}</span> : null}</>),
        },
        {
            key: 'run', header: t('contamination.colRun'),
            render: (r) => (
                <>
                    {r.runHref ? <Link href={r.runHref} className="hover:underline app-link">{r.runCode}</Link> : r.runCode}
                    {r.runCount > 1 && <span className="ml-1 text-xs text-[color:var(--brand-muted-text)]">{t('contamination.moreRuns', { n: r.runCount - 1 })}</span>}
                </>
            ),
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={t('contamination.emptyGrid')} />
}
