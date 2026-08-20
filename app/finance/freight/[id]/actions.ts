'use server'

// LOG-4b:运费单冲销的服务端动作。
//
// 【这里不判任何东西】理由是否为空、单据是否已冲销、是否被付过款,全部由
// reverse_freight_document 判 —— 它才是权威。ReasonPrompt 的禁用按钮只是不让人
// 白跑一趟;绕过界面直接调 RPC 照样会撞上同一族具名拒绝。
// **两层不是重复**:一层管体验,一层管事实(app/components/ReasonPrompt.tsx 的注释)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeFreightError } from '../../freightErrorCodes'

export async function reverseFreight(
    id: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    // 【理由原样送下去,不在这里 trim 成 null】—— 服务端的判据是
    // `p_reason IS NULL OR btrim(p_reason) = ''`,它自己会 btrim。
    // 在这里先"整理"一遍,等于把权威搬到页面上,而两份判据会漂开。
    // 【先把箱子读出来,再冲销】—— reverse_freight_document 的返回值里【没有】
    // container_id(它两个方向共用,进货侧根本没有箱子)。冲销之后再读也拿得到,
    // 但那时已经多一次往返;更要紧的是:凭空假设返回值里有那一列,就是把
    // 一个"看起来像答案的东西"当成答案。
    const before = await supabase
        .from('freight_documents').select('container_id').eq('id', id).maybeSingle()
    const containerId = (before.data?.container_id as string | null) ?? null

    const { error } = await supabase.rpc('reverse_freight_document', {
        p_freight_document_id: id,
        p_reason: reason,
    })
    if (error) return { error: await localizeFreightError(error.message) }

    revalidatePath('/finance/freight')
    revalidatePath(`/finance/freight/${id}`)
    revalidatePath('/finance/payables')
    // 冲销之后那个箱子的运费面板也变了 —— 它读的是同一批单据
    if (containerId) revalidatePath(`/logistics/containers/${containerId}`)
    return {}
}
