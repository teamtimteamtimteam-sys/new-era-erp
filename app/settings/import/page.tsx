// app/settings/import/page.tsx
// IMPORT-1:批量导入主数据的那扇门。
//
// 【为什么另立一个权限 action.bulk_import,而不是沿用 action.manage_permissions】
// 沿用会重演 DICT-ADMIN 之前那个缺陷:一个物料编辑员永远够不到物料那张屏。
// 而批量导入也【不等于】"能编辑一家供应商" —— 它是这一刀里唯一一个能一次
// 放进 500 行错数据的动作,所以它自己一个码,而且只发给 admin。
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { IMPORT_TABLES } from '@/lib/importTables'
import ImportForm from './ImportForm'

export default async function ImportPage() {
    const t = await getTranslations()
    const allowed = await can('action.bulk_import')

    // 【三种空,三句话】(5.3)第一种在这里:你【不能】导入。
    // 它不是"没有东西可导",也不是"文件是空的" —— 受限不是零。
    if (!allowed) {
        return (
            <div className="p-8 max-w-2xl" data-access-denied="1">
                <h1 className="text-2xl font-bold mb-4">{t('import.title')}</h1>
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded">
                    <p className="font-medium">{t('import.denied')}</p>
                    <p className="text-sm mt-1">{t('import.deniedHint')}</p>
                </div>
            </div>
        )
    }

    const supabase = await createClient()
    // 【失败不是空集】—— mustRows,不是 ?? []。
    const batches = mustRows(
        await supabase
            .from('import_batches')
            .select('id, target_table, file_name, row_count, code_first, code_last, imported_at')
            .order('imported_at', { ascending: false })
            .limit(20),
        'import_batches'
    )

    return (
        <div className="p-6 max-w-5xl">
            <h1 className="text-2xl font-semibold mb-1">{t('import.title')}</h1>
            <p className="text-sm text-gray-600 mb-6">{t('import.intro')}</p>

            <ImportForm tables={[...IMPORT_TABLES]} />

            <h2 className="text-lg font-semibold mt-10 mb-2">{t('import.history')}</h2>
            {batches.length === 0 ? (
                /* 【第三种空】还没有导入过任何东西 —— 与上面两种都不是一回事。 */
                <p className="text-sm text-gray-500">{t('import.historyEmpty')}</p>
            ) : (
                <table className="w-full text-sm border border-gray-200">
                    <thead className="bg-gray-50 text-left">
                        <tr>
                            <th className="px-3 py-2">{t('import.col.when')}</th>
                            <th className="px-3 py-2">{t('import.col.table')}</th>
                            <th className="px-3 py-2">{t('import.col.file')}</th>
                            <th className="px-3 py-2 text-right">{t('import.col.rows')}</th>
                            <th className="px-3 py-2">{t('import.col.codeRange')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {batches.map((b) => (
                            <tr key={b.id as string} className="border-t border-gray-200">
                                <td className="px-3 py-2">{new Date(b.imported_at as string).toLocaleString()}</td>
                                <td className="px-3 py-2">{t(`import.table.${b.target_table}`)}</td>
                                <td className="px-3 py-2">{b.file_name as string}</td>
                                <td className="px-3 py-2 text-right">{b.row_count as number}</td>
                                <td className="px-3 py-2 font-mono text-xs">
                                    {b.code_first as string} … {b.code_last as string}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
            <p className="text-xs text-gray-500 mt-2">{t('import.historyIsALog')}</p>
        </div>
    )
}
