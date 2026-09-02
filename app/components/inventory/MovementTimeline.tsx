// app/components/inventory/MovementTimeline.tsx
// 只读的库存流水时间线。服务端组件(异步),行由调用页按 occurred_at DESC 排好后传入。
// 结余(Σ qty_delta)按不变式恒等于该批次的 remaining_qty。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { type MovementRow } from './movementTypes'

export default async function MovementTimeline({
    rows,
    unit,
}: {
    rows: MovementRow[]
    unit: string
}) {
    const t = await getTranslations()
    const total = rows.reduce((s, r) => s + r.qty_delta, 0)

    // 带符号 + 单位;入库(正)绿、出库(负)红
    const qtyCell = (q: number) => (
        <span className={q < 0 ? 'text-red-600' : 'text-green-700'}>
            {(q > 0 ? '+' : '') + q} {unit}
        </span>
    )

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('movements.title')}</h2>

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500">{t('movements.empty')}</p>
            ) : (
                <>
                    <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colTime')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colType')}</th>
                                {/* SO-2:桶。成对流水的两条腿在此之前读起来完全一样 ——
                                    暂扣与预留都是"状态变更(出/进)"。 */}
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colBucket')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colQty')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colRun')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colBizDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('movements.colNotes')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600 whitespace-nowrap">
                                        {r.occurred_at_display}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {t('movements.type.' + r.movement_type)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {t('movements.bucket.' + r.stock_status)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {qtyCell(r.qty_delta)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {r.run ? (
                                            <Link href={`/operation/processing/${r.run.id}`} className="text-blue-600 hover:underline">
                                                {r.run.code}
                                            </Link>
                                        ) : (
                                            '—'
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">{r.business_date ?? '—'}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">{r.notes ?? '—'}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                    </div>

                    <p className="text-sm mt-3">
                        <span className="text-gray-600 mr-1">{t('movements.sumLabel')}:</span>
                        <span className="font-mono">{total} {unit}</span>
                    </p>
                </>
            )}
        </section>
    )
}
