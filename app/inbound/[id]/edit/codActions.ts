'use server'

// COD-1:销毁证书的作废入口。
// 【签发【不】走 server action】—— 它要渲染 PDF 并把字节存进桶,而那是路由的事
// (app/inbound/[id]/cod/pdf/route.tsx 的 POST)。面板直接 fetch 它。
// 作废不产生任何字节,所以它走 action,与其他面板同形。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeCodError } from '@/app/inbound/codErrorCodes'

export async function voidCertificate(
    batchId: string, codId: string, reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('void_cod', { p_cod_id: codId, p_reason: reason })
    if (error) return { error: await localizeCodError(error.message) }
    revalidatePath(`/inbound/${batchId}/edit`)
    return {}
}
