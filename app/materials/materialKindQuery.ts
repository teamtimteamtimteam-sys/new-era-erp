// PROC-1:物料种类的取数(服务端)。
//
// 【从表里现读,不写死】加一种物料种类是往 material_kinds 加一行,不是改这个文件
// —— 与 waste_classifications / certificate_types / metal_price_indices 同一条。
// 这正是 PROC-0b 里"把要预留的东西做成【数据】而不是【列】"那条指令的兑现处。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { MaterialKind } from './materialKindOptions'

export async function getMaterialKinds(): Promise<MaterialKind[]> {
    const supabase = await createClient()
    return mustRows(
        await supabase
            .from('material_kinds')
            .select('code, name_en, name_zh, may_ever_be_processed, has_condition_axes')
            .eq('is_active', true)
            .order('sort_order'),
        'material_kinds'
    ) as MaterialKind[]
}
