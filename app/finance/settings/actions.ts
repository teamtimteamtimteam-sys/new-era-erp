'use server'

// 期间锁设置:更新单行 finance_settings.locked_before(null = 解锁),盖 updated_by。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
// SOD-1:这条路【会】抛出具名拒绝了 —— 手动锁是一条直连 UPDATE,
// trg_finance_settings_sod 会用 SOD_POST_AND_CLOSE 拦住它。
// 此前这里把 error.message 原样塞进 finance.saveError,于是操作员看到的会是
// 「SOD_POST_AND_CLOSE|2026-08-31」这串管道分隔的机器码。
// **一条有句子却到不了屏幕的拒绝,等于没有句子**(IOD-2 那一课的形状)。
import { localizeFinanceError } from '../financeErrorCodes'

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
        // 已编码的 DB 拒绝 → 人话;其余 → 原样(localizeFinanceError 自己分辨)
        return { error: await localizeFinanceError(error.message) }
    }

    revalidatePath('/finance')
    revalidatePath('/finance/settings')
    return {}
}
