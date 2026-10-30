'use client'

// app/settings/change-history/ChangeHistoryExport.tsx
// GOLIVE-2 第 13 行 · 变更记录导出的浏览器那一半(Tim 2026-10-23 Q7 · 2026-10-30 Q3):向 ./export 要 JSON(一个字段一行),
//   写成 xlsx / csv —— 与表格导出(app/components/ui/table-export.tsx)同一套写法、同一张 About 表、同一个「Restricted」。
//   两个日期都选了、区间不超过 366 天才按得下去(路由自己也判一遍);超过 5 万条已记录变更时说出那个数,请人收窄日期区间(Q3)。
//   列名是 Q7 原文的七个英文词 —— 变更记录的每一条记录本来就只说英文(AUDIT-TRAIL-1a Q7)。
import * as React from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { ReadOnlyButton } from '@/app/components/ui/disabled-block'
import { Refusal } from '@/app/components/ui/refusal'
import { aboutRows } from '@/app/components/ui/table-export'
import { xRestricted, xText, xTime, type ExportCell } from '@/lib/export/cells'
import { buildCsv, buildXlsx, CSV_MIME, downloadBlob, exportFileName, XLSX_MIME, type ExportTable } from '@/lib/export/write'
import type { ChangeHistoryExportRow } from './export/route'

const HEADERS = ['When', 'Who', 'Record', 'What happened', 'Field', 'Old value', 'New value']

export default function ChangeHistoryExport({ query, ready }: { query: string; ready: boolean }) {
    const t = useTranslations()
    const locale = useLocale()
    const [busy, setBusy] = React.useState<null | 'xlsx' | 'csv'>(null)
    const [problem, setProblem] = React.useState<string | null>(null)

    const run = async (fmt: 'xlsx' | 'csv') => {
        setBusy(fmt)
        setProblem(null)
        try {
            const res = await fetch(`/settings/change-history/export?${query}`, { headers: { accept: 'application/json' } })
            let body: { rows?: ChangeHistoryExportRow[]; code?: string; count?: number; cap?: number; max?: number } | null
            try { body = await res.json() } catch (e) {
                throw new Error(`HTTP ${res.status} · ${e instanceof Error ? e.message : String(e)}`)
            }
            if (res.status === 413 && body?.code === 'EXPORT_TOO_MANY_ROWS') {
                setProblem(t('changeHistory.export.tooMany', { count: String(body.count ?? 0), cap: String(body.cap ?? 0) }))
                return
            }
            if (res.status === 400 && body?.code === 'EXPORT_DATES_REQUIRED') { setProblem(t('changeHistory.export.datesRequired')); return }
            if (res.status === 400 && body?.code === 'EXPORT_RANGE_TOO_LONG') { setProblem(t('changeHistory.export.tooLong', { max: String(body.max ?? 366) })); return }
            if (res.status === 403) { setProblem(t('table.export.denied')); return }
            if (!res.ok || !body?.rows) throw new Error(`HTTP ${res.status}${body?.code ? ` ${body.code}` : ''}`)
            const cell = (v: string | null, restricted: boolean): ExportCell => (restricted ? xRestricted : xText(v))
            const now = new Date()
            const title = t('changeHistory.title')
            const table: ExportTable = {
                name: 'change-history',
                title,
                headers: HEADERS,
                rows: body.rows.map((r) => [xTime(r.when), xText(r.who), xText(r.record), xText(r.what), xText(r.field),
                                            cell(r.old, r.oldRestricted), cell(r.new, r.newRestricted)]),
                restrictedText: 'Restricted',
                about: await aboutRows(t, locale, now, { title, rows: body.rows.length }),
            }
            if (fmt === 'csv') downloadBlob(buildCsv(table), CSV_MIME, exportFileName('change-history', 'csv', now))
            else downloadBlob(await buildXlsx(table), XLSX_MIME, exportFileName('change-history', 'xlsx', now))
        } catch (e) {
            setProblem(t('table.export.failed', { detail: e instanceof Error ? e.message : String(e) }))
        } finally {
            setBusy(null)
        }
    }

    return (
        <div className="flex flex-wrap items-center gap-2 mb-4 text-sm" data-change-history-export={ready ? 'ready' : 'needs-dates'}>
            <ReadOnlyButton variant="outline" size="sm" disabled={!ready || busy !== null} onClick={() => run('xlsx')}>
                {busy === 'xlsx' ? t('table.export.busy') : t('table.export.excel')}
            </ReadOnlyButton>
            <ReadOnlyButton variant="outline" size="sm" disabled={!ready || busy !== null} onClick={() => run('csv')}>
                {busy === 'csv' ? t('table.export.busy') : t('table.export.csv')}
            </ReadOnlyButton>
            {!ready && <span className="text-xs text-[color:var(--brand-muted-text)]">{t('changeHistory.export.needsDates')}</span>}
            {problem && <p role="alert" className="w-full text-xs"><Refusal>{problem}</Refusal></p>}
        </div>
    )
}
