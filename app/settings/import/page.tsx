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
import { RefusalPage } from '@/app/components/ui/refusal'
import { IMPORT_TABLES, type TemplateColumn } from '@/lib/importTables'
import ImportForm from './ImportForm'
import { ListPage } from '@/app/components/ui/list-page'
import ImportHistoryTable, { type ImportBatchRow } from './ImportHistoryTable'

export default async function ImportPage() {
    const t = await getTranslations()
    const allowed = await can('action.bulk_import')

    // 【三种空,三句话】(5.3)第一种在这里:你【不能】导入。
    // 它不是"没有东西可导",也不是"文件是空的" —— 受限不是零。
    if (!allowed) {
        // ★【CONV-0 ①:这里曾经是那块屏的第三份逐字副本 —— 现在走 <RefusalPage>】★
        //   可见变化只有一处:它现在也有「回首页」了(理由见 RefusalPage 抬头)。
        return (
            <RefusalPage
                title={t('import.title')}
                statement={t('import.denied')}
                hint={t('import.deniedHint')}
                backHomeLabel={t('common.backHome')}
            />
        )
    }

    const supabase = await createClient()

    // 【列指南与模板同一个来源】—— 一份 RPC,两处渲染(文件里第三行 / 屏幕上这一块)。
    // 不在这里抄第二份取值清单:那正是本刀在拆的东西。
    // 【"拿不到"不是"这张表没有受限列"】—— 两者必须在屏幕上分得开。
    // 上一版在 error 时返回空数组,于是指南整块消失,读起来像"这张表没什么可说的"。
    // 那正是 lib/permissions.ts 存在的全部理由,换了一块屏幕而已。
    const guideEntries = await Promise.all(IMPORT_TABLES.map(async (tbl) => {
        const res = await supabase.rpc('master_import_template_columns', { p_table: tbl })
        if (res.error) return [tbl, { status: 'unavailable' as const, cols: [] }] as const
        return [tbl, { status: 'ok' as const, cols: (res.data ?? []) as TemplateColumn[] }] as const
    }))
    const guide = Object.fromEntries(guideEntries)

    // 【失败不是空集】—— mustRows,不是 ?? []。
    const batches = mustRows(
        await supabase
            .from('import_batches')
            .select('id, target_table, file_name, row_count, code_first, code_last, imported_at')
            .order('imported_at', { ascending: false })
            .limit(20),
        'import_batches'
    )

    // CONV-5:套 CONV-1 的两文件模板。ImportForm 是这一页存在的理由,
    // 它与页顶 intro 都画在状态分支之前;历史那一段的空
    // (【第三种空】还没有导入过任何东西)由 DataTable 自己的 empty 说。
    const tableRows: ImportBatchRow[] = batches.map((b) => ({
        id: b.id as string,
        whenLabel: new Date(b.imported_at as string).toLocaleString(),
        tableLabel: t(`import.table.${b.target_table}`),
        fileName: b.file_name as string,
        rowCount: b.row_count as number,
        codeRange: `${b.code_first as string} … ${b.code_last as string}`,
    }))

    return (
        <ListPage
            title={t('import.title')}
            intro={t('import.intro')}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <ImportForm tables={[...IMPORT_TABLES]} guide={guide} />

            <h2 className="text-lg font-semibold mt-10 mb-2">{t('import.history')}</h2>
            <ImportHistoryTable rows={tableRows} empty={t('import.historyEmpty')} />
            <p className="text-xs text-gray-500 mt-2">{t('import.historyIsALog')}</p>
        </ListPage>
    )
}
