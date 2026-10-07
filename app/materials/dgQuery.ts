// MES-3b(2026-10-07,MES-3b Step 0 Q11):危险品 UN 编号字典(启用的那些)。读策略要物料 / 库存 / 进料 / 产出 / 物流 / 销售任一查看码。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { DgCode } from './dgOptions'

export async function getDgCodes(): Promise<DgCode[]> {
    const supabase = await createClient()
    return mustRows(
        await supabase.from('dangerous_goods_codes').select('code, name_en, name_zh, dg_class').eq('is_active', true).order('sort_order'),
        'dangerous_goods_codes'
    ) as DgCode[]
}
