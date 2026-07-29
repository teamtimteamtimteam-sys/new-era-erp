'use server'

// 月结:close_period(校验月末/试算平衡 + 落关账行 + 推期间锁)/
// reopen_period(盖章保留行 + 锁回退)。错误码本地化后展示。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../financeErrorCodes'

export type CloseActionState = { error?: string }

function revalidateFinance() {
    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/finance/close')
    revalidatePath('/finance/settings')
}

export async function closePeriod(periodEnd: string): Promise<CloseActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('close_period', {
        p_period_end: periodEnd,
    })

    if (error) {
        return { error: await localizeFinanceError(error.message) }
    }

    revalidateFinance()
    return {}
}

export async function reopenPeriod(periodEnd: string, reason: string): Promise<CloseActionState> {
    const t = await getTranslations()

    const trimmed = (reason ?? '').trim()
    if (!trimmed) {
        return { error: t('finance.errors.REASON_REQUIRED') }
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('reopen_period', {
        p_period_end: periodEnd,
        p_reason: trimmed,
    })

    if (error) {
        return { error: await localizeFinanceError(error.message) }
    }

    revalidateFinance()
    return {}
}
