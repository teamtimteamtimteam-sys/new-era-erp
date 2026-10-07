// MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q4,Tim):电芯结构 —— 收货两条路与两种批次页共用的读取。
//
// 【适用与否问的是【形态】,而"不知道"不是"不适用"】只有仍装着电芯的形态(material_forms.implies_dismantling)有结构可言;
//   库里的 guard_batch_cell_construction 对【没有形态】的物料放行,所以页面也放行(两边给同一个答案):
//   carries[materialId] = true(装电芯)· false(不装 —— 不摆这一格)· 不在表里(没有形态 —— 照常摆)。
// 【读的都是普通的读路】cell_constructions(加工 / 进料 / 产出任一查看码)· material_lookup(物料查名视图,MES-4b 加了 form_code)·
//   material_forms(目录,人人可读)。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'

export type CellConstructionOption = { code: string; name_en: string; name_zh: string; is_determined: boolean }
export type CellConstructionData = { options: CellConstructionOption[]; carries: Record<string, boolean> }

export async function loadCellConstructionData(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>
): Promise<CellConstructionData> {
    const [ccRes, matRes, formRes] = await Promise.all([
        supabase.from('cell_constructions').select('code, name_en, name_zh, is_determined').eq('is_active', true).order('sort_order'),
        supabase.from('material_lookup').select('id, form_code').is('deleted_at', null),
        supabase.from('material_forms').select('code, implies_dismantling'),
    ])
    const options = mustRows(ccRes, 'cell_constructions') as CellConstructionOption[]
    const mats = mustRows(matRes, 'material_lookup') as unknown as { id: string; form_code: string | null }[]
    const forms = new Map((mustRows(formRes, 'material_forms') as { code: string; implies_dismantling: boolean }[])
        .map((f) => [f.code, f.implies_dismantling]))
    const carries: Record<string, boolean> = {}
    for (const m of mats) {
        if (!m.form_code) continue          // ← 没有形态:不进这张表(照常摆出来)
        const v = forms.get(m.form_code)
        if (v !== undefined) carries[m.id] = v
    }
    return { options, carries }
}
