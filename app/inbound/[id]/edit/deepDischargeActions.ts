'use server'

// PROC-1B-iii(R2):把【实际到的货能不能深度放电】记在进料批上。
//
// ★★【它与采购行上那个判断是【两个都活着的值】,谁也不覆盖谁】★★
//   记下这里,【不会】去改采购行上买的时候下的那个判断 —— 反之亦然。
//   两者不一致是要被【看见】的:那正是拿去跟供应商谈的东西,
//   由 grn_discrepancies 报成 deep_discharge_contradicted。
//   **所以这支 action 只写一列,绝不"顺手把采购行也对齐"。**
//
// ★【R3:它不拦任何东西】★ 记一个与判断矛盾的实际【必须成功】。
//   拦住它只会让操作员回头去改那个判断,把证据抹掉 —— fixture 168 钉着这一条。
//
// 【空串 = 清掉这条轴】而"看过了但说不上来"要选 not_assessed:
//   那是一个**记下来的事实**,不是一个空值。两者在库里是两个不同的东西。
//
// 【写入的门】inbound_batches 的 UPDATE 策略(module.inbound.edit)——
//   看货的人就是收货的人。不包 RPC:这条轴没有守卫要执行,而给一件没有规则
//   要守的事包一支 DEFINER 函数,会让下一个人以为那里有一条规则。

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export async function setDeepDischargeActual(
    batchId: string,
    code: string,
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const t = await getTranslations()
    const { error } = await supabase
        .from('inbound_batches')
        .update({ deep_discharge_actual_code: code === '' ? null : code })
        .eq('id', batchId)
    if (error) {
        if (/row-level security|42501/i.test(error.message)) {
            return { error: t('inbound.deepDischarge.errors.NOT_PERMITTED') }
        }
        return { error: error.message }
    }
    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath('/purchasing/discrepancies')
    return {}
}
