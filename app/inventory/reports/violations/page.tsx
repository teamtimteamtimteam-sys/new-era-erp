// RPT-1:分类违规报表。三段,而【只有第一段是违规】。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { fetchViolations, type UndecidedRow } from './violationsQuery'

function Undecided({ title, note, colA, colB, rows, qtyLabel }: {
    title: string; note: string; colA: string; colB: string; rows: UndecidedRow[]; qtyLabel: string
}) {
    if (rows.length === 0) return null
    return (
        <section className="mb-8">
            <h2 className="font-medium mb-1">{title}</h2>
            <p className="text-xs text-gray-500 mb-2">{note}</p>
            <table className="w-full border-collapse border border-gray-300 text-sm">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left">{colA}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{colB}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{qtyLabel}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r, i) => (
                        <tr key={i}>
                            <td className="border border-gray-300 px-3 py-2">
                                <span className="font-mono text-xs">{r.code}</span> {r.name}
                            </td>
                            <td className="border border-gray-300 px-3 py-2">{r.other}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right">{r.qty} {r.unit}</td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </section>
    )
}

export default async function ViolationsPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const { violations, unconfigured, unclassified } = await fetchViolations()

    return (
        <>
            <div className="p-8">
                <div className="flex items-start justify-between mb-2">
                    <div>
                        <h1 className="text-2xl font-bold">{t('reports.violations.title')}</h1>
                        <p className="text-sm text-gray-500 mt-1">{t('reports.violations.desc')}</p>
                    </div>
                    <div className="flex gap-2 shrink-0">
                        <a href="/inventory/reports/violations/export"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.csv')}</a>
                        <a href="/inventory/reports/violations/pdf" target="_blank" rel="noopener noreferrer"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.pdf')}</a>
                    </div>
                </div>

                {/* 【计数只数违规】—— 未决定的两段永远不进这个数 */}
                <p className="text-sm mb-1">
                    {t('reports.violations.count', { n: String(violations.length) })}
                </p>
                <p className="text-xs text-gray-500 mb-6">{t('reports.violations.countNote')}</p>

                <section className="mb-8">
                    <h2 className="font-medium mb-2">{t('reports.violations.sectionViolations')}</h2>
                    {violations.length === 0 ? (
                        <p className="text-gray-500 text-sm">{t('reports.violations.none')}</p>
                    ) : (
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colLocation')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colMaterial')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colClass')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colQty')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {violations.map((v, i) => (
                                    <tr key={i} className="bg-red-50">
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{v.location_code}</td>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{v.material_code}</td>
                                        <td className="border border-gray-300 px-3 py-2">{v.class_code}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right">{v.qty}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    )}
                </section>

                <Undecided title={t('reports.violations.sectionUnconfigured')}
                           note={t('reports.violations.unconfiguredNote')}
                           colA={t('reports.colLocation')} colB={t('reports.colMaterial')}
                           qtyLabel={t('reports.colQty')} rows={unconfigured} />
                <Undecided title={t('reports.violations.sectionUnclassified')}
                           note={t('reports.violations.unclassifiedNote')}
                           colA={t('reports.colMaterial')} colB={t('reports.colLocation')}
                           qtyLabel={t('reports.colQty')} rows={unclassified} />
            </div>
        </>
    )
}
