// PROC-2b:三条物料级状态轴的取数(服务端)。
//
// 【从表里现读,不写死】加一个取值是往那三张字典加一行 —— 与 materialKindQuery /
// wasteClassQuery / certificate_types 同一条。这正是 PROC-2 把五条轴做成字典
// 换来的东西:值可以后到,而代价是一行。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { MaterialForm, MaterialSource, MaterialSizeFormat } from './materialAxesOptions'

export async function getMaterialAxes(): Promise<{
    forms: MaterialForm[]; sources: MaterialSource[]; sizeFormats: MaterialSizeFormat[]
}> {
    const supabase = await createClient()
    const [f, s, z] = await Promise.all([
        supabase.from('material_forms')
            .select('code, name_en, name_zh, implies_dismantling, may_be_sold').eq('is_active', true).order('sort_order'),
        supabase.from('material_sources')
            .select('code, name_en, name_zh, implies_never_charged').eq('is_active', true).order('sort_order'),
        supabase.from('material_size_formats')
            .select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
    ])
    return {
        forms: mustRows(f, 'material_forms') as MaterialForm[],
        sources: mustRows(s, 'material_sources') as MaterialSource[],
        sizeFormats: mustRows(z, 'material_size_formats') as MaterialSizeFormat[],
    }
}
