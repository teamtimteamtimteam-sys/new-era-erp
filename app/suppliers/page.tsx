// app/suppliers/page.tsx
// 供应商列表页(只读)
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import { getTranslations, getLocale } from '@/lib/i18n/server'

export default async function SuppliersPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: suppliers, error } = await supabase
        .from('suppliers')
        .select('id, code, legal_name, country, supplier_types, status, created_at')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('suppliers.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('suppliers.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('suppliers.listTitle')}</h1>
                <Link
                    href="/suppliers/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('suppliers.addButton')}
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">
                {t('suppliers.recordCount', { count: suppliers?.length ?? 0 })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">Code</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Legal Name</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Country</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Types</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Status</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Created</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {suppliers?.map((s) => (
                        <tr key={s.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/suppliers/${s.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {s.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{s.legal_name}</td>
                            <td className="border border-gray-300 px-4 py-2">{s.country}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {s.supplier_types?.join(', ')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {t('suppliers.status.' + s.status)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {new Date(s.created_at).toLocaleString(dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={s.id} legalName={s.legal_name} />
                            </td>
                        </tr>
                    ))}
                    {(!suppliers || suppliers.length === 0) && (
                        <tr>
                            <td
                                colSpan={7}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('suppliers.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
