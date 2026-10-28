import 'server-only'

// app/components/related/relatedRows.ts
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3c(Tim 2026-10-25)· 关联页的读取 —— 页面(related-records.tsx)与导出路由共用的那一半
// ════════════════════════════════════════════════════════════════════════════
// 页面是 keyset 分页的(20 条一页,手里只有这一屏),所以它的导出要一条服务端路由
// (`/related/<主语>/<id>/<目标>/export` · `/documents/<目标>/export`),跑【页面自己】的三层权限与同一支
// `search_related_rows`,按 keyset 一批 100 条(函数只收 1..100)取全,再用同一个映射交给表(TABLE-EXPORT-1 Q8)。
//   ★ 下面的 docType / subjectRow / shapeRelatedRows 原来写在 related-records.tsx 里,原样搬过来,两边 import 同一份 ——
//     一份权限判据两个实现,迟早各错一次(AGENTS.md「谁能看见什么只有一个求值器」)。
//   ★ 上限:第一批就带着 `total`(`count(*) OVER ()`,在翻页之前求出),超过 50,000 当场按名拒绝、说出匹配了多少行,一行都不取。
//   ★ 停止条件是【拿到 0 行】(与 fetchAllPages 同一条);游标若不前进就抛 —— 一个原地打转的循环是另一种悄悄的截断。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { getMyPermissions } from '@/lib/permissions'
import { allows } from '@/lib/modules'
import { documentHref, type DocumentLinkMode } from '@/lib/search/documentHref'
import { EXPORT_CAP, exportDenied } from '@/lib/export/serverRows'
import type { RelatedRow } from './RelatedTable'

/** 导出那一侧一批取多少 —— `search_related_rows` 只收 1..100(响亮地拒,不夹)。 */
const EXPORT_KEYSET_BATCH = 100

export type DocType = {
    key: string
    table_name: string
    route: string
    link_mode: string
    label_column: string | null
    view_permission: string[]
}

export type RowsRow = { id: string; code: string; label: string | null; total: number }

export async function docType(
    supabase: Awaited<ReturnType<typeof createClient>>, key: string,
): Promise<DocType | null> {
    return mustOne(
        await supabase.from('document_types')
            .select('key, table_name, route, link_mode, label_column, view_permission')
            .eq('key', key).maybeSingle() as { data: DocType | null; error: { message: string; code?: string } | null },
        'document_types')
}

/**
 * 主语那一行 —— **用会话身份读,所以 RLS 就是判据**(权限层 ②)。
 *
 * ★★【为什么这里有一个 cast,以及它【关掉的不是】一条会抓住错误的检查】★★
 *   表名与列名来自 `document_types`,**在运行时才知道** —— 生成的
 *   `Database` 类型按构造管不到一个运行时的表名。这不是"为了让类型过关"
 *   (AGENTS.md 点名的那一种 cast),它是类型系统本来就够不到的一格。
 *   ☞ 而真正盯着这一格的东西**存在,而且有三个**:
 *     · `check-search-registry.mjs` —— 每一条 route / link_mode 都落在真页面上;
 *     · `db/fixtures/101` —— 每个 view_permission 码都真的在该表策略的谓词里;
 *     · `db/fixtures/199` F 臂 —— 每个种类的 `code` 与 `label_column`
 *       对 authenticated **真的读得到**(6 张单据表只有列级授权)。
 */
type LooseFrom = {
    from: (table: string) => {
        select: (cols: string) => {
            eq: (col: string, val: string) => {
                maybeSingle: () => Promise<{
                    data: Record<string, unknown> | null
                    error: { message: string; code?: string } | null
                }>
            }
        }
    }
}

export async function subjectRow(
    supabase: Awaited<ReturnType<typeof createClient>>, type: DocType, id: string,
): Promise<{ code: string; label: string | null } | null> {
    const cols = type.label_column ? `code, ${type.label_column}` : 'code'
    const res = await (supabase as unknown as LooseFrom)
        .from(type.table_name).select(cols).eq('id', id).maybeSingle()
    // ★ 失败即抛。一次失败若被读成"主语看不见",屏幕上会画一块整页拒绝 ——
    //   而那是一句【关于权限的断言】,不是一句关于查询的断言。两者必须分开。
    const row = mustOne(res, `subject ${type.table_name}`)
    if (!row) return null
    return {
        code: String(row.code ?? ''),
        label: type.label_column && row[type.label_column] != null
            ? String(row[type.label_column]) : null,
    }
}

/** 一屏单据各自那一页的地址(document_detail_hrefs,INVOKER;没有逐张页面的种类得 NULL) */
export async function detailHrefs(
    supabase: Awaited<ReturnType<typeof createClient>>, key: string, ids: string[],
): Promise<Map<string, string | null>> {
    if (ids.length === 0) return new Map()
    const got = mustRows(
        await supabase.rpc('document_detail_hrefs', { p_key: key, p_ids: ids }) as {
            data: { id: string; href: string | null }[] | null; error: { message: string; code?: string } | null },
        'document_detail_hrefs')
    return new Map(got.map((g) => [g.id, g.href]))
}

/** 库里的一行 → 表的一行。★ type_list 的那 5 种没有逐张单据的落点 —— 它们是文字,不是链接(与搜索面板走同一支 documentHref)。 */
export function shapeRelatedRows(target: DocType, rows: RowsRow[], detail?: ReadonlyMap<string, string | null>): RelatedRow[] {
    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        label: r.label ?? '',
        // SYSTEM-MAP-3(grilling 第 3 条):有【那一张自己的页面】就链到它(document_detail_hrefs —— 进料批 /inbound/<id>/edit、
        //   化验单 /inbound/<批>/assays/<id> …),与单据链条同一份实现;没有的(列表类)照旧走 documentHref。
        href: detail?.get(r.id) ? (detail.get(r.id) as string) : target.link_mode === 'type_list'
            ? null
            : documentHref({
                key: target.key, route: target.route,
                linkMode: target.link_mode as DocumentLinkMode,
                id: r.id, code: r.code,
            }),
    }))
}

/**
 * 导出路由的那一半:页面的三层权限(① 目标种类的模块闸 · ② 主语读得到 · ③ 行由 RLS 过滤,函数是 INVOKER),
 * 然后按 keyset 取全。进不去 = `exportDenied()`(与页面画整页拒绝是同一个判据)。
 */
export async function relatedExportResponse(o: {
    subjectKey?: string
    subjectId?: string
    targetKey: string
}): Promise<Response> {
    const supabase = await createClient()
    const target = await docType(supabase, o.targetKey)
    if (!target) {
        throw new Error(`SEARCH_UNKNOWN_DOCUMENT_TYPE|${o.targetKey} —— 它不在 document_types 里`)
    }
    if (!allows({ all: [], any: target.view_permission }, await getMyPermissions())) return exportDenied()
    if (o.subjectKey && o.subjectId) {
        const subjType = await docType(supabase, o.subjectKey)
        if (!subjType) throw new Error(`SEARCH_UNKNOWN_DOCUMENT_TYPE|${o.subjectKey} —— 主语那一边不在 document_types 里`)
        if (!(await subjectRow(supabase, subjType, o.subjectId))) return exportDenied()
    }

    const out: RowsRow[] = []
    let after: string | undefined
    for (;;) {
        const got = mustRows(
            (await supabase.rpc('search_related_rows', {
                p_key: o.subjectKey,
                p_id: o.subjectId,
                p_target_key: o.targetKey,
                p_limit: EXPORT_KEYSET_BATCH,
                p_after_code: after,
            })) as { data: RowsRow[] | null; error: { message: string; code?: string } | null },
            'search_related_rows (export)')
        if (got.length === 0) break
        if (out.length === 0 && Number(got[0].total) > EXPORT_CAP) {
            return Response.json({ code: 'EXPORT_TOO_MANY_ROWS', count: Number(got[0].total), cap: EXPORT_CAP }, { status: 413 })
        }
        const last = got[got.length - 1].code
        if (after !== undefined && !(last < after)) {
            throw new Error(`EXPORT_READ_FAILED|search_related_rows|keyset cursor did not advance (${after} → ${last})`)
        }
        out.push(...got)
        if (out.length > EXPORT_CAP) throw new Error(`EXPORT_TOO_MANY_ROWS|search_related_rows|>${EXPORT_CAP}`)
        after = last
    }
    return Response.json({ rows: shapeRelatedRows(target, out) })
}
