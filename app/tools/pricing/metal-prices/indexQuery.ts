// METAL-2:指数选项的【取数】那一半 —— 服务端专用。
//
// 类型、哨兵与表单解析在 indexOptions.ts,那个文件必须保持纯:客户端组件
// (IndexPicker)要 import 它,而它一旦拉进 lib/supabase/server(next/headers),
// 构建会以 "You're importing a module that depends on next/headers" 失败。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { MetalPriceIndex } from './indexOptions'

export async function getMetalPriceIndices(): Promise<MetalPriceIndex[]> {
    const supabase = await createClient()
    return mustRows(
        await supabase
            .from('metal_price_indices')
            .select('code, name_en, name_zh, quote_currency')
            .eq('is_active', true)
            .order('sort_order'),
        'metal_price_indices'
    ) as MetalPriceIndex[]
}
