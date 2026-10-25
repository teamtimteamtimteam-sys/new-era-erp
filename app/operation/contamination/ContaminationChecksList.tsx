'use client'

// MES-4b(2026-10-07,MES-4b Step 0 Q21 · Q25,Tim):交叉污染抽检的只读清单 —— 产出批页(这一批被抽过的)与 /operation/contamination(最近的)共用。
//   读的是 contamination_check_rows(带门的属主视图:加工或产出查看码;只持产出码的人读不到 processing_runs,所以单号由视图借过来)。
//   单号只在读者进得去加工单页时才是一个链接(runHref 为空就是纯文字)。只列当前的那一条(更正链末端);更正过的说出理由。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { CellsSorting } from '@/app/operation/equipment/CellsTable'

export type CheckListRow = {
    id: number; runCode: string; runHref: string | null; date: string; shift: string; stream: string
    kind: 'sampled' | 'not_sampled'; batchCode: string | null; ratePct: number | null; warningPctAt: number | null
    above: boolean | null; sampledAt: string | null; notSampledReason: string | null; corrected: boolean; correctionReason: string | null
    /** TABLE-EXPORT-1:导出用的原始值 —— 加工日 `YYYY-MM-DD`、抽检时刻 ISO(屏幕上那两个是排好的字)。 */
    processDate: string; sampledAtIso: string | null
}

// TABLE-EXPORT-1:同一张清单在两处出现(/operation/contamination 的"最近"与产出批页),各自给一个名字与标题。
export type ChecksExport = {
    name: string; title: string
    /** TABLE-EXPORT-2b-2:页面只画最新 N 次时,导出向这条路由要全部(产出批页那一处不给 —— 它手里就是全体) */
    serverRows?: string
}

/** 警戒那一格屏幕上说的话 —— render 与导出共用,于是两边不可能各说各话。 */
function flagText(r: CheckListRow, t: (k: string) => string): string {
    if (r.kind !== 'sampled') return '—'
    if (r.above === true) return `${t('contamination.above')} (${r.warningPctAt}%)`
    if (r.above === false) return `${t('contamination.within')} (${r.warningPctAt}%)`
    return t('contamination.notJudged')
}

export default function ContaminationChecksList({ rows, emptyKey, exportSpec, sorting }: {
    rows: CheckListRow[]; emptyKey: string; exportSpec: ChecksExport
    /**
     * TABLE-FEATURES-1 Q9:与 CellsTable 同一种纯数据描述。/operation/contamination 只画最新 50 次 → server
     * (contaminationRows.ts 的 CHECKS_SORT,前缀 checks_);产出批页手里是全体 → 'client'。不给 = 不排(原样)。
     */
    sorting?: CellsSorting
}) {
    const t = useTranslations()
    const server = sorting && sorting !== 'client' ? sorting : null
    const sortHref = useSortHref(server?.prefix ?? '', server?.pageParam ?? 'page')
    const checkText = (r: CheckListRow) => (r.kind === 'sampled'
        ? t('contamination.rate', { rate: r.ratePct === null ? '—' : String(Number(r.ratePct.toFixed(4))), batch: r.batchCode ?? '' })
        : t('contamination.notSampledBecause', { reason: r.notSampledReason ?? '' }))
    const columns: ExportableColumn<CheckListRow>[] = [
        {
            key: 'run', header: t('contamination.colRun'), priority: true, exportAs: (r) => xText(r.runCode),
            render: (r) => (r.runHref ? <Link href={r.runHref} className="hover:underline app-link">{r.runCode}</Link> : r.runCode),
        },
        {
            // TABLE-EXPORT-1:一格两样(日期 · 班次)—— 导出是一格文字,日期写原始的 `YYYY-MM-DD`(不是排好的那串)
            key: 'shift', header: t('contamination.colShift'), render: (r) => `${r.date} · ${r.shift}`,
            exportAs: (r) => xText(`${r.processDate} · ${r.shift}`),
        },
        { key: 'stream', header: t('contamination.colStream'), render: (r) => r.stream, exportAs: (r) => xText(r.stream) },
        {
            // 这一格是一句话(率与批号,或没抽的理由)—— 导出同一句话
            key: 'check', header: t('contamination.colCheck'), priority: true,
            render: checkText, exportAs: (r) => xText(checkText(r)),
        },
        {
            key: 'flag', header: t('contamination.colWarning'), exportAs: (r) => xText(flagText(r, t)),
            render: (r) => (r.kind !== 'sampled' ? '—'
                : r.above === true ? <span className="text-red-700 font-medium" data-flag="above">{t('contamination.above')} ({r.warningPctAt}%)</span>
                    : r.above === false ? `${t('contamination.within')} (${r.warningPctAt}%)`
                        : <span className="text-amber-700">{t('contamination.notJudged')}</span>),
        },
        { key: 'when', header: t('contamination.colSampledAt'), render: (r) => r.sampledAt ?? '—', exportAs: (r) => xTime(r.sampledAtIso) },
        {
            key: 'correction', header: '', exportHeader: t('contamination.correctReason'), className: 'text-[color:var(--brand-muted-text)]',
            exportAs: (r) => xText(r.corrected ? t('contamination.correctedBecause', { reason: r.correctionReason ?? '' }) : null),
            render: (r) => (r.corrected ? t('contamination.correctedBecause', { reason: r.correctionReason ?? '' }) : ''),
        },
    ]
    const spec = { name: exportSpec.name, title: exportSpec.title, serverRows: exportSpec.serverRows }
    if (server) {
        // 白名单里的列才可排(名字查出来的、拼出来的不可排)。就地标在那份字面量上 ——
        //   check-datatable-phone 读的是 `columns={…}` 指向的那份字面量(它要看得见 priority),换成一个 .map 的产物它就瞎了。
        for (const c of columns) c.sortable = server.sortable.includes(c.key)
        return <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t(emptyKey)}
                          exportSpec={spec}
                          sorting={{ mode: 'server', coverage: { shown: server.shown, total: server.total }, active: server.active, href: sortHref }} />
    }
    if (sorting === 'client') {
        return <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t(emptyKey)}
                          exportSpec={spec} sorting={{ mode: 'client', coverage: 'complete' }} />
    }
    return <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t(emptyKey)}
                      exportSpec={spec} />
}
