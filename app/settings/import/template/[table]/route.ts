// app/settings/import/template/[table]/route.ts
// 模板下载 —— 列从 lib/database.types.ts 现读(见那个文件的抬头:为什么是它,
// 为什么在请求时,以及为什么 next.config.ts 里必须有那一行 trace)。
import { isImportTable, templateCsv } from '@/lib/importTables'
import { createClient } from '@/lib/supabase/server'

export async function GET(_req: Request, { params }: { params: Promise<{ table: string }> }) {
    const { table } = await params
    if (!isImportTable(table)) {
        return Response.json({ error: 'IMPORT_TABLE_NOT_IMPORTABLE', table }, { status: 404 })
    }
    // 【模板也要过权限】一份模板会把这套 schema 的列名与必填项摊开给人看。
    // 它不是秘密,但它属于这条路,而这条路有一个码。
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('has_permission', { p_code: 'action.bulk_import' })
    if (error) {
        // 【问不到答案 ≠ 你没有权限】—— SESSION-1c 那条规矩,这里同样成立。
        return Response.json({ error: 'PERMISSION_INDETERMINATE' }, { status: 503 })
    }
    if (data !== true) {
        return Response.json({ error: 'IMPORT_NOT_PERMITTED' }, { status: 403 })
    }
    return new Response(templateCsv(table), {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="${table}-template.csv"`,
            'Cache-Control': 'no-store',
        },
    })
}
