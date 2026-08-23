// app/settings/import/template/[table]/route.ts
// 模板下载 —— 列从【线上目录】现取(master_import_template_columns)。
//
// 【为什么是请求时查库,而不是构建时】(IMPORT-2,写在这里免得有人"改回去")
// 早先的裁定是【不要在构建时查库】,理由是:**库够不着的时候构建就会失败**。
// 这里是**请求时**,而且下面那次权限判断本来就已经打了一次 Supabase 往返 ——
// 所以查目录既没有新增依赖,也没有新增失败模式。**那条裁定的理由在这里不适用,
// 它没有被推翻。** 至于为什么不能继续用 lib/database.types.ts:
// 那份类型表达不了「GENERATED,数据库拒收供给的值」与「CHECK 闭集」,
// 而模板正是靠这两件事实才不会发出一份自己都不收的文件(见 lib/importTables.ts 抬头)。
import { isImportTable, templateCsv, type TemplateColumn } from '@/lib/importTables'
import { createClient } from '@/lib/supabase/server'

export async function GET(_req: Request, { params }: { params: Promise<{ table: string }> }) {
    const { table } = await params
    if (!isImportTable(table)) {
        return Response.json({ error: 'IMPORT_TABLE_NOT_IMPORTABLE', table }, { status: 404 })
    }
    const supabase = await createClient()
    // 【权限在这里判,不在那支 RPC 里】(IMPORT-2-fu)
    // `master_import_template_columns` 返回的是 schema 元数据(列名 / 必不必填 /
    // CHECK 取值),不是业务数据,而且它必须【不判权限】才能被 db/gate.py 在
    // 一个没有任何用户的重建库上调到(理由写在那支函数体里)。
    // 门因此在这条路由上 —— 而**"问不到答案"与"你没有权限"必须分开报**(SESSION-1c)。
    const { data: allowed, error: permErr } =
        await supabase.rpc('has_permission', { p_code: 'action.bulk_import' })
    if (permErr) {
        return Response.json({ error: 'IMPORT_TEMPLATE_UNAVAILABLE', detail: permErr.message },
                             { status: 503 })
    }
    if (allowed !== true) {
        return Response.json({ error: 'IMPORT_NOT_PERMITTED' }, { status: 403 })
    }

    const { data, error } = await supabase.rpc('master_import_template_columns', { p_table: table })
    if (error) {
        const denied = /permission|denied|42501/i.test(error.message)
        return Response.json(
            { error: denied ? 'IMPORT_NOT_PERMITTED' : 'IMPORT_TEMPLATE_UNAVAILABLE',
              detail: error.message },
            { status: denied ? 403 : 503 })
    }
    const cols = (data ?? []) as TemplateColumn[]
    if (cols.length === 0) {
        // 【0 列不是"这张表没有列"】—— 解析/查询出问题时必须响,不能发一张空表头。
        return Response.json({ error: 'IMPORT_TEMPLATE_EMPTY', table }, { status: 503 })
    }
    return new Response(templateCsv(cols), {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="${table}-template.csv"`,
            'Cache-Control': 'no-store',
        },
    })
}
