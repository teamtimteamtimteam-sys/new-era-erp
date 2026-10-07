'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import type { Database, Json } from '@/lib/database.types'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '../../errorCodes'

// FIN-25:投料双亲 —— 恰一非空(服务端 XOR 与守卫触发器双重把关)
export type InputRow = {
    inbound_batch_id?: string
    output_batch_id?: string
    quantity_consumed: number
}

// MES-4a(Q24–Q25):一条产出腿【恰好】带一次称重 —— weighing_id(挑一条现成的)或 weight_kg(+ 可选 device_id,
// 在提交的同一笔事务里记成一次手工称重)。腿的数量就是那次称重的公斤数,所以不再送 quantity;单位只能是 kg。
export type OutputRow = {
    material_id: string
    unit: string
    purity: string | null
    weighing_id?: string
    weight_kg?: number
    device_id?: string | null
}

export type CommitProcessingPayload = {
    process_date: string
    notes: string | null
    inputs: InputRow[]
    outputs: OutputRow[]
    /** FIN-36:成本分摊基准 —— 表单显式选择,DB 侧必填 */
    allocation_basis: string
    /** WO-1c:照哪一张工单做的。【可选】—— 临时起意的加工是合法的,
     *  必填换不来纪律,换来一堆事后补的假工单(见 commit_processing_run 的函数头)。*/
    work_order_id?: string | null
    /** UNBLOCK-1 Q21:这一炉用了【哪台机器】。【可选】—— 空 = 未记录。
     *  MES-4a 会把它改成必填;今天不拦。存在性 / 已购入 / 未处置三条由
     *  commit_processing_run 判(EQUIPMENT_NOT_FOUND / _NOT_ACQUIRED / _DISPOSED)。 */
    equipment_id?: string | null
    /** PROC-WIRE-1B-i:这一炉跑的是【哪一道工序】。
     *  界面必填;**数据库【不】拦** —— 线上 13 张历史单没有工序,而它们是测试残留,
     *  一条 NOT NULL 会把它们就地冻住。那个缺口是具名的,见
     *  docs/proc-operations-wired.md,不要在这里发明一条约束把它补上。 */
    operation_type_code?: string | null
    /** MES-4a(Q7–Q8):开始 / 结束(带时区的 ISO)与班次 —— 新单必填,三条拒绝在服务端(RUN_TIMES_REQUIRED / RUN_SHIFT_REQUIRED …)。 */
    started_at: string | null
    ended_at: string | null
    shift_code: string | null
    /** MES-4a(Q16):照哪一个配方版本做的(可选)。 */
    recipe_version_id: string | null
    /** MES-4a(Q11):不是照配方的那些值 —— { 字段代号: 值 }。 */
    values: Record<string, unknown> | null
    /** MES-4a(Q31):这一炉更正的那张已回滚的单。 */
    corrects_run_id: string | null
}

export type CommitProcessingState = { error?: string }

export async function commitProcessingRun(
    payload: CommitProcessingPayload
): Promise<CommitProcessingState> {
    const supabase = await createClient()

    // 【必填】这个日期决定过账期间/取哪天的汇率 —— 界面禁用是第一道,这是第二道:
    // 绕过界面也进不去。函数侧的 CURRENT_DATE 默认值已由 FIN-10 一并删除。
    if (!payload.process_date) return { error: (await getTranslations())('processing.errProcessDateRequired') }
    // MES-4a(Q17):损耗由数据库算(投入 − 产出)—— 这里不送;送一个不一样的数会被按名拒(LOSS_QTY_NOT_INPUT_MINUS_OUTPUT)。
    const lossNotSent = null as number | null
    const { error } = await supabase.rpc('commit_processing_run', {
        p_process_date: payload.process_date,
        p_notes: payload.notes,
        p_loss_qty: lossNotSent,
        p_inputs: payload.inputs,
        p_outputs: payload.outputs,
        // FIN-36:基准显式送上去 —— DB 侧必填(ALLOCATION_BASIS_REQUIRED),
        // 界面禁用不是唯一一道关,绕过界面也进不去。
        p_allocation_basis: payload.allocation_basis,
        // WO-1c:空就是空 —— 服务端那一支只在给了值的时候才存在,
        // 而它的两条拒绝(WO_NOT_FOUND / WO_NOT_RELEASED)仍然是权威。
        p_work_order_id: payload.work_order_id || null,
        // UNBLOCK-1 Q21:空就是"未记录",与工单同形;三条拒绝在服务端。
        p_equipment_id: payload.equipment_id || null,
        // PROC-WIRE-1B-i:工序决定这一炉【吃不吃料、产不产批】,以及那道
        // 【起火】闸受理哪些安全状态。
        // ★【PROC-SUPPORT-1:它现在是【必填】的,上面那句"空 = 今天的行为
        //   (may_be_fed)"已经不成立,所以那句话被删掉而不是留着】★
        //   —— 空会被 commit_processing_run 按名拒(OPERATION_TYPE_REQUIRED)。
        //   界面早就必填(下拉不预选),这里仍然把它原样送上去而【不】在客户端
        //   拦截:与 process_date / allocation_basis 同一条 —— 界面是第一道,
        //   函数是权威的那一道,绕过界面也进不去。
        p_operation_type_code: payload.operation_type_code || null,
        // MES-4a:空就送空 —— 必填的那三样由服务端按名拒,界面禁钮只是第一道。
        p_started_at: payload.started_at || null,
        p_ended_at: payload.ended_at || null,
        p_shift_code: payload.shift_code || null,
        p_recipe_version_id: payload.recipe_version_id || null,
        p_values: (payload.values ?? null) as Json,
        p_corrects_run_id: payload.corrects_run_id || null,
    } as Database['public']['Functions']['commit_processing_run']['Args'])

    if (error) {
        return { error: await localizeProcessingError(error.message) }
    }

    revalidatePath('/operation/processing')
    revalidatePath('/operation/orders') // WO-1c:完成度是读出来的,列表要重算
    revalidatePath('/inbound') // 库存被消耗
    revalidatePath('/output')  // 产生新产出批次
    if (payload.corrects_run_id) revalidatePath(`/operation/processing/${payload.corrects_run_id}`)
    redirect('/operation/processing')
}
