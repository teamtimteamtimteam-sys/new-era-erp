// MAT-1:受控废物分类的取数(服务端)。
//
// 【从表里现读,不写死】加一种分类是往 waste_classifications 加一行,
// 不是改这个文件 —— 与 certificate_types / metal_price_indices 同一条。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { WasteClass } from './wasteClassOptions'

export async function getWasteClassifications(): Promise<WasteClass[]> {
    const supabase = await createClient()
    return mustRows(
        await supabase
            .from('waste_classifications')
            .select('code, name_en, name_zh, is_controlled')
            .eq('is_active', true)
            .order('sort_order'),
        'waste_classifications'
    ) as WasteClass[]
}
