'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import type { Database } from '@/lib/database.types'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '../errorCodes'

// FIN-25:投料双亲 —— 恰一非空(服务端 XOR 与守卫触发器双重把关)
export type InputRow = {
    inbound_batch_id?: string
    output_batch_id?: string
    quantity_consumed: number
}

export type OutputRow = {
    material_id: string
    quantity: number
    unit: string
    purity: string | null
}

export type CommitProcessingPayload = {
    process_date: string
    notes: string | null
    loss_qty: number | null
    inputs: InputRow[]
    outputs: OutputRow[]
    /** FIN-36:成本分摊基准 —— 表单显式选择,DB 侧必填 */
    allocation_basis: string
    /** WO-1c:照哪一张工单做的。【可选】—— 临时起意的加工是合法的,
     *  必填换不来纪律,换来一堆事后补的假工单(见 commit_processing_run 的函数头)。*/
    work_order_id?: string | null
    /** PROC-WIRE-1B-i:这一炉跑的是【哪一道工序】。
     *  界面必填;**数据库【不】拦** —— 线上 13 张历史单没有工序,而它们是测试残留,
     *  一条 NOT NULL 会把它们就地冻住。那个缺口是具名的,见
     *  docs/proc-operations-wired.md,不要在这里发明一条约束把它补上。 */
    operation_type_code?: string | null
}

export type CommitProcessingState = { error?: string }

export async function commitProcessingRun(
    payload: CommitProcessingPayload
): Promise<CommitProcessingState> {
    const supabase = await createClient()

    // 【必填】这个日期决定过账期间/取哪天的汇率 —— 界面禁用是第一道,这是第二道:
    // 绕过界面也进不去。函数侧的 CURRENT_DATE 默认值已由 FIN-10 一并删除。
    if (!payload.process_date) return { error: (await getTranslations())('processing.errProcessDateRequired') }
    const { error } = await supabase.rpc('commit_processing_run', {
        p_process_date: payload.process_date,
        p_notes: payload.notes,
        p_loss_qty: payload.loss_qty,
        p_inputs: payload.inputs,
        p_outputs: payload.outputs,
        // FIN-36:基准显式送上去 —— DB 侧必填(ALLOCATION_BASIS_REQUIRED),
        // 界面禁用不是唯一一道关,绕过界面也进不去。
        p_allocation_basis: payload.allocation_basis,
        // WO-1c:空就是空 —— 服务端那一支只在给了值的时候才存在,
        // 而它的两条拒绝(WO_NOT_FOUND / WO_NOT_RELEASED)仍然是权威。
        p_work_order_id: payload.work_order_id || null,
        // PROC-WIRE-1B-i:工序决定这一炉【吃不吃料、产不产批】,以及那道
        // 【起火】闸受理哪些安全状态。空 = 今天的行为(may_be_fed)。
        p_operation_type_code: payload.operation_type_code || null,
    } as Database['public']['Functions']['commit_processing_run']['Args'])

    if (error) {
        return { error: await localizeProcessingError(error.message) }
    }

    revalidatePath('/processing')
    revalidatePath('/processing/orders') // WO-1c:完成度是读出来的,列表要重算
    revalidatePath('/inbound') // 库存被消耗
    revalidatePath('/output')  // 产生新产出批次
    redirect('/processing')
}
