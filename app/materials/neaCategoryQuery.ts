// MES-3a(2026-10-06,MES-3a Step 0 Q4):NEA 废物类别字典(启用的那些)。读策略要物料 / 执照 / 库存 / 进料 / 产出任一查看码。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { NeaCategory } from './neaCategoryOptions'

export async function getNeaCategories(): Promise<NeaCategory[]> {
    const supabase = await createClient()
    return mustRows(
        await supabase.from('nea_waste_categories').select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
        'nea_waste_categories'
    ) as NeaCategory[]
}
