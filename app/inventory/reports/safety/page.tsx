// RPT-1:安全库存总览。
// 【两种"空"必须分开说】没有任何物料被监控 ≠ 所有物料都在阈值之上。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../../Subnav'
import { fetchSafety } from './safetyQuery'

export default async function SafetyPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const { rows, monitored, below } = await fetchSafety()

    return (
        <>
            <Subnav />
            <div className="p-8">
                <div className="flex items-start justify-between mb-2">
                    <div>
                        <h1 className="text-2xl font-bold">{t('reports.safety.title')}</h1>
                        <p className="text-sm text-gray-500 mt-1">{t('reports.safety.desc')}</p>
                    </div>
                    <div className="flex gap-2 shrink-0">
                        <a href="/inventory/reports/safety/export"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.csv')}</a>
                        <a href="/inventory/reports/safety/pdf" target="_blank" rel="noopener noreferrer"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.pdf')}</a>
                    </div>
                </div>

                {monitored === 0 ? (
                    // 【不是"一切正常"】—— 没有人设过任何阈值
                    <p className="text-amber-800 bg-amber-50 border border-amber-300 rounded px-4 py-3 mt-4">
                        {t('reports.safety.noneMonitored')}
                    </p>
                ) : (
                    <>
                        <p className="text-sm mb-6">
                            {below === 0
                                ? t('reports.safety.allAbove', { n: String(monitored) })
                                : t('reports.safety.someBelow', { below: String(below), n: String(monitored) })}
                        </p>
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colMaterial')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colAvailable')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colThreshold')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colShortfall')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {rows.map((r) => {
                                    const short = (r.safety_stock_qty ?? 0) - r.available_qty
                                    const isBelow = short > 0
                                    return (
                                        <tr key={r.material_id} className={isBelow ? 'bg-amber-50' : ''}>
                                            <td className="border border-gray-300 px-3 py-2">
                                                <span className="font-mono text-xs">{r.code}</span> {r.name}
                                            </td>
                                            <td className="border border-gray-300 px-3 py-2 text-right">{r.available_qty} {r.unit}</td>
                                            <td className="border border-gray-300 px-3 py-2 text-right">{r.safety_stock_qty} {r.unit}</td>
                                            <td className="border border-gray-300 px-3 py-2 text-right font-medium">
                                                {isBelow ? `${short} ${r.unit}` : '—'}
                                            </td>
                                        </tr>
                                    )
                                })}
                            </tbody>
                        </table>
                    </>
                )}
            </div>
        </>
    )
}
