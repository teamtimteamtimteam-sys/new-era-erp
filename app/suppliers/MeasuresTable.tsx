'use client'

// MES-8a:一份评分卡计数的表 —— 预览(评审表单)与历史(每一次评审抄下的那一份)用同一个组件,所以两边说的是同一种话。
//   ★「Not compared」不是 0(Q3):count 是 null 时这一格写 "Not compared",并说出有几条没比过;0 只在真的比过、一条都没有时出现。
//   等级超标只显示、不计分,带着 CONTRACT-1 的说明。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xInt, xNum } from '@/lib/export/cells'
import { SCORED_MEASURES, type Measures, type ScoredMeasure } from './scorecardTypes'

// TABLE-EXPORT-1:countRaw / weightRaw 是导出读的原始值 —— count 是画出来的节点,weight 是画出来的字。
//   countRaw 为 null = 没比过(屏幕上那句 "Not compared",导出写同一句话,不写 0)。
type Row = {
    key: string; label: string; count: React.ReactNode; compared: string; weight: string
    countRaw: number | null; weightRaw: number | null
}

export default function MeasuresTable({ measures, weights }: {
    measures: Measures
    weights: Record<ScoredMeasure, number> | null
}) {
    const t = useTranslations()
    const rows: Row[] = SCORED_MEASURES.map((k) => {
        const c = measures.scored[k]
        return {
            key: k,
            label: t('scorecards.measure.' + k),
            count: c.count === null
                ? <span className="text-amber-800" data-not-compared="1">{t('scorecards.notCompared')}</span>
                : String(c.count),
            compared: c.compared === undefined ? '—' : t('scorecards.comparedOf', { compared: c.compared, not: c.not_compared ?? 0 }),
            weight: weights ? String(weights[k]) : '—',
            countRaw: c.count,
            weightRaw: weights ? weights[k] : null,
        }
    })
    rows.push({
        key: 'grade_breaches',
        label: t('scorecards.measure.grade_breaches'),
        count: String(measures.shown.grade_breaches.count),
        compared: t('scorecards.gradeBreachesNotScored'),
        weight: '—',
        countRaw: measures.shown.grade_breaches.count,
        weightRaw: null,
    })
    const columns: ExportableColumn<Row>[] = [
        { key: 'label', header: t('scorecards.colMeasure'), priority: true, render: (r) => <span data-measure={r.key}>{r.label}</span>,
          exportAs: (r) => xText(r.label) },
        { key: 'count', header: t('scorecards.colCount'), priority: true, render: (r) => r.count,
          // ★ Q3 同一条:「Not compared」不是 0 —— 导出里也是那句话
          exportAs: (r) => r.countRaw === null ? xText(t('scorecards.notCompared')) : xInt(r.countRaw) },
        { key: 'compared', header: t('scorecards.colCompared'), render: (r) => r.compared, exportAs: (r) => xText(r.compared) },
        { key: 'weight', header: t('scorecards.colWeight'), render: (r) => r.weight, exportAs: (r) => xNum(r.weightRaw, 'qty') },
    ]
    return (
        <div data-scorecard-measures="1">
            <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={null}
                exportSpec={{ name: 'supplier-scorecard-measures', title: t('scorecards.panelTitle') }} />
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                {t('scorecards.receiptsLine', { n: measures.receipts, noLine: measures.receipts_without_po_line,
                    withdrawn: measures.shown.disputes_withdrawn.count })}
            </p>
        </div>
    )
}
