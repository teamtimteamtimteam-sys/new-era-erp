'use server'

// COMM-1:佣金协议的写入口。
//
// 【为什么是直连 + RLS,而不是一支 RPC】本表【不过账、不算账】——
// 没有任何跨表的不变量要在一笔事务里守住,所以一支 RPC 只会是 INSERT 的
// 一层转写。把关的是 RLS(module.suppliers.edit)与表自己的约束,
// 而拒绝的句子由 commissionErrorCodes.ts 逐条接上(两种到达方式都接了)。
//
// ★【recognition_trigger 永不代填】★ 表单不给它默认值,这里也不 COALESCE ——
//   空就让它撞 NOT NULL,然后按名说话。给它一个默认值等于系统替一个
//   没有人签过的商业立场做主,而那个立场决定确认期间(FIN-10 一族)。

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeCommissionError } from './commissionErrorCodes'

export type CommissionInput = {
    id?: string
    agent_supplier_id: string
    side: string
    basis: string
    rate_pct: string
    amount_ccy: string
    currency: string
    recognition_trigger: string
    valid_from: string
    valid_to: string
    remarks: string
}

// 【空字符串永不喂给库】—— docs/empty-string-to-rpc-audit.md 那一族。
// '' 与 NULL 是两件事,而一个空表单格子的意思是【没说】,不是【零】。
const orNull = (v: string) => (v.trim() === '' ? null : v.trim())
const numOrNull = (v: string) => (v.trim() === '' ? null : Number(v))

export async function saveCommissionAgreement(input: CommissionInput) {
    const supabase = await createClient()
    // ★【接住 auth 的 error —— 丢掉它,「认证够不着」与「这个人没登录」就走同一条分支】★
    //   判据与实测表在 lib/supabase/middleware.ts 的抬头(SESSION-1)。
    //   这里【不放行】判断不出的那一类:created_by / updated_by 是审计事实,
    //   而一次认证故障若被当成"没登录",写下去的就是一行【作者不明】的协议 ——
    //   那正是本仓库反复点名的"一次瞬时故障与一次真实否定长得一样"。
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError) {
        return { error: await localizeCommissionError(authError.name === 'AuthRetryableFetchError'
            ? 'COMMISSION_AUTH_UNAVAILABLE'
            : 'COMMISSION_NOT_PERMITTED') }
    }

    // ★★【服务端【独立地】拒空 —— 这是 AGENTS.md 那条"两道闸"的第二道】★★
    //   第一道是表单上那个禁用的提交按钮;第二道是这里。**绕开界面也发不出去。**
    //   `recognition_trigger` 尤其要紧:它决定这笔成本落在哪个期间,
    //   而本仓库对"决定期间的值"的规矩是【必填、永不默认】(FIN-10 一族)。
    //   **第三道仍然在库上**(NOT NULL + 无默认值),fixture 150A 钉的就是那一道;
    //   这里先拒,只是为了让人看到一句话,而不是一句 'null value in column …'。
    if (orNull(input.recognition_trigger) === null) {
        return { error: await localizeCommissionError('COMMISSION_TRIGGER_REQUIRED') }
    }
    if (orNull(input.valid_from) === null || orNull(input.valid_to) === null) {
        return { error: await localizeCommissionError('COMMISSION_VALIDITY_REQUIRED') }
    }

    // 按口径决定填哪一格 —— 与表上的 CHECK 同一条规矩,在这里【也】说一遍,
    // 是为了不把一个明明能在浏览器里说清楚的错误留给约束去报。
    // 【但约束仍然是那道闸】:这里少写一句,库那一侧照样拒。
    const isPct = input.basis === 'percentage_of_value'

    const row = {
        agent_supplier_id: input.agent_supplier_id,
        side: input.side,
        basis: input.basis,
        rate_pct: isPct ? numOrNull(input.rate_pct) : null,
        amount_ccy: isPct ? null : numOrNull(input.amount_ccy),
        currency: isPct ? null : orNull(input.currency),
        // ★ 不 COALESCE、不给默认值 —— 上面已经按名拒过空值,所以到这里它一定非空。
        //   (库上的 NOT NULL 仍然是最后那道闸,fixture 150A 钉着它。)
        recognition_trigger: input.recognition_trigger.trim(),
        valid_from: input.valid_from.trim(),
        valid_to: input.valid_to.trim(),
        remarks: orNull(input.remarks),
        updated_by: user?.id ?? null,
    }

    const { error } = input.id
        ? await supabase.from('commission_agreements').update(row).eq('id', input.id)
        : await supabase.from('commission_agreements').insert({ ...row, created_by: user?.id ?? null })

    if (error) {
        return { error: await localizeCommissionError(error.message) }
    }

    revalidatePath('/commissions')
    return { success: true }
}

export async function softDeleteCommissionAgreement(id: string) {
    const supabase = await createClient()
    // 同上 —— 软删也写 updated_by,同一条理由。
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError) {
        return { error: await localizeCommissionError(authError.name === 'AuthRetryableFetchError'
            ? 'COMMISSION_AUTH_UNAVAILABLE'
            : 'COMMISSION_NOT_PERMITTED') }
    }

    const { error } = await supabase
        .from('commission_agreements')
        .update({ deleted_at: new Date().toISOString(), updated_by: user?.id ?? null })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删

    if (error) {
        return { error: await localizeCommissionError(error.message) }
    }

    revalidatePath('/commissions')
    return { success: true }
}
