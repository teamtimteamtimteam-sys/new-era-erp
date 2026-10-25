'use client'

// MES-5b-3:配料计划页上的三张表 —— 目标与预测 · 候选批次(含量、实际与差)· 混出来那一批的化验对着目标。
//   所有的数都由服务端从视图里取好、压平成字(blending_plan_prediction / _line_metals / _execution / _outcome);这里不算任何东西。
//   「受限」与「没量过」是两句不同的话,与 0 也不同 —— 三者在这里各有各的字(lib/permissions.ts 存在的理由)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xNum, xRestricted, xText, type ExportCell } from '@/lib/export/cells'

// TABLE-EXPORT-3c(Tim 2026-10-25):三张表各一对导出。行上原来只有压平好的字(「受限」也已经烤进字里),
//   所以页面另带上原始的数与一个 restricted 旗:视图说 content_restricted 的那几格导出写「受限」(与屏幕同一个条件),
//   数写成数;「—」= 没有(没有目标来源 / 还没执行 / 没有化验)→ 空格,不是 0。
export type TargetRow = {
    metal: string; bounds: string; source: string
    predicted: string; predictedTone: 'ok' | 'flag' | 'muted'
    measured: string; sources: string; flag: string
    // ── TABLE-EXPORT-3c:导出读的原始值 ──
    /** 视图的 content_restricted —— 预测、已测、来源、旗四格屏幕上是「受限」 */
    restricted: boolean
    /** 预测含量 %;null = 没测(屏幕上那句「没测」) */
    predictedPct: number | null
}
export type LineRow = {
    id: string; batchCode: string; batchHref: string | null; kind: string
    planned: string; content: string; contentMuted: boolean; actual: string; difference: string; differenceNegative: boolean
    // ── TABLE-EXPORT-3c:导出读的原始值 ──
    /** 这一批任何一种金属的含量受限 —— 含量那一格屏幕上是「受限」 */
    contentRestricted: boolean
    plannedKg: number
    /** null = 还没执行(屏幕上的「—」) */
    actualKg: number | null
    differenceKg: number | null
}
export type OutcomeRow = {
    metal: string; bounds: string; assay: string; content: string; verdict: string; verdictTone: 'ok' | 'flag' | 'muted'
    // ── TABLE-EXPORT-3c:导出读的原始值 ──
    restricted: boolean
    /** 化验含量 %;null = 没有化验(屏幕上的「—」) */
    contentPct: number | null
}

/** 屏幕上的「—」是「没有」—— 文件里写空格,不写那个横杠。 */
const dashText = (v: string): ExportCell => xText(v === '—' ? null : v)

const TONE = { ok: 'text-green-700', flag: 'text-amber-700 font-medium', muted: 'text-[color:var(--brand-muted-text)] italic' }

export function TargetsTable({ rows, planCode }: { rows: TargetRow[]; planCode: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<TargetRow>[] = [
        { key: 'metal', header: t('blending.colMetal'), priority: true, render: (r) => r.metal, exportAs: (r) => xText(r.metal) },
        // 区间「1 – 3 %」/「≥ 1 %」是一段字,照屏幕写(没有目标的金属写屏幕上那句话)
        { key: 'bounds', header: t('blending.colBounds'), render: (r) => r.bounds, exportAs: (r) => dashText(r.bounds) },
        { key: 'source', header: t('blending.colTargetSource'), render: (r) => r.source, exportAs: (r) => dashText(r.source) },
        { key: 'predicted', header: t('blending.colPredicted'), priority: true, align: 'right',
          render: (r) => <span className={TONE[r.predictedTone]}>{r.predicted}</span>,
          // 数(%);没测 → 屏幕上那句「没测」(一句陈述,不是空,更不是 0)
          exportAs: (r) => r.restricted ? xRestricted : r.predictedPct === null ? xText(r.predicted) : xNum(r.predictedPct, 'pct') },
        // 「3 批里测了 2 批」与三种来源的计数是一句组合的话 —— 照屏幕写那段字
        { key: 'measured', header: t('blending.colMeasured'), render: (r) => r.measured,
          exportAs: (r) => r.restricted ? xRestricted : xText(r.measured) },
        { key: 'sources', header: t('blending.colSources'), render: (r) => r.sources,
          exportAs: (r) => r.restricted ? xRestricted : xText(r.sources) },
        { key: 'flag', header: t('blending.colFlag'), priority: true, render: (r) => r.flag,
          exportAs: (r) => r.restricted ? xRestricted : dashText(r.flag) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty={t('blending.noTargets')}
                      exportSpec={{ name: 'blending-plan-targets', title: t('blending.targetsTitle'), aboutExtra: [[t('blending.colCode'), planCode]] }} />
}

export function LinesTable({ rows, planCode }: { rows: LineRow[]; planCode: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<LineRow>[] = [
        { key: 'batch', header: t('blending.colBatch'), priority: true,
          render: (r) => r.batchHref ? <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link> : r.batchCode,
          exportAs: (r) => xText(r.batchCode) },
        { key: 'kind', header: t('blending.colKind'), render: (r) => r.kind, exportAs: (r) => xText(r.kind) },
        // kg 写在列头上,格子是光秃秃的数 —— 与屏幕一样
        { key: 'planned', header: t('blending.colPlannedKg'), priority: true, align: 'right', render: (r) => r.planned,
          exportAs: (r) => xNum(r.plannedKg, 'qty') },
        // 一格里逐种金属连起来(「镍 12 % (化验) · 钴 3 % (手填)」)—— 一段组合的话,照屏幕写字;受限 → 「受限」
        { key: 'content', header: t('blending.colContent'),
          render: (r) => <span className={r.contentMuted ? TONE.muted : ''}>{r.content}</span>,
          exportAs: (r) => r.contentRestricted ? xRestricted : xText(r.content) },
        { key: 'actual', header: t('blending.colActualKg'), align: 'right', render: (r) => r.actual,
          exportAs: (r) => xNum(r.actualKg, 'qty') },
        { key: 'difference', header: t('blending.colDifference'), align: 'right',
          render: (r) => <span className={r.differenceNegative ? 'text-amber-700' : ''}>{r.difference}</span>,
          exportAs: (r) => xNum(r.differenceKg, 'qty') },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={t('blending.noLines')}
                      exportSpec={{ name: 'blending-plan-lines', title: t('blending.linesTitle'), aboutExtra: [[t('blending.colCode'), planCode]] }} />
}

export function OutcomeTable({ rows, planCode }: { rows: OutcomeRow[]; planCode: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<OutcomeRow>[] = [
        { key: 'metal', header: t('blending.colMetal'), priority: true, render: (r) => r.metal, exportAs: (r) => xText(r.metal) },
        { key: 'bounds', header: t('blending.colBounds'), render: (r) => r.bounds, exportAs: (r) => dashText(r.bounds) },
        // 化验单号 · 日期 · 重量口径 —— 一段组合的话,照屏幕写字
        { key: 'assay', header: t('blending.colAssay'), render: (r) => r.assay,
          exportAs: (r) => r.restricted ? xRestricted : dashText(r.assay) },
        { key: 'content', header: t('blending.colAssayContent'), align: 'right', render: (r) => r.content,
          exportAs: (r) => r.restricted ? xRestricted : xNum(r.contentPct, 'pct') },
        { key: 'verdict', header: t('blending.colVerdict'), priority: true,
          render: (r) => <span className={TONE[r.verdictTone]}>{r.verdict}</span>,
          exportAs: (r) => r.restricted ? xRestricted : dashText(r.verdict) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty={t('blending.noTargets')}
                      exportSpec={{ name: 'blending-plan-outcome', title: t('blending.outcomeTitle'), aboutExtra: [[t('blending.colCode'), planCode]] }} />
}
