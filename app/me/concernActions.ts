'use server'

// ESG-2(Tim 2026-10-31 Q11 · Q12 · Q13):/me 上「提出一个关切」—— 一位员工交一件举报。转达给 whistleblowing_report_file(要有员工档案,
//   不要任何码);「这件事涉及 CCO」必须答(是 / 否,没有默认 —— 库按名拒)。保密,不是匿名:表单照直这么说。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeEsgError } from '@/app/safety/esgErrorCodes'

export async function fileConcern(input: { subject: string; details: string; concernsCco: boolean | null }): Promise<{ error?: string }> {
    if (input.concernsCco === null) return { error: await localizeEsgError('WHISTLEBLOWING_CONCERNS_CCO_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('whistleblowing_report_file', { p_subject: input.subject, p_details: input.details, p_concerns_cco: input.concernsCco })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/me')
    return {}
}
