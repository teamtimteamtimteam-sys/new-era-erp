'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { refuseFromDriver, refuseNothingChanged, type ActionOutcome } from '@/lib/action-refusal'

export async function softDeleteSupplier(id: string): Promise<ActionOutcome> {
    const supabase = await createClient()

    const { data, error } = await supabase
        .from('suppliers')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删
        // ★★【ALERT-1:没有这一行 select,一次被 RLS 挡下的删除会报告成功】★★
        //   本表的 UPDATE 策略是 USING(p) WITH CHECK(p),两侧同一个谓词 ——
        //   不满足 p 的人先卡在 USING 上,那一行【根本没被匹配到】:
        //   零行、不抛异常、error 为 null。实测(活库,无编辑权的真账号,
        //   BEGIN…ROLLBACK):rows=0 raised=NONE。
        //   于是这里从前 return { success: true },页面照常刷新,记录纹丝不动,
        //   而屏幕上一个字都没有 —— 那正是 alert() 永远等不到的那一支。
        .select('id')

    if (error) {
        // ALERT-1:原文不做标题 —— 换成一句说得出下一步的话,原文降级进 detail。
        return await refuseFromDriver(error.message)
    }

    // ★ 零行落地 = 什么都没改。**这不是成功。** 见上面 .select('id') 的注释。
    if (!data || data.length === 0) {
        return await refuseNothingChanged('module.suppliers.edit')
    }

    revalidatePath('/suppliers')
    return { success: true }
}