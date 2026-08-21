'use server'

// PROC-2b:安全状态(多值)与化学体系确定度的写入。
//
// 【直连表 + RLS,没有 RPC】两张目标都带策略:
//   * inbound_batches 的 UPDATE 策略是 module.inbound.edit(实测);
//   * inbound_batch_safety_states 的 INSERT/DELETE 策略同上。
// 【读走遮蔽视图,写走表】—— inbound_batches 是遮蔽表,读它必须经
// inbound_batches_masked(S2);而写没有遮蔽这回事,策略就是门。
//
// 【多值的写法:整组替换,不做增量】收货的人心里有的是"这批货【现在】是什么状态"
// 这一整件事,不是"加一个/减一个"。整组替换让屏幕上看到的与库里存的永远一致;
// 增量写法则要求两边对同一个起点达成一致 —— 而那个起点会过期。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeMaterialError } from '@/app/materials/materialErrorCodes'

const CERTAINTY_UNCHOSEN = '__unchosen__'

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

    // 【整组替换】先删后插。两步之间失败会留下一个空集,而空集的意思是
    // "没有人记过" —— 那与真相(有人记过、只是没存上)不一样。
    // **这是一个已知的窄窗口,写在这里而不是假装它不存在**:两张表的写入
    // 没有共同的事务(PostgREST 一次一条语句)。要它原子,就要一个 RPC,
    // 而那是 PROC-2c 顺手做的事(它本来就要改那两个 RPC 的签名)。
    const del = await supabase.from('inbound_batch_safety_states')
        .delete().eq('inbound_batch_id', input.batchId)
    if (del.error) return { error: await localizeMaterialError(del.error.message) }

    if (input.safetyStates.length > 0) {
        const ins = await supabase.from('inbound_batch_safety_states')
            .insert(input.safetyStates.map((code) => ({
                inbound_batch_id: input.batchId, safety_state_code: code,
            })) as never)
        if (ins.error) return { error: await localizeMaterialError(ins.error.message) }
    }

    revalidatePath(`/inbound/${input.batchId}/edit`)
    revalidatePath('/inbound')
    return { success: true }
}
