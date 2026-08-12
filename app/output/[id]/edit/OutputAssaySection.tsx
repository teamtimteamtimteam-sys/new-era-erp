// app/output/[id]/edit/OutputAssaySection.tsx
// 产出批次页的化验区(服务端组件)。进料侧 AssaySection 是形状的出处;放在
// 金属含量面板旁边 —— 化验是含量的【出处】,不是另一件事。列表与徽标共用
// assay.* 的文案;链接指向产出侧的化验路由。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'

export type OutputAssayRow = {
    id: string
    code: string
    assay_date: string
    lab_name: string | null
    is_final: boolean
    applied_at: string | null
}

export default async function OutputAssaySection({
    batchId,
    rows,
}: {
    batchId: string
    rows: OutputAssayRow[]
}) {
    const t = await getTranslations()

    // 已记录但未应用的化验:批次含量还停在此前的数上。这里没有价格问题
    // (产出批没有应付),但回收率与 metal_value 分摊读的都是批次含量 —— 要显眼。
    const unapplied = rows.filter((r) => r.applied_at === null)

    return (
        <section className="mt-8 pt-8 border-t">
            <div className="flex justify-between items-center mb-4">
                <h2 className="text-xl font-bold">{t('assay.title')}</h2>
                <Link
                    href={`/output/${batchId}/assays/new`}
                    className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm"
                >
                    {t('assay.new')}
                </Link>
            </div>

            {unapplied.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('assay.output.unappliedWarning', { code: unapplied.map((r) => r.code).join(', ') })}
                </div>
            )}

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500">{t('assay.empty')}</p>
            ) : (
                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('assay.colCode')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('assay.colDate')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('assay.colLab')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('assay.colKind')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('assay.colApplied')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        <Link
                                            href={`/output/${batchId}/assays/${r.id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.code}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{r.assay_date}</td>
                                    <td className="border border-gray-300 px-3 py-2">{r.lab_name ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <span
                                            className={
                                                'px-2 py-0.5 rounded text-xs ' +
                                                (r.is_final
                                                    ? 'bg-gray-200 text-gray-700'
                                                    : 'bg-amber-100 text-amber-800')
                                            }
                                        >
                                            {r.is_final ? t('assay.kindFinal') : t('assay.kindPreliminary')}
                                        </span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <span
                                            className={
                                                'px-2 py-0.5 rounded text-xs ' +
                                                (r.applied_at
                                                    ? 'bg-green-100 text-green-800'
                                                    : 'bg-gray-200 text-gray-600')
                                            }
                                        >
                                            {r.applied_at ? t('assay.applied') : t('assay.notApplied')}
                                        </span>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </section>
    )
}
