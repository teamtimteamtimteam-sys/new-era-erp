'use client'

// MES-8a:评分卡页那张表 —— 一家供应商一行:最近一次没被取代的评审的等级(或"Not graded — V23 not set" / "Not reviewed")、窗口、记的时刻、评过几次。
//   手机上留【供应商】与【等级】—— 前者是身份,后者是这一页要人看的那一格。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ScorecardRow = {
    id: string; code: string; name: string; status: string; grade: string; graded: boolean; window: string; recorded: string; reviews: number
}

export default function ScorecardsTable({ rows, empty }: { rows: ScorecardRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<ScorecardRow>[] = [
        { key: 'code', header: t('scorecards.colSupplier'), priority: true,
          render: (r) => <Link href={`/suppliers/${r.id}/edit`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'name', header: t('scorecards.colName'), render: (r) => r.name },
        { key: 'status', header: t('scorecards.colStatus'), render: (r) => r.status },
        { key: 'grade', header: t('scorecards.colGrade'), priority: true,
          render: (r) => <span className={r.graded ? 'font-medium' : 'text-[color:var(--brand-muted-text)]'} data-grade={r.graded ? r.grade : undefined}>{r.grade}</span> },
        { key: 'window', header: t('scorecards.colWindow'), render: (r) => r.window },
        { key: 'recorded', header: t('scorecards.colRecorded'), render: (r) => r.recorded },
        { key: 'reviews', header: t('scorecards.colReviews'), render: (r) => String(r.reviews) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
