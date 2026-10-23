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
import { mustRows, mustCount } from '@/lib/db-helpers'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { IMPORTS_SHOWN, importsCount, importsPage, shapeImportRows } from './importRows'
import { RefusalPage } from '@/app/components/ui/refusal'
import { IMPORT_TABLES, type TemplateColumn } from '@/lib/importTables'
import ImportForm from './ImportForm'
import { ListPage } from '@/app/components/ui/list-page'
import ImportHistoryTable, { type ImportBatchRow } from './ImportHistoryTable'
import { formatTrailStamp } from '@/lib/dates'
import ListTrail from '@/app/components/trail/ListTrail'
import { trailCount } from '@/app/components/trail/AuditTrail'

export default async function ImportPage({
    searchParams,
}: {
    searchParams: Promise<{ trail?: string | string[] }>
}) {
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
    // ★ TABLE-EXPORT-2b-1(Tim 2026-10-23 Q1):读取与映射搬进 importRows.ts,与导出路由共用;只画最近 IMPORTS_SHOWN 次,而且说出来。
    const [batches, total] = await Promise.all([
        importsPage(supabase, 0, IMPORTS_SHOWN - 1).then((r) => mustRows(r, 'import_batches')),
        importsCount(supabase).then((r) => mustCount(r, 'import_batches count')),
    ])

    // CONV-5:套 CONV-1 的两文件模板。ImportForm 是这一页存在的理由,
    // 它与页顶 intro 都画在状态分支之前;历史那一段的空
    // (【第三种空】还没有导入过任何东西)由 DataTable 自己的 empty 说。
    // AUDIT-TRAIL-1d-1(Tim 的 Q24):批次表多一栏"谁"—— 与别的页面同一个取名器(不持 hr.view 的读者只认得出自己)
    const tableRows: ImportBatchRow[] = await shapeImportRows(supabase, batches)

    return (
        <ListPage
            title={t('import.title')}
            intro={t('import.intro')}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <ImportForm tables={[...IMPORT_TABLES]} guide={guide} />

            <h2 className="mt-10 mb-2">{t('import.history')}</h2>
            <RowCapNotice shown={tableRows.length} total={total} />
            <ImportHistoryTable rows={tableRows} empty={t('import.historyEmpty')} serverRows="/settings/import/history/export" />
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('import.historyIsALog')}</p>
            {/* AUDIT-TRAIL-1d-1(Q24):同样那几次导入的审计记录 —— 被导进去的那几行与批次之间【没有】回指(import_batches 的
                表注释不许),所以这一块只说批次自己:谁、何时、哪个文件、多少行、编号从哪到哪 */}
            <ListTrail intro="listTrail.intro.importBatches" show={trailCount((await searchParams).trail)}
                records={batches.map((b) => ({ subject: 'import_batch' as const, id: b.id as string,
                    // Record 一栏只说英文、不放文件名:文件名是人起的名字(可以是 "good.csv" 这种带点的串),它已经作为【人敲的字】
                    //   在那一条的标题里了;放在 Record 一栏会被冒烟的机器字判据读成一个代码(实测:第一次冒烟就是这么红的)
                    label: `Import ${formatTrailStamp(b.imported_at as string)}` }))} />
        </ListPage>
    )
}
