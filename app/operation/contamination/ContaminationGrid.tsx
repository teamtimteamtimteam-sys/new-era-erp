'use client'

// MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q24 · Q25,Tim):每一个(加工日, 班次, 流)抽过没有 —— 一格一行。
//   状态三种:抽过(checked)· 这一班没抽、写了理由(not_sampled)· 一条当前的抽检都没有(missing —— 提醒臂 contamination_check_missing 的同一格)。
//   最高污染率对着记录那一刻的警戒线;超过只标出来;线没给时"判不了"。点单号进那一炉(抽检记在那一页);只持产出码的人没有链接。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xDate } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { CellsSorting } from '@/app/operation/equipment/CellsTable'

export type GridRow = {
    key: string; date: string; shift: string; stream: string; state: 'checked' | 'not_sampled' | 'missing'
    maxRate: number | null; anyAbove: boolean | null; runCode: string; runHref: string | null; runCount: number
    /** TABLE-EXPORT-1:导出用的原始加工日 `YYYY-MM-DD`(屏幕上那个是排好的字)。 */
    processDate: string
}

export default function ContaminationGrid({ rows, exportUrl, sorting }: {
    rows: GridRow[]; exportUrl: string
    /** TABLE-FEATURES-1 Q9:页面只画前 300 格 —— 在数据库里排(contaminationRows.ts 的 GRID_SORT);与 CellsTable 同一种纯数据描述 */
    sorting: Extract<CellsSorting, { mode: 'server' }>
}) {
    const t = useTranslations()
    const sortHref = useSortHref(sorting.prefix ?? '', sorting.pageParam ?? 'page')
    const columns: ExportableColumn<GridRow>[] = [
        { key: 'date', header: t('contamination.colDate'), priority: true, render: (r) => r.date, exportAs: (r) => xDate(r.processDate) },
        { key: 'shift', header: t('contamination.colShift'), render: (r) => r.shift, exportAs: (r) => xText(r.shift) },
        { key: 'stream', header: t('contamination.colStream'), priority: true, render: (r) => r.stream, exportAs: (r) => xText(r.stream) },
        {
            key: 'state', header: t('contamination.colState'), priority: true, exportAs: (r) => xText(t('contamination.state.' + r.state)),
            render: (r) => (
                <span data-check-state={r.state}
                      className={r.state === 'missing' ? 'text-red-700 font-medium' : r.state === 'not_sampled' ? 'text-amber-700' : ''}>
                    {t('contamination.state.' + r.state)}
                </span>
            ),
        },
        {
            // TABLE-EXPORT-1:导出是那个百分数本身(Excel 里是一个数);"超过 / 判不了"的标记在逐次清单的警戒那一格里有字
            key: 'rate', header: t('contamination.colMaxRate'), exportAs: (r) => xNum(r.maxRate, 'pct'),
            render: (r) => (r.maxRate === null ? '—'
                : <>{String(Number(r.maxRate.toFixed(4)))}%{r.anyAbove === true
                    ? <span className="ml-2 text-red-700 font-medium" data-flag="above">{t('contamination.above')}</span>
                    : r.anyAbove === null ? <span className="ml-2 text-amber-700">{t('contamination.notJudged')}</span> : null}</>),
        },
        {
            key: 'run', header: t('contamination.colRun'),
            exportAs: (r) => xText(r.runCount > 1 ? `${r.runCode} ${t('contamination.moreRuns', { n: r.runCount - 1 })}` : r.runCode),
            render: (r) => (
                <>
                    {r.runHref ? <Link href={r.runHref} className="hover:underline app-link">{r.runCode}</Link> : r.runCode}
                    {r.runCount > 1 && <span className="ml-1 text-xs text-[color:var(--brand-muted-text)]">{t('contamination.moreRuns', { n: r.runCount - 1 })}</span>}
                </>
            ),
        },
    ]
    // TABLE-FEATURES-1 Q9:白名单里的列才可排(名字查出来的、拼出来的不可排)。就地标在那份字面量上 ——
    //   check-datatable-phone 读的是 `columns={…}` 指向的那份字面量(它要看得见 priority),换成一个 .map 的产物它就瞎了。
    for (const c of columns) c.sortable = sorting.sortable.includes(c.key)
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={t('contamination.emptyGrid')}
                      exportSpec={{ name: 'operation-contamination-shifts', title: t('contamination.title'), serverRows: exportUrl }}
                      sorting={{ mode: 'server', coverage: { shown: sorting.shown, total: sorting.total }, active: sorting.active, href: sortHref }} />
}
