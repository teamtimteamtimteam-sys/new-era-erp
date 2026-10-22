'use client'

// MES-8a:评分卡页那张表 —— 一家供应商一行:最近一次没被取代的评审的等级(或"Not graded — V23 not set" / "Not reviewed")、窗口、记的时刻、评过几次。
//   手机上留【供应商】与【等级】—— 前者是身份,后者是这一页要人看的那一格。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime, xInt } from '@/lib/export/cells'

export type ScorecardRow = {
    id: string; code: string; name: string; status: string; grade: string; graded: boolean; window: string; recorded: string; reviews: number
    /** TABLE-EXPORT-1:导出用的原始值 —— 窗口两端是 `YYYY-MM-DD`,记的时刻是 ISO(都可以没有:没评过)。 */
    windowFrom: string | null; windowTo: string | null; recordedAt: string | null
}

export default function ScorecardsTable({ rows, empty }: { rows: ScorecardRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<ScorecardRow>[] = [
        { key: 'code', header: t('scorecards.colSupplier'), priority: true, exportAs: (r) => xText(r.code),
          render: (r) => <Link href={`/suppliers/${r.id}/edit`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'name', header: t('scorecards.colName'), render: (r) => r.name, exportAs: (r) => xText(r.name) },
        { key: 'status', header: t('scorecards.colStatus'), render: (r) => r.status, exportAs: (r) => xText(r.status) },
        { key: 'grade', header: t('scorecards.colGrade'), priority: true, exportAs: (r) => xText(r.grade),
          render: (r) => <span className={r.graded ? 'font-medium' : 'text-[color:var(--brand-muted-text)]'} data-grade={r.graded ? r.grade : undefined}>{r.grade}</span> },
        // TABLE-EXPORT-1:一格装着两个日子,导出成一格就只能是文字 —— 用原始的 `YYYY-MM-DD` 拼,不用屏幕上格式化过的那串
        //   (那样 Excel 里至少按字面排得出先后)。
        { key: 'window', header: t('scorecards.colWindow'), render: (r) => r.window,
          exportAs: (r) => xText(r.windowFrom && r.windowTo ? `${r.windowFrom} – ${r.windowTo}` : null) },
        { key: 'recorded', header: t('scorecards.colRecorded'), render: (r) => r.recorded, exportAs: (r) => xTime(r.recordedAt) },
        { key: 'reviews', header: t('scorecards.colReviews'), render: (r) => String(r.reviews), exportAs: (r) => xInt(r.reviews) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'supplier-scorecards', title: t('scorecards.title') }} />
}
