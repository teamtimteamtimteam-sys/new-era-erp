// RPT-1:流水台账(带过滤)。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../../Subnav'
import { fetchLedger, parseLedgerParams, flatten } from './ledgerQuery'
import { statusKey } from '../snapshot/snapshotQuery'

export default async function LedgerPage({
    searchParams,
}: {
    searchParams: Promise<Record<string, string | undefined>>
}) {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const sp = await searchParams
    const params = parseLedgerParams(sp)
    const rows = await fetchLedger(params)
    const qs = new URLSearchParams(
        Object.entries({ from: params.from, to: params.to, material_id: params.materialId, batch: params.batchCode })
            .filter(([, v]) => v) as [string, string][]
    ).toString()

    return (
        <>
            <Subnav />
            <div className="p-8">
                <div className="flex items-start justify-between mb-2">
                    <div>
                        <h1 className="text-2xl font-bold">{t('reports.ledger.title')}</h1>
                        <p className="text-sm text-gray-500 mt-1">{t('reports.ledger.desc')}</p>
                    </div>
                    <div className="flex gap-2 shrink-0">
                        <a href={`/inventory/reports/ledger/export?${qs}`}
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.csv')}</a>
                        <a href={`/inventory/reports/ledger/pdf?${qs}`} target="_blank" rel="noopener noreferrer"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.pdf')}</a>
                    </div>
                </div>

                {/* 【默认 90 天,而且说出来】—— 一个默认过滤了却不说的报表,
                    会让人以为"就这么多流水"。 */}
                <form method="get" className="flex flex-wrap items-end gap-3 my-4">
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.from')}</label>
                        <input type="date" name="from" defaultValue={params.from}
                               className="border border-gray-300 px-2 py-1 rounded text-sm" />
                    </div>
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.to')}</label>
                        <input type="date" name="to" defaultValue={params.to}
                               className="border border-gray-300 px-2 py-1 rounded text-sm" />
                    </div>
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.material')}</label>
                        <input type="text" name="material_id" defaultValue={params.materialId}
                               placeholder="MAT-…" className="border border-gray-300 px-2 py-1 rounded text-sm w-36" />
                    </div>
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">{t('reports.ledger.batch')}</label>
                        <input type="text" name="batch" defaultValue={params.batchCode}
                               placeholder="IN-…" className="border border-gray-300 px-2 py-1 rounded text-sm w-36" />
                    </div>
                    <button type="submit" className="border border-gray-300 px-3 py-1 rounded text-sm hover:bg-gray-50">
                        {t('reports.ledger.apply')}
                    </button>
                </form>
                <p className="text-xs text-gray-500 mb-4">{t('reports.ledger.windowNote')}</p>

                {rows.length === 0 ? (
                    <p className="text-gray-500">{t('reports.ledger.empty')}</p>
                ) : (
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colDate')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colBatch')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colMaterial')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colLocation')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colType')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colStatus')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colQty')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => {
                                const f = flatten(r)
                                return (
                                    <tr key={r.id}>
                                        <td className="border border-gray-300 px-3 py-2">{f.date || '—'}</td>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{f.batch}</td>
                                        <td className="border border-gray-300 px-3 py-2">{f.material}</td>
                                        <td className="border border-gray-300 px-3 py-2">
                                            {f.location || <span className="text-gray-400">{t('reports.unspecifiedLocation')}</span>}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2">{f.type}</td>
                                        <td className="border border-gray-300 px-3 py-2">{t(statusKey(f.status))}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right">{f.qty}</td>
                                    </tr>
                                )
                            })}
                        </tbody>
                    </table>
                )}
            </div>
        </>
    )
}
