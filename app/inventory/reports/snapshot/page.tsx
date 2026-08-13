// RPT-1:库存快照(物料 × 库位 × 状态)。
// 【未指定库位与任何一个库位一样,是一个普通分组】—— 线上 79/85 行流水没有库位。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../../Subnav'
import { fetchSnapshot, groupByLocation, statusKey } from './snapshotQuery'

export default async function SnapshotPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const rows = await fetchSnapshot()
    const groups = groupByLocation(rows)

    return (
        <>
            <Subnav />
            <div className="p-8">
                <div className="flex items-start justify-between mb-2">
                    <div>
                        <h1 className="text-2xl font-bold">{t('reports.snapshot.title')}</h1>
                        <p className="text-sm text-gray-500 mt-1">{t('reports.snapshot.desc')}</p>
                    </div>
                    <div className="flex gap-2 shrink-0">
                        <a href="/inventory/reports/snapshot/export"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.csv')}</a>
                        <a href="/inventory/reports/snapshot/pdf" target="_blank" rel="noopener noreferrer"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.pdf')}</a>
                    </div>
                </div>
                <p className="text-xs text-gray-500 mb-6">{t('reports.snapshot.derivedNote')}</p>

                {groups.length === 0 ? (
                    <p className="text-gray-500">{t('reports.snapshot.empty')}</p>
                ) : (
                    groups.map(([key, g]) => (
                        <section key={key} className="mb-8">
                            <h2 className="font-medium mb-2">
                                {g.code ? `${g.code} — ${g.name ?? ''}` : t('reports.unspecifiedLocation')}
                            </h2>
                            {!g.code && (
                                <p className="text-xs text-gray-500 mb-2">{t('reports.unspecifiedLocationNote')}</p>
                            )}
                            <table className="w-full border-collapse border border-gray-300 text-sm">
                                <thead className="bg-gray-100">
                                    <tr>
                                        <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colMaterial')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colStatus')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colQty')}</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {g.rows.map((r, i) => (
                                        <tr key={i}>
                                            <td className="border border-gray-300 px-3 py-2">
                                                <span className="font-mono text-xs">{r.material_code}</span> {r.material_name}
                                            </td>
                                            <td className="border border-gray-300 px-3 py-2">{t(statusKey(r.stock_status))}</td>
                                            <td className="border border-gray-300 px-3 py-2 text-right">{r.qty} {r.unit}</td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </section>
                    ))
                )}
            </div>
        </>
    )
}
