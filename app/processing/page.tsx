// app/processing/page.tsx
// 加工单列表页(只读,删除在详情页)
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'

export default async function ProcessingPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: runs, error } = await supabase
        .from('processing_runs')
        .select('id, code, process_date, total_input, total_output, loss_qty, status, created_at')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('processing.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('processing.listTitle')}</h1>
                <Link
                    href="/processing/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('processing.addButton')}
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">
                {t('processing.recordCount', { count: runs?.length ?? 0 })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">Code</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colProcessDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colTotalInput')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colTotalOutput')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colLoss')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Status</th>
                    </tr>
                </thead>
                <tbody>
                    {runs?.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/processing/${r.id}`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {r.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.process_date ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{r.total_input ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{r.total_output ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                {r.loss_qty ?? '—'}
                                {r.loss_qty != null && r.total_input
                                    ? ` (${((r.loss_qty / r.total_input) * 100).toFixed(1)}%)`
                                    : ''}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {r.status}
                                </span>
                            </td>
                        </tr>
                    ))}
                    {(!runs || runs.length === 0) && (
                        <tr>
                            <td
                                colSpan={6}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('processing.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
