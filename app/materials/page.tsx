// app/materials/page.tsx
// 物料字典列表页(只读)
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import {
    CATEGORY_OPTIONS,
    CHEMISTRY_OPTIONS,
    UNIT_OPTIONS,
    labelKeyForValue,
    type MaterialSelectOption,
} from './options'
import { getTranslations, getLocale } from '@/lib/i18n/server'

export default async function MaterialsPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 把存储值反查成本地化文案;自定义自由文本(无 key)原样显示
    const display = (options: MaterialSelectOption[], value: string | null) => {
        const key = labelKeyForValue(options, value)
        return key ? t(key) : value ?? '—'
    }

    const { data: materials, error } = await supabase
        .from('materials')
        .select('id, code, name, category, chemistry, unit, status, created_at')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('materials.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('materials.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('materials.listTitle')}</h1>
                <Link
                    href="/materials/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('materials.addButton')}
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">
                {t('materials.recordCount', { count: materials?.length ?? 0 })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">Code</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('materials.colName')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('materials.colCategory')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('materials.colChemistry')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('materials.colUnit')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Status</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Created</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('materials.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {materials?.map((m) => (
                        <tr key={m.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/materials/${m.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {m.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{m.name}</td>
                            <td className="border border-gray-300 px-4 py-2">{display(CATEGORY_OPTIONS, m.category)}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                {m.chemistry ? display(CHEMISTRY_OPTIONS, m.chemistry) : '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{display(UNIT_OPTIONS, m.unit)}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {m.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {new Date(m.created_at).toLocaleString(dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={m.id} name={m.name} />
                            </td>
                        </tr>
                    ))}
                    {(!materials || materials.length === 0) && (
                        <tr>
                            <td
                                colSpan={8}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('materials.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
