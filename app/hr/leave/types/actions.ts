'use server'

// app/hr/leave/types/actions.ts
// 假别与公共假期的维护。RLS 在写入策略上要 module.hr.edit,所以这里不重复判断 ——
// 没权限的人写不进去,数据库会拒。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type CfgState = { error?: string; success?: boolean }

export async function saveLeaveType(
    code: string,
    patch: {
        name_en: string
        name_zh: string
        default_days_per_year: number | null
        requires_certificate_after_days: number | null
        allows_half_day: boolean
        is_active: boolean
        sort_order: number
    }
): Promise<CfgState> {
    const supabase = await createClient()
    // code 不在 patch 里 —— 它是稳定标识,建成之后不改
    const { error } = await supabase.from('leave_types').update(patch).eq('code', code)
    if (error) return { error: error.message }
    revalidatePath('/hr/leave/types')
    return { success: true }
}

export async function saveHoliday(
    id: string | null,
    patch: { holiday_date: string; name_en: string; name_zh: string; is_active: boolean; notes: string | null }
): Promise<CfgState> {
    const supabase = await createClient()
    const { error } = id
        ? await supabase.from('public_holidays').update(patch).eq('id', id)
        : await supabase.from('public_holidays').insert(patch)
    if (error) return { error: error.message }
    revalidatePath('/hr/leave/holidays')
    revalidatePath('/hr/leave/calendar')
    return { success: true }
}

export async function deleteHoliday(id: string): Promise<CfgState> {
    const supabase = await createClient()
    const { error } = await supabase.from('public_holidays').delete().eq('id', id)
    if (error) return { error: error.message }
    revalidatePath('/hr/leave/holidays')
    return { success: true }
}
