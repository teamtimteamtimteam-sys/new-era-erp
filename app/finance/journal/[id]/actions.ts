'use server'

// 冲销分录:调 reverse_journal_entry(冲销日 = 今天,默认摘要),
// 成功跳到新冲销单的详情页;错误本地化(JE_NOT_FOUND / JE_ALREADY_REVERSED / PERIOD_LOCKED / REVERSAL_BEFORE_ORIGINAL)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeFinanceError } from '../../financeErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'
import { businessToday } from '@/lib/format'

export type ReverseState = { error?: string; detail?: string }

export async function reverseEntry(entryId: string): Promise<ReverseState> {
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('reverse_journal_entry', {
        p_entry_id: entryId,
        // AP-RECON-1 Batch B(Tim Q5b):今天 = 【业务日】(新加坡)。此前取的是 UTC 日期 ——
        // 新加坡 00:00–08:00 之间它是昨天;FIN-20 之后库的 CURRENT_DATE 已经是新加坡日,
        // 那句"与 DB CURRENT_DATE 同口径"早就不成立了。有了"冲销不许早于原分录"之后,
        // 清早冲一张今天的分录会被按名拒(REVERSAL_BEFORE_ORIGINAL),所以一并改掉。
        p_reversal_date: businessToday(),
    })

    if (error) {
        return await refuseFromCoded(error.message, localizeFinanceError)
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
