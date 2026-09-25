// app/operation/processing/materialNames.ts
// ROLE-1 Batch 3b:加工两屏(新建 / 详情)的物料名,从查名视图 material_lookup 取。
//
// 仓库从这一批起持 module.processing.view,但【不持】module.materials.view ——
// 以前那两屏靠 PostgREST 把 `materials ( name )` 嵌进批次行里,换成仓库的会话,
// materials 基表被 RLS 读成零行,嵌入于是【静默】变成 null,屏幕上一排「—」。
// material_lookup 是 processing.view 读得到的视图;而 PostgREST 对视图的嵌入要靠
// 推断外键,不可靠 —— 所以不嵌,先拿批次行里的 material_id,再按 id 取一次名字映射。
// 不过滤 deleted_at:一个批次的物料后来被删了,它的名字照样要显示。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'

export async function loadMaterialNames(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>,
    ids: (string | null | undefined)[]
): Promise<Map<string, string>> {
    const unique = [...new Set(ids.filter((x): x is string => !!x))]
    if (unique.length === 0) return new Map()
    // 分块:.in() 的 id 列表走 URL,一屏几百个批次不该撞上 URL 长度上限。
    const CHUNK = 100
    const out = new Map<string, string>()
    for (let i = 0; i < unique.length; i += CHUNK) {
        const rows = mustRows(
            await supabase.from('material_lookup').select('id, name').in('id', unique.slice(i, i + CHUNK)),
            'material_lookup'
        ) as unknown as { id: string; name: string }[]
        for (const r of rows) out.set(r.id, r.name)
    }
    return out
}
