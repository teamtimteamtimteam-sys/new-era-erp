'use server'

// 冲销分录:调 reverse_journal_entry(冲销日 = 今天,默认摘要),
// 成功跳到新冲销单的详情页;错误本地化(JE_NOT_FOUND / JE_ALREADY_REVERSED / PERIOD_LOCKED)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeFinanceError } from '../../financeErrorCodes'

export type ReverseState = { error?: string }

export async function reverseEntry(entryId: string): Promise<ReverseState> {
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('reverse_journal_entry', {
        p_entry_id: entryId,
        p_reversal_date: new Date().toISOString().slice(0, 10), // 今天(UTC,与 DB CURRENT_DATE 同口径)
    })

    if (error) {
        return { error: await localizeFinanceError(error.message) }
    }

    const reversalId = (data as { reversal_id?: string } | null)?.reversal_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath(`/finance/journal/${entryId}`)

    if (reversalId) {
        redirect(`/finance/journal/${reversalId}`)
    }
    return {}
}
