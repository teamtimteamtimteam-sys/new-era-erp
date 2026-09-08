'use server'

// PUR-1:把一张采购单挂到一份合同之下。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【这一刀在这里建的是【门】,不是【机器】—— 机器 CONTRACT-1 已经建好了】★★
// ════════════════════════════════════════════════════════════════════════════
//   委托书原话是"这不是一个打印改动:那条链接要先建得出来,才印得出来"。
//   量下来(2026-09-08):**链接本身早就建得出来**——
//   link_document_to_contract 是 SECURITY DEFINER,把在效条款【当场抄下来】,
//   而委托书点名要的三条拒绝【一条不缺、而且都已经有名字】:
//     · CONTRACT_NOT_ACTIVE            —— 草稿(以及已终止/已过期/已暂停)的合同
//     · CONTRACT_SIDE_MISMATCH         —— 一份销售合同背不起一张采购单
//     · CONTRACT_COUNTERPARTY_MISMATCH —— 合同是这家、单据是那家
//   fixture 147 已经把其中两条钉在活的函数上。
//   **真正一个都没有的,是【屏幕】** —— 全仓库没有任何一处调用它(实测:app/ 与
//   lib/ 里零处)。所以本文件短得几乎不像一刀活,而那正是量出来的结论。
//
// ★【不改挂、不解挂 —— 而这是一次裁定,不是一次省略】★(Tim 2026-09-08,Q5)
//   DOCUMENT_ALREADY_UNDER_CONTRACT 已经在函数里按名拒:改挂等于把一张单据
//   当初依据的条款换掉,而那是改历史。所以这里【只有挂上去这一个动作】。
//   拒绝原样翻译成一句人话摆出来,好让一次挂错【被读懂】,而不是被反复重试。
//   要解挂,先要有一次裁定:那份已经抄下来的条款副本怎么办。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeContractError } from '@/app/contracts/contractErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type LinkContractState = { error?: string }

export async function linkOrderToContract(
    poId: string,
    _prev: LinkContractState,
    formData: FormData
): Promise<LinkContractState> {
    const contractId = String(formData.get('contract_id') ?? '').trim()
    // 【没选就什么也不做】—— 不是一个错误,是一次没有内容的提交。
    if (!contractId) return {}

    const supabase = await createClient()
    const { error } = await supabase.rpc('link_document_to_contract', {
        p_document_kind: 'purchase_order',
        p_document_id: poId,
        p_contract_id: contractId,
    })

    // 【判据一个都不在这里重抄】合同是不是 active、对手方对不对得上、是不是
    // 已经挂过 —— 三条都在 link_document_to_contract 里,而且必须与【抄写】
    // 在同一笔事务里(分两步之间那道缝,足够让一份刚被改成 terminated 的合同
    // 把条款抄出去)。这里只负责把那句拒绝翻译成人话。
    if (error) {
        // ★【PERMISSION_DENIED 在这里接,不在共用的 localizer 里】★
        //   link_document_to_contract 自己查权限,而且【按合同归属那一侧查】:
        //   买方合同要 module.suppliers.edit。一个只有采购权限的人按下这个钮,
        //   拿到的就是 `PERMISSION_DENIED|module.suppliers.edit` 这一串原文。
        //   共用的 localizer 接不了它 —— 那句话("你没有权限把单据挂到合同上")
        //   在创建合同那条路上是答非所问,而两条路共用同一个 localizer。
        //   所以接在【知道上下文的这一处】(与 purchasingErrorCodes 把
        //   PERMISSION_DENIED 映到"签发受限"是同一个形状)。
        if (error.message?.trim().startsWith('PERMISSION_DENIED')) {
            const t = await getTranslations()
            const code = error.message.trim().split('|')[1] ?? ''
            return { error: t('contracts.errors.PERMISSION_DENIED', { 0: code }) }
        }
        return { error: await localizeContractError(error.message) }
    }

    revalidatePath(`/purchasing/orders/${poId}`)
    revalidatePath('/contracts')
    return {}
}
