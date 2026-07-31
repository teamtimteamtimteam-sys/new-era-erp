// app/inbound/[id]/edit/AssaySection.tsx
// 批次页的化验区(服务端组件 —— 只有列表与链接,不需要客户端状态)。
// 位置在"金属含量"与"计价"之间:含量从哪来 → 化验 → 价格往哪去,读下来是一条线。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'

export type AssayRow = {
    id: string
    code: string
    assay_date: string
    lab_name: string | null
    is_final: boolean
    applied_at: string | null
}

export default async function AssaySection({
    batchId,
    rows,
}: {
    batchId: string
    rows: AssayRow[]
}) {
    const t = await getTranslations()

    // 已记录但未应用的化验:价格还停在此前的含量上 —— 这是钱没算对,要显眼
    const unapplied = rows.filter((r) => r.applied_at === null)

    return (
        <section className="mt-8 pt-8 border-t">
            <div className="flex justify-between items-center mb-4">
                <h2 className="text-xl font-bold">{t('assay.title')}</h2>
                <Link
                    href={`/inbound/${batchId}/assays/new`}
                    className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm"
                >
                    {t('assay.new')}
                </Link>
            </div>

            {unapplied.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('assay.unappliedWarning', { code: unapplied.map((r) => r.code).join(', ') })}
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
                                            href={`/inbound/${batchId}/assays/${r.id}`}
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
