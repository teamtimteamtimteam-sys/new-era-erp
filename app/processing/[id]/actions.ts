'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'

export type DeleteProcessingState = { error?: string }

export async function deleteProcessingRun(
    runId: string
): Promise<DeleteProcessingState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('rollback_processing_run', {
        p_run_id: runId,
    })

    if (error) {
        return { error: error.message }
    }

    revalidatePath('/processing')
    revalidatePath('/inbound')
    revalidatePath('/output')
    revalidatePath('/inventory')
    return {}
}
