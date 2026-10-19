'use server'

// MES-9a(2026-10-19,MES-9 Step 0 Q24 · Q26):给 / 清 V38 · V40 —— set_account_setting 在库里查 action.manage_permissions、判形状。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizePortalError } from '@/app/portal/portalErrorCodes'

export async function setAccountSetting(key: 'initial_password_valid_days' | 'password_min_length', value: number | null): Promise<{ error?: string }> {
    if (value !== null && !Number.isInteger(value)) value = NaN
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_account_setting', { p_key: key, p_value: Number.isNaN(value as number) ? -1 : (value as number) })
    if (error) return { error: (await localizePortalError(error.message)).text }
    revalidatePath('/settings/accounts')
    return {}
}
