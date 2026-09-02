'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '../../errorCodes'

export type DeleteProcessingState = { error?: string }

// AUDEL-1b:理由【必填】,而【录入框是 AUDEL-2】。
// 在那之前,界面传空串 → 数据库按名拒 → 屏幕上是一句看得懂的"请填写理由"。
// 这是刻意的:一个大声拒绝的按钮,好过一个悄悄写下空理由的按钮。
export async function deleteProcessingRun(
    runId: string,
    reason: string = ''
): Promise<DeleteProcessingState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('rollback_processing_run', {
        p_run_id: runId,
        p_reason: reason,
    })

    if (error) {
        return { error: await localizeProcessingError(error.message) }
    }

    revalidatePath('/operation/processing')
    revalidatePath('/inbound')
    revalidatePath('/output')
    revalidatePath('/inventory')
    return {}
}
