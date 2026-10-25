'use client'

// app/quality/samples/[id]/SampleTables.tsx
// MES-6a-1 · 样品页上的两张表:保管记录(一行一件事,按先后)与化验了这份样品的结果。字由服务端排好,这里只画。
//
// ★ TABLE-EXPORT-3c(Tim 2026-10-25):两张表各一对导出。
//   【保管记录】只可追加的留痕 —— 导出【全部】(表本来就是全体,不分页、不截断),与 TABLE-EXPORT-3 Q6 那 12 条留痕同一个待遇。
//     时刻读原始 occurred_at(xTime,新加坡时间);「—」占位的格子导出为空,不写那个破折号。
//   【化验结果】日期读原始日历日(xDate);单号那一格是链接 → 导出写单号。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xText, xTime } from '@/lib/export/cells'

export type EventRow = {
    id: string; when: string; what: string; detail: string; reason: string; notes: string
    /** TABLE-EXPORT-3c:原始时刻(ISO,带时区);上面的 when 是格式化过的字 */
    whenRaw: string
    /** TABLE-EXPORT-3c:去掉「—」占位之后的原始值(null = 没有) */
    detailRaw: string | null; reasonRaw: string | null; notesRaw: string | null
}
export type AssayRow = {
    id: string; code: string; href: string; party: string; date: string; lab: string
    /** TABLE-EXPORT-3c:化验日的原始日历日;实验室名(null = 没写) */
    dateRaw: string | null; labRaw: string | null
}

export function EventsTable({ rows, sampleCode }: { rows: EventRow[]; sampleCode: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<EventRow>[] = [
        { key: 'when', header: t('quality.sample.colWhen'), priority: true, render: (r) => r.when, exportAs: (r) => xTime(r.whenRaw) },
        { key: 'what', header: t('quality.sample.colWhat'), priority: true, render: (r) => r.what, exportAs: (r) => xText(r.what) },
        { key: 'detail', header: t('quality.sample.colDetail'), render: (r) => r.detail, exportAs: (r) => xText(r.detailRaw) },
        { key: 'reason', header: t('quality.sample.colReason'), render: (r) => r.reason, exportAs: (r) => xText(r.reasonRaw) },
        { key: 'notes', header: t('quality.form.notes'), className: 'text-gray-600', render: (r) => r.notes, exportAs: (r) => xText(r.notesRaw) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty="—"
        exportSpec={{ name: 'quality-sample-custody', title: t('quality.sample.custodyTitle'),
                      aboutExtra: [[t('quality.samples.colCode'), sampleCode]] }} />
}

export function AssaysTable({ rows, empty, sampleCode }: { rows: AssayRow[]; empty: React.ReactNode; sampleCode: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<AssayRow>[] = [
        { key: 'code', header: t('quality.sample.colAssay'), priority: true,
          render: (r) => <Link href={r.href} className="hover:underline app-link">{r.code}</Link>,
          exportAs: (r) => xText(r.code) },
        { key: 'party', header: t('quality.colParty'), priority: true, render: (r) => r.party, exportAs: (r) => xText(r.party) },
        { key: 'date', header: t('quality.colDate'), render: (r) => r.date, exportAs: (r) => xDate(r.dateRaw) },
        { key: 'lab', header: t('quality.sample.lab'), render: (r) => r.lab, exportAs: (r) => xText(r.labRaw) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'quality-sample-assays', title: t('quality.sample.assaysTitle'),
                      aboutExtra: [[t('quality.samples.colCode'), sampleCode]] }} />
}
