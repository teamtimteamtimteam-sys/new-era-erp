'use server'

// PROC-2b:安全状态(多值)与化学体系确定度的写入。
// PROC-2c:整组写从【先删后插两条语句】改成【一个 RPC】。
//
// ════════════════════════════════════════════════════════════════════════════
// 【那扇窗是什么,以及为什么它必须关】
//
// PostgREST 一次一条语句,两条语句之间没有共同的事务。所以 PROC-2b 的
//     delete(整组) → insert(新的一组)
// 在 delete 成功、insert 失败时会留下一个【空集】—— 而这张表的表注写着:
// **一条安全状态都没有 ≠ 安全,它的意思是"没有人记过"。**
// 也就是说那一刻库里存着的不是"写了一半",而是一句【意思完全不同的真话】,
// 而且没有任何东西会说它是失败的残骸。
//
// 【现在】set_inbound_safety_states 在一个函数体里删+插 —— **一个函数体对调用方
// 永远是原子的**:要么整组换成新的,要么原样不动(旧的一组原封不动留着)。
// 这不是"更整洁",是把一个能产生【错误意思】的中间态从系统里去掉。
//
// 【确定度那一列仍然是直连表 UPDATE】它是 inbound_batches 上的一列,一条语句
// 自己就是原子的,不需要 RPC。**两次写之间仍然没有共同事务** —— 确定度写成了、
// 安全状态整组失败,是可能的;但那时【两边各自都是完整的】,没有哪一边落在
// 一个意思错了的中间态上。这与上面那扇窗是两回事,写在这里免得被读成还没修完。
//
// 【读走遮蔽视图,写走表】—— inbound_batches 是遮蔽表,读它必须经
// inbound_batches_masked(S2);而写没有遮蔽这回事,策略就是门。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeMaterialError } from '@/app/materials/materialErrorCodes'
import { CERTAINTY_UNCHOSEN } from '@/app/inbound/IntakeConditionFields'

export type IntakeConditionState = { error?: string; success?: boolean }

export async function setIntakeCondition(input: {
    batchId: string
    safetyStates: string[]
    certainty: string
}): Promise<IntakeConditionState> {
    const supabase = await createClient()

    // 【确定度:哨兵 → NULL】NULL 的意思是"没有人记过",而那是一个真话,
    // 不是"未知待识别"(后者是一个【被记下来的】判断,它自己是一个取值)。
    const certainty =
        input.certainty === CERTAINTY_UNCHOSEN || input.certainty.trim() === ''
            ? null
            : input.certainty
    const upd = await supabase.from('inbound_batches')
        .update({ chemistry_certainty_code: certainty } as never)
        .eq('id', input.batchId)
    if (upd.error) return { error: await localizeMaterialError(upd.error.message) }

    // 【整组替换,一笔写完】空数组【也要传】—— "全部取消勾选"是一个正当的动作
    // (记错了要能撤回),它的意思是把这批货退回"没有人记过"。不传就成了"不动它"。
    const { error } = await supabase.rpc('set_inbound_safety_states', {
        p_inbound_batch_id: input.batchId,
        p_codes: input.safetyStates,
    })
    if (error) return { error: await localizeMaterialError(error.message) }

    revalidatePath(`/inbound/${input.batchId}/edit`)
    revalidatePath('/inbound')
    return { success: true }
}
