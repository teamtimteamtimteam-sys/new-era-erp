'use client'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3a(Tim 2026-10-23)· 报表上方那两颗「Excel / CSV」—— 照报表自己的版式导出
// ════════════════════════════════════════════════════════════════════════════
// 与 table-export.tsx 是一对:那一个导出【列表】(一行一条记录,Q12 不许合计行),这一个导出【报表】
// (抬头 · 明细 · 报表自己算的小计与合计,Q2 / Q3)。写法在 lib/export/report.ts;About 表与列表【同一份】(aboutRows)。
//
// ★ 报表的行由【服务端页面】拼好、作为 props 交过来:报表的每一个数都是页面已经从库里读到的
//   (pnl_statement · balance_sheet · trial_balance_totals · cash_flow_statement · cash_forecast_data),
//   这里不读库、不算数 —— 所以导出【按构造】与屏幕是同一份数。
// ★ 同一个文件里还有 FlatExportBar:一张【平表】的导出,而行与格子已经由服务端页面写好(手搓的透视表摊平成平表、
//   月结清单)。它走列表的写法(write.ts,Q12 不写合计行)—— 只是列定义不能跨过服务端 → 客户端那道边界
//   (函数传不过去),所以格子在服务端就写成了 ExportCell。
// ★ scripts/check-table-export.mjs 认这几个组件:一个手搓 <table> 的文件里画着 <ReportExportBar / <FlatExportBar(或 <TableExportBar),
//   那张表就算声明了导出(Tim 2026-10-23 Q2 —— 报表不是 DataTable,它没有 exportSpec 可写)。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { Refusal } from '@/app/components/ui/refusal'
import { aboutRows } from '@/app/components/ui/table-export'
import { buildCsv, buildXlsx, downloadBlob, exportFileName, CSV_MIME, XLSX_MIME } from '@/lib/export/write'
import type { ExportCell } from '@/lib/export/cells'
import { buildReportCsv, buildReportXlsx, type ReportSheet } from '@/lib/export/report'

export type ReportExportSpec = {
    /** Q9 文件名里的英文名(小写、连字符)。 */
    name: string
    /** About 表的标题(界面语言)。 */
    title: string
    headers: string[]
    sheets: ReportSheet[]
    /** 多张工作表时 CSV 多出来的那一列的列头(例如「币种」)。 */
    sheetHeader?: string
    /** About 表上多写的几行(例如报表的期间)。 */
    aboutExtra?: ReadonlyArray<[string, string]>
    /** 明细行在 CSV「行的种类」那一列的叫法:财务报表是「科目」(默认,Q2 的原话);别的报表(现金预测的周表)是「明细」。 */
    lineKind?: 'account' | 'other'
    /** About 表「筛选」那一栏;不给就列出地址栏里的查询参数。 */
    filters?: ReadonlyArray<[string, string]>
}

type Busy = null | 'xlsx' | 'csv'

export function ReportExportBar({ spec }: { spec: ReportExportSpec }) {
    const t = useTranslations()
    const locale = useLocale()
    const [busy, setBusy] = React.useState<Busy>(null)
    const [problem, setProblem] = React.useState<string | null>(null)

    const run = async (fmt: 'xlsx' | 'csv') => {
        setBusy(fmt)
        setProblem(null)
        try {
            const now = new Date()
            const lines = spec.sheets.reduce((n, s) => n + s.lines.length, 0)
            const report = {
                name: spec.name,
                title: spec.title,
                headers: spec.headers,
                sheets: spec.sheets,
                sheetHeader: spec.sheetHeader,
                restrictedText: t('common.restricted'),
                kindHeader: t('table.export.lineKind'),
                kindLabels: {
                    heading: t('table.export.lineKindHeading'),
                    line: spec.lineKind === 'other' ? t('table.export.lineKindLineOther') : t('table.export.lineKindLine'),
                    subtotal: t('table.export.lineKindSubtotal'),
                    total: t('table.export.lineKindTotal'),
                },
                about: await aboutRows(t, locale, now, { title: spec.title, rows: lines, filters: spec.filters, extra: spec.aboutExtra }),
            }
            if (fmt === 'csv') downloadBlob(buildReportCsv(report), CSV_MIME, exportFileName(spec.name, 'csv', now))
            else downloadBlob(await buildReportXlsx(report), XLSX_MIME, exportFileName(spec.name, 'xlsx', now))
        } catch (e) {
            setProblem(t('table.export.failed', { detail: e instanceof Error ? e.message : String(e) }))
        } finally {
            setBusy(null)
        }
    }

    return (
        <div className="ml-auto flex flex-wrap items-center justify-end gap-2" data-slot="table-export" data-report-export={spec.name}>
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => run('xlsx')}>
                {busy === 'xlsx' ? t('table.export.busy') : t('table.export.excel')}
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => run('csv')}>
                {busy === 'csv' ? t('table.export.busy') : t('table.export.csv')}
            </Button>
            {problem && <p role="alert" className="w-full text-right text-xs"><Refusal>{problem}</Refusal></p>}
        </div>
    )
}

export type FlatExportSpec = {
    name: string
    title: string
    headers: string[]
    /** 每一行与 headers 一一对应,已是带类型的格子。 */
    rows: ExportCell[][]
    aboutExtra?: ReadonlyArray<[string, string]>
    filters?: ReadonlyArray<[string, string]>
}

export function FlatExportBar({ spec }: { spec: FlatExportSpec }) {
    const t = useTranslations()
    const locale = useLocale()
    const [busy, setBusy] = React.useState<Busy>(null)
    const [problem, setProblem] = React.useState<string | null>(null)

    const run = async (fmt: 'xlsx' | 'csv') => {
        setBusy(fmt)
        setProblem(null)
        try {
            for (const r of spec.rows) {
                if (r.length !== spec.headers.length) throw new Error(`FLAT_EXPORT_WIDTH|${spec.name}|${r.length} cells vs ${spec.headers.length} headers`)
            }
            const now = new Date()
            const table = {
                name: spec.name,
                title: spec.title,
                headers: spec.headers,
                rows: spec.rows,
                restrictedText: t('common.restricted'),
                about: await aboutRows(t, locale, now, { title: spec.title, rows: spec.rows.length, filters: spec.filters, extra: spec.aboutExtra }),
            }
            if (fmt === 'csv') downloadBlob(buildCsv(table), CSV_MIME, exportFileName(spec.name, 'csv', now))
            else downloadBlob(await buildXlsx(table), XLSX_MIME, exportFileName(spec.name, 'xlsx', now))
        } catch (e) {
            setProblem(t('table.export.failed', { detail: e instanceof Error ? e.message : String(e) }))
        } finally {
            setBusy(null)
        }
    }

    return (
        <div className="ml-auto flex flex-wrap items-center justify-end gap-2" data-slot="table-export" data-flat-export={spec.name}>
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => run('xlsx')}>
                {busy === 'xlsx' ? t('table.export.busy') : t('table.export.excel')}
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => run('csv')}>
                {busy === 'csv' ? t('table.export.busy') : t('table.export.csv')}
            </Button>
            {problem && <p role="alert" className="w-full text-right text-xs"><Refusal>{problem}</Refusal></p>}
        </div>
    )
}
