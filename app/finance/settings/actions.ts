'use server'

// 期间锁设置:更新单行 finance_settings.locked_before(null = 解锁),盖 updated_by。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'

export type LockState = { error?: string }

export async function setPeriodLock(lockDate: string | null): Promise<LockState> {
    const t = await getTranslations()

    if (lockDate !== null && (!lockDate || Number.isNaN(Date.parse(lockDate)))) {
        return { error: t('finance.errDate') }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('finance_settings')
        .update({
            locked_before: lockDate,
            updated_by: user?.id ?? null,
        })
        .eq('id', true)

    if (error) {
        return { error: t('finance.saveError', { message: error.message }) }
    }

    revalidatePath('/finance')
    revalidatePath('/finance/settings')
    return {}
}
