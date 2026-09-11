// app/components/inventory/MovementTimeline.tsx
// 只读的库存流水时间线。服务端组件(异步),行由调用页按 occurred_at DESC 排好后传入。
// 结余(Σ qty_delta)按不变式恒等于该批次的 remaining_qty。
import { getTranslations } from '@/lib/i18n/server'
import { type MovementRow } from './movementTypes'
import MovementTimelineTable, { type MovementTableRow } from './MovementTimelineTable'

export default async function MovementTimeline({
    rows,
    unit,
}: {
    rows: MovementRow[]
    unit: string
}) {
    const t = await getTranslations()
    const total = rows.reduce((s, r) => s + r.qty_delta, 0)

    // TABLE-CONVERT-6:行【在服务端压平】—— Column.render 是函数,过不了
    // server→client 那道边界,所以表住在 ./MovementTimelineTable.tsx 里。
    // 带符号 + 单位在这一侧拼好(与转换前逐字相同);颜色那一半跟着走。
    const tableRows: MovementTableRow[] = rows.map((r) => ({
        key: r.id,
        timeText: r.occurred_at_display,
        typeText: t('movements.type.' + r.movement_type),
        bucketText: t('movements.bucket.' + r.stock_status),
        qtyText: `${(r.qty_delta > 0 ? '+' : '') + r.qty_delta} ${unit}`,
        qtyNegative: r.qty_delta < 0,
        runHref: r.run ? `/operation/processing/${r.run.id}` : null,
        runCode: r.run ? r.run.code : null,
        businessDate: r.business_date ?? '—',
        notes: r.notes ?? '—',
    }))

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="mb-4">{t('movements.title')}</h2>

            {/* TABLE-CONVERT-6:空态搬进 DataTable 的 empty prop(同一个 movements.empty),
                旧那一支不留 —— 留着 prop 就永远到不了(TABLE-CONVERT-3 §6.1)。 */}
            <MovementTimelineTable rows={tableRows} />

            {/* 结余仍旧只在【有行】的时候画 —— 这一条与空态无关,转换前后一样。 */}
            {rows.length > 0 && (
                <p className="text-sm mt-3">
                    <span className="text-gray-600 mr-1">{t('movements.sumLabel')}:</span>
                    <span className="font-mono">{total} {unit}</span>
                </p>
            )}
        </section>
    )
}
