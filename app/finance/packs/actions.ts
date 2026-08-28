'use server'

// app/finance/packs/actions.ts
// GLEXPORT-1:存档一份包。校验【全部】在数据库里 —— 页面不重复判断一遍
// (页面与服务端各写一份同一条规矩,是本仓库付过四次账的形状)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizePackError } from '../packErrorCodes'

export async function producePack(
    month: string, notes: string, supersedeReason: string,
): Promise<{ error?: string; code?: string }> {
    const supabase = await createClient()
    // 【空一律送 undefined,不替人填】"这个月已经有一份了"这条要不要理由,
    // 由数据库那条具名拒绝答话(PACK_SUPERSEDE_REASON_REQUIRED),
    // 在这里先判一次就是同一条规矩的第二处实现。
    const { data, error } = await supabase.rpc('freeze_management_pack', {
        p_period_month: `${month}-01`,
        ...(notes.trim() ? { p_notes: notes.trim() } : {}),
        ...(supersedeReason.trim() ? { p_supersede_reason: supersedeReason.trim() } : {}),
    })
    if (error) return { error: await localizePackError(error.message) }
    revalidatePath('/finance/packs')
    return { code: (data as { code?: string } | null)?.code }
}
